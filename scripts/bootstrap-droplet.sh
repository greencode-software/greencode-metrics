#!/usr/bin/env bash
# Bootstrap idempotente de un DigitalOcean Droplet fresh → DevLake en produccion.
#
# Asume:
#   - Ubuntu 24.04 LTS.
#   - Hay un Block Storage Volume adicional adjunto al droplet (typicamente en
#     /dev/disk/by-id/scsi-0DO_Volume_<volume-name>).
#   - La age private key ya esta en /etc/sops/age/keys.txt (SCP-eada en el primer
#     boot, una sola vez por el lider tecnico. Ver droplet-bootstrap.md).
#   - DO Spaces access key / secret estan dentro del SOPS secrets (no aca).
#
# Re-run safe: cada step chequea si ya esta hecho antes de actuar.
#
# Uso:
#   sudo bash <(curl -sL https://raw.githubusercontent.com/greencode-software/greencode-metrics/master/scripts/bootstrap-droplet.sh)

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/greencode-software/greencode-metrics.git}"
INSTALL_DIR="${INSTALL_DIR:-/opt/devlake}"
# Default name del Block Storage Volume en DO. Ajustar si lo creas con otro nombre.
DO_VOLUME_NAME="${DO_VOLUME_NAME:-devlake-data}"
DATA_DEVICE="/dev/disk/by-id/scsi-0DO_Volume_${DO_VOLUME_NAME}"
DATA_MOUNT="/var/lib/docker"
AGE_KEY_FILE="/etc/sops/age/keys.txt"

log()  { printf "\n\033[1;34m→\033[0m %s\n" "$*"; }
ok()   { printf "  \033[1;32m✓\033[0m %s\n" "$*"; }
warn() { printf "  \033[1;33m!\033[0m %s\n" "$*"; }
err()  { printf "  \033[1;31m✗\033[0m %s\n" "$*" >&2; }

[[ $EUID -eq 0 ]] || { err "correr como root (sudo)"; exit 1; }

# ---------- 0. precondiciones ----------
if [[ ! -s "$AGE_KEY_FILE" ]]; then
  err "Falta la age private key en $AGE_KEY_FILE."
  err "Antes de correr este script, transferila una vez via SCP:"
  err "  scp ~/.config/sops/age/keys.txt root@<droplet-ip>:$AGE_KEY_FILE"
  err "  ssh root@<droplet-ip> chmod 600 $AGE_KEY_FILE"
  exit 1
fi

# ---------- 1. paquetes base ----------
log "Instalando paquetes base"
if ! command -v docker >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg lsb-release git python3 python3-pip jq unzip
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  ok "docker instalado"
else
  ok "docker ya estaba"
fi

if ! command -v sops >/dev/null 2>&1; then
  SOPS_VER="3.9.1"
  curl -fsSL "https://github.com/getsops/sops/releases/download/v${SOPS_VER}/sops-v${SOPS_VER}.linux.amd64" -o /usr/local/bin/sops
  chmod +x /usr/local/bin/sops
  ok "sops $SOPS_VER instalado"
else
  ok "sops ya estaba"
fi

command -v age >/dev/null 2>&1 || { apt-get install -y -qq age; ok "age instalado"; }

# awscli v2 - via binary oficial. En Ubuntu 24.04 el paquete 'awscli' (v1) fue
# removido del repo principal por EOL de Python; v2 se distribuye por AWS direct.
if ! command -v aws >/dev/null 2>&1; then
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) AWS_ZIP_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" ;;
    aarch64|arm64) AWS_ZIP_URL="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" ;;
    *) err "arquitectura desconocida: $ARCH"; exit 1 ;;
  esac
  tmpdir=$(mktemp -d)
  ( cd "$tmpdir" && curl -fsSL "$AWS_ZIP_URL" -o awscliv2.zip && unzip -q awscliv2.zip && ./aws/install --update )
  rm -rf "$tmpdir"
  ok "aws cli v2 instalado ($(aws --version 2>&1))"
else
  ok "aws cli ya estaba"
fi

# ---------- 2. Block Storage para /var/lib/docker ----------
log "Configurando DO Block Storage para Docker"
if [[ -b "$DATA_DEVICE" ]]; then
  if ! blkid "$DATA_DEVICE" >/dev/null 2>&1; then
    warn "formateando $DATA_DEVICE (primera vez)"
    mkfs.ext4 -L docker-data "$DATA_DEVICE"
  fi
  if ! mountpoint -q "$DATA_MOUNT"; then
    systemctl stop docker 2>/dev/null || true
    mkdir -p "$DATA_MOUNT"
    UUID=$(blkid -s UUID -o value "$DATA_DEVICE")
    grep -q "$UUID" /etc/fstab || echo "UUID=$UUID  $DATA_MOUNT  ext4  defaults,nofail,discard  0  2" >> /etc/fstab
    mount -a
    systemctl start docker
  fi
  ok "$DATA_DEVICE montado en $DATA_MOUNT"
else
  warn "$DATA_DEVICE no existe; usando disco raiz para /var/lib/docker"
  warn "Adjunta un DO Volume llamado '$DO_VOLUME_NAME' antes que crezca el MySQL."
fi

# ---------- 3. repo ----------
log "Repo en $INSTALL_DIR"
if [[ ! -d "$INSTALL_DIR/.git" ]]; then
  git clone "$REPO_URL" "$INSTALL_DIR"
  ok "clonado"
else
  git -C "$INSTALL_DIR" pull --ff-only
  ok "pull --ff-only OK"
fi

# ---------- 4. secrets ----------
log "Decriptando secrets via SOPS+age"
export SOPS_AGE_KEY_FILE="$AGE_KEY_FILE"

# Persistir SOPS_AGE_KEY_FILE en /root/.bashrc para shells interactivas futuras,
# asi un admin puede correr `sops -d secrets/prod.env.sops` sin tener que setear
# la env var cada vez.
if ! grep -q "SOPS_AGE_KEY_FILE=$AGE_KEY_FILE" /root/.bashrc 2>/dev/null; then
  echo "export SOPS_AGE_KEY_FILE=$AGE_KEY_FILE" >> /root/.bashrc
  ok "SOPS_AGE_KEY_FILE persistido en /root/.bashrc"
fi

SOPS_FILE="$INSTALL_DIR/secrets/prod.env.sops"
ENV_FILE="$INSTALL_DIR/docker/.env"
if [[ ! -f "$SOPS_FILE" ]]; then
  err "$SOPS_FILE no existe. Encriptar primero desde la maquina del admin:"
  err "  sops -e secrets/prod.env > secrets/prod.env.sops"
  exit 1
fi
sops -d --input-type dotenv --output-type dotenv "$SOPS_FILE" > "$ENV_FILE"
chmod 600 "$ENV_FILE"
ok ".env escrito ($(wc -l < "$ENV_FILE") lineas)"

# ---------- 5. stack ----------
log "Levantando docker compose"
cd "$INSTALL_DIR/docker"
docker compose -f docker-compose.yml -f caddy/docker-compose.caddy.yml pull
docker compose -f docker-compose.yml -f caddy/docker-compose.caddy.yml up -d
ok "stack arriba"

# ---------- 6. backups cron a DO Spaces ----------
log "Cron de backup mysqldump → DO Spaces"
BACKUP_SCRIPT=/usr/local/bin/devlake-backup.sh
cat > "$BACKUP_SCRIPT" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
source /opt/devlake/docker/.env
SPACE="${DO_SPACES_BUCKET:?}"
ENDPOINT="${DO_SPACES_ENDPOINT:?}"            # ej: https://nyc3.digitaloceanspaces.com
export AWS_ACCESS_KEY_ID="${DO_SPACES_KEY:?}"
export AWS_SECRET_ACCESS_KEY="${DO_SPACES_SECRET:?}"
TS=$(date -u +%Y-%m-%dT%H%MZ)
docker exec greencode-devlake-mysql \
  mysqldump --single-transaction --quick -uroot -p"$MYSQL_ROOT_PASSWORD" lake \
  | gzip \
  | aws s3 cp - "s3://${SPACE}/devlake-lake-${TS}.sql.gz" \
      --endpoint-url "$ENDPOINT"
BASH
chmod 700 "$BACKUP_SCRIPT"
CRON_LINE="0 3 * * 0 root $BACKUP_SCRIPT > /var/log/devlake-backup.log 2>&1"
grep -qF "$BACKUP_SCRIPT" /etc/crontab || echo "$CRON_LINE" >> /etc/crontab
ok "backup semanal: domingos 03:00 UTC → s3://${DO_SPACES_BUCKET:-<spaces-bucket>}/"

# ---------- 7. healthcheck visible ----------
log "Verificando servicios"
sleep 8
docker compose -f docker-compose.yml -f caddy/docker-compose.caddy.yml ps

log "Bootstrap completado."
echo
echo "  Proximos pasos manuales:"
echo "    1. Verificar DNS: dig +short \$DOMAIN  (debe dar la Reserved IP del droplet)"
echo "    2. Probar TLS:    curl -I https://\$DOMAIN  (debe dar 200 OK con cert Let's Encrypt)"
echo "    3. Login Grafana en https://\$DOMAIN  (Google OAuth)"
echo "    4. Re-onboardear proyectos: DEVLAKE_API=https://\$DOMAIN/api scripts/onboard-github-project.sh ..."
