# Diseño — skill `onboard-dora` (self-service onboard a DevLake)

> Fecha: 2026-07-02
> Repo del trabajo: `greencode-software/Greencode-quality` (plugin GreenQA)
> Spec vive acá (greencode-metrics) por contexto DORA; el código va al plugin.

## Problema

Sumar un repo a las métricas DORA de DevLake requiere hoy **dos pasos** con
asimetría de fricción:

- **Pull (onboard)**: `scripts/onboard-github-project.sh` corrido vía **SSH +
  túnel al droplet** (runbook `dora-onboarding.md`). Requiere acceso al droplet,
  clonar greencode-metrics, y manejar env vars. Sólo lo puede hacer Plataforma.
- **Push (deploys)**: skill `/setup-dora` — self-service, 100% Claude Code.

El dueño de un proyecto (p.ej. un socio) no puede conectar su repo solo: depende
del líder técnico y del acceso al droplet. Queremos que **cada dueño de proyecto
haga lo mínimo y necesario para dejar su repo conectado**, sin infra.

## Hallazgo que habilita la simplificación

La complejidad del túnel SSH es **accidental, no necesaria**:

- Ya existe un **API admin público**: `https://api.devlake.greencodesoftware.com`
  detrás de basic auth (usuario `greencode`) — `docs/STATUS.md §Acceso`.
- El script `onboard-github-project.sh` **ya soporta** pegarle a ese API vía
  `DEVLAKE_API` + `DEVLAKE_BASIC_AUTH=user:pass` (commit `91ec806`).

O sea: el onboard puede correr contra el API público, sin túnel ni droplet.

## Modelo de confianza (decidido)

**Self-service total**: el socio corre onboard + setup-dora él mismo. Esto
implica que el socio tiene la basic-auth admin de DevLake, que es una **llave
maestra** (permite crear/editar/borrar cualquier connection/project/blueprint).
Se acepta como **riesgo asumido** entre socios de confianza. Mitigación futura
(no en este alcance): un token/endpoint acotado que sólo permita onboardear el
propio repo.

## Solución — skill `onboard-dora` en el plugin GreenQA

Skill nuevo simétrico a `setup-dora`, 100% en Claude Code.

### Estructura (espeja `skills/setup-dora/`)

```
skills/onboard-dora/
├── SKILL.md               # instrucciones al agente
└── scripts/
    └── onboard-dora.sh    # copia de onboard-github-project.sh apuntando al API público
```

**Decisión: copiar el script (no fetch remoto).** Self-contained, sin dependencia
de red en runtime ni de la visibilidad del repo greencode-metrics. Sigue el
precedente del plugin (que ya duplica `dora-deploy.yml` como asset). El header del
script apunta a la fuente canónica (`greencode-metrics/scripts/onboard-github-project.sh`)
para controlar drift a mano.

### Credenciales (se configuran una vez, en el `.env` del plugin)

Se agregan a `.env.example`:

```
# ---------- DevLake (necesario para /onboard-dora) ----------
DEVLAKE_API=https://api.devlake.greencodesoftware.com
DEVLAKE_BASIC_AUTH=greencode:<pass>   # llave maestra del admin API — pedirla a Plataforma
```

- El token de GitHub **reusa el mecanismo existente** del plugin
  (`GITHUB_TOKEN` / `GITHUB_TOKEN_<OWNER>`), ya usado por el resto de GreenQA.
- `onboard-dora.sh` hace `set -a; source "${CLAUDE_PLUGIN_ROOT}/.env"; set +a`
  si el archivo existe, para levantar `DEVLAKE_*` y los tokens.

### SKILL.md (comportamiento del agente)

1. Validar `owner/repo` (formato) y `project` (kebab-case). Si faltan, pedirlos.
2. Verificar que el `.env` tenga `DEVLAKE_BASIC_AUTH`; si no, guiar a configurarlo
   (pedir la basic-auth a Plataforma) y frenar.
3. Correr `${CLAUDE_PLUGIN_ROOT}/skills/onboard-dora/scripts/onboard-dora.sh <owner/repo> <project>`.
   **Orden de args = `<owner/repo> <project>`** (consistente con `setup-dora`),
   que es el **inverso** del script base (`<project> <owner/repo>`). Al copiar el
   script hay que reordenar el parseo de posicionales. Es el bug más probable.
4. Interpretar salida: confirmar project creado + pipeline disparado. Si el token
   no ve el repo, guiar el fix (`GITHUB_TOKEN_<OWNER>`).
5. **Encadenar con el next step**: sugerir `/setup-dora <owner/repo> <project>`
   para instrumentar los deploys (el onboard trae historia/Lead Time; setup-dora
   suma Deploy Frequency).

## Flujo del socio (end-to-end, self-service)

1. Instala/actualiza el plugin GreenQA (marketplace `greencode-internal`).
2. Completa el `.env` del plugin: token(s) de GitHub + `DEVLAKE_BASIC_AUTH`.
3. `/onboard-dora owner/repo project` → crea el project en DevLake (pull).
4. `/setup-dora owner/repo project` → workflow `dora-deploy.yml` + PR (push).
5. Merge del PR + setear repo secret `DEVLAKE_DEPLOY_WEBHOOK` (comando que imprime
   el skill) + push a la rama default.
6. Verificar en Grafana (`https://devlake.greencodesoftware.com`) que aparezca
   Deploy Frequency del project.

Sin SSH, sin droplet, sin clonar greencode-metrics.

## Naming / distinción (evitar confusión)

- `onboard-repo` = onboard a **GreenQA calidad** (lee `.greencode/quality.yml`). Ya existe.
- `onboard-dora` = onboard a **DevLake métricas** (pull para DORA). Nuevo.

Sistemas distintos, nombres distintos.

## Testing / verificación

- **Idempotencia**: correr `onboard-dora.sh` dos veces sobre el mismo repo → no
  duplica connection/scope/project (el script base ya es idempotente).
- **Smoke real**: onboardear un repo de prueba contra el API público y verificar
  vía `GET /api/projects` que el project existe con DORA habilitado.
- **Auth faltante**: sin `DEVLAKE_BASIC_AUTH` en `.env` → el skill frena con
  mensaje claro, no un 401 crudo.
- **`bash -n`** sobre el script copiado.

## Entregables

1. `skills/onboard-dora/SKILL.md` + `scripts/onboard-dora.sh` en el plugin.
2. `.env.example` del plugin: bloque DevLake.
3. Bump del plugin 0.3.7 → **0.4.0** + publicar al marketplace `greencode-internal`
   (autoUpdate propaga a quien tenga el plugin).
4. Actualizar runbook `docs/runbooks/dora-onboarding.md`: reemplazar el Paso 0
   (SSH + túnel) por `/onboard-dora`, dejando el camino script/túnel como fallback
   de Plataforma.
5. Instructivo corto para el dueño de proyecto (MD) referenciando los dos skills.

## Fuera de alcance (fase futura)

- Token/endpoint acotado por repo (para no exponer la llave maestra).
- Enganchar el deploy real para Lead Time exacto (hoy proxy `on: push`).
- Sentry (CFR/MTTR) — mapping webhook Sentry→DevLake sin validar.
