#!/usr/bin/env bash
# Onboarding idempotente de un repo de GitHub al stack DevLake de Greencode.
#
# Uso:
#   scripts/onboard-github-project.sh <devlake-project> <owner/repo>
#
# Ejemplos:
#   scripts/onboard-github-project.sh tallone-sistema-de-gestion elamonica/tallone
#   scripts/onboard-github-project.sh pinvest-platform           greencode-software/pinvest-api
#
# Env vars opcionales:
#   DEVLAKE_API=http://localhost:8088   (default)
#   ENABLE_GRAPHQL=false                (default; true requiere PAT con scope read:user)
#   TIME_AFTER=2025-11-15T00:00:00Z     (cutoff de history; default = 6 meses atras)
#
# Requisitos: curl, jq, python3, gh (autenticado en github.com), DevLake corriendo.
# El token de gh nunca se imprime ni se inspecciona; se pipea inline al body de curl.

set -euo pipefail

# ---------- args ----------
if [[ $# -ne 2 ]]; then
  echo "uso: $0 <devlake-project> <owner/repo>" >&2
  exit 64
fi
PROJECT_NAME="$1"
OWNER_REPO="$2"
OWNER="${OWNER_REPO%%/*}"
REPO="${OWNER_REPO##*/}"
if [[ -z "$OWNER" || -z "$REPO" || "$OWNER" == "$OWNER_REPO" ]]; then
  echo "owner/repo invalido: $OWNER_REPO" >&2
  exit 64
fi

DEVLAKE_API="${DEVLAKE_API:-http://localhost:8088}"
ENABLE_GRAPHQL="${ENABLE_GRAPHQL:-false}"
TIME_AFTER="${TIME_AFTER:-$(python3 -c 'from datetime import datetime,timedelta,timezone; print((datetime.now(timezone.utc)-timedelta(days=180)).strftime("%Y-%m-%dT00:00:00Z"))')}"
CONN_NAME="${PROJECT_NAME}-github"

# ---------- helpers ----------
log()  { printf "\n\033[1;34m→\033[0m %s\n" "$*" >&2; }
ok()   { printf "  \033[1;32m✓\033[0m %s\n" "$*" >&2; }
warn() { printf "  \033[1;33m!\033[0m %s\n" "$*" >&2; }
err()  { printf "  \033[1;31m✗\033[0m %s\n" "$*" >&2; }

# wrapper para ejecutar gh con el token correcto (env o keyring)
GH_USE_KEYRING="${GH_USE_KEYRING:-}"
gh_call() {
  if [[ -n "$GH_USE_KEYRING" ]]; then GITHUB_TOKEN= gh "$@"; else gh "$@"; fi
}
gh_token_pipe() {
  if [[ -n "$GH_USE_KEYRING" ]]; then GITHUB_TOKEN= gh auth token; else gh auth token; fi
}

require() {
  for bin in "$@"; do
    command -v "$bin" >/dev/null 2>&1 || { err "falta binario requerido: $bin"; exit 127; }
  done
}

# ---------- 1. preflight ----------
log "Preflight"
require curl jq python3 gh
curl -fsS "$DEVLAKE_API/projects" >/dev/null \
  || { err "DevLake API no responde en $DEVLAKE_API"; exit 1; }
ok "DevLake responde en $DEVLAKE_API"

gh auth status -h github.com >/dev/null 2>&1 \
  || { err "gh no esta autenticado (correr: gh auth login)"; exit 1; }
ok "gh autenticado"

# ---------- 2. detectar token con acceso al repo ----------
log "Buscando token gh con acceso a $OWNER_REPO"
if gh api "repos/$OWNER_REPO" --silent 2>/dev/null; then
  ok "usando token activo (GITHUB_TOKEN env)"
elif GITHUB_TOKEN= gh api "repos/$OWNER_REPO" --silent 2>/dev/null; then
  GH_USE_KEYRING=1
  ok "usando token del keyring (gho_*)"
else
  err "ningun token de gh tiene acceso a $OWNER_REPO"
  err "opciones: gh auth refresh -s repo  /  gh auth login  /  crear PAT con scope repo"
  exit 1
fi

# ---------- 3. metadata del repo ----------
log "Fetching metadata de $OWNER_REPO"
REPO_JSON=$(gh_call api "repos/$OWNER_REPO")
GITHUB_ID=$(jq      '.id'           <<<"$REPO_JSON")
OWNER_ID=$(jq       '.owner.id'     <<<"$REPO_JSON")
LANGUAGE=$(jq -r    '.language // ""' <<<"$REPO_JSON")
CLONE_URL=$(jq -r   '.clone_url'    <<<"$REPO_JSON")
HTML_URL=$(jq -r    '.html_url'     <<<"$REPO_JSON")
DEFAULT_BR=$(jq -r  '.default_branch' <<<"$REPO_JSON")
DESCRIPTION=$(jq -r '.description // ""' <<<"$REPO_JSON")
ok "githubId=$GITHUB_ID ownerId=$OWNER_ID lang=$LANGUAGE branch=$DEFAULT_BR"

# ---------- 4. connection ----------
log "Connection \"$CONN_NAME\""
CONN_ID=$(curl -fsS "$DEVLAKE_API/plugins/github/connections" \
  | jq --arg n "$CONN_NAME" '[.[]|select(.name==$n)][0].id // empty')

if [[ -n "$CONN_ID" ]]; then
  ok "ya existe (id=$CONN_ID) — re-PATCHeando token + flags"
  # PATCH exige token; mantenemos el existing payload y solo overrideamos token+enableGraphql
  CURRENT=$(curl -fsS "$DEVLAKE_API/plugins/github/connections/$CONN_ID")
  gh_token_pipe \
    | jq -Rs --argjson cur "$CURRENT" --argjson eg "$ENABLE_GRAPHQL" \
        '$cur + {token:(.|rtrimstr("\n")), enableGraphql:$eg}' \
    | curl -fsS -X PATCH -H 'Content-Type: application/json' \
        -d @- "$DEVLAKE_API/plugins/github/connections/$CONN_ID" >/dev/null
  ok "connection actualizada"
else
  CONN_ID=$(gh_token_pipe \
    | jq -Rs --arg n "$CONN_NAME" --argjson eg "$ENABLE_GRAPHQL" \
        '{name:$n, endpoint:"https://api.github.com/", token:(.|rtrimstr("\n")), proxy:"", rateLimitPerHour:0, authMethod:"AccessToken", enableGraphql:$eg}' \
    | curl -fsS -X POST -H 'Content-Type: application/json' -d @- \
        "$DEVLAKE_API/plugins/github/connections" | jq '.id')
  ok "creada (id=$CONN_ID, enableGraphql=$ENABLE_GRAPHQL)"
fi

# ---------- 5. scope (repo) ----------
log "Scope $OWNER_REPO en connection $CONN_ID"
SCOPE_PAYLOAD=$(jq -n \
  --argjson cid "$CONN_ID" --argjson gid "$GITHUB_ID" --argjson oid "$OWNER_ID" \
  --arg name "$REPO" --arg full "$OWNER_REPO" --arg lang "$LANGUAGE" \
  --arg curl "$CLONE_URL" --arg hurl "$HTML_URL" --arg desc "$DESCRIPTION" \
  '{data:[{connectionId:$cid, githubId:$gid, ownerId:$oid, name:$name, fullName:$full, language:$lang, cloneUrl:$curl, HTMLUrl:$hurl, description:$desc}]}')
curl -fsS -X PUT -H 'Content-Type: application/json' -d "$SCOPE_PAYLOAD" \
  "$DEVLAKE_API/plugins/github/connections/$CONN_ID/scopes" >/dev/null
ok "scope upserteado (name=$REPO, fullName=$OWNER_REPO)"

# ---------- 6. project ----------
log "Project \"$PROJECT_NAME\""
if curl -fsS -o /dev/null -w '%{http_code}' "$DEVLAKE_API/projects/$PROJECT_NAME" | grep -q '^200$'; then
  ok "ya existe"
else
  PROJ_PAYLOAD=$(jq -n --arg n "$PROJECT_NAME" --arg d "Onboarded by onboard-github-project.sh" \
    '{name:$n, description:$d, metrics:[{pluginName:"dora", pluginOption:"", enable:true}]}')
  curl -fsS -X POST -H 'Content-Type: application/json' -d "$PROJ_PAYLOAD" \
    "$DEVLAKE_API/projects" >/dev/null
  ok "creado (con DORA habilitado)"
fi

# ---------- 7. blueprint: mergear nuestra connection ----------
log "Blueprint: bindeando connection→scope al project"
BP_JSON=$(curl -fsS "$DEVLAKE_API/blueprints?projectName=$PROJECT_NAME")
BP_ID=$(jq '.blueprints[0].id // empty' <<<"$BP_JSON")
if [[ -z "$BP_ID" ]]; then
  err "no encontre blueprint para project $PROJECT_NAME"; exit 1
fi

# Mergear (o agregar) nuestra connection en el array existente, preservando otras.
NEW_CONN_BLOCK=$(jq -n --argjson cid "$CONN_ID" --argjson sid "$GITHUB_ID" \
  '{pluginName:"github", connectionId:$cid, scopes:[{scopeId:($sid|tostring)}]}')
PATCH_BODY=$(jq --argjson new "$NEW_CONN_BLOCK" --arg ta "$TIME_AFTER" '
  .blueprints[0]
  | .connections = ((.connections // []) | map(select(.pluginName!="github" or .connectionId!=$new.connectionId)) + [$new])
  | {connections: .connections, timeAfter: $ta}
' <<<"$BP_JSON")
curl -fsS -X PATCH -H 'Content-Type: application/json' -d "$PATCH_BODY" \
  "$DEVLAKE_API/blueprints/$BP_ID" >/dev/null
ok "blueprint $BP_ID actualizado (timeAfter=$TIME_AFTER)"

# ---------- 8. trigger pipeline ----------
log "Disparando pipeline inicial"
PIPE_ID=$(curl -fsS -X POST "$DEVLAKE_API/blueprints/$BP_ID/trigger" | jq '.id')
ok "pipeline id=$PIPE_ID lanzado"

# poll
STATUS=""
START=$(date +%s)
while :; do
  STATUS=$(curl -fsS "$DEVLAKE_API/pipelines/$PIPE_ID" | jq -r '.status // ""')
  case "$STATUS" in
    TASK_COMPLETED|TASK_FAILED|TASK_PARTIAL|TASK_CANCELLED) break ;;
  esac
  ELAPSED=$(( $(date +%s) - START ))
  printf "  ... %s (%ds)\n" "$STATUS" "$ELAPSED" >&2
  sleep 8
  if (( ELAPSED > 1800 )); then err "timeout >30min esperando pipeline"; exit 1; fi
done

PIPE_INFO=$(curl -fsS "$DEVLAKE_API/pipelines/$PIPE_ID")
SPENT=$(jq -r '.spentSeconds' <<<"$PIPE_INFO")
FIN=$(jq -r '.finishedTasks' <<<"$PIPE_INFO")
TOT=$(jq -r '.totalTasks'    <<<"$PIPE_INFO")

if [[ "$STATUS" != "TASK_COMPLETED" ]]; then
  err "pipeline terminó en estado $STATUS ($FIN/$TOT tasks, ${SPENT}s)"
  warn "ultimas líneas relevantes del container greencode-devlake:"
  docker logs --tail 200 greencode-devlake 2>&1 \
    | grep -iE 'error|forbidden|scope|fatal|panic' \
    | tail -10 >&2 || true
  exit 1
fi

# ---------- 9. resumen + URLs ----------
log "✅ Onboarding completado en ${SPENT}s ($FIN/$TOT tasks)"
echo
echo "  Project:       $PROJECT_NAME"
echo "  Repo:          $OWNER_REPO (githubId=$GITHUB_ID)"
echo "  Connection:    id=$CONN_ID  ($CONN_NAME)"
echo "  Blueprint:     id=$BP_ID    (cron diario, history desde $TIME_AFTER)"
echo "  Pipeline:      id=$PIPE_ID  TASK_COMPLETED"
echo
echo "  Grafana (filtrado a este project):"
echo "    Engineering Overview: http://localhost:3001/d/ZF6abXX7z/engineering-overview?var-project=$PROJECT_NAME"
echo "    DORA:                 http://localhost:3001/d/qNo8_0M4z/dora?var-project=$PROJECT_NAME"
echo "    GitHub (por repo):    http://localhost:3001/d/KXWvOFQnz/github"
echo
