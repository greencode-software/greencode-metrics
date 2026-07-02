# STATUS — Greencode Metrics

> Documento vivo. Se sobrescribe entero cada sesión. La historia queda en `git log`.
> Última actualización: **2026-07-01**.
>
> Orden de lectura sugerido para retomar contexto frío:
> `CLAUDE.md` → `docs/CONVENTIONS.md` → este archivo (STATUS) → `docs/ROADMAP.md`.
>
> Si sos un teammate nuevo, leé `ONBOARDING.md` (en root) primero.

---

## TL;DR

- **Stack productivo en DigitalOcean: ARRIBA** ✅
  - URL Grafana:     https://devlake.greencodesoftware.com (Google OAuth)
  - URL DevLake API: https://api.devlake.greencodesoftware.com (basic auth)
  - Reserved IP:     `134.199.247.25`
  - Droplet:         Premium AMD 2vCPU / 4GB RAM / 80GB NVMe / NYC3 (~$28/mo)
  - Volume:          `devlake-data` 50GB montado en `/var/lib/docker`
  - TLS:             Let's Encrypt automático (Caddy) en ambos subdominios
  - Backups:         cron weekly → DO Spaces `greencode-devlake-backups`

- **Primer proyecto real en prod: `pinvest-platform`** ✅ (onboardeado 2026-07-01,
  GitHub `greencode-software/pinvest`). Es el primer dato ingestado en prod.
  DORA aún vacío por diseño: falta `dora-deploy` (deploys) y webhook Sentry
  (incidentes). GitHub/PRs sí visibles en Engineering Overview + GitHub dashboards.

- **Segundo proyecto: `tallone-sistema-de-gestion`** ✅ (onboardeado 2026-07-01,
  GitHub `elamonica/tallone`, history desde 2026-03-01). Elegido como piloto de la
  action `dora-deploy`.

- **Piloto DORA en marcha** 🟡 — se instrumentaron los dos repos con la action
  `dora-deploy@v1` (ver §"Piloto DORA — estado 2026-07-01"). Pendiente: mergear
  los 2 PRs + confirmar el secret de pinvest + ver la primera entrada de Deploy
  Frequency en Grafana.

- **Pendiente inmediato**: (a) cerrar el piloto DORA (mergear PRs, secret pinvest,
  primer deploy verificado); (b) corregir el drift del stack prod (ver §"Drift
  detectado 2026-07-01"). Ver `docs/ROADMAP.md` §"Bloqueante inmediato".

- **Etapas del roadmap original** (`CLAUDE.md`):
  - 1 (local) ✅ · 2 (piloto tallone) ✅ · 6 (deploy prod) ✅
  - 3 (3 proyectos + dora-deploy) 🟡 · 4 (n8n+Slack) ⏳ · 5 (Kimai) ⏳ · 7 (MCP) ⏳

---

## Stack productivo — detalles operativos

### Containers (`docker compose ps` en droplet)

```
greencode-devlake-mysql       mysql:8.0                       127.0.0.1:3306
greencode-devlake             apache/devlake:v1.0.2           interno
greencode-devlake-grafana     apache/devlake-dashboard:v1.0.2 interno
greencode-devlake-config-ui   apache/devlake-config-ui:v1.0.2 127.0.0.1:4000 (SSH tunnel only)
greencode-devlake-caddy       caddy:2.8-alpine                0.0.0.0:80, 443, 443/udp
```

### URLs productivas

| Servicio | URL | Auth |
|---|---|---|
| Grafana | https://devlake.greencodesoftware.com | Google OAuth (`@greencodesoftware.com`) |
| DevLake API admin | https://api.devlake.greencodesoftware.com/api/... | Basic auth (user `greencode`) |
| DevLake webhook público | https://api.devlake.greencodesoftware.com/api/plugins/webhook/... | Sin auth (arreglado+deployado 2026-07-02; ver §"Webhook connections") |
| Config UI | `ssh -L 4000:127.0.0.1:4000 root@134.199.247.25` → http://localhost:4000 | SSH tunnel |

### Subdominios — por qué hay dos

Grafana y DevLake comparten el namespace `/api/` (ambos exponen `/api/user`, `/api/plugins`, etc.). Path-based routing en Caddy no alcanza para separarlos. Solución: subdominio para la API. Ver Caddyfile §"Arquitectura de hostnames".

### Datos en prod hoy

**`pinvest-platform`** (GitHub `greencode-software/pinvest`, Ruby) — onboardeado
2026-07-01. Connection id=1, Blueprint id=1 (cron diario, history desde 2026-05-01
= creación del repo). Es el primer proyecto ingestado en prod.

**`tallone-sistema-de-gestion`** (GitHub `elamonica/tallone`, Ruby) — onboardeado
2026-07-01. Connection id=2, Blueprint id=2 (history desde 2026-03-01 = creación del
repo). Piloto de la action `dora-deploy`.

**Acceso a la API para onboardear**: como el stack prod NO expone la API a internet
(el firewall de DO bloquea 8088), el onboarding se corre por túnel SSH:
`ssh -N -L 18088:127.0.0.1:8088 root@134.199.247.25` y luego
`env -u GITHUB_TOKEN DEVLAKE_API=http://localhost:18088 ./scripts/onboard-github-project.sh ...`.
Importante: la API de DevLake sirve en **root** (`/projects`, `/plugins`), NO bajo `/api`.

### Webhook connections (DORA) — creadas 2026-07-01

| Connection | id | URL pública (POST, sin auth) |
|---|---|---|
| deployments (compartida, legacy) | **1** | `https://api.devlake.greencodesoftware.com/api/plugins/webhook/connections/1/deployments` |
| sentry-incidents (genérica, legacy) | **2** | `https://api.devlake.greencodesoftware.com/api/plugins/webhook/connections/2/issues` |
| tallone-deployments | **3** | `https://api.devlake.greencodesoftware.com/api/plugins/webhook/connections/3/deployments` |
| tallone-incidents | **4** | `https://api.devlake.greencodesoftware.com/api/plugins/webhook/connections/4/issues` |

- La URL de **deployments** es lo que va como org secret `DEVLAKE_DEPLOY_WEBHOOK`
  (GitHub org `greencode-software`), consumida por `actions/dora-deploy`.
- La URL de **sentry-incidents** va como target del webhook en las Alert Rules de Sentry.
- Tag `v1` de greencode-metrics creado (apunta a master `a353558`) → `dora-deploy@v1`
  resuelve.

> ✅ **RESUELTO 2026-07-02.** Durante el PoC del spike de Sentry se descubrió que el
> webhook estaba **roto** (la afirmación previa "GET→404 = existe, sin auth" era
> incorrecta) y se corrigió + deployó. Historia:
>
> **Causa raíz**: el bloque `handle_path /api/plugins/webhook/*` del `docker/caddy/Caddyfile`
> reescribía a `/api/plugins/webhook{uri}`, pero el backend DevLake sirve la API en
> **root** (`/plugins/...`) → el `/api` sobrante daba **404**. Consecuencia:
> `dora-deploy` (que postea sin auth) **nunca registró un solo deploy** y, como la
> action sólo emite `::warning::` sin fallar, pasó inadvertido (causa raíz del AC
> abierto del issue #10). El webhook de Sentry tenía el mismo bloqueo.
>
> **Fix (commit `f2f8b99` en master, deployado a prod)**: reemplazar el bloque por
> `handle /api/plugins/webhook/*` + `uri strip_prefix /api`. La URL pública NO cambia;
> sólo se corrige el mapeo interno de Caddy. El resto de `/api/*` sigue tras basic-auth.
>
> **Verificado end-to-end 2026-07-02** contra prod:
> - `POST /api/plugins/webhook/connections/2/issues` (create incident) → **200 success**
> - `POST /api/plugins/webhook/connections/2/issue/<key>/close` → **200 success**
> - `POST .../connections/1/deployments {}` → **400** (rutea al backend, valida body)
> - admin `/api/rest/version` → **401** (sigue protegido) · Grafana → **200**
>
> ⚠️ **Gotcha del deploy (no re-descubrir)**: el Caddyfile se monta como **bind-mount
> de archivo único**. `git pull` reemplaza el archivo con un **inode nuevo**, pero el
> container sigue viendo el inode viejo → `caddy reload` recarga el config **viejo**
> (validate da OK y rc=0, engañoso). Hay que **`docker restart greencode-devlake-caddy`**
> para que re-resuelva el mount. Un `reload` solo no alcanza tras un `git pull`.
>
> **Pendiente**: quedó un incident de prueba `SPIKE-TEST-20260702-01` (cerrado) en la
> connection 2. Borrarlo del MySQL si se quiere limpieza fina. Retomar el relay de
> Sentry (spike §diseño).

> 🟠 **GAP 2 (descubierto 2026-07-02 al verificar) — el webhook no está asociado a
> ningún project.** Se posteó un deployment de prueba (`verify-20260702-tallone-01`,
> commit real de tallone) → **200 y quedó guardado** en `cicd_deployment_commits`
> con `cicd_scope_id = webhook:1`. PERO:
>
> - `project_mapping` de `tallone-sistema-de-gestion` sólo mapea su repo GitHub
>   (`github:GithubRepo:2:...`), NO el scope `webhook:1`.
> - La Deploy Frequency de Grafana cuenta deployments cuyo `cicd_scope` está en el
>   `project_mapping` del project → **el deployment del webhook no cuenta para nadie**.
>
> **Corrección al diseño**: el supuesto "una webhook `deployments` compartida (id=1)
> para todos los repos, el project se distingue en el payload" es **incorrecto**.
> DevLake atribuye por `project_mapping` (scope→project), NO por `repoUrl` del
> payload. Si se agrega `webhook:1` a varios projects, cada deploy cuenta para
> **todos** (doble conteo). Lo correcto es **una webhook connection por project**
> (ej. `tallone-deployments`, `pinvest-deployments`), cada una agregada a SU project,
> y el secret `DEVLAKE_DEPLOY_WEBHOOK` de cada repo apunta a la suya.
>
> **Corrección al diseño**: se eligió **per-project** (evita el doble conteo).
>
> ✅ **GAP 2 RESUELTO para tallone (2026-07-02)** — vía backend API por SSH:
> - Creada connection **`tallone-deployments` (id=3)** → deployments van a scope `webhook:3`.
> - **Blueprint 2 actualizado**: se agregó `{"pluginName":"webhook","connectionId":3}`
>   a `blueprint.connections`. DevLake regenera el plan con
>   `{"rowId":"webhook:3","table":"cicd_scopes"}` en `projectMappings` → **mapping
>   durable** (la corrida diaria lo mantiene). La forma correcta de asociar un webhook
>   a un project es el campo **`connections`** del blueprint (NO editar el `plan`, que
>   es autogenerado; ni `project_mapping` directo, que la corrida diaria pisa).
> - Verificado con la **query real** del panel Deployment Frequency:
>   `SELECT COUNT(DISTINCT cicd_deployment_id) ... JOIN project_mapping pm ON
>   cicd_scope_id=pm.row_id AND pm.table='cicd_scopes' WHERE project_name='tallone...'`
>   → **1 deploy** (SUCCESS/PRODUCTION). Grafana lo muestra.
>
> ⏳ **Falta para deploys reales de tallone**: actualizar el repo secret
> `DEVLAKE_DEPLOY_WEBHOOK` de `elamonica/tallone` para que apunte a la connection 3:
> `https://api.devlake.greencodesoftware.com/api/plugins/webhook/connections/3/deployments`
> (hoy apunta a la connection 1 compartida, que ya no está mapeada a tallone). Lo
> corre el dueño con `gh secret set` (el classifier bloquea valores de secret).
>
> ⏳ **pinvest**: replicar (connection `pinvest-deployments` + blueprint + secret). Ideal:
> **automatizar** la creación de la connection + `connections` del blueprint en
> `scripts/onboard-github-project.sh`, así proyecto nuevo = onboard + setup-dora, sin
> tocar DevLake a mano.
>
> **Data de prueba a limpiar**: deploys `verify-20260702-tallone-01` (scope webhook:1
> huérfano y webhook:3) + incident `SPIKE-TEST-20260702-01` (webhook:2).

---

## Sentry poller (CFR/MTTR) — implementado 2026-07-02

Servicio nuevo `services/sentry-poller/` (Python 3.12, Poetry). Poll stateless/idempotente:
cada N min, por project del `config.yml`, lista issues de Sentry (`level:[error,fatal]`,
`environment=production`, `statsPeriod=14d`), transforma a payload DevLake y postea a la
webhook connection `<project>-incidents`. Dentro del compose pega a `devlake:8080` directo.

- **Implementado por SDD** (9 tasks, TDD): config loader, transform puro, cliente Sentry,
  cliente DevLake (retry 5xx/red), sync orquestación (per-issue error-isolated), CLI
  (`--once`/`--dry-run`/loop), Dockerfile + servicio compose, y extensión de
  `scripts/onboard-github-project.sh` (crea+bindea `<project>-incidents`). **34 tests verdes.**
- **Bug encontrado en el dry-run contra Sentry real** (crítico, sólo visible en vivo): el
  endpoint de resolución era `/issues/{id}/activity/` (singular) → **404** en Sentry SaaS,
  tirando TODOS los incidents resueltos (los que alimentan MTTR). Correcto: **`/activities/`**
  (plural); el body sigue trayendo la lista bajo la key `activity`. Post-fix el dry-run de
  `tallone-prod` dio `{fetched:43, qualified:39, posted:39, errors:0}`.

### Verificación end-to-end CFR/MTTR (2026-07-02, contra prod)
- Creada connection **`tallone-incidents` (id=4)** por SSH → incidents van a scope `webhook:4`.
- **Blueprint 2** bindeado: `{"pluginName":"webhook","connectionId":4,"scopes":[{"scopeId":"4"}]}`
  agregado a `blueprint.connections` (mismo patrón durable que deployments). Tras correr el
  blueprint (pipeline 6, TASK_COMPLETED) → `project_mapping` obtiene `webhook:4 →
  tallone-sistema-de-gestion` (durable).
- Posteado un incident sintético (`POLLER-TEST-1`, resolved, created 10:00 → resolved 11:00).
  Llegó a `issues` + `incidents` (`lead_time_minutes=60`). Query real de MTTR
  (`incidents JOIN board_issues JOIN project_mapping WHERE project_name='tallone...'`) →
  **MTTR = 60 min** atribuido a tallone. **Limpiado** `POLLER-TEST-1` de `issues`/`incidents`/
  `board_issues` después.
- `config.yml` quedó con `incidents_connection_id: 4`.

⏳ **Falta para incidents reales de tallone** (lo hace el dueño): agregar
`SENTRY_AUTH_TOKEN` al `secrets/prod.env.sops` (SOPS+age) + `git pull` en `/opt/devlake` +
`docker compose up -d --build sentry-poller`. Recién ahí se postean los 39 incidents reales.
Escalar a otros projects = onboard (crea `<project>-incidents`) + entrada en `config.yml`.

---

## Piloto DORA — estado 2026-07-01

Se instrumentaron **tallone** y **pinvest** con la action reutilizable
`dora-deploy@v1`. **Hallazgo clave**: ninguno de los dos deploya por GitHub
Actions (tallone deploya por Heroku sin workflows; pinvest tiene `backend.yml` +
`frontend.yml` pero son solo CI). Por eso el enfoque no es "step después del
deploy" sino un **workflow proxy `on: push` a la rama default**.

**Limitaciones aceptadas del proxy** (documentadas en el header de cada workflow):
reporta `SUCCESS` aunque el deploy real falle, y el timing es aproximado (no espera
al deploy). Suficiente para Deploy Frequency; para Lead Time exacto habría que
enganchar el deploy real (Heroku release hook / deployment_status).

| Repo | Project DevLake | Trigger | PR | Secret |
|---|---|---|---|---|
| `elamonica/tallone` (personal) | `tallone-sistema-de-gestion` | push a `master` | [#34](https://github.com/elamonica/tallone/pull/34) | **repo secret** ✅ seteado |
| `greencode-software/pinvest` (org) | `pinvest-platform` | push a `main` | [#126](https://github.com/greencode-software/pinvest/pull/126) | **repo secret** ⏳ |

**Gotcha del secret**: `DEVLAKE_DEPLOY_WEBHOOK` apunta a la connection webhook
**deployments (id=1)**, compartida por todos los repos (el `project` distingue en
el payload). Va **siempre como repo secret** (por repo): en el **plan Free** de
GitHub los org secrets **no alcanzan a repos privados** (requieren Team/Enterprise)
y casi todos los repos de Greencode son privados; los repos personales tampoco
reciben org secrets. Un org secret único solo tendría sentido si el org pasa a
Team/Enterprise.

**Pendiente para cerrar**: (1) confirmar org secret de pinvest; (2) mergear #34 y
#126; (3) hacer un push a la rama default de cada uno y verificar que aparezca una
entrada de Deploy Frequency en el dashboard DORA de Grafana.

**Requisito de tooling**: crear/editar archivos bajo `.github/workflows/` (por API
o `git push`) necesita el scope **`workflow`** en el token. El PAT del keyring lo
tuvo que sumar (`gh auth refresh -h github.com -s workflow`, con `GITHUB_TOKEN`/`GH_TOKEN`
desactivados en el env o el refresh se niega).

**Skill de onboarding**: el patrón quedó empaquetado como skill **`setup-dora`** en
el plugin GreenQA (`greencode-software/Greencode-quality` PR #24, bump 0.3.7).
Cualquiera del equipo instrumenta sus repos con Claude Code sin re-descubrir los
gotchas. Solo deploys por ahora; Sentry (CFR/MTTR) pendiente de validar el mapping.

**Cómo sumar un repo nuevo al tracking DORA**: paso a paso completo (onboard pull →
setup-dora push → secret → verificar) en `docs/runbooks/dora-onboarding.md`.
Clave: **onboard PRIMERO** (crea el `project` + trae historia), setup-dora DESPUÉS.

---

## Drift detectado 2026-07-01

Al onboardear pinvest se encontró que el stack prod NO está corriendo con el
overlay de Caddy que cierra puertos (`docker-compose.caddy.yml`). Estado real
observado en el droplet (`docker ps`):

1. **`greencode-devlake` publicado en `0.0.0.0:8088`** y **`grafana` en `0.0.0.0:3001`**
   — el overlay debía ponerles `ports: []`. Mitigado por el **DO Cloud Firewall**,
   que bloquea 8088/3001 desde internet (verificado: sólo 22/80/443 entran). Es una
   brecha de defense-in-depth, no una exposición activa.
2. **`config-ui` NO escucha en `127.0.0.1:4000`** (contenedor Up pero sin port
   binding). El acceso admin vía SSH tunnel a 4000 documentado más abajo **no
   funciona** hoy. Para llegar a la API se usa el túnel a 8088 (ver §"Datos en prod").

**Causa probable**: el stack se levantó con el compose base sin el `-f` del overlay,
o los `ports: []` no se aplicaron. **Fix pendiente**: re-desplegar con
`docker compose -f docker/docker-compose.yml -f docker/caddy/docker-compose.caddy.yml up -d`
y verificar que 8088/3001 dejen de bindear y que config-ui quede en 127.0.0.1:4000.
Nuevo item para el tracker.

---

## Stack local — para desarrollo

Funcional. Puertos remapeados por sibling stacks en la Mac del líder técnico (`cafta-dr-adminer-1` ocupa 8080, `closup-scrapper-grafana-1` ocupa 3000):

```
greencode-devlake-mysql       127.0.0.1:3306
greencode-devlake             0.0.0.0:8088 → 8080
greencode-devlake-grafana     0.0.0.0:3001 → 3000
greencode-devlake-config-ui   0.0.0.0:4000
```

Para correr local: `cp secrets/prod.env.example docker/.env`, editar con valores dummy, `cd docker && docker compose up -d`. NO usa Caddy en local. Grafana login por usuario/pass local (no Google).

---

## Decisiones de diseño activas

1. **Cohortes temporales para AI tracking**, no labels en PRs. (`docs/CONVENTIONS.md §4`)
2. **Connection naming convention**: `<project-name>-github` impuesto por `scripts/onboard-github-project.sh`.
3. **Scope payload de plugin github**: `name`=repo solo (ej `tallone`), `fullName`=`owner/repo`.
4. **GraphQL apagado** en la connection GitHub porque el `gho_*` del keyring del líder no tiene scope `read:user`. Re-activar cuando el PAT lo tenga.
5. **DigitalOcean NYC3** como cloud provider (no AWS). SOPS+age (no KMS) para secrets.
6. **Subdomain split** para Grafana vs DevLake API. Forzoso por el conflicto de namespace `/api/`.
7. **DevLake NO tiene plugin Sentry pull** (confirmado en `/plugins`). Integración Sentry va por webhook push.
8. **Config UI accesible solo via SSH tunnel** en prod. La SPA no se puede servir desde un subpath sin build custom.
9. **Repo público** (greencode-software/greencode-metrics). Habilita que la composite action `dora-deploy` sea consumible desde otros repos sin parametrizar checkouts con PAT.

---

## Gotchas / cosas que aprender de nuevo es caro

1. **`sops -d` para `prod.env.sops` SIEMPRE necesita `--input-type dotenv --output-type dotenv`**. La extensión `.sops` no es auto-detectada → sin los flags, sops asume JSON y falla con "invalid character '#'".
2. **`SOPS_AGE_KEY_FILE=/etc/sops/age/keys.txt`** debe estar seteado en cualquier shell que necesite descifrar. El bootstrap lo persiste en `/root/.bashrc` del droplet.
3. **DO Reserved IP es inbound-only**. El egress sale por la IP nativa del droplet (`159.65.247.0`). Si alguna API externa pide whitelist, esa es la IP, no la Reserved.
4. **DO Cloud Firewall por default no permite ICMP**. `ping` puede dar timeout aunque SSH y HTTPS funcionen. Es normal.
5. **DO muestra "Configure your Volume"** con un mkfs+mount sugerido. IGNORAR. El bootstrap ya montó el Volume en `/var/lib/docker` (no en `/mnt/devlake_data` como sugiere DO).
6. **1GB RAM es insuficiente** para el stack DevLake. Mínimo 4GB. Se confirmó por swap thrashing (Disk I/O 600 MB/s, CPU 100% sostenido).
7. **Ubuntu 24.04 sacó `awscli` v1 del repo**. AWS CLI v2 se instala via binary oficial (el bootstrap lo hace).
8. **Grafana usa `/api/`** para sus propias llamadas (`/api/user`, `/api/plugins`, etc.). NO se puede mandar `/api/*` a DevLake — los namespaces se solapan. Por eso el subdomain split.
9. **`bash <(curl ...)` y `sudo` no se llevan bien**: sudo cierra los FDs del shell padre. Si ya sos root en el droplet, omitir el sudo.
10. **`raw.githubusercontent.com` cachea ~5 min**. Si cambias un script y necesitás bypasear cache, usar URL `https://raw.../refs/heads/master/...` (sin cache).
11. **No imprimir tokens nunca** — ni prefijos, ni longitud. Pipear inline al destino.

---

## Commits clave de la sesión productiva (2026-05-18)

```
6d774a8  caddy: separar DevLake API a subdominio api.{$DOMAIN}
91ec806  onboard-github: soportar DEVLAKE_BASIC_AUTH
b8fa60e  grafana: wire up Google OAuth + fix GF_SERVER_ROOT_URL para prod
b925674  bootstrap-droplet: instalar AWS CLI v2 via binary oficial
257c959  bootstrap-droplet: clonar via HTTPS (repo es publico)
cbe7748  secrets: prod.env cifrado con SOPS+age
35be739  Cambiar subdominio prod a devlake.greencodesoftware.com
4530b83  .sops.yaml: age public key real
```

Remote: `git@github.com:greencode-software/greencode-metrics.git`, branch `master`, visibility **public**.

---

## Credenciales productivas

Todas en **1Password** vault `greencode-metrics`, Secure Note "DevLake prod credentials (2026-05-18)":

- `BASIC_AUTH_USER` / `BASIC_AUTH_PASS` (Caddy → DevLake API admin)
- `GRAFANA_ADMIN_PASSWORD` (fallback login a Grafana)
- `MYSQL_ROOT_PASSWORD`, `MYSQL_PASSWORD`
- `ENCRYPTION_SECRET` (DevLake — sin esto se pierden todos los tokens guardados)
- **age private key** (adjunta como archivo en el mismo item — sin ésta, prod.env.sops no se puede descifrar)

⚠️ **El plain text de prod.env nunca debe quedar en disco**. Si necesitás editarlo, hacelo en `/tmp/`, encriptá, y borrá inmediatamente.

---

## Estructura actual del repo

```
.
├── .sops.yaml                          # age public key (real, no placeholder)
├── CLAUDE.md                           # decisiones de diseño + roadmap
├── ONBOARDING.md                       # guía 30 min para nuevo teammate
├── README.md                           # (vacío todavía)
├── actions/dora-deploy/                # composite action GH para notificar deploys
├── docker/
│   ├── .env                            # local dummy (gitignored)
│   ├── docker-compose.yml              # stack base
│   └── caddy/
│       ├── Caddyfile                   # 2 site blocks: devlake.* + api.devlake.*
│       └── docker-compose.caddy.yml    # overlay prod (suma Caddy + cierra puertos)
├── docs/
│   ├── CONVENTIONS.md                  # cómo instrumentar un proyecto
│   ├── STATUS.md                       # este archivo
│   ├── ROADMAP.md                      # pendientes priorizados
│   ├── baselines.yml                   # AI adoption start por proyecto
│   └── runbooks/
│       └── droplet-bootstrap.md        # paso a paso DO end-to-end
├── grafana-custom/                     # vacío (futuro: dashboards JSON)
├── plugins/kimai/                      # vacío (futuro: plugin PyDevLake)
├── scripts/
│   ├── bootstrap-droplet.sh            # provisioning idempotente del droplet
│   └── onboard-github-project.sh       # onboarding idempotente repo → DevLake
└── secrets/
    ├── prod.env.example                # template
    └── prod.env.sops                   # cifrado, safe para git
```

---

## Para reanudar en una sesión nueva

1. `cd ~/Documents/GreenCode/projects.nosync/greencode-metrics`
2. Leer en orden: `CLAUDE.md` → `docs/CONVENTIONS.md` → este STATUS → `docs/ROADMAP.md`.
3. `git log --oneline -10` para ver lo último.
4. Si entrás como teammate nuevo: `ONBOARDING.md` te da todo en 30 min.
5. Para validar prod desde la Mac:
   ```bash
   curl -I https://devlake.greencodesoftware.com -m 5         # → 302
   curl -I https://api.devlake.greencodesoftware.com/api/projects -m 5  # → 401
   ```
