import asyncio
import base64
import json
from pathlib import Path
import time

from fastapi.testclient import TestClient
import pytest

from server_workspace.workspace import Workspace, WorkspaceConfig, create_app, digest
from server_workspace.voice import VoiceStore, SessionBody, create_voice_app
from server_workspace.tests.test_workspace import TestCipher, Provider, FixtureAudioPreparer


class Peer:
    def __init__(self):
        self.sent = []
        self.events = asyncio.Queue()
        self.closed = False

    async def send(self, event):
        self.sent.append(event)
        if event["type"] == "session.update":
            self.events.put_nowait({"type": "session.updated"})

    async def receive(self):
        return await self.events.get()

    async def close(self):
        self.closed = True


@pytest.fixture
def voice(tmp_path, request):
    w = Workspace(WorkspaceConfig(tmp_path, Path("unused-key"), "org-test", "proj-test", baa_verified=True,
                                 retention_verified=True, safeguards_verified=True, approval_evidence="Synthetic fixture"),
                  TestCipher(), Provider(), FixtureAudioPreparer())
    private = TestClient(create_app(w, run_worker=False))
    private.__enter__()
    request.addfinalizer(lambda: private.__exit__(None, None, None))
    people = {}
    for name, role in (("admin", "admin"), ("alice", "user"), ("bobby", "user")):
        invite = w.invite(name, role)
        person = private.post("/api/register", json={"code": invite["code"], "password": "long-test-password"}).json()
        people[name] = (person, {"Authorization": "Bearer " + person["token"]})
    ah = people["admin"][1]
    policy = {"enabled": True, "realtime_retention_verified": True, "device_acceptance_verified": True,
              "approval_evidence": "Synthetic acceptance; no real provider calls"}
    assert private.put("/api/admin/voice/policy", headers=ah, json=policy).status_code == 200
    a = people["alice"][1]
    assistant = private.get("/api/assistants", headers=a).json()["assistants"][0]
    assistant["voice"] = {"enabled": True, "model": "gpt-realtime-2.1", "voice": "marin"}
    assert private.put("/api/assistants/"+assistant["id"], headers=a, json=assistant).status_code == 200
    device = private.post("/api/voice/devices", headers=a, json={"device_id": "watch-alice"}).json()
    vh = {"Authorization": "Bearer " + device["token"]}
    peers = []

    async def factory(*_):
        peer = Peer()
        peers.append(peer)
        return peer

    app = create_voice_app(w, factory)
    with TestClient(app) as public:
        yield w, private, public, people, assistant, device, vh, peers


def start(v, request="request-1", **fields):
    _, _, public, _, _, _, headers, _ = v
    response = public.post("/voice/v1/sessions", headers=headers, json={"request_id": request, **fields})
    assert response.status_code == 200, response.text
    public.portal.call(asyncio.sleep, 0.01)
    return response.json()


def push(v, event):
    public, peers = v[2], v[7]
    async def deliver():
        peers[-1].events.put_nowait(event)
        await asyncio.sleep(0.02)
    public.portal.call(deliver)


def test_old_assistant_put_preserves_voice_and_default_repairs(voice):
    _, private, _, people, assistant, _, _, _ = voice
    a = people["alice"][1]
    saved = private.put("/api/assistants/"+assistant["id"], headers=a,
                        json={k: assistant[k] for k in ("name", "model", "instructions")}).json()
    assert saved["voice"]["enabled"] is True
    config = private.get("/api/voice/config", headers=a).json()
    assert config["default_assistant_id"] == assistant["id"]
    assert "instructions" not in config["assistants"][0]
    saved["voice"]["enabled"] = False
    private.put("/api/assistants/"+assistant["id"], headers=a, json=saved)
    assert private.get("/api/voice/config", headers=a).json()["default_assistant_id"] == ""


def test_voice_disabled_until_actual_approvals(voice):
    w, private, public, people, _, _, vh, peers = voice
    ah = people["admin"][1]
    assert private.put("/api/admin/voice/policy", headers=ah, json={"enabled": True}).status_code == 422
    assert private.put("/api/admin/voice/policy", headers=ah, json={"enabled": False}).status_code == 200
    assert public.post("/voice/v1/sessions", headers=vh, json={"request_id": "blocked"}).status_code == 409
    assert not peers
    assert VoiceStore(w).available() is False


def test_public_gateway_has_only_voice_routes_and_rejects_phone_tokens(voice):
    _, _, public, people, _, _, _, _ = voice
    for route in ("/api/login", "/api/recordings", "/api/admin/voice/policy", "/docs", "/openapi.json"):
        assert public.get(route).status_code == 404
    assert public.get("/voice/v1/config", headers=people["alice"][1]).status_code == 401
    assert public.get("/voice/v1/config").status_code == 401


def test_administrator_pilot_allows_device_testing_without_enabling_users(voice):
    _, private, _, people, _, _, _, _ = voice
    policy = {"enabled": False, "pilot_enabled": True, "realtime_retention_verified": True,
              "device_acceptance_verified": False, "approval_evidence": "Synthetic pilot"}
    assert private.put("/api/admin/voice/policy", headers=people["admin"][1], json=policy).status_code == 200
    assert private.get("/api/voice/config", headers=people["admin"][1]).json()["enabled"] is True
    assert private.get("/api/voice/config", headers=people["alice"][1]).json()["enabled"] is False
    assert private.post("/api/voice/devices", headers=people["admin"][1], json={"device_id": "pilot-watch"}).status_code == 200
    assert private.post("/api/voice/devices", headers=people["alice"][1], json={"device_id": "not-pilot"}).status_code == 409


def test_device_hash_storage_and_parent_revocation(voice):
    w, private, public, people, _, device, vh, _ = voice
    s = start(voice)
    with w.db() as db:
        stored = db.execute("SELECT hash FROM voice_devices").fetchone()[0]
    assert stored != device["token"] and device["token"] not in w.database.read_bytes().decode("latin1")
    private.delete("/api/session", headers=people["alice"][1])
    assert public.get("/voice/v1/config", headers=vh).status_code == 401
    public.portal.call(asyncio.sleep, 1.1)
    assert public.app.state.voice.sessions[s["id"]].state == "ended"


@pytest.mark.parametrize("cause", ["device-expiry", "administrator-revocation", "assistant-deletion", "session-limit", "idle-limit"])
def test_access_changes_and_limits_terminate_active_conversations(voice, cause):
    w, private, public, people, assistant, _, vh, _ = voice
    s = start(voice)
    session = public.app.state.voice.sessions[s["id"]]
    if cause == "device-expiry":
        with w.db() as db: db.execute("UPDATE voice_devices SET expires=0")
        assert public.get("/voice/v1/config", headers=vh).status_code == 401
    elif cause == "administrator-revocation":
        owner = people["alice"][0]["user"]["id"]
        assert private.delete(f"/api/admin/users/{owner}/sessions", headers=people["admin"][1]).status_code == 200
        assert public.get("/voice/v1/config", headers=vh).status_code == 401
    elif cause == "assistant-deletion":
        assert private.delete("/api/assistants/"+assistant["id"], headers=people["alice"][1]).status_code == 200
    elif cause == "session-limit":
        session.started = time.monotonic() - 601
    else:
        session.activity = time.monotonic() - 121
    public.portal.call(asyncio.sleep, 1.1)
    assert session.state == "ended" and voice[7][-1].closed


def test_public_history_and_controls_are_isolated_by_owner(voice):
    s = start(voice)
    device = voice[1].post("/api/voice/devices", headers=voice[3]["bobby"][1], json={"device_id": "watch-bobby"}).json()
    headers = {"Authorization": "Bearer " + device["token"]}
    assert voice[2].get("/voice/v1/conversations/"+s["conversation_id"], headers=headers).status_code == 404
    assert voice[2].delete("/voice/v1/conversations/"+s["conversation_id"], headers=headers).status_code == 404
    assert voice[2].post(f"/voice/v1/sessions/{s['id']}/control", headers=headers, json={"action": "end"}).status_code == 404
    assert voice[2].get("/voice/v1/conversations", headers=headers).json()["conversations"] == []
    assert voice[2].app.state.voice.sessions[s["id"]].state != "ended"


def test_create_idempotent_one_active_and_named_assistant_validation(voice):
    s = start(voice)
    assert start(voice)["id"] == s["id"]
    assert len(voice[7]) == 1
    assert voice[2].post("/voice/v1/sessions", headers=voice[6], json={"request_id": "another"}).status_code == 409
    voice[2].post(f"/voice/v1/sessions/{s['id']}/control", headers=voice[6], json={"action": "end"})
    assert voice[2].post("/voice/v1/sessions", headers=voice[6], json={"request_id": "missing", "assistant_id": "missing"}).status_code == 404


def test_administrator_can_adjust_active_limit_without_duplicate_resume(voice):
    private, public, ah, h = voice[1], voice[2], voice[3]["admin"][1], voice[6]
    policy = private.get("/api/admin/voice/policy", headers=ah).json()
    assert policy["max_active_sessions"] == 1
    policy["max_active_sessions"] = 2
    assert private.put("/api/admin/voice/policy", headers=ah, json=policy).status_code == 200
    first, second = start(voice), start(voice, "parallel")
    assert first["id"] != second["id"]
    assert public.post("/voice/v1/sessions", headers=h, json={"request_id": "over-limit"}).status_code == 409
    public.post(f"/voice/v1/sessions/{second['id']}/control", headers=h, json={"action": "end"})
    assert public.post("/voice/v1/sessions", headers=h,
                       json={"request_id": "duplicate-resume", "conversation_id": first["conversation_id"]}).status_code == 409


def test_slow_provider_setup_does_not_block_another_user(voice):
    w, private, public, people, _, device, _, peers = voice
    bh = people["bobby"][1]
    assistant = private.get("/api/assistants", headers=bh).json()["assistants"][0]
    assistant["voice"] = {"enabled": True, "model": "gpt-realtime-2.1", "voice": "cedar"}
    assert private.put("/api/assistants/"+assistant["id"], headers=bh, json=assistant).status_code == 200
    other = private.post("/api/voice/devices", headers=bh, json={"device_id": "watch-bobby"}).json()
    store = VoiceStore(w)
    alice, bob = store.authenticate_hash(digest(device["token"])), store.authenticate_hash(digest(other["token"]))
    gateway = public.app.state.voice
    async def prove():
        started, release = asyncio.Event(), asyncio.Event()
        async def factory(_, __, owner):
            if owner == alice["id"]:
                started.set(); await release.wait()
            peer = Peer(); peers.append(peer); return peer
        gateway.peer_factory = factory
        pending = asyncio.create_task(gateway.create(alice, SessionBody(request_id="slow-alice")))
        await started.wait()
        try:
            info = await asyncio.wait_for(gateway.create(bob, SessionBody(request_id="ready-bob")), 1)
            assert info["state"] != "ended"
        finally:
            release.set(); await pending
    public.portal.call(prove)


def test_audio_retries_mute_sequence_and_size_validation(voice):
    s = start(voice)
    c, h, peer = voice[2], voice[6], voice[7][-1]
    route = f"/voice/v1/sessions/{s['id']}/audio"
    headers = {**h, "Content-Type": "application/octet-stream"}
    data = bytes(9600)
    for _ in range(2):
        assert c.post(route+"?sequence=0", headers=headers, content=data).status_code == 200
    assert len([e for e in peer.sent if e["type"] == "input_audio_buffer.append"]) == 1
    assert c.post(route+"?sequence=0", headers=headers, content=b"different!").status_code == 409
    assert c.post(route+"?sequence=2", headers=headers, content=data).status_code == 409
    assert c.post(route+"?sequence=1", headers=headers, content=bytes(48002)).status_code == 413
    c.post(f"/voice/v1/sessions/{s['id']}/control", headers=h, json={"action": "mute", "muted": True})
    assert c.post(route+"?sequence=1", headers=headers, content=data).status_code == 200
    assert len([e for e in peer.sent if e["type"] == "input_audio_buffer.append"]) == 1


def test_combined_microphone_batch_and_lost_ack_preserve_one_provider_append(voice):
    s = start(voice)
    public, peer = voice[2], voice[7][-1]
    route = f"/voice/v1/sessions/{s['id']}/audio?sequence=0"
    headers = {**voice[6], "Content-Type": "application/octet-stream"}
    data = b"".join(bytes([index]) * 9600 for index in range(5))
    for _ in range(2):
        assert public.post(route, headers=headers, content=data).status_code == 200
    appends = [e for e in peer.sent if e["type"] == "input_audio_buffer.append"]
    assert len(appends) == 1 and base64.b64decode(appends[0]["audio"]) == data


def test_transcripts_owner_admin_review_and_delete_rejects_late_events(voice):
    w, private, public, people, _, _, vh, _ = voice
    s = start(voice)
    push(voice, {"type": "input_audio_buffer.speech_started", "item_id": "u1"})
    push(voice, {"type": "conversation.item.input_audio_transcription.completed", "item_id": "u1", "transcript": "Hello voice"})
    push(voice, {"type": "response.output_audio_transcript.done", "item_id": "a1", "transcript": "Hello there"})
    cid = s["conversation_id"]
    path = "/api/voice/conversations/"+cid
    assert private.get(path, headers=people["bobby"][1]).status_code == 404
    assert private.get(path, headers=people["admin"][1]).status_code == 404
    assert private.get("/api/admin/voice/conversations/"+cid, headers=people["admin"][1]).status_code == 200
    assert private.get("/api/admin/voice/conversations/"+cid, headers=people["bobby"][1]).status_code == 403
    detail = private.get(path, headers=people["alice"][1]).json()
    assert [t["text"] for t in detail["turns"]] == ["Hello voice", "Hello there"]
    assert private.get("/api/admin/audit", headers=people["admin"][1]).json()["events"][0]["action"] == "admin-voice-content-reviewed"
    assert public.delete("/voice/v1/conversations/"+cid, headers=vh).status_code == 200
    assert not VoiceStore(w).save_turn(cid, {"id": "late", "role": "assistant", "text": "Must not return"})
    assert private.get(path, headers=people["alice"][1]).status_code == 404
    assert public.app.state.voice.sessions[s["id"]].state == "ended"


def test_interruption_truncates_and_explicit_resume_omits_unheard_answer(voice):
    s = start(voice)
    peer = voice[7][-1]
    push(voice, {"type": "conversation.item.input_audio_transcription.completed", "item_id": "u1", "transcript": "Question"})
    push(voice, {"type": "response.output_audio.delta", "item_id": "a1", "delta": base64.b64encode(bytes(9600)).decode()})
    push(voice, {"type": "response.output_audio_transcript.done", "item_id": "a1", "transcript": "Unheard answer"})
    push(voice, {"type": "input_audio_buffer.speech_started", "item_id": "u2"})
    control = f"/voice/v1/sessions/{s['id']}/control"
    c, h = voice[2], voice[6]
    assert c.post(control, headers=h, json={"action": "interrupt", "item_id": "a1", "audio_end_ms": 80}).status_code == 200
    assert any(e["type"] == "conversation.item.truncate" and e["audio_end_ms"] == 80 for e in peer.sent)
    c.post(control, headers=h, json={"action": "end"})
    resumed = start(voice, "resume", conversation_id=s["conversation_id"])
    assert resumed["conversation_id"] == s["conversation_id"]
    seeds = [e["item"]["content"][0]["text"] for e in voice[7][-1].sent if e["type"] == "conversation.item.create"]
    assert seeds == ["Question"]
    c.post(f"/voice/v1/sessions/{resumed['id']}/control", headers=h, json={"action": "end"})
    fresh = start(voice, "fresh")
    assert fresh["conversation_id"] != s["conversation_id"]


def test_watch_disconnect_and_policy_change_end_live_sessions(voice):
    s = start(voice)
    session = voice[2].app.state.voice.sessions[s["id"]]
    session.touched = time.monotonic() - 15
    voice[2].portal.call(asyncio.sleep, 1.1)
    assert session.state == "ended"
    s = start(voice, "again")
    policy = voice[1].get("/api/admin/voice/policy", headers=voice[3]["admin"][1]).json()
    policy["enabled"] = False
    voice[1].put("/api/admin/voice/policy", headers=voice[3]["admin"][1], json=policy)
    voice[2].portal.call(asyncio.sleep, 1.1)
    assert voice[2].app.state.voice.sessions[s["id"]].state == "ended"


def test_fully_played_answers_are_kept_when_the_user_speaks_again(voice):
    s = start(voice)
    push(voice, {"type": "response.output_audio.delta", "item_id": "a1", "delta": base64.b64encode(bytes(9600)).decode()})
    push(voice, {"type": "response.output_audio_transcript.done", "item_id": "a1", "transcript": "A complete answer"})
    push(voice, {"type": "response.done", "response": {"status": "completed"}})
    control = f"/voice/v1/sessions/{s['id']}/control"
    assert voice[2].post(control, headers=voice[6], json={"action": "played", "item_id": "a1", "audio_end_ms": 200}).status_code == 200
    push(voice, {"type": "input_audio_buffer.speech_started", "item_id": "u2"})
    detail = VoiceStore(voice[0]).conversation(s["conversation_id"], voice[3]["alice"][0]["user"]["id"])
    assert detail["turns"][0]["interrupted"] is False


def test_connection_loss_labels_unconfirmed_audio_and_excludes_it_from_resume(voice):
    s = start(voice)
    push(voice, {"type": "conversation.item.input_audio_transcription.completed", "item_id": "u1", "transcript": "Question"})
    push(voice, {"type": "response.output_audio.delta", "item_id": "a1", "delta": base64.b64encode(bytes(9600)).decode()})
    push(voice, {"type": "response.output_audio_transcript.done", "item_id": "a1", "transcript": "Playback was not confirmed"})
    session = voice[2].app.state.voice.sessions[s["id"]]
    voice[2].portal.call(session.end, "The Watch disconnected.")
    detail = VoiceStore(voice[0]).conversation(s["conversation_id"], voice[3]["alice"][0]["user"]["id"])
    assert detail["turns"][1]["interrupted"] is True
    start(voice, "resume-disconnected", conversation_id=s["conversation_id"])
    seeds = [e["item"]["content"][0]["text"] for e in voice[7][-1].sent if e["type"] == "conversation.item.create"]
    assert seeds == ["Question"]


def test_delayed_input_transcription_preserves_turn_order(voice):
    s = start(voice)
    push(voice, {"type": "input_audio_buffer.speech_started", "item_id": "u1"})
    push(voice, {"type": "response.output_audio_transcript.done", "item_id": "a1", "transcript": "Answer"})
    push(voice, {"type": "conversation.item.input_audio_transcription.completed", "item_id": "u1", "transcript": "Question"})
    session = voice[2].app.state.voice.sessions[s["id"]]
    async def drain():
        events = []
        while session.events.controls: events.append(await session.events.get())
        return [e["turn"]["role"] for e in events if e["type"] == "turn"]
    assert voice[2].portal.call(drain) == ["user", "assistant"]
    detail = VoiceStore(voice[0]).conversation(s["conversation_id"], voice[3]["alice"][0]["user"]["id"])
    assert [t["text"] for t in detail["turns"]] == ["Question", "Answer"]


def test_failed_transcription_is_visible_but_not_seeded_as_user_speech(voice):
    s = start(voice)
    push(voice, {"type": "input_audio_buffer.speech_started", "item_id": "u1"})
    push(voice, {"type": "conversation.item.input_audio_transcription.failed", "item_id": "u1"})
    detail = VoiceStore(voice[0]).conversation(s["conversation_id"], voice[3]["alice"][0]["user"]["id"])
    assert detail["turns"][0]["text"] == "[Speech could not be transcribed]"
    assert detail["turns"][0]["final"] is False
    voice[2].post(f"/voice/v1/sessions/{s['id']}/control", headers=voice[6], json={"action": "end"})
    start(voice, "resume-failed", conversation_id=s["conversation_id"])
    assert not any(e["type"] == "conversation.item.create" for e in voice[7][-1].sent)


def test_gateway_init_and_recovery_never_reset_recording_jobs(voice):
    w = voice[0]
    with w.db() as db:
        db.execute("INSERT INTO recordings VALUES('active-recording',?,'processing',0,0,0,0,?)",
                   (voice[3]["alice"][0]["user"]["id"], w.encode({})))
    second = Workspace(w.config, TestCipher(), Provider(), FixtureAudioPreparer(), recover_jobs=False)
    create_voice_app(second).state.voice.recover()
    with w.db() as db:
        assert db.execute("SELECT state FROM recordings WHERE id='active-recording'").fetchone()[0] == "processing"


def test_provider_configuration_and_no_raw_audio_files(voice):
    start(voice)
    update = voice[7][-1].sent[0]["session"]
    assert {tool["name"] for tool in update["tools"]} == {"calculate", "current_time"}
    assert update["tool_choice"] == "auto"
    assert update["audio"]["input"]["format"]["rate"] == 24000
    assert update["audio"]["output"]["voice"] == "marin"
    assert update["instructions"].endswith(voice[4]["instructions"])
    assert update["audio"]["input"]["turn_detection"]["create_response"] is False
    assert set(p.name for p in voice[0].config.root.iterdir()) == {"workspace.sqlite3"}


def test_each_committed_question_gets_a_reply_even_when_previous_response_is_cancelling(voice):
    s = start(voice)
    peer = voice[7][-1]
    for index in range(3):
        push(voice, {"type": "input_audio_buffer.speech_started", "item_id": f"u{index}"})
        push(voice, {"type": "input_audio_buffer.speech_stopped", "item_id": f"u{index}"})
        push(voice, {"type": "input_audio_buffer.committed", "item_id": f"u{index}"})
        # Retry/duplicate provider notification must not cause a second reply.
        push(voice, {"type": "input_audio_buffer.committed", "item_id": f"u{index}"})
        if index:
            assert len([e for e in peer.sent if e["type"] == "response.create"]) == index
            push(voice, {"type": "response.done", "response": {"id": f"r{index-1}", "status": "cancelled", "output": []}})
        assert len([e for e in peer.sent if e["type"] == "response.create"]) == index + 1
        push(voice, {"type": "response.created", "response": {"id": f"r{index}"}})
    assert voice[2].app.state.voice.sessions[s["id"]].state != "ended"


def test_delayed_interrupt_of_old_audio_does_not_end_or_clear_the_new_reply(voice):
    s = start(voice)
    audio = base64.b64encode(bytes(9600)).decode()
    push(voice, {"type": "response.output_audio.delta", "item_id": "old", "delta": audio})
    push(voice, {"type": "input_audio_buffer.speech_started", "item_id": "next"})
    push(voice, {"type": "response.output_audio.delta", "item_id": "new", "delta": audio})
    route = f"/voice/v1/sessions/{s['id']}/control"
    for _ in range(2):
        assert voice[2].post(route, headers=voice[6], json={"action": "interrupt", "item_id": "old", "audio_end_ms": 80}).status_code == 200
    session = voice[2].app.state.voice.sessions[s["id"]]
    assert session.last_output_item == "new" and session.state != "ended"
    assert session.events.audio_bytes == 9600
    assert len([e for e in voice[7][-1].sent if e["type"] == "conversation.item.truncate"]) == 1


def test_playback_ack_before_provider_done_keeps_a_fully_heard_answer(voice):
    s = start(voice)
    push(voice, {"type": "response.output_audio.delta", "item_id": "a1", "delta": base64.b64encode(bytes(9600)).decode()})
    route = f"/voice/v1/sessions/{s['id']}/control"
    assert voice[2].post(route, headers=voice[6], json={"action": "played", "item_id": "a1", "audio_end_ms": 200}).status_code == 200
    push(voice, {"type": "response.output_audio.done", "item_id": "a1"})
    assert voice[2].app.state.voice.sessions[s["id"]].last_output_item is None


def test_nested_voice_fields_and_web_policy_survive_older_client_saves(voice):
    w, private, _, people, assistant, _, _, _ = voice
    a, admin = people["alice"][1], people["admin"][1]
    assistant["voice"]["web_search"] = True
    assert private.put("/api/assistants/" + assistant["id"], headers=a, json=assistant).status_code == 200
    assistant["voice"].pop("web_search")
    assert private.put("/api/assistants/" + assistant["id"], headers=a, json=assistant).json()["voice"]["web_search"] is True
    policy = private.get("/api/admin/voice/policy", headers=admin).json()
    policy["public_web_search_enabled"] = True
    assert private.put("/api/admin/voice/policy", headers=admin, json=policy).status_code == 200
    policy.pop("public_web_search_enabled")
    assert private.put("/api/admin/voice/policy", headers=admin, json=policy).json()["public_web_search_enabled"] is True
    start(voice)
    assert "search_web" in {t["name"] for t in voice[7][-1].sent[0]["session"]["tools"]}


def test_tool_result_creates_a_spoken_continuation_without_blocking_audio_reader(voice):
    s = start(voice)
    gateway, peer = voice[2].app.state.voice, voice[7][-1]
    called = []
    async def execute(name, arguments):
        called.append((name, arguments))
        return {"result": 42}
    gateway.tools.execute = execute
    push(voice, {"type": "input_audio_buffer.speech_started", "item_id": "u1"})
    push(voice, {"type": "input_audio_buffer.speech_stopped", "item_id": "u1"})
    push(voice, {"type": "input_audio_buffer.committed", "item_id": "u1"})
    push(voice, {"type": "response.created", "response": {"id": "r1"}})
    push(voice, {"type": "response.done", "response": {"id": "r1", "status": "completed", "output": [
        {"type": "function_call", "name": "calculate", "call_id": "c1", "arguments": '{"expression":"6*7"}'}]}})
    assert called == [("calculate", {"expression": "6*7"})]
    outputs = [e["item"] for e in peer.sent if e["type"] == "conversation.item.create"]
    assert outputs[-1]["type"] == "function_call_output" and json.loads(outputs[-1]["output"])["result"] == 42
    assert len([e for e in peer.sent if e["type"] == "response.create"]) == 2
    assert gateway.sessions[s["id"]].state != "ended"


def test_new_question_cancels_slow_search_and_still_gets_its_own_response(voice):
    s = start(voice)
    gateway, peer = voice[2].app.state.voice, voice[7][-1]
    async def execute(*_):
        await asyncio.sleep(60)
        return {"text": "Stale result must not be spoken"}
    gateway.tools.execute = execute
    push(voice, {"type": "input_audio_buffer.speech_started", "item_id": "u1"})
    push(voice, {"type": "input_audio_buffer.speech_stopped", "item_id": "u1"})
    push(voice, {"type": "input_audio_buffer.committed", "item_id": "u1"})
    push(voice, {"type": "response.created", "response": {"id": "r1"}})
    push(voice, {"type": "response.done", "response": {"id": "r1", "status": "completed", "output": [
        {"type": "function_call", "name": "calculate", "call_id": "c1", "arguments": '{"expression":"1+1"}'}]}})
    assert gateway.sessions[s["id"]].tool_task
    push(voice, {"type": "input_audio_buffer.speech_started", "item_id": "u2"})
    push(voice, {"type": "input_audio_buffer.speech_stopped", "item_id": "u2"})
    push(voice, {"type": "input_audio_buffer.committed", "item_id": "u2"})
    assert len([e for e in peer.sent if e["type"] == "response.create"]) == 2
    assert gateway.sessions[s["id"]].tool_task is None


def test_search_citations_survive_caption_updates_and_history(voice):
    s = start(voice)
    session = voice[2].app.state.voice.sessions[s["id"]]
    session.sources = [{"title": "Official source", "url": "https://example.org/source"}]
    push(voice, {"type": "response.output_audio_transcript.delta", "item_id": "a1", "delta": "Current "})
    push(voice, {"type": "response.output_audio_transcript.done", "item_id": "a1", "transcript": "Current result"})
    detail = VoiceStore(voice[0]).conversation(s["conversation_id"], voice[3]["alice"][0]["user"]["id"])
    assert detail["turns"][0]["sources"] == session.sources


def test_tool_session_end_cancels_pending_work_and_saves_only_safe_counters(voice):
    s = start(voice)
    gateway = voice[2].app.state.voice
    async def execute(*_):
        await asyncio.sleep(60)
        return {"text": "Never retained"}
    gateway.tools.execute = execute
    push(voice, {"type": "response.done", "response": {"id": "r1", "status": "completed", "output": [
        {"type": "function_call", "name": "calculate", "call_id": "c1", "arguments": '{"expression":"1+1"}'}]}})
    assert gateway.sessions[s["id"]].tool_task
    voice[2].post(f"/voice/v1/sessions/{s['id']}/control", headers=voice[6], json={"action": "end"})
    voice[2].portal.call(asyncio.sleep, 0.01)
    assert gateway.sessions[s["id"]].tool_task is None
    detail = VoiceStore(voice[0]).conversation(s["conversation_id"], voice[3]["alice"][0]["user"]["id"])
    assert detail["diagnostics"]["tool_calls"] == 1
    assert "expression" not in json.dumps(detail) and "Never retained" not in json.dumps(detail)


def test_tool_preamble_and_final_answer_require_independent_playback_confirmations(voice):
    s = start(voice)
    session = voice[2].app.state.voice.sessions[s['id']]
    assert s['playback_markers'] is True
    for item in ('preamble', 'answer'):
        push(voice, {'type': 'response.output_audio.delta', 'item_id': item, 'delta': base64.b64encode(bytes(9600)).decode()})
        push(voice, {'type': 'response.output_audio_transcript.done', 'item_id': item, 'transcript': 'Synthetic reply'})
        push(voice, {'type': 'response.output_audio.done', 'item_id': item})
        push(voice, {'type': 'response.output_audio.done', 'item_id': item})
    assert len([e for e in session.events.controls if e['type'] == 'audio_done']) == 2
    for _ in range(2):
        assert voice[2].post(f"/voice/v1/sessions/{s['id']}/control", headers=voice[6],
            json={'action': 'played', 'item_id': 'answer', 'audio_end_ms': 200}).status_code == 200
    assert session.metrics['playback_confirmations'] == 1
    voice[2].post(f"/voice/v1/sessions/{s['id']}/control", headers=voice[6], json={'action': 'end'})
    data = VoiceStore(voice[0]).conversation(s['conversation_id'], voice[3]['alice'][0]['user']['id'])
    assert [t['interrupted'] for t in data['turns']] == [True, False]
    assert data['diagnostics']['playback'] == [
        {'turn_index': 0, 'generated_bytes': 9600, 'streamed_bytes': 0, 'played_ms': 0, 'provider_finished': True, 'confirmed': False},
        {'turn_index': 1, 'generated_bytes': 9600, 'streamed_bytes': 0, 'played_ms': 200, 'provider_finished': True, 'confirmed': True}]


def test_barge_in_discards_all_unheard_tool_audio_and_keeps_heard_preamble(voice):
    s = start(voice)
    session = voice[2].app.state.voice.sessions[s['id']]
    for item in ('heard', 'unheard-preamble', 'unheard-answer'):
        push(voice, {'type': 'response.output_audio.delta', 'item_id': item, 'delta': base64.b64encode(bytes(9600)).decode()})
        push(voice, {'type': 'response.output_audio.done', 'item_id': item})
    voice[2].post(f"/voice/v1/sessions/{s['id']}/control", headers=voice[6],
                 json={'action': 'played', 'item_id': 'heard', 'audio_end_ms': 200})
    # Treat the acknowledged packet as already handed to the HTTP stream.
    session.events.discard_audio('heard')
    push(voice, {'type': 'input_audio_buffer.speech_started', 'item_id': 'next-user'})
    assert session.events.audio_bytes == 0
    assert session.blocked_output == {'unheard-preamble', 'unheard-answer'}
    assert {e['item_id'] for e in session.events.controls if e['type'] == 'interrupt'} == session.blocked_output


def test_brief_request_stall_has_grace_but_real_disconnect_ends_session(voice):
    s = start(voice)
    session = voice[2].app.state.voice.sessions[s['id']]
    session.attached = True
    session.touched = time.monotonic() - 8.2
    voice[2].portal.call(asyncio.sleep, 1.1)
    assert session.state != 'ended'
    session.touched = time.monotonic() - 16
    voice[2].portal.call(asyncio.sleep, 1.1)
    assert session.state == 'ended' and voice[7][-1].closed


def test_bounded_output_stops_slow_watch(voice):
    s = start(voice)
    push(voice, {"type": "response.output_audio.delta", "item_id": "a1", "delta": base64.b64encode(bytes(1440002)).decode()})
    assert voice[2].app.state.voice.sessions[s["id"]].state == "ended"


def test_provider_generating_six_second_reply_does_not_end_healthy_watch(voice):
    s = start(voice)
    push(voice, {"type": "response.output_audio.delta", "item_id": "a1", "delta": base64.b64encode(bytes(288000)).decode()})
    session = voice[2].app.state.voice.sessions[s["id"]]
    assert session.state == "speaking"
    assert session.events.audio_bytes == 288000
    push(voice, {"type": "input_audio_buffer.speech_started", "item_id": "u2"})
    assert session.state == "listening" and session.events.audio_bytes == 0


def test_sse_terminal_event_is_versioned_and_no_store(voice):
    s = start(voice)
    c, h = voice[2], voice[6]
    c.post(f"/voice/v1/sessions/{s['id']}/control", headers=h, json={"action": "end"})
    response = c.get(f"/voice/v1/sessions/{s['id']}/events", headers=h)
    assert response.headers["cache-control"] == "no-store"
    event = json.loads(next(line[6:] for line in response.text.splitlines() if line.startswith("data: ")))
    assert event["type"] == "ended" and event["version"] == 1


def test_oversized_json_is_rejected_before_parsing(voice):
    response = voice[2].post("/voice/v1/sessions", headers={"Content-Type": "application/json"}, content=b"x" * 65537)
    assert response.status_code == 413


def test_retention_evidence_is_bound_to_org_and_project(voice):
    w = voice[0]
    with w.db() as db:
        row = db.execute("SELECT content FROM voice_policy WHERE id=1").fetchone()
        policy = w.decode(row[0]); policy["project_id"] = "another-project"
        db.execute("UPDATE voice_policy SET content=? WHERE id=1", (w.encode(policy),))
    assert VoiceStore(w).available() is False
