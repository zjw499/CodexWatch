"""Voice-only HTTPS gateway. PCM exists only in bounded memory, never on disk."""
from __future__ import annotations

import asyncio
import base64
from contextlib import asynccontextmanager, suppress
import json
import secrets
import time
from urllib.parse import urlparse
import uuid

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, StreamingResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, Field

from .workspace import Workspace, digest, fail, identifier


class VoicePolicy(BaseModel):
    enabled: bool = False
    pilot_enabled: bool = False
    realtime_retention_verified: bool = False
    device_acceptance_verified: bool = False
    approval_evidence: str = Field(default="", max_length=4000)
    session_seconds: int = Field(default=600, ge=60, le=3600)
    idle_seconds: int = Field(default=120, ge=30, le=600)
    organization_id: str = ""
    project_id: str = ""


class DeviceBody(BaseModel):
    device_id: str = Field(min_length=1, max_length=140)


class PreferencesBody(BaseModel):
    default_assistant_id: str = Field(default="", max_length=140)


class SessionBody(BaseModel):
    request_id: str = Field(min_length=1, max_length=140)
    assistant_id: str | None = Field(default=None, max_length=140)
    conversation_id: str | None = Field(default=None, max_length=140)


class ControlBody(BaseModel):
    action: str
    muted: bool = False
    item_id: str | None = Field(default=None, max_length=140)
    audio_end_ms: int = Field(default=0, ge=0, le=3600000)


class VoiceStore:
    def __init__(self, workspace: Workspace):
        self.w = workspace

    def policy(self) -> VoicePolicy:
        with self.w.db() as db:
            row = db.execute("SELECT content FROM voice_policy WHERE id=1").fetchone()
        return VoicePolicy.model_validate(self.w.decode(row[0])) if row else VoicePolicy(enabled=self.w.config.voice_enabled)

    def available(self, owner: str | None = None) -> bool:
        policy = self.policy()
        approval = self.w.approval()
        with self.w.db() as db:
            row = db.execute("SELECT content FROM policy WHERE id=1").fetchone()
            if row:
                approval = self.w.decode(row[0])
            pilot = bool(policy.pilot_enabled and owner and db.execute(
                "SELECT 1 FROM users WHERE id=? AND role='admin' AND active=1", (owner,)).fetchone())
        configured = (approval.get("organization_id") == self.w.config.organization_id
                      and approval.get("project_id") == self.w.config.project_id
                      and all(approval.get(k) for k in ("baa_verified", "retention_verified", "safeguards_verified"))
                      and approval.get("approval_evidence", "").strip())
        return bool(configured and policy.organization_id == self.w.config.organization_id
                    and policy.project_id == self.w.config.project_id and policy.realtime_retention_verified
                    and ((policy.enabled and policy.device_acceptance_verified) or pilot) and policy.approval_evidence.strip()
                    and valid_gateway(self.w.config.voice_gateway_url))

    def require_available(self, owner: str):
        if not self.available(owner):
            fail(409, "Watch voice is awaiting organization approval or device acceptance")

    def profiles(self, owner: str):
        with self.w.db() as db:
            rows = db.execute("SELECT id,content FROM assistants WHERE owner=? ORDER BY rowid", (owner,)).fetchall()
        result = []
        for row in rows:
            data = self.w.decode(row["content"])
            voice = data.get("voice") or {}
            if voice.get("enabled") and voice.get("model") in self.w.config.voice_models and voice.get("voice") in self.w.config.voice_voices:
                # Instructions are read only by the PC when creating a provider session.
                result.append({"id": row["id"], "name": data["name"], "model": voice["model"], "voice": voice["voice"]})
        return result

    def repair_default(self, owner: str):
        profiles = self.profiles(owner)
        with self.w.db() as db:
            row = db.execute("SELECT content FROM voice_preferences WHERE owner=?", (owner,)).fetchone()
            current = self.w.decode(row[0]).get("default_assistant_id", "") if row else ""
            if not any(p["id"] == current for p in profiles):
                current = profiles[0]["id"] if profiles else ""
                db.execute("INSERT OR REPLACE INTO voice_preferences VALUES(?,?)",
                           (owner, self.w.encode({"default_assistant_id": current})))
        return current

    def configuration(self, owner: str):
        policy = self.policy()
        return {"version": 1, "enabled": self.available(owner), "gateway_url": self.w.config.voice_gateway_url,
                "default_assistant_id": self.repair_default(owner), "assistants": self.profiles(owner),
                "models": self.w.config.voice_models, "voices": self.w.config.voice_voices,
                "session_seconds": policy.session_seconds, "idle_seconds": policy.idle_seconds}

    def provision(self, user, device_id: str):
        identifier(device_id)
        self.require_available(user["id"])
        token = secrets.token_urlsafe(32)
        with self.w.db() as db:
            self.w.require_session(db, user)
            parent = db.execute("SELECT expires FROM sessions WHERE hash=?", (user["session_hash"],)).fetchone()
            db.execute("DELETE FROM voice_devices WHERE owner=? AND device_id=?", (user["id"], device_id))
            db.execute("INSERT INTO voice_devices VALUES(?,?,?,?,?)",
                       (digest(token), user["id"], user["session_hash"], device_id, parent[0]))
            self.w.audit(db, user["id"], "voice-device-provisioned", device_id)
        return {"version": 1, "token": token, "owner_id": user["id"], "expires": parent[0],
                "gateway_url": self.w.config.voice_gateway_url, "device_id": device_id}

    def authenticate_hash(self, token_hash: str):
        with self.w.db() as db:
            row = db.execute("""SELECT d.owner AS id,d.hash AS device_hash,d.parent_session AS session_hash
                FROM voice_devices d JOIN sessions s ON s.hash=d.parent_session AND s.user_id=d.owner
                JOIN users u ON u.id=d.owner WHERE d.hash=? AND d.expires>? AND s.expires>? AND u.active=1""",
                             (token_hash, time.time(), time.time())).fetchone()
        if not row:
            fail(401, "Open Scribe Pilot on your iPhone to set up Watch voice again")
        return dict(row)

    def conversation(self, conversation_id: str, owner: str, *, review=False):
        identifier(conversation_id)
        with self.w.db() as db:
            row = db.execute("SELECT * FROM voice_conversations WHERE id=? AND deleted=0", (conversation_id,)).fetchone()
            if not row or (row["owner"] != owner and not review):
                fail(404, "Conversation unavailable")
            if review and row["owner"] != owner:
                self.w.audit(db, owner, "admin-voice-content-reviewed", conversation_id)
            return {**self.w.decode(row["content"]), "id": row["id"], "owner": row["owner"],
                    "assistant_id": row["assistant_id"], "state": row["state"], "created": row["created"], "updated": row["updated"]}

    def history(self, owner: str, *, review=False, offset=0):
        if offset < 0:
            fail(422, "Invalid offset")
        with self.w.db() as db:
            rows = db.execute("SELECT * FROM voice_conversations WHERE deleted=0 "
                              + ("" if review else "AND owner=? ") + "ORDER BY updated DESC LIMIT 100 OFFSET ?",
                              (offset,) if review else (owner, offset)).fetchall()
            if review:
                self.w.audit(db, owner, "admin-voice-history-reviewed", "voice-history")
        result = []
        for row in rows:
            value = self.w.decode(row["content"])
            result.append({"id": row["id"], "owner": row["owner"], "assistant_id": row["assistant_id"],
                           "assistant_name": value["assistant_name"], "title": value["title"],
                           "created": row["created"], "updated": row["updated"], "state": row["state"]})
        return {"conversations": result}

    def delete(self, conversation_id: str, owner: str):
        self.conversation(conversation_id, owner)
        with self.w.db() as db:
            # Tombstone prevents delayed provider events from recreating deleted content.
            db.execute("UPDATE voice_conversations SET deleted=1,state='ended',content=?,updated=? WHERE id=? AND owner=?",
                       (self.w.encode({}), time.time(), conversation_id, owner))
            db.execute("UPDATE voice_sessions SET state='ended' WHERE conversation_id=?", (conversation_id,))
            self.w.audit(db, owner, "voice-conversation-deleted", conversation_id)

    def save_turn(self, conversation_id: str, turn: dict):
        with self.w.db() as db:
            row = db.execute("SELECT content FROM voice_conversations WHERE id=? AND deleted=0", (conversation_id,)).fetchone()
            if not row:
                return False
            data = self.w.decode(row[0])
            turns = data["turns"]
            old = next((t for t in turns if t["id"] == turn["id"]), None)
            if old:
                turn["interrupted"] = old.get("interrupted", False) or turn.get("interrupted", False)
                old.update(turn)
            else:
                turns.append(turn)
            if turn["role"] == "user" and turn["text"].strip() and data["title"] == "Voice conversation":
                data["title"] = turn["text"].strip()[:100]
            db.execute("UPDATE voice_conversations SET content=?,updated=? WHERE id=? AND deleted=0",
                       (self.w.encode(data), time.time(), conversation_id))
        return True


def valid_gateway(value: str):
    url = urlparse(value)
    return (url.scheme == "https" and url.hostname and url.hostname.endswith(".ts.net")
            and url.port == 8443 and url.path == "/voice/v1" and not url.username and not url.password
            and not url.query and not url.fragment)


class VoiceBodyLimit:
    """Bound JSON and PCM before FastAPI buffers bodies, including chunked requests."""
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or scope["method"] not in {"POST", "PUT", "PATCH"}:
            return await self.app(scope, receive, send)
        chunks = []
        size = 0
        while True:
            message = await receive()
            if message["type"] == "http.disconnect":
                return
            chunk = message.get("body", b"")
            size += len(chunk)
            if size > 65536:
                return await JSONResponse({"detail": "Voice request is too large"}, status_code=413)(scope, receive, send)
            chunks.append(chunk)
            if not message.get("more_body", False):
                break
        body = b"".join(chunks)
        delivered = False

        async def replay():
            nonlocal delivered
            if not delivered:
                delivered = True
                return {"type": "http.request", "body": body, "more_body": False}
            return await receive()
        await self.app(scope, replay, send)


def install_private_routes(app, workspace, account, admin):
    store = VoiceStore(workspace)

    @app.get("/api/voice/config")
    def configuration(user=Depends(account)):
        return store.configuration(user["id"])

    @app.put("/api/voice/preferences")
    def preferences(body: PreferencesBody, user=Depends(account)):
        if not any(p["id"] == body.default_assistant_id for p in store.profiles(user["id"])):
            fail(422, "Choose a voice-enabled assistant")
        with workspace.db() as db:
            workspace.require_session(db, user)
            db.execute("INSERT OR REPLACE INTO voice_preferences VALUES(?,?)", (user["id"], workspace.encode(body.model_dump())))
        return store.configuration(user["id"])

    @app.post("/api/voice/devices")
    def provision(body: DeviceBody, user=Depends(account)):
        return store.provision(user, body.device_id)

    @app.delete("/api/voice/devices/{device_id}")
    def revoke_device(device_id: str, user=Depends(account)):
        with workspace.db() as db:
            db.execute("DELETE FROM voice_devices WHERE owner=? AND device_id=?", (user["id"], identifier(device_id)))
            workspace.audit(db, user["id"], "voice-device-revoked", device_id)
        return {"ok": True}

    @app.get("/api/voice/conversations")
    def history(offset: int = 0, user=Depends(account)):
        return store.history(user["id"], offset=offset)

    @app.get("/api/voice/conversations/{conversation_id}")
    def detail(conversation_id: str, user=Depends(account)):
        return store.conversation(conversation_id, user["id"])

    @app.delete("/api/voice/conversations/{conversation_id}")
    def delete(conversation_id: str, user=Depends(account)):
        store.delete(conversation_id, user["id"])
        return {"ok": True}

    @app.get("/api/admin/voice/conversations")
    def review_history(offset: int = 0, user=Depends(admin)):
        return store.history(user["id"], review=True, offset=offset)

    @app.get("/api/admin/voice/conversations/{conversation_id}")
    def review_detail(conversation_id: str, user=Depends(admin)):
        return store.conversation(conversation_id, user["id"], review=True)

    @app.get("/api/admin/voice/policy")
    def policy(user=Depends(admin)):
        return store.policy().model_dump()

    @app.put("/api/admin/voice/policy")
    def update_policy(body: VoicePolicy, user=Depends(admin)):
        if body.enabled and not (body.realtime_retention_verified and body.device_acceptance_verified and body.approval_evidence.strip()):
            fail(422, "Verify Realtime retention and physical Watch acceptance before enabling voice")
        if body.pilot_enabled and not (body.realtime_retention_verified and body.approval_evidence.strip()):
            fail(422, "Verify Realtime retention before administrator pilot testing")
        body.organization_id = workspace.config.organization_id
        body.project_id = workspace.config.project_id
        with workspace.db() as db:
            workspace.require_session(db, user)
            db.execute("INSERT OR REPLACE INTO voice_policy VALUES(1,?)", (workspace.encode(body.model_dump()),))
            workspace.audit(db, user["id"], "voice-policy-updated", workspace.config.project_id)
        return body.model_dump()


class OpenAIRealtimePeer:
    @classmethod
    async def open(cls, workspace, model, owner):
        from websockets.asyncio.client import connect
        headers = workspace.provider.headers()
        headers["OpenAI-Safety-Identifier"] = digest(owner)
        socket = await connect("wss://api.openai.com/v1/realtime?model=" + model, additional_headers=headers,
                               open_timeout=10, max_size=2**20, compression=None)
        return cls(socket)

    def __init__(self, socket):
        self.socket = socket

    async def send(self, event):
        await self.socket.send(json.dumps(event))

    async def receive(self):
        return json.loads(await self.socket.recv())

    async def close(self):
        await self.socket.close()


class VoiceSession:
    def __init__(self, gateway, sid, user, conversation, profile):
        self.gateway = gateway
        self.store = gateway.store
        self.id = sid
        self.user = user
        self.conversation_id = conversation["id"]
        self.profile = profile
        self.history = conversation["turns"]
        self.state = "connecting"
        self.peer = None
        self.events = asyncio.Queue(maxsize=128)
        self.queued_bytes = 0
        self.event_id = 0
        self.sequence = 0
        self.last_audio_hash = ""
        self.audio_bytes = 0
        self.audio_lock = asyncio.Lock()
        self.started = self.activity = self.touched = time.monotonic()
        self.ended_at = None
        self.muted = False
        self.attached = False
        self.last_output_item = None
        self.output_bytes = {}
        self.output_done = set()
        self.blocked_output = set()
        self.turns = {}
        self.reader = self.monitor = None

    def info(self):
        return {"version": 1, "id": self.id, "conversation_id": self.conversation_id,
                "assistant_id": self.profile["id"], "assistant_name": self.profile["name"], "state": self.state}

    async def emit(self, kind, **fields):
        if self.state == "ended" and kind != "ended":
            return
        self.event_id += 1
        event = {"version": 1, "id": self.event_id, "type": kind, **fields}
        size = len(fields.get("audio", ""))
        if self.events.full() or self.queued_bytes + size > 256000:
            await self.end("Audio connection is too slow. Start a new conversation.")
            return
        self.queued_bytes += size
        self.events.put_nowait(event)

    async def start(self):
        try:
            self.peer = await self.gateway.peer_factory(self.store.w, self.profile["model"], self.user["id"])
            transcription = "gpt-4o-mini-transcribe" if "gpt-4o-mini-transcribe" in self.store.w.config.transcription_models else self.store.w.config.transcription_models[0]
            await self.peer.send({"type": "session.update", "session": {
                "type": "realtime", "model": self.profile["model"], "output_modalities": ["audio"],
                "instructions": self.profile["instructions"], "tools": [], "tool_choice": "none", "max_output_tokens": 1024,
                "audio": {"input": {"format": {"type": "audio/pcm", "rate": 24000},
                                    "transcription": {"model": transcription},
                                    "turn_detection": {"type": "semantic_vad", "eagerness": "medium",
                                                       "create_response": True, "interrupt_response": True}},
                          "output": {"format": {"type": "audio/pcm", "rate": 24000}, "voice": self.profile["voice"]}}}})
            # Most recent complete text turns; interrupted answers are not represented as heard.
            budget = 24000
            seed = []
            for turn in reversed(self.history):
                if not turn.get("final") or turn.get("interrupted") or not turn["text"]:
                    continue
                if len(turn["text"]) > budget:
                    break
                budget -= len(turn["text"])
                seed.append(turn)
            for turn in reversed(seed):
                await self.peer.send({"type": "conversation.item.create", "item": {
                    "type": "message", "role": turn["role"], "content": [{
                        "type": "input_text" if turn["role"] == "user" else "output_text", "text": turn["text"]}]}})
            self.reader = asyncio.create_task(self.read_provider())
            self.monitor = asyncio.create_task(self.watchdog())
        except Exception:
            await self.end("The voice service could not connect. Try again.")

    def save(self, item_id, role, text=None, final=None, interrupted=False):
        turn = self.turns.setdefault(item_id, {"id": self.id + ":" + item_id, "role": role, "text": "",
                                             "final": False, "interrupted": False})
        if text is not None:
            turn["text"] = text[:24000]
        if final is not None:
            turn["final"] = final
        turn["interrupted"] = turn["interrupted"] or interrupted
        self.store.save_turn(self.conversation_id, dict(turn))
        return dict(turn)

    async def read_provider(self):
        try:
            while self.state != "ended":
                event = await self.peer.receive()
                kind = event.get("type")
                item = event.get("item_id")
                if kind == "session.updated":
                    self.state = "listening"
                    await self.emit("state", state=self.state)
                elif kind == "input_audio_buffer.speech_started":
                    self.activity = time.monotonic()
                    if item:
                        self.save(item, "user")
                    if self.last_output_item:
                        self.blocked_output.add(self.last_output_item)
                        await self.emit("interrupt", item_id=self.last_output_item)
                    self.state = "listening"
                    await self.emit("state", state=self.state)
                elif kind == "input_audio_buffer.speech_stopped":
                    self.state = "thinking"
                    await self.emit("state", state=self.state)
                elif kind == "conversation.item.input_audio_transcription.completed" and item:
                    turn = self.save(item, "user", event.get("transcript", ""), final=True)
                    await self.emit("turn", turn=turn)
                elif kind == "conversation.item.input_audio_transcription.failed" and item:
                    turn = self.save(item, "user", "[Speech could not be transcribed]", final=True)
                    await self.emit("turn", turn=turn)
                elif kind == "response.output_audio.delta" and item:
                    if item in self.blocked_output:
                        continue
                    self.last_output_item = item
                    self.output_bytes[item] = self.output_bytes.get(item, 0) + len(base64.b64decode(event["delta"], validate=True))
                    self.activity = time.monotonic()
                    self.state = "speaking"
                    await self.emit("audio", item_id=item, audio=event["delta"])
                elif kind == "response.output_audio_transcript.delta" and item:
                    old = self.turns.get(item, {}).get("text", "")
                    turn = self.save(item, "assistant", old + event.get("delta", ""))
                    await self.emit("turn", turn=turn)
                elif kind == "response.output_audio_transcript.done" and item:
                    turn = self.save(item, "assistant", event.get("transcript", ""), final=True)
                    await self.emit("turn", turn=turn)
                elif kind == "response.done":
                    if self.last_output_item:
                        self.output_done.add(self.last_output_item)
                    if event.get("response", {}).get("status") == "failed":
                        await self.end("The assistant could not respond. Start a new conversation.")
                    else:
                        self.state = "listening"
                        await self.emit("state", state=self.state)
                elif kind == "error":
                    # Harmless cancellation/truncation races must not expose provider errors.
                    if event.get("error", {}).get("code") not in {"response_cancel_not_active", "conversation_already_truncated"}:
                        await self.end("The voice service could not continue. Start a new conversation.")
        except asyncio.CancelledError:
            raise
        except Exception:
            await self.end("The voice connection ended. Completed text was saved.")

    async def watchdog(self):
        try:
            while self.state != "ended":
                await asyncio.sleep(1)
                self.store.authenticate_hash(self.user["device_hash"])
                self.store.require_available(self.user["id"])
                self.store.conversation(self.conversation_id, self.user["id"])
                if not any(p["id"] == self.profile["id"] for p in self.store.profiles(self.user["id"])):
                    await self.end("This assistant is no longer available.")
                    return
                policy = self.store.policy()
                now = time.monotonic()
                if now - self.started >= policy.session_seconds:
                    await self.end("Conversation time limit reached. Start a new conversation.")
                elif now - self.activity >= policy.idle_seconds:
                    await self.end("Conversation ended after inactivity.")
                elif now - self.touched > (8 if self.attached else 12):
                    await self.end("The Watch disconnected. Completed text was saved.")
                elif self.state == "connecting" and now - self.started > 10:
                    await self.end("The voice service did not become ready. Try again.")
        except asyncio.CancelledError:
            raise
        except Exception:
            await self.end("Voice access ended. Open Scribe Pilot on your iPhone.")

    async def audio(self, sequence, data):
        async with self.audio_lock:
            fingerprint = digest(base64.b64encode(data).decode())
            if sequence == self.sequence - 1 and fingerprint == self.last_audio_hash:
                return {"ok": True, "next_sequence": self.sequence}
            if sequence != self.sequence:
                fail(409, "Audio sequence changed; start a new conversation")
            if self.state in {"ended", "connecting"}:
                fail(409, "Voice session is not ready")
            if not data or len(data) > 48000 or len(data) % 2:
                fail(413, "Send at most one second of PCM16 mono audio")
            if self.audio_bytes + len(data) > (time.monotonic() - self.started + 2) * 48000:
                fail(429, "Audio arrived faster than real time")
            self.touched = time.monotonic()
            if not self.muted:
                try:
                    await self.peer.send({"type": "input_audio_buffer.append", "audio": base64.b64encode(data).decode()})
                except Exception:
                    await self.end("The voice connection ended. Completed text was saved.")
                    fail(502, "Voice connection ended")
            self.audio_bytes += len(data)
            self.last_audio_hash = fingerprint
            self.sequence += 1
            return {"ok": True, "next_sequence": self.sequence}

    async def control(self, body):
        self.touched = time.monotonic()
        if body.action == "end":
            await self.end("Conversation ended.")
        elif body.action == "heartbeat":
            pass
        elif body.action == "played":
            if body.item_id == self.last_output_item and body.item_id in self.output_done:
                total = self.output_bytes.get(body.item_id, 0) / 48
                if body.audio_end_ms >= total - 5:
                    self.last_output_item = None
        elif body.action == "mute":
            self.muted = body.muted
            if self.peer and self.muted:
                await self.peer.send({"type": "input_audio_buffer.clear"})
        elif body.action == "interrupt":
            if body.item_id != self.last_output_item:
                fail(422, "Unknown playback item")
            total = self.output_bytes.get(body.item_id, 0) / 48
            if body.item_id in self.output_done and body.audio_end_ms >= total - 5:
                self.last_output_item = None
            else:
                self.blocked_output.add(body.item_id)
                turn = self.save(body.item_id, "assistant", interrupted=True)
                await self.emit("turn", turn=turn)
                await self.peer.send({"type": "conversation.item.truncate", "item_id": body.item_id,
                                      "content_index": 0, "audio_end_ms": min(body.audio_end_ms, int(total))})
        else:
            fail(422, "Unknown voice control")
        return {"ok": True}

    async def end(self, message):
        if self.state == "ended":
            return
        self.state = "ended"
        self.ended_at = time.monotonic()
        for task in (self.reader, self.monitor):
            if task and task is not asyncio.current_task():
                task.cancel()
        with self.store.w.db() as db:
            db.execute("UPDATE voice_sessions SET state='ended' WHERE id=?", (self.id,))
            db.execute("UPDATE voice_conversations SET state='ended',updated=? WHERE id=? AND deleted=0",
                       (time.time(), self.conversation_id))
            self.store.w.audit(db, self.user["id"], "voice-session-ended", self.id)
        while not self.events.empty():
            self.events.get_nowait()
        self.queued_bytes = 0
        await self.emit("ended", message=message)
        if self.peer:
            with suppress(Exception):
                await asyncio.wait_for(self.peer.close(), 3)


class VoiceGateway:
    def __init__(self, workspace, peer_factory=None):
        self.store = VoiceStore(workspace)
        self.peer_factory = peer_factory or OpenAIRealtimePeer.open
        self.sessions = {}
        self.lock = asyncio.Lock()

    def recover(self):
        with self.store.w.db() as db:
            db.execute("UPDATE voice_conversations SET state='ended' WHERE id IN (SELECT conversation_id FROM voice_sessions WHERE state='active')")
            db.execute("UPDATE voice_sessions SET state='ended' WHERE state='active'")

    async def create(self, user, body):
        self.store.require_available(user["id"])
        identifier(body.request_id)
        self.store.w.rate_limit("voice-start:" + digest(user["id"]), 60)
        async with self.lock:
            default_assistant = self.store.repair_default(user["id"])
            for sid, session in list(self.sessions.items()):
                if session.ended_at and time.monotonic() - session.ended_at > 60:
                    del self.sessions[sid]
            with self.store.w.db() as db:
                db.execute("BEGIN IMMEDIATE")
                old = db.execute("SELECT * FROM voice_sessions WHERE owner=? AND request_id=?", (user["id"], body.request_id)).fetchone()
                if old:
                    if old["device_hash"] != user["device_hash"]:
                        fail(409, "A conversation is already active on another Watch")
                    if old["id"] in self.sessions:
                        return self.sessions[old["id"]].info()
                    fail(410, "That connection ended. Start a new conversation")
                if db.execute("SELECT 1 FROM voice_sessions WHERE owner=? AND state='active'", (user["id"],)).fetchone():
                    fail(409, "End your current voice conversation first")
                previous = self.store.conversation(body.conversation_id, user["id"]) if body.conversation_id else None
                aid = body.assistant_id or (previous["assistant_id"] if previous else default_assistant)
                row = db.execute("SELECT content FROM assistants WHERE id=? AND owner=?", (aid, user["id"])).fetchone()
                if not row or not any(p["id"] == aid for p in self.store.profiles(user["id"])):
                    fail(404, "Choose an available voice assistant in Settings")
                data = self.store.w.decode(row[0])
                profile = {"id": aid, "name": data["name"], "instructions": data["instructions"], **data["voice"]}
                if previous and previous["assistant_id"] != aid:
                    fail(422, "Resume with the conversation's original assistant")
                conversation = previous or {"id": str(uuid.uuid4()), "title": "Voice conversation", "turns": [], "assistant_name": data["name"]}
                now = time.time()
                if not previous:
                    db.execute("INSERT INTO voice_conversations VALUES(?,?,?,'active',0,?,?,?)",
                               (conversation["id"], user["id"], aid, now, now, self.store.w.encode(conversation)))
                else:
                    db.execute("UPDATE voice_conversations SET state='active',updated=? WHERE id=?", (now, conversation["id"]))
                sid = str(uuid.uuid4())
                db.execute("INSERT INTO voice_sessions VALUES(?,?,?,?,?,'active',?)",
                           (sid, user["id"], user["device_hash"], conversation["id"], body.request_id, now))
                self.store.w.audit(db, user["id"], "voice-session-started", sid)
            session = VoiceSession(self, sid, user, conversation, profile)
            self.sessions[sid] = session
            await session.start()
            return session.info()

    def session(self, sid, user):
        session = self.sessions.get(identifier(sid))
        if not session or session.user["id"] != user["id"] or session.user["device_hash"] != user["device_hash"]:
            fail(404, "Voice session unavailable")
        return session


def create_voice_app(workspace, peer_factory=None):
    gateway = VoiceGateway(workspace, peer_factory)
    bearer = HTTPBearer(auto_error=False)

    @asynccontextmanager
    async def lifespan(app):
        gateway.recover()
        yield
        for session in list(gateway.sessions.values()):
            await session.end("The voice gateway restarted. Completed text was saved.")

    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None, lifespan=lifespan)
    app.add_middleware(VoiceBodyLimit)
    app.state.voice = gateway

    @app.middleware("http")
    async def headers(request, call_next):
        response = await call_next(request)
        response.headers.update({"Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"})
        return response

    def account(credentials: HTTPAuthorizationCredentials | None = Depends(bearer)):
        if not credentials:
            fail(401, "Watch voice setup required")
        return gateway.store.authenticate_hash(digest(credentials.credentials))

    @app.get("/voice/v1/health")
    def health():
        return {"ok": True, "version": 1}

    @app.get("/voice/v1/config")
    def config(user=Depends(account)):
        return gateway.store.configuration(user["id"])

    @app.get("/voice/v1/conversations")
    def history(offset: int = 0, user=Depends(account)):
        return gateway.store.history(user["id"], offset=offset)

    @app.get("/voice/v1/conversations/{cid}")
    def detail(cid: str, user=Depends(account)):
        return gateway.store.conversation(cid, user["id"])

    @app.delete("/voice/v1/conversations/{cid}")
    async def delete(cid: str, user=Depends(account)):
        gateway.store.delete(cid, user["id"])
        for session in list(gateway.sessions.values()):
            if session.conversation_id == cid:
                await session.end("Conversation deleted.")
        return {"ok": True}

    @app.post("/voice/v1/sessions")
    async def create(body: SessionBody, user=Depends(account)):
        return await gateway.create(user, body)

    @app.post("/voice/v1/sessions/{sid}/audio")
    async def audio(sid: str, request: Request, sequence: int, user=Depends(account)):
        gateway.store.require_available(user["id"])
        if request.headers.get("content-type", "").split(";")[0] != "application/octet-stream":
            fail(415, "PCM16 audio required")
        data = bytearray()
        async for chunk in request.stream():
            data.extend(chunk)
            if len(data) > 48000:
                fail(413, "Audio batch is too large")
        return await gateway.session(sid, user).audio(sequence, bytes(data))

    @app.post("/voice/v1/sessions/{sid}/control")
    async def control(sid: str, body: ControlBody, user=Depends(account)):
        session = gateway.session(sid, user)
        try:
            return await session.control(body)
        except HTTPException:
            raise
        except Exception:
            await session.end("The voice connection ended. Completed text was saved.")
            fail(502, "Voice connection ended")

    @app.get("/voice/v1/sessions/{sid}/events")
    async def events(sid: str, request: Request, user=Depends(account)):
        session = gateway.session(sid, user)
        if session.attached:
            fail(409, "This conversation already has an event connection")
        session.attached = True
        session.touched = time.monotonic()

        async def stream():
            try:
                while True:
                    try:
                        event = await asyncio.wait_for(session.events.get(), 2)
                    except asyncio.TimeoutError:
                        yield ": heartbeat\n\n"
                        continue
                    session.queued_bytes -= len(event.get("audio", ""))
                    yield "id: " + str(event["id"]) + "\ndata: " + json.dumps(event, separators=(",", ":")) + "\n\n"
                    if event["type"] == "ended":
                        break
            finally:
                await session.end("The Watch disconnected. Completed text was saved.")
        return StreamingResponse(stream(), media_type="text/event-stream", headers={"X-Accel-Buffering": "no"})

    return app
