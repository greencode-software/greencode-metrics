# Conectá tu repo a las métricas DORA

> Guía para **dueños de proyecto**. En ~10 minutos dejás tu repo conectado al
> stack de métricas de Greencode (DevLake) y empezás a ver **Deploy Frequency**
> y **Lead Time** en Grafana. No necesitás acceso a servidores ni SSH.

## Qué vas a lograr

- Tu repo aparece como un **project** en DevLake (trae commits, PRs, reviews).
- Cada push a tu rama default queda registrado como **deploy** → Deploy Frequency.
- Todo se ve en Grafana: https://devlake.greencodesoftware.com

## Requisitos (una sola vez)

1. **Claude Code** instalado.
2. **Plugin GreenQA** ≥ **0.4.0** (marketplace `greencode-internal`).
3. Un **GitHub token** que vea tu repo (PAT clásico con scope `repo` **y** `workflow`,
   o fine-grained equivalente). El scope `workflow` es obligatorio para el paso 2.
4. La **basic-auth de DevLake** — pedísela al equipo de Plataforma (`@elamonica`).
   Es la llave del API de métricas; guardala como un secret, no la compartas.

## Paso a paso

### 1. Instalá / actualizá el plugin GreenQA

En Claude Code:

```
/plugin
```

Buscá **Greencode Quality (GreenQA)** en el marketplace `greencode-internal` e
instalalo (o actualizá si ya lo tenés; con autoUpdate suele venir solo).

### 2. Configurá las credenciales (archivo `.env` del plugin)

Copiá `.env.example` a `.env` dentro del plugin y completá:

```
GITHUB_TOKEN=<tu PAT con scope repo + workflow>
DEVLAKE_BASIC_AUTH=greencode:<pass que te pasó Plataforma>
```

> ¿Repos de varios owners? Podés usar `GITHUB_TOKEN_<OWNER>` (ej:
> `GITHUB_TOKEN_GREENCODE_SOFTWARE`). El plugin busca primero el del owner.

### 3. Onboardeá el repo (trae la historia)

```
/onboard-dora owner/repo nombre-project
```

- `owner/repo` — ej: `greencode-software/mi-repo`
- `nombre-project` — nombre en DevLake, kebab-case `<cliente>-<producto>`
  (ej: `pinvest-platform`). Si no sabés cuál usar, preguntale a Plataforma.

Esto crea el project en DevLake y dispara la primera ingesta (commits, PRs, reviews).

### 4. Instrumentá los deploys

```
/setup-dora owner/repo nombre-project
```

Abre un **PR** en tu repo que agrega `.github/workflows/dora-deploy.yml`. El skill
te imprime el comando exacto para setear el **repo secret** `DEVLAKE_DEPLOY_WEBHOOK`.

### 5. Cerrá el círculo

1. **Mergeá el PR** que abrió el paso 4.
2. **Seteá el repo secret** con el comando que te imprimió el skill.
3. **Hacé un push** a tu rama default (o simplemente mergeá algo).

### 6. Verificá

En unos minutos, en Grafana (https://devlake.greencodesoftware.com) filtrás por tu
project y deberías ver una entrada de **Deploy Frequency**. Listo, quedaste conectado.

## Si algo falla

| Síntoma | Causa probable | Fix |
|---|---|---|
| El skill dice que no ve el repo | El token no tiene acceso | Usá `GITHUB_TOKEN_<OWNER>` con un PAT que vea ese repo |
| **404** al subir el workflow (paso 4) | Al token le falta el scope `workflow` | `env -u GITHUB_TOKEN -u GH_TOKEN gh auth refresh -h github.com -s workflow` |
| No aparece Deploy Frequency | Todavía no hubo push post-merge | Hacé un push a la rama default y esperá unos minutos |
| `/onboard-dora` da 401 | Falta / está mal `DEVLAKE_BASIC_AUTH` | Revisá el `.env`; pedí la creds a Plataforma |

## Qué pedirle a Plataforma

- La **basic-auth de DevLake** (`DEVLAKE_BASIC_AUTH`).
- El **nombre del project** en kebab-case, si no lo tenés definido.

## Nota sobre los números

Hoy, si tu repo no deploya por GitHub Actions, el workflow dispara en **cada push**
a la rama default y siempre reporta `SUCCESS` (timing aproximado). Sirve muy bien
para **Deploy Frequency**; el **Lead Time exacto** queda pendiente de enganchar el
deploy real. Si tenés un job de deploy en Actions, avisá a Plataforma para medir mejor.
