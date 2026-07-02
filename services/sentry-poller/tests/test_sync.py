from unittest.mock import MagicMock
from sentry_poller.config import ProjectCfg
from sentry_poller.sync import sync_project, sync_all

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

def test_sync_project_counts_error_when_resolution_raises():
    # resolution_date raising mid-loop must count as 1 error and NOT abort the batch
    sentry = MagicMock()
    sentry.list_incident_issues.return_value = [_issue("1", status="resolved"), _issue("2")]
    sentry.resolution_date.side_effect = RuntimeError("sentry down")
    devlake = MagicMock()
    stats = sync_project(sentry, devlake, PROJ)
    assert stats["qualified"] == 2
    assert stats["errors"] == 1     # issue 1 (resolved) failed in resolution_date
    assert stats["posted"] == 1     # issue 2 (unresolved) still posted

def test_sync_all_isolates_project_failure():
    proj_ok = ProjectCfg("proj-a", "a-prod", 4)
    proj_bad = ProjectCfg("proj-b", "b-prod", 5)
    def _list(slug):
        if slug == "b-prod":
            raise RuntimeError("boom")
        return [_issue("1")]
    sentry = MagicMock()
    sentry.list_incident_issues.side_effect = _list
    devlake = MagicMock()
    results = sync_all(sentry, devlake, [proj_ok, proj_bad])
    assert len(results) == 2
    assert results[0]["posted"] == 1    # proj-a succeeded
    assert results[1]["errors"] == 1    # proj-b failure isolated

def test_sync_all_aggregates_multiple_projects():
    proj_a = ProjectCfg("proj-a", "a-prod", 4)
    proj_b = ProjectCfg("proj-b", "b-prod", 5)
    sentry = MagicMock()
    sentry.list_incident_issues.return_value = [_issue("1")]
    devlake = MagicMock()
    results = sync_all(sentry, devlake, [proj_a, proj_b])
    assert len(results) == 2
    assert all(r["posted"] == 1 for r in results)
