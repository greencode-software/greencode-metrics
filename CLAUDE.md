# Greencode Metrics Platform

> 📍 **Para arrancar fresco en una sesión nueva**: leer este archivo,
> después `docs/CONVENTIONS.md` (cómo instrumentar cada proyecto) y
> `docs/STATUS.md` (estado actual y lo que sigue).

Plataforma centralizada de métricas de ingeniería para todos los proyectos
de Greencode Software SRL, basada en Apache DevLake.

## Objetivo

Tener una vista única, con baselines documentados, de la calidad y el flujo de
desarrollo de todos los proyectos activos. Esto sirve para:

1. Toma de decisiones internas (asignación, alertas tempranas).
2. Evidencia objetiva para auditorías ISO 9001:2015.
3. Medir el impacto de cambios en el proceso, especialmente la adopción
   progresiva de asistencia con IA, usando cohortes temporales por proyecto.

## Stack

- Apache DevLake (última estable) como motor de ingesta y normalización.
- MySQL como almacén.
- Grafana con dashboards prebuilt + dashboards custom Greencode.
- Sources: BitBucket Cloud, GitHub, Sentry, SonarCloud, Kimai (custom plugin).

## Decisiones de diseño

- **No usamos labels de PR para tracking de IA.** Medimos por cohortes
  temporales: cada proyecto tiene una fecha documentada de "AI adoption start"
  y comparamos antes/después. Más confiable que labels manuales que se degradan.

- **Convenciones de naming**: project en DevLake = `<cliente>-<producto>` en
  kebab-case. Ejemplos: `idb-belize-dw`, `pinvest-platform`, `closeup-medical`.

- **Deployment tracking**: cada repo llama a una GitHub Action / Bitbucket Pipe
  reutilizable de Greencode al deployar a prod. No se confía en heurísticas de
  rama.

- **Secrets**: nunca commiteados. `.env` local para dev, GitHub Secrets para CI,
  Vault / SOPS cuando pase a prod en la VM.

## Estructura del repo

- `docker/` — docker-compose, configs de servicios
- `actions/dora-deploy/` — GitHub Action reutilizable para notificar deploys
- `plugins/kimai/` — plugin PyDevLake custom para Kimai (en desarrollo)
- `grafana-custom/` — dashboards JSON exportados, versionados
- `scripts/` — scripts de bootstrap, backups, migraciones
- `docs/` — convenciones, runbooks, baselines por proyecto

## Etapas del roadmap

1. ✅ Levantar DevLake local con docker-compose
2. ⏳ Conectar 1 proyecto piloto (Pinvest)
3. ⏳ Onboarding de 3 proyectos más + GitHub Action de deploys
4. ⏳ n8n workflow para alertas a Slack
5. ⏳ Plugin Kimai
6. ⏳ Migración a VM productiva con reverse proxy + auth
7. ⏳ MCP server + agente Slack conversacional

## Cómo trabajar acá con Claude Code

- Antes de cambios en `docker-compose.yml`, validá con `docker compose config`.
- Para tests del plugin Kimai: `cd plugins/kimai && poetry run pytest`.
- No bajar la versión de DevLake sin migrar el schema de MySQL primero.
- Dashboards de Grafana: exportar JSON y commitear en `grafana-custom/`.
