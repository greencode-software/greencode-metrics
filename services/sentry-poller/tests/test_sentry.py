from unittest.mock import MagicMock
from sentry_poller.sentry import SentryClient

def _resp(json_data, link=None, status=200):
    r = MagicMock()
    r.status_code = status
    r.json.return_value = json_data
    r.headers = {"Link": link} if link else {}
    r.raise_for_status = MagicMock()
    return r

def test_list_incident_issues_single_page():
    session = MagicMock()
    session.get.return_value = _resp([{"id": "1", "level": "error"}])
    c = SentryClient("tok", "greencode", session=session)
    issues = c.list_incident_issues("tallone-prod")
    assert [i["id"] for i in issues] == ["1"]
    url, kwargs = session.get.call_args
    assert "projects/greencode/tallone-prod/issues/" in url[0]
    assert kwargs["params"]["environment"] == "production"
    assert kwargs["params"]["query"] == "level:[error,fatal]"

def test_list_incident_issues_follows_pagination():
    session = MagicMock()
    next_link = '<https://sentry.io/next>; rel="next"; results="true"; cursor="c1"'
    stop_link = '<https://sentry.io/stop>; rel="next"; results="false"; cursor="c2"'
    session.get.side_effect = [
        _resp([{"id": "1"}], link=next_link),
        _resp([{"id": "2"}], link=stop_link),
    ]
    c = SentryClient("tok", "greencode", session=session)
    issues = c.list_incident_issues("tallone-prod")
    assert [i["id"] for i in issues] == ["1", "2"]

    # Verify cross-page filter preservation
    first_call, second_call = session.get.call_args_list
    assert first_call.kwargs["params"]["query"] == "level:[error,fatal]"
    assert first_call.kwargs["params"]["environment"] == "production"
    assert second_call.args[0] == "https://sentry.io/next"

def test_resolution_date_picks_set_resolved():
    session = MagicMock()
    session.get.return_value = _resp({"activity": [
        {"type": "note", "dateCreated": "2026-06-30T00:00:00Z"},
        {"type": "set_resolved", "dateCreated": "2026-07-01T10:00:00Z"},
    ]})
    c = SentryClient("tok", "greencode", session=session)
    assert c.resolution_date("1") == "2026-07-01T10:00:00Z"

def test_resolution_date_none_when_absent():
    session = MagicMock()
    session.get.return_value = _resp({"activity": [{"type": "note", "dateCreated": "x"}]})
    c = SentryClient("tok", "greencode", session=session)
    assert c.resolution_date("1") is None

def test_resolution_date_picks_most_recent_when_multiple():
    session = MagicMock()
    session.get.return_value = _resp({"activity": [
        {"type": "set_resolved", "dateCreated": "2026-07-05T09:00:00Z"},
        {"type": "set_resolved_in_release", "dateCreated": "2026-07-01T10:00:00Z"},
    ]})
    c = SentryClient("tok", "greencode", session=session)
    assert c.resolution_date("1") == "2026-07-05T09:00:00Z"
