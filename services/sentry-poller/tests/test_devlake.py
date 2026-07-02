from unittest.mock import MagicMock
import pytest
import requests
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

def test_post_issue_retries_on_5xx_then_succeeds(monkeypatch):
    import sentry_poller.devlake as dv
    monkeypatch.setattr(dv.time, "sleep", lambda *_: None)
    session = MagicMock()
    session.post.side_effect = [_resp(503), _resp(200)]
    c = DevLakeClient("http://devlake:8080/plugins/webhook", session=session, max_retries=3)
    c.post_issue(4, {"issueKey": "1"})
    assert session.post.call_count == 2

def test_post_issue_retries_on_network_error_then_succeeds(monkeypatch):
    import sentry_poller.devlake as dv
    monkeypatch.setattr(dv.time, "sleep", lambda *_: None)
    session = MagicMock()
    session.post.side_effect = [requests.ConnectionError("boom"), _resp(200)]
    c = DevLakeClient("http://devlake:8080/plugins/webhook", session=session, max_retries=3)
    c.post_issue(4, {"issueKey": "1"})
    assert session.post.call_count == 2

def test_post_issue_raises_after_exhausting_retries(monkeypatch):
    import sentry_poller.devlake as dv
    monkeypatch.setattr(dv.time, "sleep", lambda *_: None)
    session = MagicMock()
    session.post.return_value = _resp(503)
    c = DevLakeClient("http://devlake:8080/plugins/webhook", session=session, max_retries=3)
    with pytest.raises(RuntimeError, match="503"):
        c.post_issue(4, {"issueKey": "1"})
    assert session.post.call_count == 3
