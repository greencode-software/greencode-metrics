from unittest.mock import MagicMock
from sentry_poller.config import ProjectCfg
from sentry_poller.sync import sync_project

PROJ = ProjectCfg("tallone-sistema-de-gestion", "tallone-prod", 4)

def _issue(id_, level="error", status="unresolved"):
    return {"id": id_, "title": "t", "level": level, "status": status,
            "firstSeen": "2026-01-01T00:00:00Z", "lastSeen": "2026-01-02T00:00:00Z",
            "permalink": "http://x"}

def test_sync_posts_only_qualifying():
    sentry = MagicMock()
    sentry.list_incident_issues.return_value = [
        _issue("1", level="error"),
        _issue("2", level="warning"),   # no califica
        _issue("3", level="fatal"),
    ]
    devlake = MagicMock()
    stats = sync_project(sentry, devlake, PROJ)
    assert stats == {"fetched": 3, "qualified": 2, "posted": 2, "errors": 0}
    assert devlake.post_issue.call_count == 2
    # postea a la connection del project
    conn_ids = {call.args[0] for call in devlake.post_issue.call_args_list}
    assert conn_ids == {4}

def test_sync_resolved_fetches_resolution_date():
    sentry = MagicMock()
    sentry.list_incident_issues.return_value = [_issue("9", status="resolved")]
    sentry.resolution_date.return_value = "2026-01-02T05:00:00Z"
    devlake = MagicMock()
    sync_project(sentry, devlake, PROJ)
    sentry.resolution_date.assert_called_once_with("9")
    payload = devlake.post_issue.call_args.args[1]
    assert payload["status"] == "DONE"
    assert payload["resolutionDate"] == "2026-01-02T05:00:00+00:00"

def test_sync_dry_run_does_not_post():
    sentry = MagicMock()
    sentry.list_incident_issues.return_value = [_issue("1")]
    devlake = MagicMock()
    stats = sync_project(sentry, devlake, PROJ, dry_run=True)
    assert stats["posted"] == 1        # cuenta lo que hubiera posteado
    devlake.post_issue.assert_not_called()

def test_sync_counts_post_errors_and_continues():
    sentry = MagicMock()
    sentry.list_incident_issues.return_value = [_issue("1"), _issue("2")]
    devlake = MagicMock()
    devlake.post_issue.side_effect = [RuntimeError("boom"), None]
    stats = sync_project(sentry, devlake, PROJ)
    assert stats["posted"] == 1
    assert stats["errors"] == 1
