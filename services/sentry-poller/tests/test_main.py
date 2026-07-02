from unittest.mock import patch
import pytest
from sentry_poller.config import Config, ProjectCfg
from sentry_poller.__main__ import run_once

CFG = Config("greencode", 30, "http://devlake:8080/plugins/webhook",
             [ProjectCfg("tallone-sistema-de-gestion", "tallone-prod", 4)])

def test_run_once_wires_clients_and_syncs():
    with patch("sentry_poller.__main__.SentryClient") as S, \
         patch("sentry_poller.__main__.DevLakeClient") as D, \
         patch("sentry_poller.__main__.sync_all", return_value=[{"posted": 1}]) as sync:
        out = run_once(CFG, "tok", dry_run=True)
    S.assert_called_once_with("tok", "greencode")
    D.assert_called_once_with("http://devlake:8080/plugins/webhook")
    assert sync.call_args.kwargs["dry_run"] is True
    assert out == [{"posted": 1}]

def test_main_requires_token(monkeypatch):
    from sentry_poller.__main__ import main
    monkeypatch.delenv("SENTRY_AUTH_TOKEN", raising=False)
    assert main(["--once", "--config", "/nonexistent"]) == 2

def test_main_invalid_config_returns_2(monkeypatch, tmp_path):
    from sentry_poller.__main__ import main
    monkeypatch.setenv("SENTRY_AUTH_TOKEN", "tok")
    bad = tmp_path / "bad.yml"
    bad.write_text("sentry_org: [unclosed\n")  # malformed YAML -> load_config raises ValueError
    assert main(["--once", "--config", str(bad)]) == 2

def test_main_loop_runs_once_then_sleeps(monkeypatch):
    from sentry_poller import __main__ as m
    monkeypatch.setenv("SENTRY_AUTH_TOKEN", "tok")
    cfg = Config("greencode", 30, "http://devlake:8080/plugins/webhook",
                 [ProjectCfg("p", "p-prod", 4)])
    monkeypatch.setattr(m, "load_config", lambda _p: cfg)
    calls = {"n": 0}
    monkeypatch.setattr(m, "run_once", lambda *a, **k: calls.__setitem__("n", calls["n"] + 1))

    class _Stop(Exception):
        pass

    sleeps = []
    def _sleep(secs):
        sleeps.append(secs)
        raise _Stop()
    monkeypatch.setattr(m.time, "sleep", _sleep)

    with pytest.raises(_Stop):
        m.main([])  # no --once -> enters the poll loop
    assert calls["n"] == 1
    assert sleeps == [30 * 60]
