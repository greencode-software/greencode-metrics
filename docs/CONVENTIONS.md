# Greencode Engineering Metrics — Convenciones

Este documento define cómo se debe instrumentar **cada proyecto** de Greencode para
alimentar el stack central de métricas (DevLake en `metrics.greencode.com.ar`).

Forma parte del checklist de kickoff de proyecto y es auditable bajo ISO 9001.

---

## 1. Fuentes que DevLake consume por proyecto

| Fuente            | Qué aporta                                       | Obligatorio |
|-------------------|--------------------------------------------------|-------------|
| BitBucket/GitHub  | Commits, PRs, reviews, code churn                | Sí          |
| Sentry            | Incidents, MTTR, change failure rate             | Sí          |
| SonarCloud/Sonar  | Coverage, code smells, debt, security hotspots   | Sí          |
| Webhook "deploy"  | Marca cuándo hubo deploy a producción            | Sí          |
| Kimai (custom)    | Horas reales por proyecto / fase                 | Recomendado |

---

## 2. Convención de deployments

DevLake **no sabe** qué commit es un deploy a prod salvo que se lo digamos.

Cada repo debe llamar a la action reutilizable en su workflow de deploy a prod:

```yaml
# .github/workflows/deploy-prod.yml  (o equivalente en BitBucket Pipelines)
- name: Notify DevLake
  uses: greencode/dora-deploy-action@v1
  with:
    devlake-webhook: ${{ secrets.DEVLAKE_DEPLOY_WEBHOOK }}
    project: <nombre-del-cliente>
    environment: production
    commit-sha: ${{ github.sha }}
```

El secret `DEVLAKE_DEPLOY_WEBHOOK` se gestiona a nivel organization en GitHub y a nivel
workspace en BitBucket — no se rota por proyecto.

---

## 3. Convención de incidents (Sentry)

En cada proyecto Sentry, crear una **Alert Rule** "Production Incident":

- Condición: `event.level >= error` AND `environment = production`
- Acción: Send a notification via Webhook
- URL: `https://metrics.greencode.com.ar/api/plugins/webhook/1/issues`
- Payload: usar el template documentado en `/docs/sentry-webhook-payload.md`

Resolver el issue en Sentry cierra el incident en DevLake automáticamente (MTTR).

---

## 4. Etiquetado de PRs asistidos por IA

Para medir el impacto de IA en productividad, usar labels en los PRs:

- `ai-assisted` — el PR fue producido con asistencia significativa de Claude Code,
  Copilot u otra IA generativa de código.
- `ai-review` — el code review fue asistido por IA.

DevLake agrupa por label y permite comparar cycle time, review rounds y bug reopen
rate entre cohortes.

---

## 5. Naming de proyectos en DevLake

Un "Project" en DevLake = un cliente/contrato Greencode.
Nombre canónico: `<cliente>-<producto>` en kebab-case minúsculas.

Ejemplos: `idb-belize-dw`, `closeup-medical-directory`, `pinvest-platform`,
`epresis-greenvoice-integration`.

---

## 6. Checklist kickoff de proyecto

- [ ] Project creado en DevLake con naming canónico
- [ ] Repo(s) conectados (BitBucket o GitHub)
- [ ] Proyecto Sentry conectado vía Alert Rule → webhook
- [ ] Proyecto SonarCloud conectado
- [ ] Workflow de deploy llama a `greencode/dora-deploy-action`
- [ ] Baseline screenshot guardado en Drive (carpeta del proyecto / 06-Metrics)
- [ ] Project Manager agregado como viewer en Grafana
