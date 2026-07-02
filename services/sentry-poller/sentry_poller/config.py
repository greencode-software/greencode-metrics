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
        try:
            raw = yaml.safe_load(fh)
        except yaml.YAMLError as exc:
            raise ValueError(f"config: YAML inválido: {exc}") from exc
    raw = raw or {}
    if not isinstance(raw, dict):
        raise ValueError("config: el root debe ser un mapping")
    for key in _REQUIRED_TOP:
        if key not in raw:
            raise ValueError(f"config: falta campo requerido '{key}'")
    if not isinstance(raw["projects"], list):
        raise ValueError("config: 'projects' debe ser una lista")
    projects = []
    for i, p in enumerate(raw["projects"]):
        if not isinstance(p, dict):
            raise ValueError(f"config: project[{i}] debe ser un mapping")
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
