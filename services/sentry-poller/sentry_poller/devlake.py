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
            try:
                resp = self._s.post(url, json=payload, timeout=30)
            except requests.RequestException as exc:
                last = f"error de red: {exc}"
            else:
                code = resp.status_code
                if 200 <= code < 300:
                    return
                if 400 <= code < 500:
                    raise RuntimeError(f"DevLake rechazó el payload (HTTP {code}): {resp.text[:300]}")
                last = f"HTTP {code}"
            if attempt < self._max_retries:
                time.sleep(attempt * 2)  # backoff solo ENTRE intentos (5xx o red)
        raise RuntimeError(f"DevLake no respondió OK tras {self._max_retries} intentos (último {last})")
