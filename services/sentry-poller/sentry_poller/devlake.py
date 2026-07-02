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
