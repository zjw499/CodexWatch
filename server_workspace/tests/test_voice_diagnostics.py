import copy
import os
import uuid

import pytest

from server_workspace.tests.test_voice import voice  # isolated authenticated fixture
from server_workspace.voice_diagnostics import DiagnosticStore
from server_workspace.tests.test_voice import start


def report():
    return {"version": 1, "request_id": str(uuid.uuid4()), "revision": 1, "kind": "voice-startup",
            "build": "150", "watch_os": "26.6", "completed": False,
            "results": [{"phase": "N", "before": {"engineRunning": True, "captureRate": 48000.0},
                         "after": {"engineRunning": False}, "inputFrames": 1104, "drainedFrames": 1104,
                         "convertedFrames": 552, "pendingFrames": 552, "configurationChanges": 1,
                         "events": [{"kind": "stopped", "elapsedMs": 350, "attempt": 1,
                                     "snapshot": {"engineRunning": False}, "inputFrames": 1104,
                                     "convertedFrames": 552, "batches": 0}]}]}


def upload(v, body):
    return v[2].post("/voice/v1/diagnostics", headers=v[6], json=body)


def test_reply_playback_counters_are_safe_owner_bound_and_old_retries_still_match(voice):
    body = report(); body['kind'] = 'voice-session'
    body['transport'] = {'endReason': 'closed', 'peakUploadBytes': 192000}
    assert upload(voice, body).status_code == 200
    assert upload(voice, body).status_code == 200
    body['request_id'] = str(uuid.uuid4())
    body['transport'].update({'sessionID': str(uuid.uuid4()), 'replyPlayback': {
        'scheduledFrames': 9600, 'completedFrames': 4800, 'completedItems': 1}, 'maxAudioGapMs': 1700})
    assert upload(voice, body).status_code == 422
    session = start(voice)
    body['transport']['sessionID'] = session['id']
    assert upload(voice, body).status_code == 200
    body['request_id'] = str(uuid.uuid4())
    body['transport']['replyPlayback']['transcript'] = 'Must never be accepted'
    assert upload(voice, body).status_code == 422


def test_diagnostics_are_encrypted_owner_scoped_and_audited_on_admin_review(voice):
    w, private, public, people, _, _, vh, _ = voice
    body = report()
    assert upload(voice, body).status_code == 200
    alice, bobby, admin = [people[n][1] for n in ("alice", "bobby", "admin")]
    path = "/api/voice/diagnostics/" + body["request_id"]
    assert private.get(path, headers=alice).json()["report"]["results"][0]["inputFrames"] == 1104
    assert private.get(path, headers=bobby).status_code == 404
    assert private.get("/api/voice/diagnostics", headers=bobby).json()["reports"] == []
    assert private.get("/api/admin/voice/diagnostics", headers=alice).status_code == 403
    assert private.get("/api/admin/voice/diagnostics/" + body["request_id"], headers=admin).status_code == 200
    with w.db() as db:
        stored = db.execute("SELECT content FROM voice_diagnostics").fetchone()[0]
        assert stored.startswith(b"TEST:")  # injectable test cipher; production DPAPI is checked separately
        assert w.decode(stored)["results"][0]["inputFrames"] == 1104
        assert db.execute("SELECT 1 FROM audit WHERE action='admin-voice-diagnostics-reviewed' AND target=?",
                          (body["request_id"],)).fetchone()
    assert public.get("/voice/v1/diagnostics").status_code == 405
    assert public.get("/api/voice/diagnostics", headers=vh).status_code == 404
    assert public.post("/voice/v1/diagnostics", headers=alice, json=body).status_code == 401


def test_lost_ack_is_idempotent_and_speaker_feedback_cannot_modify_counters(voice):
    body = report(); body["kind"] = "audio-test"
    assert upload(voice, body).status_code == 200
    assert upload(voice, body).json()["revision"] == 1
    changed = copy.deepcopy(body); changed["results"][0]["inputFrames"] += 1
    assert upload(voice, changed).status_code == 409
    feedback = copy.deepcopy(body); feedback.update(revision=2, speaker_heard=True)
    assert upload(voice, feedback).json()["revision"] == 2
    assert upload(voice, body).json()["revision"] == 2
    assert upload(voice, feedback).json()["revision"] == 2
    with voice[0].db() as db:
        assert db.execute("SELECT COUNT(*) FROM voice_diagnostics").fetchone()[0] == 1
    premature = report(); premature["kind"] = "audio-test"; premature["revision"] = 2
    assert upload(voice, premature).status_code == 409


def test_session_report_records_safe_transport_counters_and_rejects_private_payloads(voice):
    body = report(); body["kind"] = "voice-session"
    body["transport"] = {"endReason": "upload-backlog", "uploadedBytes": 48000,
                         "uploadRequests": 1, "pendingUploadBytes": 96000, "peakUploadBytes": 96000,
                         "lastUploadMs": 600, "maxUploadMs": 600, "receivedAudioBytes": 9600,
                         "playbackFrames": 4800, "peakPlaybackFrames": 9600}
    assert upload(voice, body).status_code == 200
    assert upload(voice, body).status_code == 200
    stored = DiagnosticStore(voice[0]).local_review("alice")["report"]
    assert stored["transport"] == body["transport"]
    for key, value in (("providerPayload", "forbidden"), ("endReason", "private string"), ("maxUploadMs", -1)):
        changed = copy.deepcopy(body); changed["request_id"] = str(uuid.uuid4())
        changed["transport"][key] = value
        assert upload(voice, changed).status_code == 422


def test_older_counter_reports_keep_their_original_idempotency_body(voice):
    body = report()
    assert upload(voice, body).status_code == 200
    stored = DiagnosticStore(voice[0]).local_review("alice")["report"]
    assert "transport" not in stored
    assert upload(voice, body).status_code == 200


@pytest.mark.parametrize("change", [
    lambda x: x.update(audio="forbidden"), lambda x: x.update(token="forbidden"),
    lambda x: x.update(transcript="forbidden"), lambda x: x.update(watch_os="device serial"),
    lambda x: x.update(build="provider payload"), lambda x: x.update(version=2),
    lambda x: x["results"][0]["before"].update(inputPorts=["private device name"]),
    lambda x: x["results"][0]["before"].update(captureFormat="arbitrary format"),
    lambda x: x["results"][0].update(peakLevel=0.3),
    lambda x: x["results"][0].update(inputFrames=-1),
    lambda x: x["results"][0].update(nativeCode="-308"),
    lambda x: x["results"].append(copy.deepcopy(x["results"][0])),
    lambda x: x.update(completed=True, kind="audio-test"),
])
def test_report_rejects_audio_private_strings_bad_types_and_unbounded_counters(voice, change):
    body = report(); change(body)
    assert upload(voice, body).status_code == 422
    with voice[0].db() as db:
        assert db.execute("SELECT COUNT(*) FROM voice_diagnostics").fetchone()[0] == 0


def test_diagnostics_reject_revoked_credentials_and_late_upload_after_deletion(voice):
    body = report(); assert upload(voice, body).status_code == 200
    assert voice[1].delete("/api/voice/diagnostics/" + body["request_id"], headers=voice[3]["alice"][1]).status_code == 200
    assert upload(voice, body).status_code == 410
    voice[1].delete("/api/session", headers=voice[3]["alice"][1])
    assert upload(voice, report()).status_code == 401


def test_local_support_review_is_explicit_account_scoped_audited_and_does_not_reset_jobs(voice):
    w = voice[0]
    body = report(); assert upload(voice, body).status_code == 200
    assert DiagnosticStore(w).local_review("bobby")["report"] is None
    reviewed = DiagnosticStore(w).local_review("alice")
    assert reviewed["report"]["request_id"] == body["request_id"]
    with w.db() as db:
        assert db.execute("SELECT 1 FROM audit WHERE actor='local-diagnostics-review' AND "
                          "action='local-voice-diagnostics-reviewed' AND target=?", (body["request_id"],)).fetchone()


def test_diagnostic_storage_bounds_recent_reports_and_does_not_recover_recordings(voice):
    w = voice[0]
    for _ in range(101):
        assert upload(voice, report()).status_code == 200
    with w.db() as db:
        assert db.execute("SELECT COUNT(*) FROM voice_diagnostics WHERE deleted=0").fetchone()[0] == 100
        # A second, non-recording server must never recover the running recording worker.
        from server_workspace.workspace import Workspace
        db.execute("INSERT INTO recordings VALUES('active-fixture','alice','processing',0,0,0,0,?)", (w.encode({}),))
    Workspace(w.config, w.cipher, w.provider, w.audio_preparer, recover_jobs=False)
    with w.db() as db:
        assert db.execute("SELECT state FROM recordings WHERE id='active-fixture'").fetchone()[0] == "processing"


@pytest.mark.skipif(os.name != "nt", reason="Production DPAPI requires Windows")
def test_actual_windows_cipher_keeps_diagnostic_counters_encrypted_on_disk(voice):
    from server_workspace.workspace import WindowsCipher
    w = voice[0]
    prior = w.cipher
    try:
        w.cipher = WindowsCipher()
        body = report()
        assert upload(voice, body).status_code == 200
        with w.db() as db:
            stored = db.execute("SELECT content FROM voice_diagnostics WHERE id=?", (body["request_id"],)).fetchone()[0]
        assert b'"captureRate"' not in stored
        assert w.decode(stored)["results"][0]["inputFrames"] == 1104
    finally:
        w.cipher = prior
