# ONBOARDING — Greencode Metrics

> Guía para que un miembro del equipo se sume al proyecto en ~30 min.
>
> Si recién llegás: leé este archivo de principio a fin. Después `CLAUDE.md`
> (decisiones de diseño), `docs/STATUS.md` (estado actual) y `docs/ROADMAP.md`
> (qué falta hacer).

---

## ¿Qué es esto?

Plataforma centralizada de **engineering metrics** para todos los proyectos de
Greencode Software SRL. Es **Apache DevLake** (engine open-source) + MySQL +
Grafana + Caddy, productivo en un Droplet de DigitalOcean.

**Para qué sirve:**
- Métricas DORA por proyecto (Deploy Frequency, Lead Time, Change Failure Rate, MTTR).
- Evidencia objetiva para auditorías ISO 9001:2015.
- Medir impacto de la adopción de IA, con cohortes pre/post fecha definida.

**Decisiones críticas a tener en mente** (más detalle en `CLAUDE.md`):
- AI tracking se hace por **cohortes temporales**, NO por labels en PRs.
- Cada proyecto tiene un nombre canónico en DevLake: `<cliente>-<producto>` en kebab-case.
- Nada de secrets en el repo en plain text. SOPS+age para producción.

---

## 1. Pre-requisitos en tu Mac (10 min)

Asumimos Mac con Homebrew. Adaptá si usás Linux/WSL.

```bash
# Tools básicos
brew install git gh sops age jq

# Docker Desktop (si no lo tenés)
# https://www.docker.com/products/docker-desktop/
# O via brew: brew install --cask docker

# Verificar
docker --version
gh --version
sops --version
age --version
```

**Verificá que Docker corre**: abrí Docker Desktop y esperá que el daemon arranque.
Después: `docker ps` debería responder sin error.

---

## 2. Acceso — qué pedirle al líder técnico

Mandale un mensaje al líder técnico (`@elamonica`) pidiendo:

1. **Acceso al repo**: invitación a `github.com/greencode-software/greencode-metrics` (ya es público, pero necesitás write access para PR-ear).
2. **SSH key registrada en el Droplet** productivo: te pedirá tu pubkey (`cat ~/.ssh/id_ed25519.pub`).
3. **age private key**: la baja de 1Password (vault `greencode-metrics`, Secure Note "DevLake prod credentials"). Guardala en `~/.config/sops/age/keys.txt`:
   ```bash
   mkdir -p ~/.config/sops/age
   # pegar el contenido en keys.txt:
   $EDITOR ~/.config/sops/age/keys.txt
   chmod 600 ~/.config/sops/age/keys.txt
   ```
4. **Acceso a 1Password vault `greencode-metrics`** (todas las credentials viven ahí).
5. **Invite a DigitalOcean** (rol read-only para empezar; ver consola y métricas).

**No te pase tokens por chat/email**. Todo via 1Password o vault compartido.

---

## 3. Setup local (5 min)

```bash
git clone git@github.com:greencode-software/greencode-metrics.git
cd greencode-metrics

# Crear .env local con dummy values para dev
cp secrets/prod.env.example docker/.env
$EDITOR docker/.env
# Reemplazar TODOS los REPLACE_ME con valores dummy. NO uses los de prod.
# Para passwords aleatorios: openssl rand -base64 24

# Levantar stack local (sin Caddy)
cd docker
docker compose up -d

# Esperar 60s a que MySQL termine de inicializar
sleep 60
docker compose ps
# Esperás ver 4 containers Up: mysql, devlake, grafana, config-ui
```

**URLs locales:**
- Grafana:    http://localhost:3001 (login `admin` / la pass que pusiste en `.env`)
- Config UI:  http://localhost:4000
- DevLake API: http://localhost:8088

⚠️ Si tenés otros stacks en la Mac usando 3000/8080, los puertos están remapeados
a 3001/8088 a propósito. Mirá el docker-compose para detalles.

---

## 4. Acceso a producción (5 min)

Una vez que el líder te registró la SSH key:

```bash
# Validar SSH al droplet
ssh root@134.199.247.25 'echo ok'

# Validar prod desde tu Mac
curl -I https://devlake.greencodesoftware.com
# → HTTP/2 302 (redirect a /login, Grafana)

curl -I https://api.devlake.greencodesoftware.com/api/projects
# → HTTP/2 401 (basic auth requerida)
```

**Para acceder a la Config UI en prod** (no expuesta públicamente):

```bash
# en una terminal aparte, dejar abierto:
ssh -L 4000:127.0.0.1:4000 root@134.199.247.25 -N

# en el browser:
open http://localhost:4000
```

**Para descifrar `prod.env.sops`** (solo si necesitás ver/editar secrets reales):

```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
sops -d --input-type dotenv --output-type dotenv secrets/prod.env.sops
# IMPORTANTE: nunca redirijas la salida a un archivo en disco salvo /tmp/
# y borralo inmediatamente después.
```

---

## 5. Arquitectura en 1 minuto

```
                                  ┌─────────────────────────────┐
                                  │  DigitalOcean Droplet NYC3  │
                                  │  134.199.247.25 (Reserved)  │
                                  │                              │
        devlake.greencodesoftware.com ─┤── Caddy (TLS auto) ─── Grafana :3000
                                  │       │                       │
    api.devlake.greencodesoftware.com ─┤   ├── basic_auth ─────── DevLake :8080
                                  │       │                       │
                                  │       └── webhook público ────┘
                                  │                              │
                                  │  MySQL :3306 (interno)       │
                                  │  Config UI :4000 (loopback)  │
                                  │  Volume /var/lib/docker      │
                                  └─────────────────────────────┘
                                                │
                                  cron weekly mysqldump → DO Spaces
```

- **Caddy** termina TLS (Let's Encrypt auto) y rutea por hostname.
- **DevLake** es el engine: tiene plugins (github, bitbucket, sentry-webhook, sonarqube, dora, etc.).
- **Grafana** es la vista. Login via Google OAuth (`@greencodesoftware.com`).
- **MySQL** persiste todo lo que ingesta DevLake.
- **Config UI** sirve para administrar connections/blueprints desde una UI (alternativa al API).
- **DO Spaces** (S3-compatible) recibe los backups.

Secrets cifrados con **SOPS+age**. El droplet descifra al boot con la age private key en `/etc/sops/age/keys.txt`.

---

## 6. Estructura del repo

```
.
├── CLAUDE.md                # decisiones de diseño + roadmap original (autoridad)
├── ONBOARDING.md            # este archivo
├── docker/                  # stack
│   ├── docker-compose.yml   # base (mysql + devlake + grafana + config-ui)
│   ├── .env                 # local dummy, gitignored
│   └── caddy/               # overlay productivo (Caddy + cierre de puertos)
├── docs/
│   ├── CONVENTIONS.md       # cómo instrumentar un proyecto Greencode
│   ├── STATUS.md            # estado actual (qué está corriendo, qué no)
│   ├── ROADMAP.md           # pendientes priorizados
│   ├── baselines.yml        # fechas AI adoption start por proyecto
│   └── runbooks/            # paso-a-paso de tareas operativas
├── actions/dora-deploy/     # composite GH action para notificar deploys a DevLake
├── scripts/
│   ├── bootstrap-droplet.sh        # provisioning del droplet (idempotente)
│   └── onboard-github-project.sh   # onboardea un repo a DevLake (idempotente)
├── grafana-custom/          # dashboards JSON custom (vacío todavía)
├── plugins/kimai/           # plugin PyDevLake (futuro)
└── secrets/
    ├── prod.env.example     # template
    └── prod.env.sops        # cifrado con age
```

---

## 7. Workflow para contribuir

1. **Branch desde master**:
   ```bash
   git checkout -b <tu-nombre>/<descripcion-corta>
   ```
2. **Commitear** en chunks lógicos. Mensajes en español.
3. **Validar local** antes de pushear:
   - Si tocaste `docker-compose.yml`: `docker compose config` y `docker compose up -d` local.
   - Si tocaste el `Caddyfile`: verificá con `docker run --rm -v $PWD/docker/caddy/Caddyfile:/etc/caddy/Caddyfile:ro caddy:2.8-alpine caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile` (puede tirar warning por env vars no expandidos — eso es OK).
   - Si tocaste el `onboard-github-project.sh`: `bash -n scripts/onboard-github-project.sh` (syntax check).
4. **Push** y abrir PR contra `master`.
5. **Review** por el líder técnico. Si urge y es low-risk, merge directo después de validar.
6. **Deploy a prod** (si el cambio aplica): SSH al droplet, `git pull`, `docker compose -f docker-compose.yml -f caddy/docker-compose.caddy.yml up -d` o `caddy reload` según corresponda.

⚠️ **No pushear `master` saltando PR salvo emergencia documentada**. El repo no tiene protected branches todavía pero la convención es PR-driven.

---

## 8. Convenciones críticas

Estas las te ahorran horas (las aprendimos a los golpes):

1. **`sops -d` para `prod.env.sops` SIEMPRE necesita `--input-type dotenv --output-type dotenv`**. Sin esto, sops asume JSON y falla con "invalid character '#'".
2. **`SOPS_AGE_KEY_FILE` debe estar seteado** para descifrar. En tu Mac: `~/.config/sops/age/keys.txt`. En el droplet: `/etc/sops/age/keys.txt` (ya está en `.bashrc` del root).
3. **No imprimir tokens** — ni prefijos, ni longitud, en logs, en commits, en chat. Si los necesitás, pipearlos inline al destino y olvidate.
4. **Naming de proyectos en DevLake**: `<cliente>-<producto>` en kebab-case. Ejemplos en `docs/CONVENTIONS.md`.
5. **Connection name = `<project>-github`** (o `-bitbucket`, etc.). Lo impone el script de onboarding.
6. **Scope payload del plugin github**: `name`=repo solo (`tallone`), `fullName`=`owner/repo` (`elamonica/tallone`). Si te confundís, da 404.
7. **Caddy: NO usar `/api/*` genérico** para mandar a DevLake. Conflicto con Grafana (ambos usan `/api/`). Por eso hay subdominio `api.devlake.*` separado.
8. **Mínimo 4GB RAM en el droplet**. Con 1GB hay swap thrashing al primer boot.

---

## 9. Tu primera contribución sugerida

Pick uno según interés:

- **DO Uptime Check** (`docs/ROADMAP.md §3.1`) — el más simple, 30 min. Te familiarizás con la DO console.
- **Configurar Sentry webhook** (`§1.1`) — útil y aprendés DevLake API. ~2h.
- **Onboardear un segundo proyecto** (`§2.2-2.4`) — gana exposure al flujo end-to-end. ~2h.
- **Custom dashboard "scorecard"** (`§8.1`) — si te gusta Grafana. ~4h.

Después de tu primer merge, ya estás en órbita. Sumate al equipo en Slack y avísanos.

---

## 10. Recursos y links útiles

- **Repo**: https://github.com/greencode-software/greencode-metrics
- **Grafana prod**: https://devlake.greencodesoftware.com
- **DevLake API prod**: https://api.devlake.greencodesoftware.com/api/
- **Apache DevLake docs**: https://devlake.apache.org/docs/
- **DO console**: https://cloud.digitalocean.com/
- **Route 53**: AWS console, dominio `greencodesoftware.com`
- **1Password vault**: `greencode-metrics`

---

## ¿Quedaste trabado?

- Lo primero: leé `docs/STATUS.md` para ver el estado actual.
- Después `git log --oneline -20` para entender el contexto reciente.
- Si todavía no resolvés, hablalo en el canal `#greencode-metrics` (Slack) o pingueá al líder técnico directo.

Welcome aboard 🚀
