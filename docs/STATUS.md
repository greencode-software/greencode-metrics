# STATUS — Greencode Metrics

> Documento vivo. Se sobrescribe entero cada sesión. La historia queda en `git log`.
> Última actualización: **2026-05-15**.
> Si abrís una sesión nueva con Claude Code, este es el primer archivo que conviene
> que lea (después de `CLAUDE.md` y `docs/CONVENTIONS.md`).

---

## TL;DR

- **Etapa 1** (stack local): ✅ funcionando. 4 containers up, tallone como piloto ingerido (274 commits, 0 PRs, 0 issues — el repo no usa PRs).
- **Etapa 2** (piloto): ✅ cerrado con `elamonica/tallone` → project `tallone-sistema-de-gestion`.
- **Etapa 3** (3 proyectos más + action de deploys): 🟡 script reusable listo y testeado; action `dora-deploy` lista; falta onboardear repos reales y mergear la action en cada workflow.
- **Etapa 4** (n8n + Slack): ⏳ pendiente. Era el próximo trabajo cuando se escribió este STATUS.
- **Etapa 5** (plugin Kimai): ⏳ pendiente.
- **Etapa 6** (deploy productivo): 🟡 assets listos para **DigitalOcean** (no AWS). Falta levantar el droplet en sí — bloqueado en input del usuario (ver "Pendiente del usuario" abajo).
- **Etapa 7** (MCP + Slack agent): ⏳ futuro.

Decisión de provider productivo: **DigitalOcean NYC3** (no AWS). Razones documentadas en commit `e52cbce`. Cifrado de secrets: **SOPS+age** (no KMS).

---

## Estado del entorno local

```
docker compose ps (en docker/docker-compose.yml):
  greencode-devlake-mysql       MySQL 8.0      127.0.0.1:3306
  greencode-devlake             DevLake v1.0.2 0.0.0.0:8088 → 8080
  greencode-devlake-grafana     Grafana 11.6   0.0.0.0:3001 → 3000
  greencode-devlake-config-ui   ConfigUI       0.0.0.0:4000
```

**Puertos no son los default** porque hay sibling stacks en la Mac (`cafta-dr-adminer-1` ocupa 8080, `closup-scrapper-grafana-1` ocupa 3000). En productivo vuelven a 3000/8080 detrás de Caddy.

**Grafana login**: `admin / admin` no funciona por API (el usuario cambió el password en el primer login del browser). No es bloqueante para el uso por UI.

**Secrets locales** (`docker/.env`, gitignoreado): dummy values, sólo para dev. NO son los de prod.

### Datos ingeridos hoy

| Métrica | Valor |
|---|---|
| Project en DevLake | `tallone-sistema-de-gestion` |
| Connection | id=2, `tallone-sistema-de-gestion-github`, `enableGraphql=false` |
| Repo | `elamonica/tallone` (githubId 1184731792) |
| Commits | 274 (autor único: Ezequiel Lamonica) |
| Rango fechas commits | 2026-03-06 a 2026-05-06 |
| PRs / issues / CI runs | 0 (el repo no usa PRs ni issues en GH; sin Actions) |
| Pipeline más reciente | id=5, TASK_COMPLETED, 27s, 6/6 tasks |

### URLs locales útiles

- Engineering Overview: http://localhost:3001/d/ZF6abXX7z/engineering-overview?var-project=tallone-sistema-de-gestion
- GitHub dashboard: http://localhost:3001/d/KXWvOFQnz/github
- Config UI: http://localhost:4000
- DevLake API: http://localhost:8088

⚠️ **Cuidado con time range default de Grafana** — varios dashboards default a `now-6h`. Los commits de tallone son de hace 9-70 días. Pisar el selector a "Last 90 days" o "Last 6 months".

---

## Decisiones de diseño tomadas en esta línea de trabajo

1. **GraphQL apagado en la connection GitHub.** Workaround porque el `gho_*` del keyring no tiene scope `read:user`. Trabaja por REST (más lento pero suficiente para 1-5 proyectos). Re-activar cuando el token tenga `read:user`.
2. **Connection naming = `<project>-github`** (impuesto por `scripts/onboard-github-project.sh`). Mejor que naming ad-hoc.
3. **Scope payload del plugin github**: `name`=repo solo (ej `tallone`), `fullName`=owner/repo (ej `elamonica/tallone`). Confundirlos da `repos//milestones` 404.
4. **DevLake NO tiene plugin Sentry pull.** Confirmado en `/plugins`. La integración Sentry va por **webhook push**, lo que requiere URL pública (= etapa 6 para que tenga sentido).
5. **Cohortes temporales para tracking IA** (no labels en PRs). Documentado en `CONVENTIONS.md §4` y `docs/baselines.yml`.
6. **DigitalOcean** como cloud provider. SOPS+age para secrets.
7. **Multi-token soportado** en la onboarding script via `--token-env`/`--token-file`, manteniendo `gh auth token` como default.

---

## Roadmap con commits

```
5cf5ddb  onboard-github: --token-env y --token-file (multi-source)
e52cbce  Migrar etapa 6 a DigitalOcean Droplet
3f204eb  CONVENTIONS §4: cohortes temporales en vez de labels
0c1cc12  Etapa 6: assets para deploy productivo (action + Caddy + bootstrap + SOPS + runbook)
ef988dc  Onboarding piloto tallone + port remap local
07984d2  Initial scaffold
```

Remote: `git@github.com:greencode-software/greencode-metrics.git`, branch `master`.

---

## Pendiente del usuario (bloqueantes para etapa 6)

| # | Item | Para qué |
|---|---|---|
| 1 | Generar age key (`age-keygen`), pasarme public key | Setear en `.sops.yaml`, encriptar `prod.env` real |
| 2 | Crear Droplet (Premium AMD 4GB) + Block Storage Volume `devlake-data` + Reserved IP | Provisioning |
| 3 | Pasarme la Reserved IP | A record en Cloudflare |
| 4 | Crear cliente Google OAuth para Grafana | Reemplazar admin/admin |
| 5 | Definir fecha "AI adoption start" para tallone (opcional) | Llenar `docs/baselines.yml` |
| 6 | Decidir si crear usuario de servicio en GH org `greencode-software` | Actualmente usa cuenta personal `elamonica` para todo. El usuario explicitamente difirió esta decisión. |
| 7 | Cuando estén las webhook connections en DevLake productivo, configurar Sentry alert rules | Habilita CFR/MTTR de DORA |

---

## Lo que se puede avanzar sin esos inputs

| Item | Estado | Notas |
|---|---|---|
| **n8n workflow + Slack alertas** (etapa 4) | sin empezar | Bocetar como service del compose + workflow JSON exportable. Próximo trabajo natural si nadie redirecciona. |
| **Plugin Kimai** (etapa 5) | sin empezar | Necesita un brief del usuario sobre qué endpoints expone su Kimai. |
| **Dashboard custom Greencode** | sin empezar | Un Grafana JSON que muestre todos los proyectos en una tabla resumen tipo "performance scorecard". Complementa los prebuilt. |
| Re-activar GraphQL en connection | bloqueado | `gh auth refresh -h github.com -s read:user`. Sólo afecta velocidad. |
| Tag `v1` del repo | bloqueado | Para que `dora-deploy@v1` resuelva en los workflows consumidores. Hacer cuando el usuario diga "está listo". |

---

## Gotchas / cosas que aprender de nuevo es caro

1. **Token gh activo vs keyring**: `GITHUB_TOKEN` env var sobreescribe al keyring. Si el activo no tiene acceso a un repo, `GITHUB_TOKEN= gh ...` cae al keyring (`gho_*`). La onboarding script lo detecta solo.
2. **No imprimir tokens nunca** — ni prefijos, ni longitud, ni nada. Pipear inline al destino. Memoria del usuario lo confirmó como regla durable (commit log no, pero está en mi `~/.claude/projects/.../memory/`).
3. **DevLake webhook plugin tiene 2 connections distintas** en prod (una para `deploys`, otra para `incidents`). Documentado en el runbook.
4. **`?` en URLs en zsh** se globa, romper curl. Single-quoting de URLs cuando tengan query string.
5. **`/etc/sops/age/keys.txt`** es la única forma que el droplet puede desencriptar `secrets/prod.env.sops`. SCP-eada una sola vez en el primer bootstrap. Si se pierde, hay que rotar age key y re-encriptar todo.
6. **CONVENTIONS.md** tenía una inconsistencia con CLAUDE.md (labels IA vs cohortes); se resolvió por CLAUDE.md (commit `3f204eb`). Criterio del usuario: CLAUDE.md es el documento autoritativo.
7. **`sops -d` para `prod.env.sops` SIEMPRE necesita `--input-type dotenv --output-type dotenv`**. La extension `.sops` no es auto-detectada por SOPS, asi que sin esos flags asume JSON y falla con `invalid character '#'`. El bootstrap script y el `.sops.yaml` ya lo tienen documentado/aplicado.

---

## Estructura actual del repo

```
.
├── .sops.yaml                          # age public key (placeholder)
├── CLAUDE.md                           # decisiones de diseño + roadmap (no editar sin consenso)
├── README.md                           # vacío todavía
├── actions/dora-deploy/
│   ├── action.yml                      # composite action: notifica deploys a DevLake
│   └── README.md
├── docker/
│   ├── .env                            # dummy local (gitignored)
│   ├── docker-compose.yml              # stack base (mysql + devlake + grafana + config-ui)
│   └── caddy/
│       ├── Caddyfile                   # TLS + reverse proxy + basic auth
│       └── docker-compose.caddy.yml    # overlay para sumar Caddy en prod
├── docs/
│   ├── CONVENTIONS.md                  # cómo instrumentar un proyecto Greencode
│   ├── STATUS.md                       # este archivo
│   ├── baselines.yml                   # fechas AI adoption start por proyecto
│   └── runbooks/
│       └── droplet-bootstrap.md        # paso a paso DO end-to-end
├── grafana-custom/                     # vacío (futuro: dashboards JSON exportados)
├── plugins/kimai/                      # vacío (futuro: plugin PyDevLake)
├── scripts/
│   ├── bootstrap-droplet.sh            # provisioning idempotente del droplet
│   └── onboard-github-project.sh       # onboarding idempotente de un repo a DevLake
└── secrets/
    └── prod.env.example                # template; el real va encriptado en prod.env.sops
```

---

## Para reanudar en una sesión nueva

1. Leer `CLAUDE.md` (decisiones de diseño) y `docs/CONVENTIONS.md` (instrumentación por proyecto).
2. Leer este archivo (STATUS).
3. Revisar `git log --oneline -10` para ver lo último que se commiteó.
4. `docker compose ps` desde `docker/` para ver si el stack local sigue arriba.
5. Si el usuario pide algo de etapa 4+, este archivo dice "lo que se puede avanzar sin esos inputs". Si pide algo de etapa 6, mirar "Pendiente del usuario" y confirmar si esos inputs ya llegaron.

Memorias persistentes del usuario para esta sesión (en `~/.claude/projects/.../memory/`):
- `feedback_no_credential_inspection.md` — nunca imprimir/inspeccionar tokens.
- `project_devlake_github_scopes.md` — scopes de PAT necesarios + semántica de `name`/`fullName`.
- `project_cloud_provider.md` — DO/age/dominio prod.
