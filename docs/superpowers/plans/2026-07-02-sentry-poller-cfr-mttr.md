# Sentry Poller (CFR/MTTR) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Un container que consulta la API de Sentry por incidents de producción y los postea al webhook de DevLake, habilitando CFR y MTTR por project.

**Architecture:** Poller (pull) stateless/idempotente. Loop cada N min: por cada project del config, lista issues de Sentry (prod, error/fatal), transforma a payload DevLake, y postea a la webhook connection `<project>-incidents` de ese project. Dentro del compose network pega directo a `devlake:8080` (sin Caddy).

**Tech Stack:** Python 3.12, `requests`, `PyYAML`, `pytest`. Poetry. Docker.

## Global Constraints

- Python **3.12**. Deps mínimas: `requests`, `pyyaml` (runtime); `pytest` (dev). Nada más.
- El **token nunca** se imprime ni se logea ni va al config. Solo por env `SENTRY_AUTH_TOKEN`.
- Sentry org: **`greencode`**. Base API: `https://sentry.io/api/0`.
- DevLake webhook base **dentro del stack**: `http://devlake:8080/plugins/webhook` (root, sin `/api`, sin auth). El backend sirve en root (verificado).
- Incident payload DevLake (campos requeridos): `issueKey`, `title`, `status` (`TODO|IN_PROGRESS|DONE`), `originalStatus`, `createdDate` (ISO-8601 con offset `+00:00`). Para DORA: `type="INCIDENT"`; `resolutionDate` al resolver.
- Criterio de incident: `level ∈ {error, fatal}` y `environment=production` y `status ∈ {unresolved, resolved}` (se ignoran `ignored`).
- Naming: connection por project `<devlake-project>-incidents` (paralelo a `<devlake-project>-deployments`).
- El poller es **idempotente**: re-postear el mismo `issueKey` actualiza; no hay estado local.
- `statsPeriod` del endpoint de issues solo acepta `''|24h|14d` (NO `90d`).

---

### Task 1: Scaffold + config loader

**Files:**
- Create: `services/sentry-poller/pyproject.toml`
- Create: `services/sentry-poller/config.yml`
- Create: `services/sentry-poller/sentry_poller/__init__.py`
- Create: `services/sentry-poller/sentry_poller/config.py`
- Test: `services/sentry-poller/tests/test_config.py`

**Interfaces:**
- Produces: `load_config(path: str) -> Config` donde
  `Config = {"sentry_org": str, "poll_interval_minutes": int, "devlake_webhook_base": str, "projects": list[ProjectCfg]}`
  y `ProjectCfg = {"devlake_project": str, "sentry_project": str, "incidents_connection_id": int}`.
  Devuelto como dataclasses `Config` y `ProjectCfg`.

- [ ] **Step 1: Escribir el test que falla**

`services/sentry-poller/tests/test_config.py`:
```python
from pathlib import Path
from sentry_poller.config import load_config

def test_load_config_parses_projects(tmp_path: Path):
    cfg_file = tmp_path / "config.yml"
    cfg_file.write_text(
        "sentry_org: greencode\n"
        "poll_interval_minutes: 30\n"
        "devlake_webhook_base: http://devlake:8080/plugins/webhook\n"
        "projects:\n"
        "  - devlake_project: tallone-sistema-de-gestion\n"
        "    sentry_project: tallone-prod\n"
        "    incidents_connection_id: 4\n"
    )
    cfg = load_config(str(cfg_file))
    assert cfg.sentry_org == "greencode"
    assert cfg.poll_interval_minutes == 30
    assert cfg.devlake_webhook_base == "http://devlake:8080/plugins/webhook"
    assert len(cfg.projects) == 1
    assert cfg.projects[0].sentry_project == "tallone-prod"
    assert cfg.projects[0].incidents_connection_id == 4

def test_load_config_rejects_missing_field(tmp_path: Path):
    cfg_file = tmp_path / "bad.yml"
    cfg_file.write_text(
        "sentry_org: greencode\n"
        "poll_interval_minutes: 30\n"
        "devlake_webhook_base: http://devlake:8080/plugins/webhook\n"
        "projects:\n"
        "  - devlake_project: x\n"
        "    sentry_project: y\n"  # falta incidents_connection_id
    )
    import pytest
    with pytest.raises(ValueError, match="incidents_connection_id"):
        load_config(str(cfg_file))
```

- [ ] **Step 2: Correr el test — debe fallar**

Run: `cd services/sentry-poller && poetry run pytest tests/test_config.py -v`
Expected: FAIL (`ModuleNotFoundError: sentry_poller.config`)

- [ ] **Step 3: Crear pyproject.toml**

`services/sentry-poller/pyproject.toml`:
```toml
[tool.poetry]
name = "sentry-poller"
version = "0.1.0"
description = "Poll Sentry incidents into DevLake for DORA CFR/MTTR"
authors = ["Greencode Software"]
packages = [{ include = "sentry_poller" }]

[tool.poetry.dependencies]
python = "^3.12"
requests = "^2.32"
pyyaml = "^6.0"

[tool.poetry.group.dev.dependencies]
pytest = "^8.0"

[build-system]
requires = ["poetry-core"]
build-backend = "poetry.core.masonry.api"
```

- [ ] **Step 4: Crear el package + config.py**

`services/sentry-poller/sentry_poller/__init__.py`: (vacío)

`services/sentry-poller/sentry_poller/config.py`:
```python
from __future__ import annotations
from dataclasses import dataclass
import yaml


@dataclass(frozen=True)
class ProjectCfg:
    devlake_project: str
    sentry_project: str
    incidents_connection_id: int


@dataclass(frozen=True)
class Config:
    sentry_org: str
    poll_interval_minutes: int
    devlake_webhook_base: str
    projects: list[ProjectCfg]


_REQUIRED_TOP = ("sentry_org", "poll_interval_minutes", "devlake_webhook_base", "projects")
_REQUIRED_PROJ = ("devlake_project", "sentry_project", "incidents_connection_id")


def load_config(path: str) -> Config:
    with open(path) as fh:
        raw = yaml.safe_load(fh) or {}
    for key in _REQUIRED_TOP:
        if key not in raw:
            raise ValueError(f"config: falta campo requerido '{key}'")
    projects = []
    for i, p in enumerate(raw["projects"]):
        for key in _REQUIRED_PROJ:
            if key not in p:
                raise ValueError(f"config: project[{i}] falta '{key}'")
        projects.append(ProjectCfg(
            devlake_project=p["devlake_project"],
            sentry_project=p["sentry_project"],
            incidents_connection_id=int(p["incidents_connection_id"]),
        ))
    return Config(
        sentry_org=raw["sentry_org"],
        poll_interval_minutes=int(raw["poll_interval_minutes"]),
        devlake_webhook_base=raw["devlake_webhook_base"],
        projects=projects,
    )
```

`services/sentry-poller/config.yml`:
```yaml
sentry_org: greencode
poll_interval_minutes: 30
devlake_webhook_base: http://devlake:8080/plugins/webhook
projects:
  - devlake_project: tallone-sistema-de-gestion
    sentry_project: tallone-prod
    incidents_connection_id: 0   # reemplazar por el id real de tallone-incidents (Task 8/9)
```

- [ ] **Step 5: Correr el test — debe pasar**

Run: `cd services/sentry-poller && poetry install && poetry run pytest tests/test_config.py -v`
Expected: PASS (2 passed)

- [ ] **Step 6: Commit**

```bash
git add services/sentry-poller/pyproject.toml services/sentry-poller/config.yml services/sentry-poller/sentry_poller/ services/sentry-poller/tests/test_config.py
git commit -m "feat(sentry-poller): scaffold + config loader"
```

---

### Task 2: transform — issue Sentry → payload DevLake (PURO)

**Files:**
- Create: `services/sentry-poller/sentry_poller/transform.py`
- Test: `services/sentry-poller/tests/test_transform.py`

**Interfaces:**
- Consumes: nada (funciones puras sobre dicts).
- Produces:
  - `QUALIFYING_LEVELS: set[str]` = `{"error", "fatal"}`
  - `qualifies(issue: dict) -> bool` — True si `issue["level"]` está en QUALIFYING_LEVELS y `issue["status"]` en `{"unresolved","resolved"}`.
  - `to_devlake_payload(issue: dict, resolution_date: str | None) -> dict` — payload listo para POST.
  - `normalize_ts(ts: str) -> str` — normaliza `...Z` → `...+00:00`.

- [ ] **Step 1: Escribir el test que falla**

`services/sentry-poller/tests/test_transform.py`:
```python
from sentry_poller.transform import qualifies, to_devlake_payload, normalize_ts

UNRESOLVED = {
    "id": "6907284203",
    "title": "Error: StreamChat error code 4",
    "level": "error",
    "status": "unresolved",
    "firstSeen": "2025-09-27T14:36:26.910000Z",
    "lastSeen": "2026-07-02T15:32:33.196000Z",
    "permalink": "https://greencode.sentry.io/issues/6907284203/",
}
RESOLVED = {**UNRESOLVED, "status": "resolved"}

def test_normalize_ts_z_to_offset():
    assert normalize_ts("2025-09-27T14:36:26.910000Z") == "2025-09-27T14:36:26.910000+00:00"
    assert normalize_ts("2025-09-27T14:36:26+00:00") == "2025-09-27T14:36:26+00:00"

def test_qualifies_error_unresolved():
    assert qualifies(UNRESOLVED) is True

def test_qualifies_rejects_warning():
    assert qualifies({**UNRESOLVED, "level": "warning"}) is False

def test_qualifies_rejects_ignored():
    assert qualifies({**UNRESOLVED, "status": "ignored"}) is False

def test_qualifies_accepts_fatal_resolved():
    assert qualifies({**RESOLVED, "level": "fatal"}) is True

def test_payload_unresolved_is_in_progress():
    p = to_devlake_payload(UNRESOLVED, None)
    assert p["issueKey"] == "6907284203"
    assert p["type"] == "INCIDENT"
    assert p["status"] == "IN_PROGRESS"
    assert p["originalStatus"] == "unresolved"
    assert p["createdDate"] == "2025-09-27T14:36:26.910000+00:00"
    assert p["url"] == "https://greencode.sentry.io/issues/6907284203/"
    assert "resolutionDate" not in p

def test_payload_resolved_sets_resolution_date():
    p = to_devlake_payload(RESOLVED, "2026-07-01T10:00:00Z")
    assert p["status"] == "DONE"
    assert p["resolutionDate"] == "2026-07-01T10:00:00+00:00"

def test_payload_resolved_without_activity_falls_back_to_last_seen():
    p = to_devlake_payload(RESOLVED, None)
    assert p["status"] == "DONE"
    assert p["resolutionDate"] == "2026-07-02T15:32:33.196000+00:00"

def test_payload_truncates_long_title():
    long = {**UNRESOLVED, "title": "x" * 400}
    assert len(to_devlake_payload(long, None)["title"]) == 255
```

- [ ] **Step 2: Correr el test — debe fallar**

Run: `cd services/sentry-poller && poetry run pytest tests/test_transform.py -v`
Expected: FAIL (`ModuleNotFoundError: sentry_poller.transform`)

- [ ] **Step 3: Implementar transform.py**

`services/sentry-poller/sentry_poller/transform.py`:
```python
from __future__ import annotations

QUALIFYING_LEVELS = {"error", "fatal"}
_INCIDENT_STATUSES = {"unresolved", "resolved"}


def normalize_ts(ts: str) -> str:
    """Sentry usa sufijo 'Z'; DevLake espera offset '+00:00'. Ambos ISO-8601."""
    return ts[:-1] + "+00:00" if ts.endswith("Z") else ts


def qualifies(issue: dict) -> bool:
    return (
        issue.get("level") in QUALIFYING_LEVELS
        and issue.get("status") in _INCIDENT_STATUSES
    )


def to_devlake_payload(issue: dict, resolution_date: str | None) -> dict:
    resolved = issue["status"] == "resolved"
    payload = {
        "issueKey": str(issue["id"]),
        "title": issue["title"][:255],
        "url": issue.get("permalink", ""),
        "type": "INCIDENT",
        "status": "DONE" if resolved else "IN_PROGRESS",
        "originalStatus": issue["status"],
        "createdDate": normalize_ts(issue["firstSeen"]),
    }
    if resolved:
        payload["resolutionDate"] = normalize_ts(resolution_date or issue["lastSeen"])
    return payload
```

- [ ] **Step 4: Correr el test — debe pasar**

Run: `cd services/sentry-poller && poetry run pytest tests/test_transform.py -v`
Expected: PASS (9 passed)

- [ ] **Step 5: Commit**

```bash
git add services/sentry-poller/sentry_poller/transform.py services/sentry-poller/tests/test_transform.py
git commit -m "feat(sentry-poller): transform Sentry issue -> DevLake incident payload"
```

---

### Task 3: Sentry API client

**Files:**
- Create: `services/sentry-poller/sentry_poller/sentry.py`
- Test: `services/sentry-poller/tests/test_sentry.py`

**Interfaces:**
- Consumes: nada.
- Produces: clase `SentryClient(token: str, org: str, base: str = "https://sentry.io/api/0", session=None)` con:
  - `list_incident_issues(project_slug: str) -> list[dict]` — issues con `level:[error,fatal]`, `environment=production`, paginado por header `Link`.
  - `resolution_date(issue_id: str) -> str | None` — dateCreated del último activity con type en `{"set_resolved","set_resolved_in_release","set_resolved_in_commit"}`, o `None`.

- [ ] **Step 1: Escribir el test que falla**

`services/sentry-poller/tests/test_sentry.py`:
```python
from unittest.mock import MagicMock
from sentry_poller.sentry import SentryClient

def _resp(json_data, link=None, status=200):
    r = MagicMock()
    r.status_code = status
    r.json.return_value = json_data
    r.headers = {"Link": link} if link else {}
    r.raise_for_status = MagicMock()
    return r

def test_list_incident_issues_single_page():
    session = MagicMock()
    session.get.return_value = _resp([{"id": "1", "level": "error"}])
    c = SentryClient("tok", "greencode", session=session)
    issues = c.list_incident_issues("tallone-prod")
    assert [i["id"] for i in issues] == ["1"]
    url, kwargs = session.get.call_args
    assert "projects/greencode/tallone-prod/issues/" in url[0]
    assert kwargs["params"]["environment"] == "production"
    assert kwargs["params"]["query"] == "level:[error,fatal]"

def test_list_incident_issues_follows_pagination():
    session = MagicMock()
    next_link = '<https://sentry.io/next>; rel="next"; results="true"; cursor="c1"'
    stop_link = '<https://sentry.io/stop>; rel="next"; results="false"; cursor="c2"'
    session.get.side_effect = [
        _resp([{"id": "1"}], link=next_link),
        _resp([{"id": "2"}], link=stop_link),
    ]
    c = SentryClient("tok", "greencode", session=session)
    issues = c.list_incident_issues("tallone-prod")
    assert [i["id"] for i in issues] == ["1", "2"]

def test_resolution_date_picks_set_resolved():
    session = MagicMock()
    session.get.return_value = _resp({"activity": [
        {"type": "note", "dateCreated": "2026-06-30T00:00:00Z"},
        {"type": "set_resolved", "dateCreated": "2026-07-01T10:00:00Z"},
    ]})
    c = SentryClient("tok", "greencode", session=session)
    assert c.resolution_date("1") == "2026-07-01T10:00:00Z"

def test_resolution_date_none_when_absent():
    session = MagicMock()
    session.get.return_value = _resp({"activity": [{"type": "note", "dateCreated": "x"}]})
    c = SentryClient("tok", "greencode", session=session)
    assert c.resolution_date("1") is None
```

- [ ] **Step 2: Correr el test — debe fallar**

Run: `cd services/sentry-poller && poetry run pytest tests/test_sentry.py -v`
Expected: FAIL (`ModuleNotFoundError: sentry_poller.sentry`)

- [ ] **Step 3: Implementar sentry.py**

`services/sentry-poller/sentry_poller/sentry.py`:
```python
from __future__ import annotations
import re
import requests

_RESOLVED_ACTIVITY = {"set_resolved", "set_resolved_in_release", "set_resolved_in_commit"}
_NEXT_RE = re.compile(r'<([^>]+)>;\s*rel="next";\s*results="(\w+)"')


class SentryClient:
    def __init__(self, token: str, org: str, base: str = "https://sentry.io/api/0", session=None):
        self._org = org
        self._base = base.rstrip("/")
        self._s = session or requests.Session()
        self._s.headers.update({"Authorization": f"Bearer {token}"})

    def list_incident_issues(self, project_slug: str) -> list[dict]:
        url = f"{self._base}/projects/{self._org}/{project_slug}/issues/"
        params = {"query": "level:[error,fatal]", "environment": "production", "limit": 100}
        out: list[dict] = []
        while url:
            r = self._s.get(url, params=params, timeout=30)
            r.raise_for_status()
            out.extend(r.json())
            url, params = self._next_page(r.headers.get("Link", ""))
        return out

    @staticmethod
    def _next_page(link_header: str):
        for m in _NEXT_RE.finditer(link_header):
            href, has_results = m.group(1), m.group(2)
            if has_results == "true":
                return href, None  # cursor ya está en la URL
        return None, None

    def resolution_date(self, issue_id: str) -> str | None:
        r = self._s.get(f"{self._base}/issues/{issue_id}/activity/", timeout=30)
        r.raise_for_status()
        latest = None
        for act in r.json().get("activity", []):
            if act.get("type") in _RESOLVED_ACTIVITY:
                latest = act.get("dateCreated")  # activity viene más-reciente-primero
                break
        return latest
```

- [ ] **Step 4: Correr el test — debe pasar**

Run: `cd services/sentry-poller && poetry run pytest tests/test_sentry.py -v`
Expected: PASS (4 passed)

- [ ] **Step 5: Commit**

```bash
git add services/sentry-poller/sentry_poller/sentry.py services/sentry-poller/tests/test_sentry.py
git commit -m "feat(sentry-poller): Sentry API client (issues + resolution date)"
```

---

### Task 4: DevLake webhook client

**Files:**
- Create: `services/sentry-poller/sentry_poller/devlake.py`
- Test: `services/sentry-poller/tests/test_devlake.py`

**Interfaces:**
- Consumes: nada.
- Produces: clase `DevLakeClient(webhook_base: str, session=None, max_retries: int = 3)` con
  `post_issue(connection_id: int, payload: dict) -> None` — POST a
  `{webhook_base}/connections/{connection_id}/issues`; reintenta en 5xx/red; lanza en 4xx.

- [ ] **Step 1: Escribir el test que falla**

`services/sentry-poller/tests/test_devlake.py`:
```python
from unittest.mock import MagicMock
import pytest
from sentry_poller.devlake import DevLakeClient

def _resp(status):
    r = MagicMock(); r.status_code = status; r.text = "ok"; return r

def test_post_issue_hits_correct_url():
    session = MagicMock(); session.post.return_value = _resp(200)
    c = DevLakeClient("http://devlake:8080/plugins/webhook", session=session)
    c.post_issue(4, {"issueKey": "1"})
    url, kwargs = session.post.call_args
    assert url[0] == "http://devlake:8080/plugins/webhook/connections/4/issues"
    assert kwargs["json"] == {"issueKey": "1"}

def test_post_issue_raises_on_4xx():
    session = MagicMock(); session.post.return_value = _resp(400)
    c = DevLakeClient("http://devlake:8080/plugins/webhook", session=session)
    with pytest.raises(RuntimeError, match="400"):
        c.post_issue(4, {"issueKey": "1"})

def test_post_issue_retries_on_5xx_then_succeeds():
    session = MagicMock()
    session.post.side_effect = [_resp(503), _resp(200)]
    c = DevLakeClient("http://devlake:8080/plugins/webhook", session=session, max_retries=3)
    c.post_issue(4, {"issueKey": "1"})
    assert session.post.call_count == 2
```

- [ ] **Step 2: Correr el test — debe fallar**

Run: `cd services/sentry-poller && poetry run pytest tests/test_devlake.py -v`
Expected: FAIL (`ModuleNotFoundError`)

- [ ] **Step 3: Implementar devlake.py**

`services/sentry-poller/sentry_poller/devlake.py`:
```python
from __future__ import annotations
import time
import requests


class DevLakeClient:
    def __init__(self, webhook_base: str, session=None, max_retries: int = 3):
        self._base = webhook_base.rstrip("/")
        self._s = session or requests.Session()
        self._max_retries = max_retries

    def post_issue(self, connection_id: int, payload: dict) -> None:
        url = f"{self._base}/connections/{connection_id}/issues"
        last = None
        for attempt in range(1, self._max_retries + 1):
            resp = self._s.post(url, json=payload, timeout=30)
            code = resp.status_code
            if 200 <= code < 300:
                return
            if 400 <= code < 500:
                raise RuntimeError(f"DevLake rechazó el payload (HTTP {code}): {resp.text[:300]}")
            last = code
            time.sleep(attempt * 2)  # backoff en 5xx/red
        raise RuntimeError(f"DevLake no respondió OK tras {self._max_retries} intentos (último HTTP {last})")
```

- [ ] **Step 4: Correr el test — debe pasar**

Run: `cd services/sentry-poller && poetry run pytest tests/test_devlake.py -v`
Expected: PASS (3 passed)

- [ ] **Step 5: Commit**

```bash
git add services/sentry-poller/sentry_poller/devlake.py services/sentry-poller/tests/test_devlake.py
git commit -m "feat(sentry-poller): DevLake webhook client (post_issue + retries)"
```

---

### Task 5: sync — orquestación por project

**Files:**
- Create: `services/sentry-poller/sentry_poller/sync.py`
- Test: `services/sentry-poller/tests/test_sync.py`

**Interfaces:**
- Consumes: `SentryClient` (Task 3), `DevLakeClient` (Task 4), `qualifies`/`to_devlake_payload` (Task 2), `ProjectCfg` (Task 1).
- Produces:
  - `sync_project(sentry, devlake, proj: ProjectCfg, dry_run: bool = False) -> dict` — devuelve
    `{"fetched": int, "qualified": int, "posted": int, "errors": int}`.
  - `sync_all(sentry, devlake, projects: list[ProjectCfg], dry_run: bool = False) -> list[dict]`.

- [ ] **Step 1: Escribir el test que falla**

`services/sentry-poller/tests/test_sync.py`:
```python
from unittest.mock import MagicMock
from sentry_poller.config import ProjectCfg
from sentry_poller.sync import sync_project

PROJ = ProjectCfg("tallone-sistema-de-gestion", "tallone-prod", 4)

def _issue(id_, level="error", status="unresolved"):
    return {"id": id_, "title": "t", "level": level, "status": status,
            "firstSeen": "2026-01-01T00:00:00Z", "lastSeen": "2026-01-02T00:00:00Z",
            "permalink": "http://x"}

def test_sync_posts_only_qualifying():
    sentry = MagicMock()
    sentry.list_incident_issues.return_value = [
        _issue("1", level="error"),
        _issue("2", level="warning"),   # no califica
        _issue("3", level="fatal"),
    ]
    devlake = MagicMock()
    stats = sync_project(sentry, devlake, PROJ)
    assert stats == {"fetched": 3, "qualified": 2, "posted": 2, "errors": 0}
    assert devlake.post_issue.call_count == 2
    # postea a la connection del project
    conn_ids = {call.args[0] for call in devlake.post_issue.call_args_list}
    assert conn_ids == {4}

def test_sync_resolved_fetches_resolution_date():
    sentry = MagicMock()
    sentry.list_incident_issues.return_value = [_issue("9", status="resolved")]
    sentry.resolution_date.return_value = "2026-01-02T05:00:00Z"
    devlake = MagicMock()
    sync_project(sentry, devlake, PROJ)
    sentry.resolution_date.assert_called_once_with("9")
    payload = devlake.post_issue.call_args.args[1]
    assert payload["status"] == "DONE"
    assert payload["resolutionDate"] == "2026-01-02T05:00:00+00:00"

def test_sync_dry_run_does_not_post():
    sentry = MagicMock()
    sentry.list_incident_issues.return_value = [_issue("1")]
    devlake = MagicMock()
    stats = sync_project(sentry, devlake, PROJ, dry_run=True)
    assert stats["posted"] == 1        # cuenta lo que hubiera posteado
    devlake.post_issue.assert_not_called()

def test_sync_counts_post_errors_and_continues():
    sentry = MagicMock()
    sentry.list_incident_issues.return_value = [_issue("1"), _issue("2")]
    devlake = MagicMock()
    devlake.post_issue.side_effect = [RuntimeError("boom"), None]
    stats = sync_project(sentry, devlake, PROJ)
    assert stats["posted"] == 1
    assert stats["errors"] == 1
```

- [ ] **Step 2: Correr el test — debe fallar**

Run: `cd services/sentry-poller && poetry run pytest tests/test_sync.py -v`
Expected: FAIL (`ModuleNotFoundError`)

- [ ] **Step 3: Implementar sync.py**

`services/sentry-poller/sentry_poller/sync.py`:
```python
from __future__ import annotations
import logging
from .config import ProjectCfg
from .transform import qualifies, to_devlake_payload

log = logging.getLogger("sentry_poller.sync")


def sync_project(sentry, devlake, proj: ProjectCfg, dry_run: bool = False) -> dict:
    stats = {"fetched": 0, "qualified": 0, "posted": 0, "errors": 0}
    issues = sentry.list_incident_issues(proj.sentry_project)
    stats["fetched"] = len(issues)
    for issue in issues:
        if not qualifies(issue):
            continue
        stats["qualified"] += 1
        resolution = sentry.resolution_date(issue["id"]) if issue["status"] == "resolved" else None
        payload = to_devlake_payload(issue, resolution)
        if dry_run:
            log.info("[dry-run] %s -> conn %s: %s", proj.sentry_project,
                     proj.incidents_connection_id, payload)
            stats["posted"] += 1
            continue
        try:
            devlake.post_issue(proj.incidents_connection_id, payload)
            stats["posted"] += 1
        except Exception as exc:  # noqa: BLE001 — un issue no debe frenar el resto
            stats["errors"] += 1
            log.warning("post falló para %s/%s: %s", proj.sentry_project, issue["id"], exc)
    return stats


def sync_all(sentry, devlake, projects: list[ProjectCfg], dry_run: bool = False) -> list[dict]:
    results = []
    for proj in projects:
        try:
            results.append(sync_project(sentry, devlake, proj, dry_run=dry_run))
        except Exception as exc:  # noqa: BLE001 — un project no debe frenar los demás
            log.error("sync de %s falló: %s", proj.sentry_project, exc)
            results.append({"fetched": 0, "qualified": 0, "posted": 0, "errors": 1})
    return results
```

- [ ] **Step 4: Correr el test — debe pasar**

Run: `cd services/sentry-poller && poetry run pytest tests/test_sync.py -v`
Expected: PASS (4 passed)

- [ ] **Step 5: Commit**

```bash
git add services/sentry-poller/sentry_poller/sync.py services/sentry-poller/tests/test_sync.py
git commit -m "feat(sentry-poller): sync orchestration por project + dry-run"
```

---

### Task 6: CLI / entrypoint (loop, --once, --dry-run)

**Files:**
- Create: `services/sentry-poller/sentry_poller/__main__.py`
- Test: `services/sentry-poller/tests/test_main.py`

**Interfaces:**
- Consumes: `load_config` (Task 1), `SentryClient`, `DevLakeClient`, `sync_all`.
- Produces: `build_clients(cfg, token) -> tuple[SentryClient, DevLakeClient]`; `run_once(cfg, token, dry_run) -> list[dict]`; `main(argv=None) -> int`.
- Requiere env `SENTRY_AUTH_TOKEN`. Flags: `--once`, `--dry-run`, `--config PATH` (default `config.yml`).

- [ ] **Step 1: Escribir el test que falla**

`services/sentry-poller/tests/test_main.py`:
```python
from unittest.mock import patch, MagicMock
from sentry_poller.config import Config, ProjectCfg
from sentry_poller.__main__ import run_once

CFG = Config("greencode", 30, "http://devlake:8080/plugins/webhook",
             [ProjectCfg("tallone-sistema-de-gestion", "tallone-prod", 4)])

def test_run_once_wires_clients_and_syncs():
    with patch("sentry_poller.__main__.SentryClient") as S, \
         patch("sentry_poller.__main__.DevLakeClient") as D, \
         patch("sentry_poller.__main__.sync_all", return_value=[{"posted": 1}]) as sync:
        out = run_once(CFG, "tok", dry_run=True)
    S.assert_called_once()
    D.assert_called_once_with("http://devlake:8080/plugins/webhook")
    assert sync.call_args.kwargs["dry_run"] is True
    assert out == [{"posted": 1}]

def test_main_requires_token(monkeypatch):
    from sentry_poller.__main__ import main
    monkeypatch.delenv("SENTRY_AUTH_TOKEN", raising=False)
    assert main(["--once", "--config", "/nonexistent"]) == 2
```

- [ ] **Step 2: Correr el test — debe fallar**

Run: `cd services/sentry-poller && poetry run pytest tests/test_main.py -v`
Expected: FAIL (`ModuleNotFoundError` / no `run_once`)

- [ ] **Step 3: Implementar __main__.py**

`services/sentry-poller/sentry_poller/__main__.py`:
```python
from __future__ import annotations
import argparse
import logging
import os
import sys
import time

from .config import Config, load_config
from .sentry import SentryClient
from .devlake import DevLakeClient
from .sync import sync_all

log = logging.getLogger("sentry_poller")


def build_clients(cfg: Config, token: str):
    sentry = SentryClient(token, cfg.sentry_org)
    devlake = DevLakeClient(cfg.devlake_webhook_base)
    return sentry, devlake


def run_once(cfg: Config, token: str, dry_run: bool):
    sentry, devlake = build_clients(cfg, token)
    results = sync_all(sentry, devlake, cfg.projects, dry_run=dry_run)
    for proj, stats in zip(cfg.projects, results):
        log.info("sync %s: %s", proj.sentry_project, stats)
    return results


def main(argv=None) -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    ap = argparse.ArgumentParser(prog="sentry-poller")
    ap.add_argument("--config", default=os.environ.get("SENTRY_POLLER_CONFIG", "config.yml"))
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--dry-run", action="store_true",
                    default=os.environ.get("SENTRY_POLLER_DRY_RUN") == "1")
    args = ap.parse_args(argv)

    token = os.environ.get("SENTRY_AUTH_TOKEN")
    if not token:
        log.error("falta env SENTRY_AUTH_TOKEN")
        return 2
    try:
        cfg = load_config(args.config)
    except (OSError, ValueError) as exc:
        log.error("config inválida: %s", exc)
        return 2

    if args.once:
        run_once(cfg, token, args.dry_run)
        return 0

    log.info("poller arrancado (cada %d min, dry_run=%s)", cfg.poll_interval_minutes, args.dry_run)
    while True:
        run_once(cfg, token, args.dry_run)
        time.sleep(cfg.poll_interval_minutes * 60)


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Correr el test — debe pasar**

Run: `cd services/sentry-poller && poetry run pytest tests/test_main.py -v && poetry run pytest -v`
Expected: PASS (test_main 2 passed; suite completa verde)

- [ ] **Step 5: Commit**

```bash
git add services/sentry-poller/sentry_poller/__main__.py services/sentry-poller/tests/test_main.py
git commit -m "feat(sentry-poller): CLI entrypoint (loop/--once/--dry-run)"
```

---

### Task 7: Dockerfile + docker-compose + secret

**Files:**
- Create: `services/sentry-poller/Dockerfile`
- Modify: `docker/docker-compose.yml` (agregar servicio `sentry-poller`)
- Modify: `secrets/prod.env.example` (agregar `SENTRY_AUTH_TOKEN=`)

**Interfaces:**
- Consumes: el package `sentry_poller` (Tasks 1-6).
- Produces: servicio `sentry-poller` en la red del compose que alcanza `devlake:8080`.

- [ ] **Step 1: Crear Dockerfile**

`services/sentry-poller/Dockerfile`:
```dockerfile
FROM python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir requests==2.32.3 pyyaml==6.0.2
COPY sentry_poller/ ./sentry_poller/
COPY config.yml ./config.yml
ENTRYPOINT ["python", "-m", "sentry_poller"]
```

- [ ] **Step 2: Agregar el servicio al compose**

Localizar el bloque `services:` en `docker/docker-compose.yml` y agregar (con la misma
indentación que los otros servicios, y usando el nombre de red/servicio `devlake`):
```yaml
  sentry-poller:
    build: ../services/sentry-poller
    container_name: greencode-sentry-poller
    restart: always
    environment:
      SENTRY_AUTH_TOKEN: ${SENTRY_AUTH_TOKEN}
    depends_on:
      - devlake
    # config.yml viaja en la imagen; para overridear sin rebuild, montar:
    # volumes:
    #   - ../services/sentry-poller/config.yml:/app/config.yml:ro
```

- [ ] **Step 3: Agregar el secret al ejemplo**

En `secrets/prod.env.example`, agregar una línea:
```
SENTRY_AUTH_TOKEN=
```

- [ ] **Step 4: Validar el compose**

Run: `cd docker && SENTRY_AUTH_TOKEN=dummy docker compose config >/dev/null && echo OK`
Expected: `OK` (sin errores de sintaxis)

- [ ] **Step 5: Commit**

```bash
git add services/sentry-poller/Dockerfile docker/docker-compose.yml secrets/prod.env.example
git commit -m "feat(sentry-poller): Dockerfile + servicio compose + secret ejemplo"
```

---

### Task 8: onboard-github-project.sh — crear `<project>-incidents`

**Files:**
- Modify: `scripts/onboard-github-project.sh`

**Interfaces:**
- Consumes: patrón existente de la webhook connection `<project>-deployments` (sección 6b) y el merge de blueprint (sección 7).
- Produces: connection `<project>-incidents` creada + bindeada al blueprint; su id impreso en el resumen.

- [ ] **Step 1: Definir el nombre de la connection**

En `scripts/onboard-github-project.sh`, junto a `WEBHOOK_CONN_NAME="${PROJECT_NAME}-deployments"`, agregar:
```bash
INCIDENTS_CONN_NAME="${PROJECT_NAME}-incidents"
```

- [ ] **Step 2: Crear la connection de incidents (idempotente)**

Justo después del bloque `# ---------- 6b. webhook connection de deployments ...`, agregar un bloque análogo:
```bash
# ---------- 6c. webhook connection de incidents (DORA CFR/MTTR) ----------
log "Webhook de incidents \"$INCIDENTS_CONN_NAME\""
INC_ID=$(dl_curl "$DEVLAKE_API/plugins/webhook/connections" \
  | jq --arg n "$INCIDENTS_CONN_NAME" '[.[]|select(.name==$n)][0].id // empty')
if [[ -n "$INC_ID" ]]; then
  ok "ya existe (id=$INC_ID)"
else
  INC_ID=$(dl_curl -X POST -H 'Content-Type: application/json' \
    -d "$(jq -n --arg n "$INCIDENTS_CONN_NAME" '{name:$n}')" \
    "$DEVLAKE_API/plugins/webhook/connections" | jq '.id')
  ok "creada (id=$INC_ID) — incidents iran a scope webhook:$INC_ID"
fi
```

- [ ] **Step 3: Bindear la connection de incidents en el blueprint**

En la sección 7, donde se arma `WH_CONN_BLOCK` y el `PATCH_BODY`, agregar el bloque de
incidents y sumarlo al array. Reemplazar el bloque existente por:
```bash
NEW_CONN_BLOCK=$(jq -n --argjson cid "$CONN_ID" --argjson sid "$GITHUB_ID" \
  '{pluginName:"github", connectionId:$cid, scopes:[{scopeId:($sid|tostring)}]}')
WH_CONN_BLOCK=$(jq -n --argjson cid "$WH_ID" \
  '{pluginName:"webhook", connectionId:$cid, scopes:[{scopeId:($cid|tostring)}]}')
INC_CONN_BLOCK=$(jq -n --argjson cid "$INC_ID" \
  '{pluginName:"webhook", connectionId:$cid, scopes:[{scopeId:($cid|tostring)}]}')
PATCH_BODY=$(jq --argjson new "$NEW_CONN_BLOCK" --argjson wh "$WH_CONN_BLOCK" --argjson inc "$INC_CONN_BLOCK" --arg ta "$TIME_AFTER" '
  .blueprints[0]
  | .connections = ((.connections // [])
      | map(select(
          (.pluginName!="github"  or .connectionId!=$new.connectionId) and
          (.pluginName!="webhook" or (.connectionId!=$wh.connectionId and .connectionId!=$inc.connectionId))))
      + [$new, $wh, $inc])
  | {connections: .connections, timeAfter: $ta}
' <<<"$BP_JSON")
```

- [ ] **Step 4: Mostrar la connection de incidents en el resumen**

En la sección 9, después de la línea `echo "  Webhook deploy:..."`, agregar:
```bash
echo "  Webhook incident:id=$INC_ID  ($INCIDENTS_CONN_NAME) → scope webhook:$INC_ID"
```
Y en el bloque DORA del resumen, agregar:
```bash
echo "    3) CFR/MTTR: poné incidents_connection_id: $INC_ID para $PROJECT_NAME en services/sentry-poller/config.yml"
```

- [ ] **Step 5: Validar sintaxis**

Run: `bash -n scripts/onboard-github-project.sh && echo OK`
Expected: `OK`

- [ ] **Step 6: Commit**

```bash
git add scripts/onboard-github-project.sh
git commit -m "feat(onboard): crear webhook <project>-incidents + bindear al blueprint"
```

---

### Task 9: Integración — crear `tallone-incidents`, verificar CFR/MTTR

**Files:**
- Modify: `services/sentry-poller/config.yml` (poner el id real)
- Modify: `docs/STATUS.md` (registrar el estado)

**Interfaces:**
- Consumes: todo lo anterior. Corre contra el DevLake prod por SSH (backend `devlake:8080`).

> ⚠️ Estos pasos escriben en prod (DevLake). Confirmar con el usuario antes (política de
> la sesión). El backend no tiene auth; se accede por SSH a `root@134.199.247.25`.

- [ ] **Step 1: Crear la connection `tallone-incidents` + bindear al blueprint**

Correr el onboard idempotente para tallone (crea `tallone-incidents` y la bindea):
```bash
# por SSH/túnel, con la API de DevLake accesible. Anotar el INC_ID que imprime.
ssh root@134.199.247.25 'docker exec greencode-devlake curl -s -X POST -H "Content-Type: application/json" -d "{\"name\":\"tallone-incidents\"}" http://localhost:8080/plugins/webhook/connections' | jq '{name,id}'
```
Anotar el `id` (ej. 4). Bindearlo al blueprint 2 agregando el bloque webhook a `connections`
(mismo procedimiento validado para `tallone-deployments`: GET blueprint, jq add
`{pluginName:"webhook",connectionId:<INC_ID>,scopes:[{scopeId:"<INC_ID>"}]}`, PATCH, verificar GET).

- [ ] **Step 2: Poner el id real en el config**

Editar `services/sentry-poller/config.yml`: `incidents_connection_id: <INC_ID>`.

- [ ] **Step 3: Dry-run contra Sentry real**

```bash
cd services/sentry-poller
SENTRY_AUTH_TOKEN=<token> poetry run python -m sentry_poller --once --dry-run
```
Expected: loguea 0+ incidents de `tallone-prod` (hoy tallone-prod está limpio → 0 posted,
sin errores). Confirma que la query a Sentry funciona.

- [ ] **Step 4: Prueba real end-to-end (incident sintético)**

Postear un incident de prueba a `tallone-incidents` (scope webhook:<INC_ID>) y verificar la
query real de CFR/MTTR:
```bash
BASE=https://api.devlake.greencodesoftware.com/api/plugins/webhook
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"issueKey":"POLLER-TEST-1","title":"[TEST] poller","type":"INCIDENT","status":"DONE","originalStatus":"resolved","createdDate":"2026-07-02T10:00:00+00:00","resolutionDate":"2026-07-02T11:00:00+00:00","url":"http://x"}' \
  "$BASE/connections/<INC_ID>/issues"
# verificar en MySQL que el issue quedó con type=INCIDENT y resolution_date, y que la
# query de "Time to Restore Service" del dashboard devuelve MTTR para tallone.
```
Expected: 200; el incident aparece atribuido a `tallone-sistema-de-gestion`. **Limpiar** el
`POLLER-TEST-1` del MySQL después.

- [ ] **Step 5: Actualizar STATUS + commit**

Registrar en `docs/STATUS.md`: poller implementado, `tallone-incidents` creada+bindeada,
CFR/MTTR verificado. Commit:
```bash
git add services/sentry-poller/config.yml docs/STATUS.md
git commit -m "chore(sentry-poller): tallone-incidents id real + verificación CFR/MTTR"
```

---

## Notas de despliegue (post-implementación)

- Agregar `SENTRY_AUTH_TOKEN` al `secrets/prod.env.sops` (SOPS+age) — lo hace el dueño.
- Deploy: `git pull` en `/opt/devlake` + `docker compose ... up -d --build sentry-poller`.
  Recordar el gotcha de bind-mounts si se monta `config.yml` (restart, no solo reload).
- Escalar a otros projects: onboard del project (crea `<project>-incidents`) + agregar la
  entrada al `config.yml`.
