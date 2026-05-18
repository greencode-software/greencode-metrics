# `dora-deploy` action

Composite GitHub Action que notifica al stack DevLake de Greencode que ocurrio un
deploy a un entorno. Es lo que habilita **Deploy Frequency** y **Lead Time for
Changes** del cuadrante DORA en los dashboards.

## Cuando llamarla

En cualquier workflow de deploy de cualquier repo Greencode, despues de que el
deploy en si fue exitoso. Tipicamente al final del workflow.

## Ejemplo minimo

```yaml
# .github/workflows/deploy-prod.yml
name: Deploy to production

on:
  push:
    branches: [master]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Deploy to Heroku
        id: deploy
        run: |
          # ... tu logica de deploy aca ...
          echo "started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$GITHUB_OUTPUT"

      - name: Notify DevLake
        if: always()  # IMPORTANTE: notifica tambien deploys fallidos (cuenta CFR)
        uses: greencode-software/greencode-metrics/actions/dora-deploy@v1
        with:
          project:     tallone-sistema-de-gestion
          environment: production
          commit-sha:  ${{ github.sha }}
          repo-url:    ${{ github.server_url }}/${{ github.repository }}
          ref-name:    ${{ github.ref_name }}
          webhook-url: ${{ secrets.DEVLAKE_DEPLOY_WEBHOOK }}
          started-at:  ${{ steps.deploy.outputs.started_at }}
          result:      ${{ job.status == 'success' && 'SUCCESS' || 'FAILURE' }}
```

## Inputs

| Input | Requerido | Default | Descripcion |
|---|---|---|---|
| `project` | sí | — | Nombre del project en DevLake (kebab-case) |
| `commit-sha` | sí | — | SHA del commit deployado |
| `repo-url` | sí | — | URL del repo en GitHub |
| `webhook-url` | sí | — | URL del webhook DevLake (org secret `DEVLAKE_DEPLOY_WEBHOOK`) |
| `environment` | no | `production` | `production` / `staging` / `development` |
| `started-at` | no | now − 1min | ISO-8601 de inicio del deploy |
| `result` | no | `SUCCESS` | `SUCCESS` o `FAILURE` |
| `ref-name` | no | `main` | Branch o tag deployado |

## El secret `DEVLAKE_DEPLOY_WEBHOOK`

Se gestiona a **nivel organization** en GitHub Settings → Secrets → Actions.
Lo provee el equipo de Plataforma cuando se levanta DevLake; no se rota por proyecto.

Formato:
```
https://metrics.greencodesoftware.com/api/plugins/webhook/connections/<conn-id>/deployments
```

El `<conn-id>` corresponde a la "webhook connection" creada en DevLake especificamente
para recibir deploys (distinta de la que recibe incidents de Sentry).

## Garantias / no garantias

- **No aborta el deploy** si DevLake esta caido. El telemetry-loss es preferible a
  bloquear releases por una metrica.
- Reintenta 3 veces con backoff lineal (3s, 6s, 9s).
- Valida el JSON antes de mandar — falla rapido si los inputs estan corruptos.
- Si `if: always()`, registra tambien deploys con `result: FAILURE`, que es lo que
  alimenta **Change Failure Rate** de DORA.

## Como verificar que llego

En el stack DevLake, una vez configurado:

```bash
curl -u <basic-user>:<basic-pass> \
  https://metrics.greencodesoftware.com/api/cicd_deployment_commits \
  | jq '.[] | select(.environment=="PRODUCTION")'
```

O directo en MySQL:

```sql
SELECT name, environment, started_date, finished_date, result
FROM cicd_deployments
WHERE name LIKE '%tallone%'
ORDER BY started_date DESC LIMIT 10;
```

## Convenciones relacionadas

Ver `docs/CONVENTIONS.md` del repo `greencode-metrics` para naming canonico de
projects y el resto del checklist de onboarding.
