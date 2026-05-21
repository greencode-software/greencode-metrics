#!/usr/bin/env bash
# Onboarding idempotente de un proyecto SonarCloud al stack DevLake de Greencode.
# Hace, en este orden y de forma re-ejecutable:
#   1. valida que el token tenga acceso a SonarCloud
#   2. fetch metadata del proyecto SonarCloud (name, visibility)
#   3. crea o actualiza la connection sonarqube en DevLake
#   4. upsertea el scope (projectKey) en esa connection
#   5. asegura que exista el project DevLake (no lo crea si ya existe)
#   6. mergea el bloque sonarqube en el blueprint del project (preservando github, etc.)
#   7. dispara un pipeline manual (POST /pipelines) con SOLO las subtasks
#      necesarias del plugin sonarqube y polea hasta TASK_COMPLETED. No usa
#      POST /blueprints/{id}/trigger porque ese arrastra subtasks default que
#      en nuestro flujo no son necesarias y pueden errorear.
#
# Uso:
#   scripts/onboard-sonarcloud-project.sh [opciones] <devlake-project> <sonar-project-key>
#
# Opciones de token (mutuamente excluyentes):
#   --token-env VARNAME    leer token desde env var $VARNAME (no aparece en argv)
#   --token-file PATH      leer token desde archivo (chmod 600 recomendado)
#   (sin flag)             fallback a $SONAR_TOKEN si esta seteada
#
# Ejemplos:
#   # local, token en env var:
#   SONAR_TOKEN_GREENCODE=558... SONARCLOUD_ORG=greencode-software \
#     scripts/onboard-sonarcloud-project.sh --token-env SONAR_TOKEN_GREENCODE \
#       agrored-frontend agrored-frontend
#
#   # prod, detras de Caddy basic auth:
#   DEVLAKE_API='https://api.devlake.greencodesoftware.com/api' \
#   DEVLAKE_BASIC_AUTH='greencode:<pass>' \
#   SONARCLOUD_ORG=greencode-software \
#     scripts/onboard-sonarcloud-project.sh --token-file ~/.greencode/tokens/sonarcloud \
#       agrored-frontend agrored-frontend
#
# Env vars:
#   DEVLAKE_API=http://localhost:8088     (default)
#   DEVLAKE_BASIC_AUTH=user:pass          (cuando la API esta detras de Caddy)
#   SONARCLOUD_ORG=greencode-software     (required; SonarCloud organization key)
#   SONARCLOUD_ENDPOINT=https://sonarcloud.io/api  (default; util para SonarQube self-hosted)
#
# Requisitos: curl, jq, python3. El token nunca se imprime, nunca pasa por argv,
# solo por stdin/env de subshells. Se encripta server-side por DevLake con
# ENCRYPTION_SECRET al persistirse en MySQL.

set -euo pipefail

# ---------- args ----------
TOKEN_SOURCE="env"             # env | file
TOKEN_SOURCE_REF="SONAR_TOKEN" # default env var si no se pasa flag

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --token-env)
      [[ -n "${2:-}" ]] || { echo "--token-env requiere VARNAME" >&2; exit 64; }
      TOKEN_SOURCE="env"; TOKEN_SOURCE_REF="$2"; shift 2 ;;
    --token-file)
      [[ -n "${2:-}" ]] || { echo "--token-file requiere PATH" >&2; exit 64; }
      TOKEN_SOURCE="file"; TOKEN_SOURCE_REF="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,35p' "$0"; exit 0 ;;
    --) shift; break ;;
    -*) echo "flag desconocido: $1" >&2; exit 64 ;;
    *)  break ;;
  esac
done

if [[ $# -ne 2 ]]; then
  echo "uso: $0 [--token-env VAR | --token-file PATH] <devlake-project> <sonar-project-key>" >&2
  exit 64
fi
PROJECT_NAME="$1"
SONAR_KEY="$2"

DEVLAKE_API="${DEVLAKE_API:-http://localhost:8088}"
SONARCLOUD_ENDPOINT="${SONARCLOUD_ENDPOINT:-https://sonarcloud.io/api}"
SONARCLOUD_ORG="${SONARCLOUD_ORG:-}"
CONN_NAME="${PROJECT_NAME}-sonarcloud"

# ---------- helpers ----------
log()  { printf "\n\033[1;34m→\033[0m %s\n" "$*" >&2; }
ok()   { printf "  \033[1;32m✓\033[0m %s\n" "$*" >&2; }
warn() { printf "  \033[1;33m!\033[0m %s\n" "$*" >&2; }
err()  { printf "  \033[1;31m✗\033[0m %s\n" "$*" >&2; }

# token_pipe: imprime el token al stdout. Para uso unico, siempre via pipe.
# Nunca lo asigna a una variable persistente, nunca lo logea.
token_pipe() {
  case "$TOKEN_SOURCE" in
    env)
      local v="${!TOKEN_SOURCE_REF:-}"
      [[ -n "$v" ]] || { err "env var \$$TOKEN_SOURCE_REF esta vacia"; exit 1; }
      printf '%s' "$v" ;;
    file)
      [[ -r "$TOKEN_SOURCE_REF" ]] || { err "no se puede leer $TOKEN_SOURCE_REF"; exit 1; }
      tr -d '[:space:]' < "$TOKEN_SOURCE_REF" ;;
  esac
}

# sc_api PATH [extra curl args]: GET contra la API de SonarCloud usando el token activo.
# SonarCloud acepta el token como username en HTTP Basic (password vacia).
# El token entra al subshell por stdin (no argv, no env del shell padre).
sc_api() {
  local path="$1"; shift || true
  token_pipe | { read -r T; curl -fsS -u "$T:" "$@" "$SONARCLOUD_ENDPOINT/$path"; }
}

# dl_curl: wrapper de curl para la API de DevLake. Inyecta basic auth si
# $DEVLAKE_BASIC_AUTH esta seteado (formato user:pass).
dl_curl() {
  if [[ -n "${DEVLAKE_BASIC_AUTH:-}" ]]; then
    curl -fsS -u "$DEVLAKE_BASIC_AUTH" "$@"
  else
    curl -fsS "$@"
  fi
}

require() {
  for bin in "$@"; do
    command -v "$bin" >/dev/null 2>&1 || { err "falta binario requerido: $bin"; exit 127; }
  done
}

# ---------- 1. preflight ----------
log "Preflight"
require curl jq python3
[[ -n "$SONARCLOUD_ORG" ]] || { err "SONARCLOUD_ORG no esta seteada (ej: greencode-software)"; exit 64; }
dl_curl "$DEVLAKE_API/projects" >/dev/null \
  || { err "DevLake API no responde en $DEVLAKE_API"; exit 1; }
ok "DevLake responde en $DEVLAKE_API"

# ---------- 2. validar token SonarCloud ----------
log "Validando token contra $SONARCLOUD_ENDPOINT (org=$SONARCLOUD_ORG)"
VALID=$(sc_api "authentication/validate" | jq -r '.valid // false')
if [[ "$VALID" != "true" ]]; then
  err "el token no es valido en $SONARCLOUD_ENDPOINT"
  err "generar uno en https://sonarcloud.io/account/security/ (User Token)"
  exit 1
fi
ok "token valido"

# ---------- 3. metadata del proyecto SonarCloud ----------
log "Fetching metadata de SonarCloud projectKey=$SONAR_KEY"
PROJ_JSON=$(sc_api "projects/search?organization=$SONARCLOUD_ORG&projects=$SONAR_KEY")
SONAR_PROJ=$(jq --arg k "$SONAR_KEY" '.components[]|select(.key==$k)' <<<"$PROJ_JSON")
if [[ -z "$SONAR_PROJ" ]]; then
  err "no se encontro projectKey=$SONAR_KEY en org=$SONARCLOUD_ORG"
  err "verificar https://sonarcloud.io/project/overview?id=$SONAR_KEY"
  exit 1
fi
SONAR_NAME=$(jq -r '.name'       <<<"$SONAR_PROJ")
SONAR_VIS=$(jq -r  '.visibility' <<<"$SONAR_PROJ")
ok "projectKey=$SONAR_KEY name=\"$SONAR_NAME\" visibility=$SONAR_VIS"

# ---------- 4. connection ----------
log "Connection \"$CONN_NAME\""
CONN_ID=$(dl_curl "$DEVLAKE_API/plugins/sonarqube/connections" \
  | jq --arg n "$CONN_NAME" '[.[]|select(.name==$n)][0].id // empty')

if [[ -n "$CONN_ID" ]]; then
  ok "ya existe (id=$CONN_ID) — re-PATCHeando token + endpoint + org"
  CURRENT=$(dl_curl "$DEVLAKE_API/plugins/sonarqube/connections/$CONN_ID")
  CUR_ORG=$(jq -r '.org // ""' <<<"$CURRENT")
  if [[ -n "$CUR_ORG" && "$CUR_ORG" != "$SONARCLOUD_ORG" ]]; then
    warn "org cambia: \"$CUR_ORG\" → \"$SONARCLOUD_ORG\" (re-ingesta puede traer datos nuevos)"
  fi
  token_pipe \
    | jq -Rs --argjson cur "$CURRENT" --arg ep "$SONARCLOUD_ENDPOINT" --arg org "$SONARCLOUD_ORG" \
        '$cur + {token:(.|rtrimstr("\n")), endpoint:$ep, org:$org}' \
    | dl_curl -X PATCH -H 'Content-Type: application/json' \
        -d @- "$DEVLAKE_API/plugins/sonarqube/connections/$CONN_ID" >/dev/null
  ok "connection actualizada (org=$SONARCLOUD_ORG)"
else
  CONN_ID=$(token_pipe \
    | jq -Rs --arg n "$CONN_NAME" --arg ep "$SONARCLOUD_ENDPOINT" --arg org "$SONARCLOUD_ORG" \
        '{name:$n, endpoint:$ep, token:(.|rtrimstr("\n")), org:$org, proxy:"", rateLimitPerHour:0}' \
    | dl_curl -X POST -H 'Content-Type: application/json' -d @- \
        "$DEVLAKE_API/plugins/sonarqube/connections" | jq '.id')
  ok "creada (id=$CONN_ID, org=$SONARCLOUD_ORG)"
fi

# ---------- 5. scope (projectKey) ----------
log "Scope projectKey=$SONAR_KEY en connection $CONN_ID"
SCOPE_PAYLOAD=$(jq -n \
  --argjson cid "$CONN_ID" \
  --arg key "$SONAR_KEY" --arg name "$SONAR_NAME" --arg vis "$SONAR_VIS" \
  '{data:[{connectionId:$cid, projectKey:$key, name:$name, qualifier:"TRK", visibility:$vis}]}')
dl_curl -X PUT -H 'Content-Type: application/json' -d "$SCOPE_PAYLOAD" \
  "$DEVLAKE_API/plugins/sonarqube/connections/$CONN_ID/scopes" >/dev/null
ok "scope upserteado (projectKey=$SONAR_KEY)"

# ---------- 6. project ----------
log "Project \"$PROJECT_NAME\""
if dl_curl -o /dev/null -w '%{http_code}' "$DEVLAKE_API/projects/$PROJECT_NAME" | grep -q '^200$'; then
  ok "ya existe"
else
  warn "no existe — creandolo (recomendado: correr onboard-github-project.sh primero)"
  PROJ_PAYLOAD=$(jq -n --arg n "$PROJECT_NAME" --arg d "Onboarded by onboard-sonarcloud-project.sh" \
    '{name:$n, description:$d, metrics:[{pluginName:"dora", pluginOption:"", enable:true}]}')
  dl_curl -X POST -H 'Content-Type: application/json' -d "$PROJ_PAYLOAD" \
    "$DEVLAKE_API/projects" >/dev/null
  ok "creado"
fi

# ---------- 7. blueprint: mergear nuestra connection ----------
log "Blueprint: bindeando connection→scope al project"
BP_JSON=$(dl_curl "$DEVLAKE_API/blueprints?projectName=$PROJECT_NAME")
BP_ID=$(jq '.blueprints[0].id // empty' <<<"$BP_JSON")
if [[ -z "$BP_ID" ]]; then
  err "no encontre blueprint para project $PROJECT_NAME"; exit 1
fi

# El scopeId del plugin sonarqube ES el projectKey (string), no un id numerico.
# Mergeamos preservando otras connections (github, bitbucket, etc.) y reemplazando
# la entrada sonarqube+connectionId si ya estaba.
NEW_CONN_BLOCK=$(jq -n --argjson cid "$CONN_ID" --arg sid "$SONAR_KEY" \
  '{pluginName:"sonarqube", connectionId:$cid, scopes:[{scopeId:$sid}]}')
PATCH_BODY=$(jq --argjson new "$NEW_CONN_BLOCK" '
  .blueprints[0]
  | .connections = ((.connections // []) | map(select(.pluginName!="sonarqube" or .connectionId!=$new.connectionId)) + [$new])
  | {connections: .connections}
' <<<"$BP_JSON")
dl_curl -X PATCH -H 'Content-Type: application/json' -d "$PATCH_BODY" \
  "$DEVLAKE_API/blueprints/$BP_ID" >/dev/null
ok "blueprint $BP_ID actualizado"

# ---------- 8. trigger pipeline (manual, solo subtasks de sonarqube) ----------
# Disparamos un pipeline manual via POST /pipelines en vez de
# POST /blueprints/{id}/trigger. Motivo: el trigger del blueprint dispara TODAS
# las connections del blueprint (github, bitbucket, sonarqube, etc.), y algunas
# subtasks default del plugin sonarqube no son necesarias para nuestro flujo y
# pueden fallar. Pinneamos el plan al subset que efectivamente queremos correr.
log "Disparando pipeline manual (solo subtasks de sonarqube)"
PIPE_NAME="sonarcloud-onboard-${PROJECT_NAME}-$(date +%s)"
PIPE_PAYLOAD=$(jq -n \
  --argjson bpid "$BP_ID" --argjson cid "$CONN_ID" \
  --arg key "$SONAR_KEY" --arg name "$PIPE_NAME" \
  '{
    blueprintId: $bpid,
    fullSync:    true,
    name:        $name,
    plan: [[
      {
        plugin: "sonarqube",
        subtasks: [
          "CollectAdditionalFilemetrics", "ExtractAdditionalFileMetrics",
          "CollectFilemetrics",           "ExtractFilemetrics",
          "CollectIssues",                "ExtractIssues",
          "CollectHotspots",              "ExtractHotspots",
          "convertProjects",
          "convertIssues",
          "convertIssueImpacts",
          "convertIssueCodeBlocks",
          "convertHotspots",
          "convertFileMetrics"
        ],
        options:    { connectionId: $cid, projectKey: $key },
        skipOnFail: false
      }
    ]]
  }')
PIPE_ID=$(dl_curl -X POST -H 'Content-Type: application/json' \
  -d "$PIPE_PAYLOAD" "$DEVLAKE_API/pipelines" | jq '.id')
ok "pipeline id=$PIPE_ID lanzado ($PIPE_NAME)"

STATUS=""
START=$(date +%s)
while :; do
  STATUS=$(dl_curl "$DEVLAKE_API/pipelines/$PIPE_ID" | jq -r '.status // ""')
  case "$STATUS" in
    TASK_COMPLETED|TASK_FAILED|TASK_PARTIAL|TASK_CANCELLED) break ;;
  esac
  ELAPSED=$(( $(date +%s) - START ))
  printf "  ... %s (%ds)\n" "$STATUS" "$ELAPSED" >&2
  sleep 8
  if (( ELAPSED > 1800 )); then err "timeout >30min esperando pipeline"; exit 1; fi
done

PIPE_INFO=$(dl_curl "$DEVLAKE_API/pipelines/$PIPE_ID")
SPENT=$(jq -r '.spentSeconds'   <<<"$PIPE_INFO")
FIN=$(jq -r   '.finishedTasks'  <<<"$PIPE_INFO")
TOT=$(jq -r   '.totalTasks'     <<<"$PIPE_INFO")

if [[ "$STATUS" != "TASK_COMPLETED" ]]; then
  err "pipeline terminó en estado $STATUS ($FIN/$TOT tasks, ${SPENT}s)"
  warn "ultimas líneas relevantes del container greencode-devlake:"
  docker logs --tail 200 greencode-devlake 2>&1 \
    | grep -iE 'error|forbidden|sonar|fatal|panic' \
    | tail -10 >&2 || true
  exit 1
fi

# ---------- 9. resumen ----------
log "✅ Onboarding SonarCloud completado en ${SPENT}s ($FIN/$TOT tasks)"
echo
echo "  Project:       $PROJECT_NAME"
echo "  SonarCloud:    $SONAR_KEY (org=$SONARCLOUD_ORG)"
echo "  Connection:    id=$CONN_ID  ($CONN_NAME)"
echo "  Blueprint:     id=$BP_ID"
echo "  Pipeline:      id=$PIPE_ID  TASK_COMPLETED"
echo
echo "  Grafana (filtrado a este project):"
echo "    Engineering Overview: http://localhost:3001/d/ZF6abXX7z/engineering-overview?var-project=$PROJECT_NAME"
echo "    SonarQube:            http://localhost:3001/d/sonarqube/sonarqube?var-project=$PROJECT_NAME"
echo
