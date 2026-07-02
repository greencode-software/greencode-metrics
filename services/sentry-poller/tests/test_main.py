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
