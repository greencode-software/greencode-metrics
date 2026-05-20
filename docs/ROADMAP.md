# ROADMAP — Greencode Metrics

> ⚠️ **Los items accionables se trackean ahora en
> [GitHub Issues](https://github.com/greencode-software/greencode-metrics/issues)**
> (creado 2026-05-20). Este archivo se mantiene como **snapshot histórico** del
> primer breakdown — útil para entender por qué arrancamos así, no como
> source-of-truth.
>
> Para tomar un trabajo, ir a Issues y filtrar por `label:afk` (autónomos) o
> `label:hitl` (necesitan input humano). El backlog está bajo `label:phase-2`.
>
> Mapping aproximado de las secciones de abajo a issues:
> - §0 Bloqueante inmediato → #1, #2, #3
> - §1 Plugins faltantes → #4 (Sentry), #5 (SonarCloud), #6 (Bitbucket), #13 (GraphQL), #14 (GitLab), #15 (yBug)
> - §2 Onboarding de proyectos → #7 (pinvest), #8 (closeup), #9 (risk-monitor), #10 (dora-deploy + tag v1)
> - §3 Operación/DX → #11 (uptime), #12 (subdomain Config UI), #16 (auto-deploy), #17 (snapshots), #18 (rotation), #19 (logs), #20 (service user)
> - §4 Infra a mediano plazo → #21 (Terraform), #22 (Managed MySQL), #23 (staging), #24 (Cloudflare)
> - §5 n8n+Slack → #25
> - §6 Plugin Kimai → #26
> - §7 MCP + Slack → #27
> - §8 Dashboards custom → #28 (scorecard), #29 (cohort comparison)

Pendientes priorizados. Snapshot del primer breakdown — complemento de `STATUS.md`
(estado actual) y `CLAUDE.md` (visión + etapas originales).

> Convención original: cada item llevaba **Owner** (quién lo hace) y **Effort**
> (S/M/L). S = <2h, M = 2-8h, L = >1 día. En Issues esto se reemplazó por labels
> `afk`/`hitl` (tipo de trabajo) + asignación explícita (owner).

---

## 0. Bloqueante inmediato (terminar para cerrar el deploy prod)

| # | Item | Effort | Notas |
|---|---|---|---|
| 0.1 | Validar end-to-end del stack prod | S | `curl -I https://devlake.greencodesoftware.com` → 302; `/api/projects` → 401; webhook público → 200. Login Google OAuth en browser. |
| 0.2 | Re-onboardear `tallone-sistema-de-gestion` contra prod | S | `DEVLAKE_API='https://api.devlake.greencodesoftware.com/api' DEVLAKE_BASIC_AUTH='greencode:<pass>' ./scripts/onboard-github-project.sh tallone-sistema-de-gestion elamonica/tallone` |
| 0.3 | Crear las 2 webhook connections en prod (deploys + sentry-incidents) | S | Ver `docs/runbooks/droplet-bootstrap.md §"Webhook connections"`. Guardar los `connection-id`. |
| 0.4 | Llenar `docs/baselines.yml` con AI adoption start de tallone | S | El usuario tiene que decidir la fecha. |

---

## 1. Plugins de DevLake faltantes (Sentry, SonarCloud, etc.)

| # | Item | Effort | Notas |
|---|---|---|---|
| 1.1 | **Sentry → webhook**: configurar Alert Rule en cada proyecto Sentry para POST-ear a `https://api.devlake.greencodesoftware.com/api/plugins/webhook/connections/<sentry-conn-id>/issues` | M | DevLake no tiene plugin Sentry pull; sólo recibe push por webhook. Requiere 0.3 hecho. |
| 1.2 | **SonarCloud connection**: connection plugin `sonarqube` (sirve para SonarCloud también) | M | Configurar token de SonarCloud, mapear a project. Habilita métricas de calidad. |
| 1.3 | **Bitbucket Cloud connection**: para proyectos que viven en bitbucket.org/greencode-software | M | Plugin `bitbucket` ya está habilitado en DevLake. Crear app password Bitbucket. Adaptar script onboard. |
| 1.4 | **GitLab connection** (si aplica algún proyecto) | M | Plugin `gitlab` disponible. |
| 1.5 | **TestRail / TestLink / Tracker de QA** (yBug, etc.) | L | Requiere plugin custom PyDevLake. Ver `plugins/kimai/` como modelo. |
| 1.6 | **Re-activar GraphQL** en connections GitHub | S | `gh auth refresh -h github.com -s read:user` localmente, o crear PAT classic con scope `read:user`. PATCH connection cambiando `enableGraphql:true`. Acelera ~3x el sync. |

---

## 2. Onboarding de proyectos reales (etapa 3 del roadmap)

| # | Item | Effort | Notas |
|---|---|---|---|
| 2.1 | Levantar lista canónica de proyectos a onboardear | S | Tener "proyectos.yml" o usar el `baselines.yml`. Hoy sólo tallone. |
| 2.2 | Onboardear **pinvest-platform** (`greencode-software/pinvest-api` + frontend repo) | M | Requiere PAT con acceso a la org. |
| 2.3 | Onboardear **closeup-medical** | M | Confirmar dónde viven los repos (GitHub o Bitbucket). |
| 2.4 | Onboardear **idb-belize-dw** | M | Idem. |
| 2.5 | Integrar `dora-deploy` action en el workflow de prod de tallone | S | PR al repo `elamonica/tallone` agregando step `uses: greencode-software/greencode-metrics/actions/dora-deploy@v1` después del deploy. |
| 2.6 | Tag `v1` del repo greencode-metrics | S | Para que `dora-deploy@v1` resuelva estable. Hacer cuando 2.5 esté validado. |
| 2.7 | Replicar 2.5 en los demás repos productivos | M | Idealmente como PR template o hooks. |

---

## 3. Operación / Observabilidad / DX

| # | Item | Effort | Notas |
|---|---|---|---|
| 3.1 | **DO Uptime Check** sobre `https://devlake.greencodesoftware.com` | S | Gratis. Alerta a Slack o email si cae. |
| 3.2 | **Auto-deploy** del stack via GitHub Action en push a master | M | Workflow que hace SSH al droplet y `git pull && docker compose up -d`. Necesita `DROPLET_SSH_KEY` como GH secret. |
| 3.3 | **Volume snapshots** programados (semanal, diferente día que mysqldump) | S | `doctl compute volume-action snapshot` via cron. Belt and suspenders. |
| 3.4 | **Subdominio para Config UI** (`admin-devlake.greencodesoftware.com`) | S | Reemplaza el SSH tunnel actual. Caddy + 1 A record. Misma basic auth. |
| 3.5 | **Rotación de secrets**: dry-run cada 6 meses, documentar el procedimiento | M | Sobretodo del `ENCRYPTION_SECRET` y del basic auth. |
| 3.6 | **Logs centralizados** (opcional) | L | Si Caddy/Mysql/Devlake logs crecen mucho, mandar a Loki o algo. Por ahora local en el droplet alcanza. |
| 3.7 | **Decidir y crear usuario de servicio en GH org `greencode-software`** | M | Hoy todos los onboardings usan la cuenta personal del líder. No escala. |

---

## 4. Mejoras de infra a mediano plazo

| # | Item | Effort | Notas |
|---|---|---|---|
| 4.1 | **Terraform para el droplet** (provider digitalocean) | L | Que la creación del droplet + volume + Reserved IP + firewall + DNS sea declarativa. Justifica si recreás >2x al año. |
| 4.2 | **Managed MySQL de DO** ($15/mo) | M | Cuando los datos pasen 5 GB o haya más de 5 proyectos. Separa storage de compute. |
| 4.3 | **Staging environment** | L | Otro droplet más chico para probar upgrades de DevLake sin romper prod. |
| 4.4 | **Cloudflare delante** | S | Si en algún momento querés DDoS protection / ocultar origin IP. Caddyfile ya tiene un placeholder para modo full-strict. |

---

## 5. Etapa 4 — n8n + alertas Slack

| # | Item | Effort | Notas |
|---|---|---|---|
| 5.1 | Sumar `n8n` como service al docker-compose | M | Imagen oficial `n8nio/n8n`. Auth básica via Caddy o n8n built-in. |
| 5.2 | Workflow: poll DevLake API → si DORA cae bajo umbral, postear a Slack | M | n8n tiene node de HTTP request y Slack. Definir umbrales en YAML versionable. |
| 5.3 | Exportar workflow a JSON y commitear en `n8n/workflows/` | S | Que sea reproducible. |

---

## 6. Etapa 5 — Plugin Kimai (PyDevLake)

| # | Item | Effort | Notas |
|---|---|---|---|
| 6.1 | Brief del API de Kimai (endpoints expuestos, auth, paginación) | S | El usuario tiene el setup, hay que mapear qué queremos extraer. |
| 6.2 | Scaffold del plugin PyDevLake en `plugins/kimai/` | M | Seguir el tutorial oficial DevLake. |
| 6.3 | Implementar collectors básicos: timesheets, projects, users | L | |
| 6.4 | Conectar Kimai data con projects de DevLake para reportes cross-source | L | |

---

## 7. Etapa 7 — MCP + agente Slack conversacional

| # | Item | Effort | Notas |
|---|---|---|---|
| 7.1 | MCP server que expone DevLake API queries como tools | L | Para usar desde Claude. |
| 7.2 | Bot Slack con Claude API que responde "¿cómo va pinvest?" | L | Stretch goal, post-MVP. |

---

## 8. Dashboards custom Greencode

| # | Item | Effort | Notas |
|---|---|---|---|
| 8.1 | **Scorecard global**: un dashboard JSON que muestre todos los proyectos en una tabla resumen con DORA + calidad + flujo | M | Complementa los prebuilt. Exportar JSON a `grafana-custom/`. |
| 8.2 | **Cohort comparison**: pre/post AI adoption, derivado de `baselines.yml` | M | Visualizar el impacto de IA con datos duros. ISO-friendly. |

---

## Cuando completes un item

1. Branch local, commit con mensaje claro.
2. Push, PR al main repo.
3. Merge.
4. Actualizá STATUS.md si afecta al estado operacional.
5. Tachá el item de este ROADMAP (o eliminalo + agregalo a STATUS §"commits clave").
6. Avisá en el canal del equipo.
