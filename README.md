# Greencode Metrics

Plataforma centralizada de engineering metrics para todos los proyectos de
**Greencode Software SRL**, basada en [Apache DevLake](https://devlake.apache.org/).
Métricas DORA por proyecto, calidad de código, flujo de desarrollo, y análisis
de cohortes pre/post adopción de IA — todo para auditoría ISO 9001:2015 y toma
de decisiones internas.

## Producción

| Servicio | URL | Auth |
|---|---|---|
| Grafana (dashboards) | https://devlake.greencodesoftware.com | Google OAuth (`@greencodesoftware.com`) |
| DevLake API admin | https://api.devlake.greencodesoftware.com/api/... | Basic auth |
| DevLake API webhook público | https://api.devlake.greencodesoftware.com/api/plugins/webhook/... | URL secreta |
| Config UI | SSH tunnel: `ssh -L 4000:127.0.0.1:4000 root@<droplet>` | acceso por red |

Stack: **DigitalOcean** Droplet (Premium AMD 4GB, NYC3) · **Caddy** reverse proxy
con TLS auto (Let's Encrypt) · **MySQL 8** · **DevLake v1.0.2** · **Grafana 11.6**
· secrets cifrados con **SOPS+age** · backups semanales a **DO Spaces**.

## Cómo arrancar

- **Soy nuevo en el proyecto** → [`ONBOARDING.md`](./ONBOARDING.md) (guía de 30 min)
- **Necesito instrumentar un proyecto Greencode** → [`docs/CONVENTIONS.md`](./docs/CONVENTIONS.md)
- **Quiero saber qué está corriendo** → [`docs/STATUS.md`](./docs/STATUS.md)
- **Voy a hacer un cambio operativo en el droplet** → [`docs/runbooks/`](./docs/runbooks/)
- **Estoy buscando qué hay para hacer** → [GitHub Issues](https://github.com/greencode-software/greencode-metrics/issues)
- **Decisiones de diseño / contexto histórico** → [`CLAUDE.md`](./CLAUDE.md)

## Estructura del repo

```
.
├── CLAUDE.md                # decisiones de diseño y roadmap original
├── ONBOARDING.md            # guía para nuevo teammate
├── docker/                  # stack base + overlay Caddy productivo
├── actions/dora-deploy/     # composite GH Action para notificar deploys
├── docs/                    # CONVENTIONS, STATUS, ROADMAP, runbooks, baselines
├── scripts/                 # bootstrap del droplet + onboarding de repos
├── grafana-custom/          # dashboards JSON (custom Greencode)
├── plugins/                 # plugins PyDevLake custom (Kimai, etc.)
└── secrets/                 # prod.env.sops cifrado (.sops.yaml define la age key)
```

## Pendientes

Todo el trabajo a hacer se trackea en **[GitHub Issues](https://github.com/greencode-software/greencode-metrics/issues)** —
phase-1 (sin label `phase-2`) son prioridad ahora; `phase-2` es backlog.

Labels:
- `afk` — puede ejecutarse sin intervención humana
- `hitl` — requiere decisión humana o credenciales
- `onboarding` — onboardear un proyecto al stack
- `phase-2` — backlog / fase posterior

## Contribuir

Workflow estándar: branch desde `master` → commit → push → PR → review →
merge. El detalle de pre-requisitos, accesos, conventions y workflow en
[`ONBOARDING.md`](./ONBOARDING.md).

## Soporte

Canal interno `#greencode-metrics` en Slack. Para temas urgentes operativos del
stack productivo, contactar al líder técnico (`@elamonica`).
