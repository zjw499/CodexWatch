import asyncio
from pathlib import Path
import uuid

from fastapi.testclient import TestClient
import pytest

from server_workspace.workspace import Workspace, WorkspaceConfig, WindowsCipher, create_app


class TestCipher:
    """Test-only cipher. Production must instantiate WindowsCipher."""
    def seal(self, value):
        return b"TEST:" + value
    def open(self, value):
        assert value.startswith(b"TEST:")
        return value[5:]


class Provider:
    def __init__(self):
        self.calls = []
        self.before_response = None
    async def transcribe(self, audio, model):
        self.calls.append(("transcribe", model, audio))
        if getattr(self, "during_transcription", None):
            self.during_transcription()
        return "Alex will send the agenda Friday."
    async def generate(self, model, instructions, transcript, chat):
        self.calls.append(("generate", model, instructions, transcript, chat))
        if self.before_response:
            self.before_response()
        return "Follow-up: Alex sends the agenda Friday."


@pytest.fixture
def setup(tmp_path):
    provider = Provider()
    config = WorkspaceConfig(tmp_path, Path("unused-key"), "org-test", "proj-test", baa_verified=True,
                             retention_verified=True, safeguards_verified=True, approval_evidence="Synthetic fixture only")
    workspace = Workspace(config, TestCipher(), provider)
    client = TestClient(create_app(workspace, run_worker=False))
    def user(username, role="user"):
        invitation = workspace.invite(username, role)
        response = client.post("/api/register", json={"code": invitation["code"], "password": "long-test-password"})
        assert response.status_code == 200
        account = response.json()
        return account, {"Authorization": "Bearer " + account["token"]}
    admin, ah = user("admin", "admin")
    alice, a = user("alice")
    bob, b = user("bobby")
    return workspace, client, provider, (admin, ah), (alice, a), (bob, b)


def upload(client, headers, record_id="recording-1", parts=1):
    response = client.put("/api/recordings/"+record_id, headers=headers,
                          json={"title": "Check-in", "source": "iPhone", "expected_parts": parts})
    assert response.status_code == 200, response.text
    for index in range(parts):
        response = client.put(f"/api/recordings/{record_id}/parts/{index}", headers=headers,
                              content=b"audio"+str(index).encode())
        assert response.status_code == 200


def process_body(client, headers):
    assistant = client.get("/api/assistants", headers=headers).json()["assistants"][0]
    return {"assistant_id": assistant["id"], "transcription_model": "gpt-4o-mini-transcribe"}


def test_cross_user_read_write_delete_and_admin_review(setup):
    w, c, p, (_, ah), (_, a), (_, b) = setup
    upload(c, a)
    for method, suffix, kwargs in [
        ("get", "", {}), ("get", "/parts/0", {}), ("delete", "", {}),
        ("patch", "", {"json": {"title": "stolen"}}),
        ("post", "/process", {"json": process_body(c, b)}),
        ("put", "/parts/0", {"content": b"audio0"}),
    ]:
        assert getattr(c, method)("/api/recordings/recording-1"+suffix, headers=b, **kwargs).status_code == 404
    assert c.get("/api/recordings/recording-1?review=true", headers=b).status_code == 404
    assert c.get("/api/recordings/recording-1", headers=ah).status_code == 404
    assert c.get("/api/recordings/recording-1?review=true", headers=ah).status_code == 200
    assert c.get("/api/recordings", headers=b).json()["recordings"] == []
    events = c.get("/api/admin/audit", headers=ah).json()["events"]
    assert any(e["action"] == "admin-content-reviewed" for e in events)
    assert c.get("/api/admin/recordings", headers=b).status_code == 403


def test_one_use_invite_password_and_session_revocation(setup):
    w, c, p, (_, ah), (alice, a), (_, b) = setup
    inv = w.invite("carol", "user")
    assert c.post("/api/register", json={"code": inv["code"], "password": "short"}).status_code == 422
    args = {"code": inv["code"], "password": "long-test-password"}
    assert c.post("/api/register", json=args).status_code == 200
    assert c.post("/api/register", json=args).status_code == 400
    assert c.post("/api/login", json={"username": "alice", "password": "wrong"}).status_code == 401
    assert c.delete(f"/api/admin/users/{alice['user']['id']}/sessions", headers=ah).status_code == 200
    assert c.get("/api/me", headers=a).status_code == 401
    assert c.post("/api/login", json={"username": "alice", "password": "long-test-password"}).status_code == 200


def test_login_throttle_commits_failed_attempts(setup):
    _, c, _, _, _, _ = setup
    for _ in range(10):
        assert c.post("/api/login", json={"username": "alice", "password": "wrong"}).status_code == 401
    assert c.post("/api/login", json={"username": "alice", "password": "wrong"}).status_code == 429


def test_processing_custom_assistant_chat_idempotency_and_retained_audio(setup):
    w, c, p, _, (_, a), (_, b) = setup
    aid = str(uuid.uuid4())
    assistant = {"name": "Action list", "instructions": "Only list explicit actions.", "model": "gpt-4.1"}
    assert c.put("/api/assistants/"+aid, headers=a, json=assistant).status_code == 200
    assert c.put("/api/assistants/"+aid, headers=b, json=assistant).status_code == 404
    upload(c, a, parts=2)
    body = {"assistant_id": aid, "transcription_model": "gpt-4o-transcribe"}
    assert c.post("/api/recordings/recording-1/process", headers=a, json=body).status_code == 200
    assert c.post("/api/recordings/recording-1/process", headers=a, json=body).status_code == 200
    asyncio.run(w.run_next())
    result = c.get("/api/recordings/recording-1", headers=a).json()
    assert result["state"] == "ready" and result["assistant_name"] == "Action list"
    assert len([call for call in p.calls if call[0] == "transcribe"]) == 2
    assert p.calls[-1][1:3] == ("gpt-4.1", "Only list explicit actions.")
    assert c.get("/api/recordings/recording-1/parts/0", headers=a).content == b"audio0"
    chat = {"message": "Who owns the action?", "request_id": "message-1"}
    assert c.post("/api/recordings/recording-1/chat", headers=a, json=chat).status_code == 200
    assert c.post("/api/recordings/recording-1/chat", headers=a, json=chat).status_code == 200
    assert len(c.get("/api/recordings/recording-1", headers=a).json()["chat"]) == 2
    assert c.patch("/api/recordings/recording-1", headers=a, json={"summary": "Reviewed notes"}).status_code == 200


def test_deleted_content_never_reappears_from_worker_or_late_upload(setup):
    w, c, p, _, (_, a), _ = setup
    upload(c, a)
    c.post("/api/recordings/recording-1/process", headers=a, json=process_body(c, a))
    p.before_response = lambda: c.delete("/api/recordings/recording-1", headers=a)
    asyncio.run(w.run_next())
    assert c.get("/api/recordings/recording-1", headers=a).status_code == 404
    assert c.put("/api/recordings/recording-1", headers=a, json={"title": "late", "source": "Watch", "expected_parts": 1}).status_code == 410
    with w.db() as db:
        assert db.execute("SELECT COUNT(*) FROM parts").fetchone()[0] == 0
        row = db.execute("SELECT * FROM recordings").fetchone()
        assert w.decode(row["content"]) == {}


def test_tombstone_before_upload_and_audio_conflict(setup):
    _, c, _, _, (_, a), _ = setup
    assert c.delete("/api/recordings/not-yet-uploaded", headers=a).status_code == 200
    assert c.put("/api/recordings/not-yet-uploaded", headers=a, json={"title": "late", "source": "Watch", "expected_parts": 1}).status_code == 410
    upload(c, a)
    assert c.put("/api/recordings/recording-1/parts/0", headers=a, content=b"changed").status_code == 409


def test_approval_fail_closed_and_does_not_send_audio(setup):
    w, c, p, (_, ah), (_, a), _ = setup
    upload(c, a)
    w.config.retention_verified = False
    assert c.post("/api/recordings/recording-1/process", headers=a, json=process_body(c, a)).status_code == 409
    assert p.calls == []
    assert c.put("/api/admin/policy", headers=a, json={"baa_verified": True, "retention_verified": True, "safeguards_verified": True, "approval_evidence": "approved"}).status_code == 403
    assert c.put("/api/admin/policy", headers=ah, json={"baa_verified": True, "retention_verified": True, "safeguards_verified": True, "approval_evidence": ""}).status_code == 422


def test_restart_resumes_checkpoints_and_policy_bound_to_project(setup):
    w, c, p, (_, ah), (_, a), _ = setup
    upload(c, a, parts=2)
    c.post("/api/recordings/recording-1/process", headers=a, json=process_body(c, a))
    with w.db() as db:
        row = db.execute("SELECT * FROM recordings").fetchone()
        data = w.decode(row["content"])
        data["checkpoints"] = {"0": "Saved first part"}
        db.execute("UPDATE recordings SET state='processing',content=?", (w.encode(data),))
    restarted = Workspace(w.config, TestCipher(), p)
    asyncio.run(restarted.run_next())
    assert len([call for call in p.calls if call[0] == "transcribe"]) == 1
    c.put("/api/admin/policy", headers=ah, json={"baa_verified": True, "retention_verified": True, "safeguards_verified": True, "approval_evidence": "approved"})
    other = Workspace(WorkspaceConfig(w.config.root, Path("unused"), "org-test", "different-project"), TestCipher(), p)
    assert not other.processing_enabled


def test_windows_encryption_roundtrip_and_no_plaintext(tmp_path):
    import os
    if os.name != "nt":
        pytest.skip("DPAPI is Windows-only")
    cipher = WindowsCipher()
    content = b"private synthetic transcript"
    encrypted = cipher.seal(content)
    assert content not in encrypted
    assert cipher.open(encrypted) == content


def test_existing_results_import_without_audio_and_regenerate(setup):
    w, c, p, _, (_, a), _ = setup
    result = c.put("/api/recordings/old-transcript", headers=a, json={"title": "Old meeting", "source": "iPhone", "expected_parts": 0,
        "transcript": "Alex will send the agenda Friday.", "summary": "Existing reviewed notes"})
    assert result.status_code == 200 and result.json()["state"] == "ready"
    assert c.post("/api/recordings/old-transcript/chat", headers=a, json={"message": "Who?", "request_id": "first"}).status_code == 409
    assert c.post("/api/recordings/old-transcript/process", headers=a, json=process_body(c, a)).status_code == 200
    asyncio.run(w.run_next())
    result = c.get("/api/recordings/old-transcript", headers=a).json()
    assert result["state"] == "ready"
    assert not any(call[0] == "transcribe" for call in p.calls)
    assert "Alex" in result["transcript"]


def test_rename_during_transcription_is_not_overwritten(setup):
    w, c, p, _, (_, a), _ = setup
    upload(c, a)
    c.post("/api/recordings/recording-1/process", headers=a, json=process_body(c, a))
    p.during_transcription = lambda: c.patch("/api/recordings/recording-1", headers=a, json={"title": "Renamed while running"})
    asyncio.run(w.run_next())
    assert c.get("/api/recordings/recording-1", headers=a).json()["title"] == "Renamed while running"


def test_revocation_during_chat_prevents_returning_or_saving_content(setup):
    w, c, p, (_, ah), (alice, a), _ = setup
    upload(c, a)
    c.post("/api/recordings/recording-1/process", headers=a, json=process_body(c, a))
    asyncio.run(w.run_next())
    p.before_response = lambda: c.delete(f"/api/admin/users/{alice['user']['id']}/sessions", headers=ah)
    assert c.post("/api/recordings/recording-1/chat", headers=a, json={"message": "Who?", "request_id": "revoked-chat"}).status_code == 401
    with w.db() as db:
        assert w.decode(db.execute("SELECT content FROM recordings").fetchone()[0])["chat"] == []
