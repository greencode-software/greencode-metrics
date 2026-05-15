# Runbook: bootstrap del stack DevLake en EC2

Levantar el stack desde cero en un EC2 nuevo, end-to-end. Sirve para:
- Setup productivo inicial.
- Recovery despues de un disaster (instance reemplazada).
- Setup de un environment de staging para probar upgrades de DevLake.

Tiempo estimado: 45-60 min la primera vez, ~10 min en recovery.

---

## Pre-requisitos (one-time, lider tecnico)

Antes del primer bootstrap, asegurarse que existen:

- [ ] **Cuenta AWS** con region `us-east-1` elegida.
- [ ] **Route 53 hosted zone** para `greencodesoftware.com` (o el dominio que uses).
- [ ] **KMS key** creada para encriptar secrets via SOPS:
  ```bash
  aws kms create-key --description "greencode-metrics SOPS" --tags TagKey=app,TagValue=devlake
  aws kms create-alias --alias-name alias/greencode-metrics --target-key-id <key-id>
  ```
  Copiar el ARN al `.sops.yaml`.
- [ ] **IAM role** `greencode-metrics-ec2` con politicas:
  - `kms:Decrypt` sobre la KMS key de arriba.
  - `s3:PutObject` sobre `s3://greencode-devlake-backups/*`.
- [ ] **S3 bucket** `greencode-devlake-backups` (con versionado + lifecycle a Glacier
      a los 90 dias).
- [ ] **Google OAuth client** para Grafana (Console → APIs → Credentials → OAuth 2.0 Client).
- [ ] **GitHub PAT de servicio** (no de un humano) con `repo, read:org, read:user, workflow`.
- [ ] **`secrets/prod.env`** creado con valores reales, y encriptado:
  ```bash
  # solo el lider tecnico tiene acceso plain — luego se borra:
  cp secrets/prod.env.example secrets/prod.env
  $EDITOR secrets/prod.env               # poner valores reales
  sops -e secrets/prod.env > secrets/prod.env.sops
  rm secrets/prod.env                    # ELIMINAR plain text local
  git add secrets/prod.env.sops .sops.yaml
  git commit -m "secrets: prod env encriptado"
  ```

---

## EC2 + DNS (15 min)

1. **Levantar EC2**:
   - AMI: Ubuntu 24.04 LTS (HVM, SSD).
   - Instance type: `t3.medium` (start) o `t3.large` (≥3 proyectos).
   - Storage: 20 GB raiz + **un EBS gp3 adicional de 50 GB** (será `/dev/nvme1n1`).
   - IAM role: `greencode-metrics-ec2`.
   - Security group `greencode-metrics-sg`:
     - 443/tcp desde 0.0.0.0/0
     - 80/tcp desde 0.0.0.0/0  (solo redirige a 443)
     - 22/tcp desde tu IP fija o VPN
   - User data: vacio (el bootstrap es manual la primera vez para que veas qué pasa).

2. **Elastic IP**: alocar y asociar a la instance. Sin esto, cada stop/start cambia
   la IP publica y rompe el DNS.

3. **DNS**: en Route 53, A record `metrics.greencode.com.ar → <EIP>`. TTL 300.

4. **Verificar DNS antes de seguir**:
   ```bash
   dig +short metrics.greencode.com.ar
   # debe devolver la EIP
   ```
   Si no propaga: esperar 5 min. Caddy no va a poder obtener cert si DNS no resuelve.

---

## Bootstrap (10 min)

SSH al EC2:

```bash
ssh -i ~/.ssh/greencode-metrics.pem ubuntu@metrics.greencode.com.ar
```

Correr el script:

```bash
sudo bash <(curl -sL https://raw.githubusercontent.com/greencode-software/greencode-metrics/main/scripts/bootstrap-ec2.sh)
```

El script es idempotente. Si falla a la mitad, lo re-corres y retoma.

Output esperado al final:
```
→ Bootstrap completado.
  Proximos pasos manuales:
    1. Verificar DNS: ...
    2. Probar TLS: ...
```

---

## Validacion (5 min)

- [ ] `dig +short metrics.greencode.com.ar` → EIP correcto.
- [ ] `curl -I https://metrics.greencode.com.ar` → 200 OK, header `Server: Caddy`.
- [ ] `curl -I https://metrics.greencode.com.ar/api/plugins/webhook/connections`
      → 200 con respuesta JSON (el path `/api/plugins/webhook/*` es publico).
- [ ] `curl -I https://metrics.greencode.com.ar/api/projects` → 401 Unauthorized
      (basic auth funcionando).
- [ ] Browser a `https://metrics.greencode.com.ar` → Grafana login con Google.
- [ ] Browser a `https://metrics.greencode.com.ar/admin` → prompt basic auth → Config UI.

---

## Onboarding de proyectos contra el stack productivo

Una vez validado, re-onboardear cada proyecto:

```bash
# desde tu Mac (no en el EC2), con DEVLAKE_API apuntando al stack publico:
DEVLAKE_API="https://metrics.greencode.com.ar/api" \
  ./scripts/onboard-github-project.sh \
    tallone-sistema-de-gestion elamonica/tallone
```

Notas:
- El script va a usar tu `gh auth token` — para el stack productivo conviene crear
  un PAT de servicio nuevo y exportarlo como `GITHUB_TOKEN` antes de correr el script.
- Como `/api/projects` requiere basic auth, hay que agregarle credenciales a curl
  dentro del script — TODO: parametrizar `--basic-auth` en
  `scripts/onboard-github-project.sh`. Issue tracked.

---

## Webhook connections (necesarias para Sentry y dora-deploy)

En el stack productivo hace falta crear dos webhook connections distintas:
una para deploys, otra para incidents. Ejecutar **una vez**:

```bash
WEBHOOK_API="https://metrics.greencode.com.ar/api/plugins/webhook/connections"
AUTH="-u greencode:<basic-pass>"

# deploys
curl -fsS $AUTH -X POST -H 'Content-Type: application/json' \
  -d '{"name":"deploys-global"}' "$WEBHOOK_API" | jq '.id'
# → digamos, devuelve 1

# incidents
curl -fsS $AUTH -X POST -H 'Content-Type: application/json' \
  -d '{"name":"sentry-incidents"}' "$WEBHOOK_API" | jq '.id'
# → digamos, devuelve 2
```

Luego:
- En GitHub org secrets, crear `DEVLAKE_DEPLOY_WEBHOOK` con valor:
  `https://metrics.greencode.com.ar/api/plugins/webhook/connections/1/deployments`
- En cada proyecto Sentry, crear un Alert Rule → action Webhook con URL:
  `https://metrics.greencode.com.ar/api/plugins/webhook/connections/2/issues`

Despues de eso, los datos empiezan a fluir solos a las dashboards DORA.

---

## Backups

El cron de `mysqldump → S3` queda configurado por el bootstrap (semanal, domingos
03:00 UTC).

Para restore desde S3:

```bash
aws s3 ls s3://greencode-devlake-backups/ | tail -5
aws s3 cp s3://greencode-devlake-backups/devlake-lake-2026-MM-DDTHHmmZ.sql.gz - \
  | gunzip \
  | docker exec -i greencode-devlake-mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" lake
```

Snapshots EBS van por AWS Backup (configurar plan diario via console, retencion 14d).

---

## Recovery: instance reemplazada

Si el EC2 muere y necesitas recrearlo:

1. Levantar EC2 nuevo (steps "EC2 + DNS" arriba), **reusando el EBS data volume**
   si lo retuviste (snapshot reciente o el volume original).
2. Mover el EIP al EC2 nuevo (no cambia el DNS).
3. Correr `bootstrap-ec2.sh`.
4. Si tuviste que recrear el EBS desde snapshot, los datos vienen incluidos.
   Si no tenias el EBS y usas un mysqldump de S3, restorear con el comando de
   "Backups" arriba.

Tiempo: 15-20 min si el snapshot esta cerca.

---

## Troubleshooting

| Sintoma | Diagnostico | Fix |
|---|---|---|
| `curl https://...` da `connection refused` | Security group cierra 443 | abrir 443 en SG |
| Caddy no obtiene cert: error ACME `no such host` | DNS no propagó | esperar; re-arrancar `docker compose restart caddy` |
| Caddy no obtiene cert: rate limit | Let's Encrypt cuota | usar staging endpoint mientras testeas (`acme_ca https://acme-staging-v02.api.letsencrypt.org/directory`) |
| `/api/projects` da 502 | DevLake no arrancó | `docker logs greencode-devlake \| tail -50` |
| Login Grafana redirige a localhost | `GF_SERVER_ROOT_URL` mal | poner `https://metrics.greencode.com.ar` en .env y reiniciar grafana |
| Webhook deploys no aparece en DORA | falta job `org` que hace project_mapping | Re-correr blueprint del project; o esperar cron diario |
