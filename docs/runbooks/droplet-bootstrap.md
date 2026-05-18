# Runbook: bootstrap del stack DevLake en DigitalOcean Droplet

Levantar el stack desde cero en un Droplet nuevo, end-to-end. Sirve para:
- Setup productivo inicial.
- Recovery despues de un disaster (droplet destruido o region down).
- Setup de un environment de staging para probar upgrades de DevLake.

Tiempo estimado: 45-60 min la primera vez, ~10 min en recovery.

---

## Pre-requisitos (one-time, lider tecnico)

Antes del primer bootstrap, asegurarse que existen:

- [ ] **Cuenta DigitalOcean** con metodo de pago configurado.
- [ ] **DNS para `greencode.com.ar`**: actualmente en **AWS Route 53**. Sólo DNS; sin
      proxy/WAF. Para este caso (admin tool detrás de basic auth + Google OAuth) alcanza.
      Si en el futuro se quiere DDoS protection / esconder origin IP, mover a Cloudflare.
- [ ] **age key pair** generado (encriptacion de secrets via SOPS):
  ```bash
  mkdir -p ~/.config/sops/age
  age-keygen -o ~/.config/sops/age/keys.txt
  # Output: public key (age1xyz...) — copialo al .sops.yaml.
  # La private key (keys.txt) va a 1Password en una vault compartida del equipo.
  ```
  La private key es **lo unico** que da acceso a desencriptar prod secrets. Su perdida =
  re-crear todos los secrets desde cero (todas las connections DevLake, todos los tokens).
- [ ] **DO Spaces bucket** `greencode-devlake-backups` (region NYC3 o donde elijas).
- [ ] **DO Spaces Access Key + Secret** generados (API → Spaces Keys).
- [ ] **Google OAuth client** para Grafana (Console → APIs → Credentials → OAuth 2.0).
- [ ] **GitHub PAT** del usuario que va a ingresar los repos (por ahora: `elamonica`
      personal, con scopes `repo, read:org, read:user, workflow`). A futuro migrar a
      cuenta de servicio.
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

## Droplet + Volume + DNS (15 min)

1. **Crear Droplet**:
   - Region: NYC3 (latencia LATAM razonable y misma region que Spaces).
   - Image: Ubuntu 24.04 (LTS) x64.
   - Size: **Premium AMD 2vCPU / 4GB RAM / 80GB SSD** ($24/mo). Subir a 8GB cuando
     metas el plugin Kimai o tengas 5+ proyectos.
   - Authentication: SSH key (tu key publica).
   - Hostname: `metrics-prod-01`.
   - Tags: `devlake`, `prod`.

2. **Reserved IP**: API → Networking → Reserved IPs → New → asignar al droplet.
   Sin esto, cada destroy/create del droplet cambia la IP y rompe el DNS.

3. **Block Storage Volume**:
   - Volumes → Create → 50 GB, region NYC3, **name: `devlake-data`**.
   - Attach al droplet, **sin auto-format** (el bootstrap lo formatea).
   - El device aparece como `/dev/disk/by-id/scsi-0DO_Volume_devlake-data`.

4. **DO Cloud Firewall** (equivalente a SG de AWS):
   - Inbound: 22 (SSH) desde tu IP, 80/443 desde 0.0.0.0/0.
   - Outbound: todo.
   - Apply al droplet.

5. **DNS en Route 53**:
   - AWS Console → Route 53 → Hosted zones → `greencode.com.ar` → Create record.
   - Record name: `metrics`, Type: **A**, Value: `<Reserved IP>`, TTL 300, Simple routing.
   - Propagacion <1 min.

6. **Verificar DNS antes de seguir**:
   ```bash
   dig +short metrics.greencode.com.ar
   # debe devolver la Reserved IP
   ```

---

## Bootstrap (10 min)

SSH al droplet:

```bash
ssh root@metrics.greencode.com.ar
```

**Paso unico antes de correr el script**: subir la age private key. Solo se hace
una vez por droplet (o cuando se rota la key):

```bash
# desde tu Mac:
scp ~/.config/sops/age/keys.txt root@metrics.greencode.com.ar:/tmp/age-keys.txt

# en el droplet:
mkdir -p /etc/sops/age
mv /tmp/age-keys.txt /etc/sops/age/keys.txt
chmod 600 /etc/sops/age/keys.txt
chown root:root /etc/sops/age/keys.txt
```

Correr el bootstrap:

```bash
sudo bash <(curl -sL https://raw.githubusercontent.com/greencode-software/greencode-metrics/master/scripts/bootstrap-droplet.sh)
```

El script es idempotente. Si falla a la mitad, lo re-corres y retoma.

---

## Validacion (5 min)

- [ ] `dig +short metrics.greencode.com.ar` → Reserved IP correcta.
- [ ] `curl -I https://metrics.greencode.com.ar` → 200 OK, header `Server: Caddy`.
- [ ] `curl -I https://metrics.greencode.com.ar/api/plugins/webhook/connections`
      → 200 con JSON (path publico).
- [ ] `curl -I https://metrics.greencode.com.ar/api/projects` → 401 Unauthorized
      (basic auth protegiendo).
- [ ] Browser a `https://metrics.greencode.com.ar` → Grafana login con Google.
- [ ] Browser a `https://metrics.greencode.com.ar/admin` → prompt basic auth → Config UI.

DNS via Route 53: nada mas que hacer aca despues de validar (no hay proxy que activar).
Si en el futuro se decide mover a Cloudflare, ver "Migracion DNS" mas abajo.

---

## Onboarding de proyectos contra el stack productivo

```bash
# desde tu Mac (no en el droplet), con DEVLAKE_API apuntando al stack publico:
DEVLAKE_API="https://metrics.greencode.com.ar/api" \
  ./scripts/onboard-github-project.sh \
    tallone-sistema-de-gestion elamonica/tallone

# para proyectos de la org greencode-software, usar la misma cuenta gh:
DEVLAKE_API="https://metrics.greencode.com.ar/api" \
  ./scripts/onboard-github-project.sh \
    pinvest-platform greencode-software/pinvest-api
```

Notas:
- El script usa `gh auth token` (tu cuenta personal `elamonica`) hasta que se cree un
  usuario de servicio. Tu cuenta debe tener acceso de lectura a los repos de la org.
- Como `/api/projects` requiere basic auth, hay que setear las credenciales:
  ```bash
  export DEVLAKE_BASIC_AUTH="greencode:<basic-pass>"
  ```
  (Pendiente: parametrizar `--basic-auth` en `scripts/onboard-github-project.sh`.)

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

El cron de `mysqldump → DO Spaces` queda configurado por el bootstrap (semanal,
domingos 03:00 UTC).

Para restore desde Spaces:

```bash
export AWS_ACCESS_KEY_ID="$DO_SPACES_KEY"
export AWS_SECRET_ACCESS_KEY="$DO_SPACES_SECRET"
aws s3 ls --endpoint-url "$DO_SPACES_ENDPOINT" s3://greencode-devlake-backups/ | tail -5
aws s3 cp --endpoint-url "$DO_SPACES_ENDPOINT" \
  s3://greencode-devlake-backups/devlake-lake-2026-MM-DDTHHmmZ.sql.gz - \
  | gunzip \
  | docker exec -i greencode-devlake-mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" lake
```

**Snapshots del Volume** van via DO console: Volume → Snapshots → Take Snapshot.
O programar via `doctl` en cron. Costo: $0.06/GB-month.

---

## Recovery: droplet reemplazado

Si el droplet muere y necesitas recrearlo:

1. Crear droplet nuevo (steps "Droplet + Volume + DNS" arriba), **detacheando el
   Volume del droplet viejo y atacheandolo al nuevo** si tenes los datos ahi.
2. Mover la Reserved IP al droplet nuevo (no cambia el DNS).
3. SCP la age key al `/etc/sops/age/keys.txt`.
4. Correr `bootstrap-droplet.sh`.
5. Si no tenes el Volume (perdiste tambien los datos), restorear desde Spaces con
   el comando de "Backups" arriba.

Tiempo: 15-20 min si tenes el Volume + Reserved IP intactos.

---

## Troubleshooting

| Sintoma | Diagnostico | Fix |
|---|---|---|
| `curl https://...` da `connection refused` | Cloud Firewall cierra 443 | abrir 443 en el FW |
| Caddy no obtiene cert: `no such host` | DNS no propagó | esperar; `docker compose restart caddy` |
| Caddy no obtiene cert despues de varios intentos | rate limit Let's Encrypt | usar staging mientras testeas: en Caddyfile global, `acme_ca https://acme-staging-v02.api.letsencrypt.org/directory` |
| `/api/projects` da 502 | DevLake no arrancó | `docker logs greencode-devlake \| tail -50` |
| Login Grafana redirige a localhost | `GF_SERVER_ROOT_URL` mal | poner `https://metrics.greencode.com.ar` en .env y reiniciar grafana |
| Webhook deploys no aparece en DORA | falta job `org` que hace project_mapping | re-correr blueprint del project; o esperar cron diario |
| Cloudflare da error 521 (web server is down) | Caddy crasheó o no escucha en 80/443 | `docker compose logs caddy`; chequear que ports 80/443 esten libres |
| `sops -d` falla con "no key could decrypt the data" | age key faltante o no es la correcta | verificar `/etc/sops/age/keys.txt` esta presente y permisos 600; la public key del .sops.yaml tiene que matchear con la private |
