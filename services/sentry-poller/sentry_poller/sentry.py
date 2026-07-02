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
        params = {"query": "level:[error,fatal]", "environment": "production",
                  "statsPeriod": "14d", "limit": 100}
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
        # endpoint es "activities" (plural); "activity" (singular) da 404 en Sentry SaaS.
        # el body sigue trayendo la lista bajo la key "activity".
        r = self._s.get(f"{self._base}/issues/{issue_id}/activities/", timeout=30)
        r.raise_for_status()
        latest = None
        for act in r.json().get("activity", []):
            if act.get("type") in _RESOLVED_ACTIVITY:
                latest = act.get("dateCreated")  # activity viene más-reciente-primero
                break
        return latest
