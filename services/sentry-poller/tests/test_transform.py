from sentry_poller.transform import qualifies, to_devlake_payload, normalize_ts

UNRESOLVED = {
    "id": "6907284203",
    "title": "Error: StreamChat error code 4",
    "level": "error",
    "status": "unresolved",
    "firstSeen": "2025-09-27T14:36:26.910000Z",
    "lastSeen": "2026-07-02T15:32:33.196000Z",
    "permalink": "https://greencode.sentry.io/issues/6907284203/",
}
RESOLVED = {**UNRESOLVED, "status": "resolved"}

def test_normalize_ts_z_to_offset():
    assert normalize_ts("2025-09-27T14:36:26.910000Z") == "2025-09-27T14:36:26.910+00:00"
    assert normalize_ts("2025-09-27T14:36:26+00:00") == "2025-09-27T14:36:26+00:00"

def test_normalize_ts_truncates_micros_to_millis():
    # DevLake parsea millis (.000) y rechaza 6 decimales con HTTP 400
    assert normalize_ts("2026-04-24T14:26:11.247822Z") == "2026-04-24T14:26:11.247+00:00"
    assert normalize_ts("2026-04-24T14:26:11.247822+00:00") == "2026-04-24T14:26:11.247+00:00"

def test_qualifies_error_unresolved():
    assert qualifies(UNRESOLVED) is True

def test_qualifies_rejects_warning():
    assert qualifies({**UNRESOLVED, "level": "warning"}) is False

def test_qualifies_rejects_ignored():
    assert qualifies({**UNRESOLVED, "status": "ignored"}) is False

def test_qualifies_accepts_fatal_resolved():
    assert qualifies({**RESOLVED, "level": "fatal"}) is True

def test_payload_unresolved_is_in_progress():
    p = to_devlake_payload(UNRESOLVED, None)
    assert p["issueKey"] == "6907284203"
    assert p["type"] == "INCIDENT"
    assert p["status"] == "IN_PROGRESS"
    assert p["originalStatus"] == "unresolved"
    assert p["createdDate"] == "2025-09-27T14:36:26.910+00:00"
    assert p["url"] == "https://greencode.sentry.io/issues/6907284203/"
    assert "resolutionDate" not in p

def test_payload_resolved_sets_resolution_date():
    p = to_devlake_payload(RESOLVED, "2026-07-01T10:00:00Z")
    assert p["status"] == "DONE"
    assert p["resolutionDate"] == "2026-07-01T10:00:00+00:00"

def test_payload_resolved_without_activity_falls_back_to_last_seen():
    p = to_devlake_payload(RESOLVED, None)
    assert p["status"] == "DONE"
    assert p["resolutionDate"] == "2026-07-02T15:32:33.196+00:00"

def test_payload_truncates_long_title():
    long = {**UNRESOLVED, "title": "x" * 400}
    assert len(to_devlake_payload(long, None)["title"]) == 255
