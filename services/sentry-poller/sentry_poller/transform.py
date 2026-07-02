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
