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
