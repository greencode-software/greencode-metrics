# Greencode Engineering Metrics — Convenciones

Este documento define cómo se debe instrumentar **cada proyecto** de Greencode para
alimentar el stack central de métricas (DevLake en `devlake.greencodesoftware.com`).

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
- URL: `https://api.devlake.greencodesoftware.com/api/plugins/webhook/1/issues`
- Payload: usar el template documentado en `/docs/sentry-webhook-payload.md`

Resolver el issue en Sentry cierra el incident en DevLake automáticamente (MTTR).

---

## 3b. Convención de calidad de código (SonarCloud)

Cada proyecto Greencode se analiza con SonarCloud. El onboarding al stack de
métricas es idempotente y vive en `scripts/onboard-sonarcloud-project.sh`:

```bash
SONARCLOUD_ORG=greencode-software \
  scripts/onboard-sonarcloud-project.sh \
    --token-env SONAR_TOKEN_GREENCODE \
    <devlake-project> <sonar-project-key>
```

Reglas:

- **Naming**: la connection se llama `<devlake-project>-sonarcloud`, en paralelo a
  la convención `<devlake-project>-github`.
- **Org**: `SONARCLOUD_ORG` es obligatoria y queda persistida en la connection
  (campo `org`). Default operativo: `greencode-software`. Si en el futuro
  aparece otra org (cliente con cuenta SonarCloud propia, separación legal,
  etc.), se onboardea pasando `SONARCLOUD_ORG=<otra-org>` y el script crea una
  connection nueva sin tocar la existente. Cada connection apunta a UNA sola
  org — no se mezclan proyectos de orgs distintas en el mismo `connectionId`.
- **Endpoint**: `https://sonarcloud.io/api` para SonarCloud (default). Para una
  instancia SonarQube self-hosted se sobreescribe con `SONARCLOUD_ENDPOINT` y
  se omite `SONARCLOUD_ORG` (SonarQube on-prem no usa el concepto de org —
  pero el script igual exige la env var; en ese caso pasar el string vacío
  no funciona, así que self-hosted requiere un wrapper o edición puntual).
- **Token**: User Token de SonarCloud generado por una cuenta con visibilidad
  sobre la org. Guardado en 1Password (item `SonarCloud — service token`).
  Nunca pasa por argv; el script lo lee por env var o archivo y lo manda
  directo a la API. DevLake lo encripta en MySQL con `ENCRYPTION_SECRET`.
- **Scope**: el `projectKey` de SonarCloud (no el name humano). Es lo que aparece
  en la URL `sonarcloud.io/project/overview?id=<key>`.
- **Project DevLake**: debe existir antes (lo crea `onboard-github-project.sh`).
  Si no existe, el script lo crea con DORA habilitado y warning.
- **Re-corridas**: idempotente. Re-PATCHea token + endpoint + org, upsertea el
  scope y mergea la connection en el blueprint preservando github/bitbucket/etc.
  Si cambiás la `org` de una connection existente, el script avisa por stderr
  porque la próxima ingesta puede traer datos nuevos.

---

## 4. Tracking de adopción de IA por proyecto

**No usamos labels de PR.** Los labels manuales se degradan rápido en la práctica
(devs olvidan, son inconsistentes entre personas, sesgan a posteriori). En vez de
eso, medimos **por cohortes temporales**:

- Cada proyecto documenta una fecha de **"AI adoption start"** — el momento desde
  el cual el equipo de ese proyecto adopta asistencia con IA de forma sistemática.
- DevLake compara las mismas métricas **antes vs después** de esa fecha, **para el
  mismo proyecto**. Nunca cruza cohortes entre proyectos distintos (cada equipo
  tiene contexto, stack y cliente distinto).

### Dónde se documenta la fecha

Archivo único `docs/baselines.yml` en este repo:

```yaml
# docs/baselines.yml
- project: tallone-sistema-de-gestion
  ai_adoption_start: 2026-01-15
  notes: "Adopción de Claude Code para feature dev. Confirmado por elamonica."

- project: pinvest-platform
  ai_adoption_start: 2025-11-01
  notes: "Copilot organization-wide; Claude Code para PRs grandes."

- project: idb-belize-dw
  ai_adoption_start: null   # aun no adoptado
```

### Cómo lo consume DevLake

Las queries de Grafana hacen `JOIN` contra esta tabla (cargada vía el plugin
`customize` de DevLake, o vía import CSV directo a una tabla auxiliar). Cada
panel relevante (throughput, cycle time, CFR) tiene una variante "by cohort"
que separa pre/post fecha para el project seleccionado.

### Cómo se decide la fecha

- No tiene que ser un día específico — usar el inicio de la semana o el sprint
  en el que el equipo lo adoptó.
- Cambiar la fecha post-hoc es legítimo si te das cuenta que pifiaste la
  estimación; queda registrado en el git log del archivo.
- Si un proyecto **vuelve atrás** (deja de usar IA), no se borra la entrada:
  se agrega un campo `ai_adoption_end` y se documenta el motivo.

---

## 5. Naming de proyectos en DevLake

Un "Project" en DevLake = un cliente/contrato Greencode.
Nombre canónico: `<cliente>-<producto>` en kebab-case minúsculas.

Ejemplos: `idb-belize-dw`, `closeup-medical-directory`, `pinvest-platform`,
`epresis-greenvoice-integration`.

---

## 6. Checklist kickoff de proyecto

- [ ] Project creado en DevLake con naming canónico (`scripts/onboard-github-project.sh`)
- [ ] Repo(s) conectados (BitBucket o GitHub) — la onboarding script lo cubre
- [ ] Proyecto Sentry conectado vía Alert Rule → webhook
- [ ] Proyecto SonarCloud conectado (`scripts/onboard-sonarcloud-project.sh`)
- [ ] Workflow de deploy llama a `greencode-software/greencode-metrics/actions/dora-deploy@v1`
- [ ] Entrada en `docs/baselines.yml` con `ai_adoption_start` (o `null` si aún no aplica)
- [ ] Baseline screenshot guardado en Drive (carpeta del proyecto / 06-Metrics)
- [ ] Project Manager agregado como viewer en Grafana
