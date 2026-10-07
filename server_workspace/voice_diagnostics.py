"""Strict, bounded hardware diagnostics. No audio, transcript or arbitrary strings."""
from typing import Literal
import time
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, model_validator

from .workspace import fail


class SafeBody(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, allow_inf_nan=False)


Port = Literal["built-in mic", "built-in speaker", "Bluetooth HFP", "Bluetooth A2DP", "Bluetooth LE",
               "headphones", "headset mic", "Other"]
Stage = Literal["SESSION-01", "SESSION-02", "ECHO-01", "INPUT-01", "OUTPUT-01", "PCM-01", "START-01"]


class Snapshot(SafeBody):
    engineRunning: bool = False
    category: Literal["Unknown", "Other", "record", "playAndRecord", "playback"] = "Unknown"
    mode: Literal["Unknown", "Other", "default", "voiceChat"] = "Unknown"
    inputPorts: list[Port] = Field(default_factory=list, max_length=8)
    outputPorts: list[Port] = Field(default_factory=list, max_length=8)
    hardwareInputRate: float = Field(default=0, ge=0, le=384000)
    hardwareInputChannels: int = Field(default=0, ge=0, le=32)
    captureRate: float = Field(default=0, ge=0, le=384000)
    captureChannels: int = Field(default=0, ge=0, le=32)
    outputRate: float = Field(default=0, ge=0, le=384000)
    outputChannels: int = Field(default=0, ge=0, le=32)
    voiceProcessing: bool = False
    inputMuted: bool = False
    outputVolume: float = Field(default=0, ge=0, le=1)
    captureFormat: Literal["Unknown", "Other", "Float32", "Float64", "Int16", "Int32"] = "Unknown"
    captureInterleaved: bool = False
    captureBytesPerFrame: int = Field(default=0, ge=0, le=256)


class EngineEvent(SafeBody):
    kind: Literal["start", "configuration", "stopped", "rebuild", "ready", "timeout"]
    elapsedMs: int = Field(ge=0, le=3600000)
    attempt: int = Field(ge=1, le=3)
    snapshot: Snapshot
    inputFrames: int = Field(ge=0, le=2000000000)
    convertedFrames: int = Field(ge=0, le=2000000000)
    batches: int = Field(ge=0, le=100000)


class Result(SafeBody):
    phase: Literal["N", "M", "D", "V", "E", "R", "A", "S", "P"]
    before: Snapshot
    after: Snapshot
    inputFrames: int = Field(default=0, ge=0, le=2000000000)
    drainedFrames: int = Field(default=0, ge=0, le=2000000000)
    convertedFrames: int = Field(default=0, ge=0, le=2000000000)
    pendingFrames: int = Field(default=0, ge=0, le=4800)
    batches: int = Field(default=0, ge=0, le=100000)
    receiverFailure: int = Field(default=0, ge=0, le=16)
    conversionFailed: bool = False
    conversionErrors: int = Field(default=0, ge=0, le=100000)
    converterStatus: int = Field(default=0, ge=0, le=4)
    converterCode: int | None = Field(default=None, ge=-2147483648, le=2147483647)
    renderedFrames: int = Field(default=0, ge=0, le=2000000000)
    failedStage: Stage | None = None
    nativeCode: int | None = Field(default=None, ge=-2147483648, le=2147483647)
    configurationChanges: int = Field(default=0, ge=0, le=100000)
    startupAttempts: int = Field(default=1, ge=1, le=3)
    events: list[EngineEvent] = Field(default_factory=list, max_length=12)


class DiagnosticReport(SafeBody):
    version: Literal[1] = 1
    request_id: str = Field(min_length=36, max_length=36)
    revision: int = Field(default=1, ge=1, le=100)
    kind: Literal["audio-test", "voice-startup"]
    build: str = Field(pattern=r"^[0-9]{1,8}$")
    watch_os: str = Field(pattern=r"^[0-9]{1,3}(\.[0-9]{1,3}){0,2}$")
    completed: bool
    speaker_heard: bool | None = None
    route_changes: int = Field(default=0, ge=0, le=100000)
    interruptions: int = Field(default=0, ge=0, le=100000)
    media_resets: int = Field(default=0, ge=0, le=100000)
    results: list[Result] = Field(min_length=1, max_length=9)

    @model_validator(mode="after")
    def safe_run(self):
        try:
            if str(UUID(self.request_id)).upper() != self.request_id.upper():
                raise ValueError()
        except ValueError:
            raise ValueError("A diagnostic request UUID is required") from None
        phases = [r.phase for r in self.results]
        if len(set(phases)) != len(phases):
            raise ValueError("Duplicate diagnostic phases")
        if self.kind == "voice-startup" and (phases != ["N"] or self.speaker_heard is not None):
            raise ValueError("Startup diagnostics require one normal capture result")
        if self.kind == "audio-test" and self.completed and set(phases) != set("NMDVERASP"):
            raise ValueError("A completed test requires all phases")
        return self


class DiagnosticStore:
    def __init__(self, workspace):
        self.w = workspace

    def save(self, owner, report):
        value = report.model_dump()
        now = time.time()
        with self.w.db() as db:
            # Validate the credential again inside the same transaction as the write.
            from .voice import VoiceStore
            VoiceStore(self.w).authenticate_hash(owner["device_hash"])
            row = db.execute("SELECT * FROM voice_diagnostics WHERE owner=? AND id=?",
                             (owner["id"], report.request_id)).fetchone()
            revision = report.revision
            if row:
                if row["deleted"]:
                    fail(410, "Diagnostic report deleted")
                old = self.w.decode(row["content"])
                baseline = lambda v: {k: v[k] for k in v if k not in {"revision", "speaker_heard"}}
                if baseline(old) != baseline(value):
                    fail(409, "Diagnostic request already used")
                if revision <= row["revision"]:
                    if revision == row["revision"] and old != value:
                        fail(409, "Diagnostic revision already used")
                    return {"version": 1, "id": report.request_id, "revision": row["revision"]}
                if revision != row["revision"] + 1 or report.kind != "audio-test":
                    fail(409, "Invalid diagnostic revision")
                db.execute("UPDATE voice_diagnostics SET revision=?,updated=?,content=? WHERE owner=? AND id=?",
                           (revision, now, self.w.encode(value), owner["id"], report.request_id))
            else:
                if db.execute("SELECT 1 FROM voice_diagnostics WHERE id=?", (report.request_id,)).fetchone():
                    fail(409, "Diagnostic request already used")
                if revision != 1:
                    fail(409, "Submit the original report first")
                db.execute("INSERT INTO voice_diagnostics VALUES(?,?,?,0,?,?,?)",
                           (report.request_id, owner["id"], revision, now, now, self.w.encode(value)))
                # Keep a bounded recent support history per account.
                db.execute("DELETE FROM voice_diagnostics WHERE owner=? AND deleted=0 AND id NOT IN "
                           "(SELECT id FROM voice_diagnostics WHERE owner=? AND deleted=0 ORDER BY created DESC LIMIT 100)",
                           (owner["id"], owner["id"]))
        return {"version": 1, "id": report.request_id, "revision": revision}

    def history(self, owner, review=False):
        with self.w.db() as db:
            rows = db.execute("SELECT id,owner,revision,created,updated FROM voice_diagnostics WHERE deleted=0 "
                              + ("" if review else "AND owner=? ") + "ORDER BY updated DESC LIMIT 100",
                              () if review else (owner,)).fetchall()
            if review:
                self.w.audit(db, owner, "admin-voice-diagnostics-history-reviewed", "voice-diagnostics")
            return {"reports": [dict(row) for row in rows]}

    def detail(self, owner, report_id, review=False):
        with self.w.db() as db:
            row = db.execute("SELECT * FROM voice_diagnostics WHERE id=? AND deleted=0 "
                              + ("" if review else "AND owner=?"),
                              (report_id,) if review else (report_id, owner)).fetchone()
            if not row:
                fail(404, "Diagnostic report unavailable")
            if review:
                self.w.audit(db, owner, "admin-voice-diagnostics-reviewed", report_id)
            return {"report": self.w.decode(row["content"]), "created": row["created"], "updated": row["updated"]}

    def delete(self, owner, report_id):
        self.detail(owner, report_id)
        with self.w.db() as db:
            db.execute("UPDATE voice_diagnostics SET deleted=1,content=?,updated=? WHERE owner=? AND id=?",
                       (self.w.encode({}), time.time(), owner, report_id))
            self.w.audit(db, owner, "voice-diagnostics-deleted", report_id)

    def local_review(self, username, report_id=None):
        """Explicit host-operator support command, scoped to the requested account and audited."""
        with self.w.db() as db:
            user = db.execute("SELECT id FROM users WHERE username=?", (username.lower(),)).fetchone()
            if not user:
                fail(404, "Account unavailable")
            if report_id is None:
                latest = db.execute("SELECT id FROM voice_diagnostics WHERE owner=? AND deleted=0 "
                                    "ORDER BY updated DESC LIMIT 1", (user[0],)).fetchone()
                if not latest:
                    return {"report": None}
                report_id = latest[0]
            value = self.detail(user[0], report_id)
            self.w.audit(db, "local-diagnostics-review", "local-voice-diagnostics-reviewed", report_id)
            return value
