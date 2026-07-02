# Spec — Sentry → DevLake CFR/MTTR vía poller — 2026-07-02

## Objetivo

Alimentar las métricas DORA de **Change Failure Rate (CFR)** y **Mean Time To
Restore (MTTR)** en DevLake a partir de los incidents de producción registrados en
Sentry, sin exponer ningún endpoint público y con atribución correcta por project.

Cierra la fase 2 de DORA (la fase 1 —Deploy Frequency + Lead Time vía `dora-deploy`—
ya quedó funcionando). Sucede al spike `2026-07-02-sentry-devlake-webhook-mapping.md`,
que validó el lado DevLake y descartó el push nativo de Sentry.

## Contexto heredado (verificado)

- El webhook de DevLake **funciona** tras el fix de Caddy (`f2f8b99`): POST público a
  `https://api.devlake.greencodesoftware.com/api/plugins/webhook/connections/<id>/issues`
  → 200. Sin auth (la URL es el secreto).
- DevLake atribuye un incident a un project **por `project_mapping` (scope→project)**,
  NO por el payload. Igual que los deploys. Por eso cada project necesita **su propia**
  webhook connection de incidents, bindeada a su blueprint (campo `connections`).
- Sentry: org **`greencode`**. Project del piloto: **`tallone-prod`** (ruby-rails) ↔
  DevLake project `tallone-sistema-de-gestion`. Hay `SENTRY_AUTH_TOKEN` disponible.
- Sentry **no** permite templatear su webhook ni manda el evento de resolución en las
  Alert Rules → el modelo pull (poller sobre la API) es el elegido.

## Decisiones (brainstorming 2026-07-02)

| Decisión | Elegido |
|---|---|
| Arquitectura | **Poller (pull)** — sin endpoint público |
| Runtime | **Container en docker-compose** (`sentry-poller`, loop interno) |
| Criterio de incident | **prod + level error/fatal** (unresolved + resueltos) |
| Atribución | **Per-project** — connection `<project>-incidents` por project |
| Alcance 1ª iteración | Solo **tallone**, diseñado para escalar por config |
| Interval | 30 min (configurable) |

## Arquitectura

Un servicio `sentry-poller` en `docker/docker-compose.yml`, `restart: always`, con un
loop: `while true: sync_all(); sleep(interval)`. En cada ciclo, por cada project del
config:

```
Sentry API (org greencode)                    DevLake webhook (interno o público)
  GET issues (prod, error/fatal,       →  transform  →   POST /connections/<id>/issues
     unresolved + resolved)                              (idempotente, upsert por issueKey)
```

El poller es **stateless/idempotente**: cada corrida re-asienta el estado actual de
cada issue. No hay cursor ni store de "vistos" — re-postear un create actualiza el
issue en DevLake; postear el estado resuelto setea `resolutionDate`. Correr dos veces
seguidas es inocuo.

### Flujo por issue

1. `issueKey` = id numérico del issue de Sentry (estable entre open y resolve).
2. Payload DevLake (`POST /plugins/webhook/connections/<incidents_conn_id>/issues`):
   | Campo | Valor |
   |---|---|
   | issueKey | `<sentry issue id>` |
   | title | `issue.title` |
   | url | `issue.permalink` |
   | type | `"INCIDENT"` |
   | status | `IN_PROGRESS` (unresolved) · `DONE` (resolved) |
   | originalStatus | `issue.status` (`unresolved`/`resolved`) |
   | createdDate | `issue.firstSeen` (ISO-8601 con offset) |
   | resolutionDate | tiempo de resolución (solo si resolved) → MTTR |
3. **Resolución (MTTR)**: se intenta postear el create con `status=DONE` +
   `resolutionDate` en **un solo endpoint** (`/issues`, que acepta `resolutionDate`).
   Durante la implementación se verifica que DevLake compute el MTTR así; si no, se
   usa el endpoint dedicado `POST /connections/<id>/issue/<issueKey>/close`.
   - Fuente del timestamp de resolución: campo de resolución del issue de Sentry
     (`statusDetails`/activity). Fallback si no está disponible: el `lastSeen`, o el
     momento de detección (granularidad = interval). A resolver en impl.

### Query a Sentry

`GET /api/0/projects/greencode/<sentry_project>/issues/` con:
- `query`: `level:[error,fatal]` (+ se recuperan unresolved y resolved; se puede correr
  dos queries `is:unresolved` / `is:resolved statsPeriod acotado`).
- `environment=production` (param).
- Ventana acotada (ej. `statsPeriod=90d` para resolved, para no arrastrar historia
  infinita). Los unresolved se traen todos.
- Paginación por header `Link` (cursor de Sentry).

## Per-project connections + automatización

- Cada DevLake project tiene su connection `<project>-incidents` (nombre paralelo a
  `<project>-deployments`), bindeada al blueprint en `connections`. DevLake regenera
  `project_mapping` con `{rowId:"webhook:<id>", table:"cicd_scopes"}` → los incidents
  cuentan para ESE project.
- Se automatiza en `scripts/onboard-github-project.sh`: además de `<project>-deployments`,
  crea `<project>-incidents` y la agrega al blueprint. El script imprime ambos ids.
- La connection compartida `sentry-incidents` (id=2) queda **deprecada** (no se borra;
  se deja de usar). tallone usa `tallone-incidents`.

## Config

`services/sentry-poller/config.yml` (versionado, sin secrets):

```yaml
sentry_org: greencode
poll_interval_minutes: 30
# base del webhook DevLake que ve el poller (interno al compose network o público)
devlake_webhook_base: http://devlake:8080/plugins/webhook   # dentro del stack
projects:
  - devlake_project: tallone-sistema-de-gestion
    sentry_project: tallone-prod
    incidents_connection_id: <id de tallone-incidents>
```

Nota: dentro del compose network el poller pega directo a `devlake:8080` (root, sin
`/api`, sin Caddy) — más simple y no depende del fix de Caddy.

## Secrets

- `SENTRY_AUTH_TOKEN`: se agrega a `secrets/prod.env.sops` (SOPS+age) y se inyecta al
  container `sentry-poller` por env. Nunca en el config ni en logs.

## Estructura del repo

```
services/sentry-poller/
├── Dockerfile
├── pyproject.toml            # poetry, python 3.12
├── config.yml                # mapping projects (versionado)
├── sentry_poller/
│   ├── __init__.py
│   ├── __main__.py           # loop: sync_all(); sleep
│   ├── config.py             # carga/valida config.yml
│   ├── sentry.py             # cliente Sentry API (paginado, filtros)
│   ├── devlake.py            # cliente webhook DevLake (post_issue)
│   ├── transform.py          # issue Sentry → payload DevLake (PURO, testeable)
│   └── sync.py               # orquesta: fetch → transform → post por project
└── tests/
    ├── fixtures/             # payloads reales de Sentry (sanitizados)
    ├── test_transform.py
    └── test_sync.py
```

`docker/docker-compose.yml`: nuevo servicio `sentry-poller` (build local,
`restart: always`, env `SENTRY_AUTH_TOKEN`, `DEVLAKE_WEBHOOK_BASE`, monta `config.yml`).

## Modos de operación

- **Normal**: loop cada `poll_interval_minutes`.
- **Dry-run** (`SENTRY_POLLER_DRY_RUN=1` o `--dry-run`): fetchea y transforma pero
  **logea** el payload en vez de postear. Para validar contra Sentry real sin escribir
  en DevLake.
- **One-shot** (`--once`): un ciclo y termina (para tests/manual).

## Manejo de errores

- Fallo al fetchear un project → loguea y sigue con los demás (no aborta el ciclo).
- Fallo al postear un issue → reintento con backoff (hasta 3); si falla, loguea y sigue
  (el próximo ciclo lo re-intenta, es idempotente).
- Rate limit de Sentry (429) → respeta `Retry-After`.
- El container nunca "crashea" por un ciclo fallido; `restart: always` cubre caídas
  duras.

## Testing

- **Unit** (`test_transform.py`): fixtures de issues Sentry (unresolved, resolved,
  distintos niveles/environments) → asserts sobre el payload DevLake (campos, status,
  filtrado de no-prod / no-error).
- **Sync** (`test_sync.py`): cliente Sentry mockeado → verifica que sólo se postean los
  que califican y con el `incidents_connection_id` correcto por project.
- **Manual/integración**: dry-run contra Sentry real (tallone-prod) revisando el log;
  luego un `--once` real contra un `tallone-incidents` de prueba y verificar en el
  MySQL + la query real de CFR/MTTR de Grafana.

## Verificación de aceptación

1. `--once` real crea/actualiza incidents de `tallone-prod` en la connection
   `tallone-incidents`, visibles en `issues` (type=INCIDENT) de DevLake.
2. Un issue resuelto en Sentry queda con `resolutionDate` en DevLake.
3. Las queries reales de los paneles **Change Failure Rate** y **Time to Restore
   Service** de Grafana devuelven datos para `tallone-sistema-de-gestion`.

## Fuera de alcance (futuro)

- Otros projects (axia, cafta, cuidar, …) — se suman por config una vez validado tallone.
- Criterio de incident configurable por project (hoy fijo: prod + error/fatal).
- Alertas / n8n. Migración del criterio a "issues marcados" si el CFR resulta ruidoso.
```
