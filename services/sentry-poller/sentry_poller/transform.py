from __future__ import annotations
import re

QUALIFYING_LEVELS = {"error", "fatal"}
_INCIDENT_STATUSES = {"unresolved", "resolved"}

# Sentry manda microsegundos (6 decimales); DevLake parsea con layout de
# milisegundos (".000") y rechaza (HTTP 400) más de 3 dígitos de fracción.
_TRUNC_FRAC = re.compile(r"(\.\d{3})\d+")


def normalize_ts(ts: str) -> str:
    """Sentry usa sufijo 'Z' y microsegundos; DevLake espera offset '+00:00' y
    milisegundos (3 decimales). Pasamos Z->+00:00 y truncamos la fracción a 3."""
    s = ts[:-1] + "+00:00" if ts.endswith("Z") else ts
    return _TRUNC_FRAC.sub(r"\1", s)


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
