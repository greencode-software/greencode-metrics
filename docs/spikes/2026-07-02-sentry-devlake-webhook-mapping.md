# Spike — Mapping webhook Sentry → DevLake (CFR/MTTR) — 2026-07-02

**Tipo**: investigación / PoC (sin implementación).
**Fase**: DORA fase 2 (Change Failure Rate + Mean Time To Restore).
**Pregunta**: ¿el webhook nativo de Sentry puede postear directo al endpoint
`/plugins/webhook/connections/2/issues` de DevLake, o hace falta un relay?

## TL;DR

**Hace falta un relay. Sí o sí.** Dos razones independientes:

1. **Shape incompatible + Sentry no permite templatear el payload.** El JSON que
   manda Sentry es fijo y no coincide con el schema que DevLake exige (faltan
   `issueKey`, `status`, `createdDate`, `originalStatus` en el nivel/nombres que
   DevLake espera; los datos de Sentry viven anidados en `data.event`/`data.issue`).
2. **MTTR necesita el evento de resolución.** Un webhook de *Alert Rule* dispara
   solo cuando el issue **se dispara**, nunca cuando se **resuelve**. Sin el evento
   "resolved" no hay `resolutionDate` → no hay MTTR. Para capturarlo hay que usar
   el **Integration Platform "issue" webhook** (issue.created / issue.resolved),
   no una Alert Rule.

Conclusión: un pequeño transformador HTTP (relay) que reciba el webhook de Sentry,
mapee campos, y haga **dos** llamadas distintas a DevLake (una al crear, otra al
resolver). Recomendación: **n8n** (ya está en el roadmap, sin infra nueva).

---

## Lado DevLake — schema del incoming webhook

Endpoints reales (validados 2026-07-02, GET → **HTTP 404** = existen, solo POST):

| Acción | Método | URL |
|---|---|---|
| Registrar/actualizar issue | POST | `https://api.devlake.greencodesoftware.com/api/plugins/webhook/connections/2/issues` |
| Cerrar issue (setea `resolutionDate`) | POST | `https://api.devlake.greencodesoftware.com/api/plugins/webhook/connections/2/issue/<issueKey>/close` |

Body de `POST .../issues` (campos **requeridos** en negrita):

| Campo | Tipo | Req | Notas |
|---|---|---|---|
| **issueKey** | string | ✅ | único por connection → usar el **Sentry group id** (estable open↔close) |
| **title** | string | ✅ | |
| **status** | string | ✅ | solo `TODO` \| `IN_PROGRESS` \| `DONE` |
| **originalStatus** | string | ✅ | status crudo de la fuente (ej. `unresolved`/`resolved`) |
| **createdDate** | string | ✅ | ISO-8601 con offset: `2020-01-01T12:00:00+00:00` |
| type | string | | `INCIDENT` \| `BUG` \| `REQUIREMENT` → para DORA: **`INCIDENT`** |
| resolutionDate | string | | ISO-8601; para MTTR debe quedar seteado al cerrar |
| url | string | | permalink del issue en Sentry |
| description, severity, component, priority, ... | | | opcionales |

**DORA**: `type=INCIDENT` + `resolutionDate` seteado al cerrar. DevLake correlaciona
los incidents con los deployments (los que ya manda `dora-deploy`) por ventana
temporal para calcular **CFR** y **MTTR**. No hace falta linkear manualmente.

> ⚠️ **Drift a corregir**: `docs/CONVENTIONS.md §3` todavía apunta a la URL vieja
> `.../webhook/1/issues`. La connection real de sentry-incidents es **id=2** y el
> path correcto es `.../webhook/connections/2/issues`. Además falta crear
> `docs/sentry-webhook-payload.md` (referenciado pero inexistente).

---

## Lado Sentry — qué manda (y qué NO se puede)

Sentry tiene dos mecanismos de webhook, **ninguno templatable**:

### a) Alert Rule → "Send a notification via Webhook" (legacy)
- Dispara **solo al trigger** del alert (issue visto/condición cumplida).
- Payload fijo con los datos del evento. **No sirve solo** porque nunca avisa la
  resolución → sin MTTR.

### b) Integration Platform — Internal Integration con webhook de recurso `issue`
- Se suscribe al recurso **issue**; dispara en `issue.created`, `issue.resolved`,
  `issue.assigned`, `issue.ignored`.
- Payload (fijo, no configurable):
  ```
  {
    "action": "created" | "resolved" | ...,
    "actor":  { "id", "name", "type" },
    "data":   { "issue": { "id", "title", "culprit", "permalink",
                           "firstSeen", "status", "project": {...}, ... } },
    "installation": { "uuid" }
  }
  ```
- **Este es el que sirve**: da tanto el alta (`created`) como el cierre
  (`resolved`) con un **group id estable** para usar de `issueKey`.

> Para filtrar solo incidents de producción (la convención `event.level>=error AND
> environment=production`) puede seguir existiendo una Alert Rule para *notificar*,
> pero el **tracking** para DORA va por el webhook de Integration Platform. El relay
> puede filtrar por `data.issue.project`/tags si hace falta acotar a prod.

---

## El mapeo (lo que hace el relay)

**Al recibir `action=created`** → `POST .../connections/2/issues`:

| DevLake | ← Sentry |
|---|---|
| issueKey | `data.issue.id` |
| title | `data.issue.title` |
| url | `data.issue.permalink` |
| type | `"INCIDENT"` (constante) |
| status | `"IN_PROGRESS"` (o `TODO`) |
| originalStatus | `data.issue.status` (ej. `unresolved`) |
| createdDate | `data.issue.firstSeen` (normalizar a ISO-8601 con offset) |

**Al recibir `action=resolved`** → `POST .../connections/2/issue/<data.issue.id>/close`
(DevLake setea `resolutionDate` = ahora y computa el lead time del incident = MTTR).

Puntos finos:
- Normalizar timestamps de Sentry (`...Z`) al formato con offset `+00:00`.
- `issueKey` **debe** ser idéntico en el alta y el cierre → siempre `data.issue.id`.
- Idempotencia: reenvíos de `created` deben ser no-op (mismo `issueKey`).

---

## Opciones de relay

| Opción | Pro | Contra |
|---|---|---|
| **n8n** (recomendado) | Ya en el roadmap (fase 4, alertas Slack); sin infra nueva; HTTP-in → Function → HTTP-out; visual/auditable | Levantar n8n antes de lo previsto |
| Micro-servicio (FastAPI) tras Caddy | Control total, testeable con pytest | Nuevo servicio a mantener/deployar en la VM |
| Plugin PyDevLake Sentry (pull) | "Nativo" | DevLake **no** tiene plugin Sentry; habría que escribirlo entero — mucho más caro que el relay |

Recomendación: **n8n**. Adelanta trabajo de la fase 4 y el webhook queda como un
workflow simple (1 trigger + switch por `action` + 2 HTTP requests).

---

## Próximos pasos (fuera de este spike)

1. Capturar un payload **real** de Sentry (crear una Internal Integration de prueba
   en un proyecto Sentry y disparar un issue) para confirmar nombres de campos
   exactos (`firstSeen` vs `first_seen`, forma de `permalink`, etc.).
2. PoC de escritura: hacer **un** POST manual a `.../connections/2/issues` con un
   payload hand-crafted y ver el incident en Grafana → valida el lado DevLake sin
   construir el relay. (Escribe en DevLake prod → confirmar con el usuario antes.)
3. Decidir n8n vs micro-servicio y crear el issue de implementación.
4. Corregir el drift de `docs/CONVENTIONS.md §3` y crear `docs/sentry-webhook-payload.md`.

## Fuentes
- DevLake incoming webhook: https://devlake.apache.org/docs/Plugins/webhook
- Sentry integration platform webhooks: https://docs.sentry.io/organization/integrations/integration-platform/webhooks/
- Estado interno: `docs/STATUS.md §"Webhook connections"`, `docs/CONVENTIONS.md §3`.
