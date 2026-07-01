# Runbook — Sumar un repo al tracking DORA

> Cómo dar de alta un repo nuevo para que aparezca en los dashboards DORA de
> DevLake (Deploy Frequency + Lead Time). Escrito 2026-07-01.

## Modelo mental: son DOS cosas complementarias

| | `onboard-github-project.sh` | skill `/setup-dora` |
|---|---|---|
| Dirección | DevLake **PULL** ← GitHub API | Repo **PUSH** → DevLake webhook |
| Qué trae | commits, PRs, reviews, issues, CI | eventos de **deploy** |
| Crea el `project` en DevLake | **Sí** | No (asume que existe) |
| Habilita | PR metrics, cycle time, **Lead Time** | **Deploy Frequency** |
| Frecuencia | una vez + cron diario | en cada push/deploy |

**El orden importa**: onboard PRIMERO (crea el `project` + trae historia), setup-dora
DESPUÉS (le suma los deploys). Si corrés setup-dora sin onboardear, el deploy llega
pero queda huérfano (sin `project`) y no hay commits para calcular Lead Time.

---

## Paso 0 — Onboardear el repo (pull de GitHub → DevLake)

Sólo para repos **nuevos**. Los ya trackeados (pinvest, tallone) saltan este paso.

La API de DevLake NO está expuesta a internet (firewall bloquea 8088) → se corre
por **túnel SSH**:

```bash
# Terminal 1: abrir el túnel (dejar corriendo)
ssh -N -L 18088:127.0.0.1:8088 root@134.199.247.25

# Terminal 2: correr el onboard (desde el repo greencode-metrics)
env -u GITHUB_TOKEN DEVLAKE_API=http://localhost:18088 \
  ./scripts/onboard-github-project.sh <project-name-kebab> <owner/repo>
```

- `<project-name-kebab>`: nombre del project en DevLake (ej: `closeup-medical`).
  Convención: `<cliente>-<producto>`.
- El script es idempotente: crea/actualiza connection, scope, project (con DORA on),
  blueprint (cron diario, history 6 meses por default) y dispara el pipeline inicial.
- Si el repo vive en la org y tu token del keyring no lo ve, pasá el PAT con
  `--token-env VARNAME` (ver `--help` del script).

---

## Paso 1 — Instrumentar los deploys (push repo → DevLake)

Con Claude Code (necesita el plugin GreenQA instalado/actualizado):

```
/setup-dora <owner/repo> <project-name-kebab>
```

No hace falta estar parado en la ruta del repo: trabaja vía API de GitHub. Detecta
la rama default, crea el branch `ci/dora-deploy-devlake`, sube
`.github/workflows/dora-deploy.yml` y abre un PR. Requiere scope `workflow` en el
token (ver Gotchas).

---

## Paso 2 — Mergear el PR + setear el repo secret

```bash
# El secret va SIEMPRE por repo (ver Gotchas):
env -u GITHUB_TOKEN -u GH_TOKEN gh secret set DEVLAKE_DEPLOY_WEBHOOK \
  --repo <owner/repo> --body '<URL webhook deployments — conn id=1>'
```

La URL del webhook `deployments` está en `docs/STATUS.md §"Webhook connections"`
(connection id=1). Es la misma para todos los repos; el campo `project` del payload
los distingue.

---

## Paso 3 — Verificar

Hacé un push a la rama default del repo → en unos minutos debería aparecer una
entrada de **Deploy Frequency** en el dashboard DORA de Grafana:
`https://devlake.greencodesoftware.com` (filtrar por `var-project=<project>`).

---

## Gotchas (caros de re-descubrir)

1. **Todo `gh` con `env -u GITHUB_TOKEN -u GH_TOKEN`** — hay un `GITHUB_TOKEN` en el
   env de la Mac que pisa el keyring y rompe `gh`.
2. **Scope `workflow` obligatorio** para crear archivos en `.github/workflows/`
   (por API o `git push`). Sin él, la API devuelve **404** (no 403), confuso. Sumarlo:
   `env -u GITHUB_TOKEN -u GH_TOKEN gh auth refresh -h github.com -s workflow`
   (con los tokens desactivados del env, o el refresh se niega).
3. **El secret va SIEMPRE por repo, no org secret.** En el plan **Free** de GitHub
   los org secrets NO alcanzan a repos privados (requieren Team/Enterprise) y casi
   todos los repos de Greencode son privados. Los repos personales tampoco reciben
   org secrets. Un org secret único sólo tendría sentido con Team/Enterprise.
4. **Enfoque proxy**: si el repo no deploya por GitHub Actions, el workflow dispara
   en cada push a la rama default y reporta siempre `SUCCESS`, timing aproximado.
   Sirve para Deploy Frequency; el Lead Time exacto queda pendiente de enganchar el
   deploy real.
5. **Sentry (CFR/MTTR) no está acá todavía** — el mapping webhook Sentry→DevLake no
   está validado. Fase futura.
