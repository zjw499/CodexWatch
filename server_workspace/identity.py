"""Invitation-only agency membership, consent, and account lifecycle.

All authorization comes from the authenticated account. Agency identifiers in
request bodies never change the caller's membership or review scope.
"""
from __future__ import annotations

import json
import re
import secrets
import time
import uuid

from .workspace import digest, fail
from fastapi import HTTPException


CONSENT_VERSION = "2026-10-20"
DEFAULT_AGENCY = "sky-data-services"


def invitation_code(value: str) -> str:
    """Accept a code or the app's shared invitation without changing its case."""
    # Messaging apps may wrap a code or insert invisible formatting marks.
    value = value.translate(dict.fromkeys(map(ord, "\u200b\u200e\u200f\u2060\ufeff")))
    candidate = re.sub(r"\s+", "", value).strip("\"'`")
    if re.fullmatch(r"[A-Za-z0-9_-]{32}", candidate):
        return candidate
    labels = list(re.finditer(r"\binvitation\s+code\s*:", value, re.IGNORECASE))
    if len(labels) == 1:
        match = re.match(r"\s*((?:[A-Za-z0-9_-]\s*){32})(?![A-Za-z0-9_-])", value[labels[0].end():])
        if match:
            return re.sub(r"\s+", "", match[1])
    fail(400, "Invitation is invalid or expired")


class AgencyAccess:
    def __init__(self, workspace):
        self.w = workspace

    def migrate(self, db):
        db.execute("CREATE TABLE IF NOT EXISTS schema_migrations (name TEXT PRIMARY KEY, applied REAL NOT NULL)")
        db.execute("CREATE TABLE IF NOT EXISTS agencies (id TEXT PRIMARY KEY, name TEXT NOT NULL, active INTEGER NOT NULL DEFAULT 1, created REAL NOT NULL)")
        db.execute("INSERT OR IGNORE INTO agencies VALUES(?,?,1,?)", (DEFAULT_AGENCY, "Sky Data Services", time.time()))
        additions = {
            "users": {"agency_id": "TEXT NOT NULL DEFAULT 'sky-data-services'", "platform_operator": "INTEGER NOT NULL DEFAULT 0",
                      "consent_version": "TEXT NOT NULL DEFAULT ''", "consented_at": "REAL NOT NULL DEFAULT 0"},
            "invites": {"agency_id": "TEXT NOT NULL DEFAULT 'sky-data-services'", "platform_operator": "INTEGER NOT NULL DEFAULT 0"},
            "audit": {"agency_id": "TEXT NOT NULL DEFAULT 'sky-data-services'"},
        }
        for table, fields in additions.items():
            existing = {row[1] for row in db.execute(f"PRAGMA table_info({table})")}
            for field, definition in fields.items():
                if field not in existing:
                    db.execute(f"ALTER TABLE {table} ADD COLUMN {field} {definition}")
        db.execute("CREATE INDEX IF NOT EXISTS users_agency ON users(agency_id,active)")
        db.execute("CREATE INDEX IF NOT EXISTS audit_agency ON audit(agency_id,id)")
        db.execute("CREATE TABLE IF NOT EXISTS account_deletions (id TEXT PRIMARY KEY, user_id TEXT NOT NULL, agency_id TEXT NOT NULL, requested REAL NOT NULL, completed REAL NOT NULL)")
        if not db.execute("SELECT 1 FROM schema_migrations WHERE name='agency-access-v1'").fetchone():
            # Preserve every existing account and encrypted content row. Only the
            # first existing administrator becomes the platform configuration owner.
            db.execute("UPDATE users SET platform_operator=1 WHERE id=(SELECT id FROM users WHERE role='admin' AND active=1 ORDER BY rowid LIMIT 1)")
            db.execute("INSERT INTO schema_migrations VALUES('agency-access-v1',?)", (time.time(),))

    def public_user(self, user):
        with self.w.db() as db:
            row = db.execute("SELECT u.id,u.username,u.role,u.agency_id,u.platform_operator,u.consent_version,a.name AS agency_name FROM users u JOIN agencies a ON a.id=u.agency_id WHERE u.id=?", (user["id"],)).fetchone()
        if not row:
            fail(401, "Sign in again")
        return {**dict(row), "platform_operator": bool(row["platform_operator"])}

    def agency(self, db, actor):
        row = db.execute("SELECT agency_id,role,platform_operator,active FROM users WHERE id=?", (actor,)).fetchone()
        if not row or not row["active"]:
            fail(401, "Sign in again")
        return row

    def invitation_attempt(self, value, status):
        """Keep fixed diagnostic labels, never the code, password, or IP address."""
        detail = {"support_id": str(uuid.uuid4()), "status": status,
                  "input_characters": len(value), "shared_message": bool(re.search(r"invitation\s+code\s*:", value, re.IGNORECASE)),
                  "reason": "accepted" if status == 200 else "invalid_format"}
        try:
            code = invitation_code(value)
        except HTTPException:
            code = None
        with self.w.db() as db:
            invite = db.execute("SELECT i.used,i.expires,i.agency_id,a.active FROM invites i LEFT JOIN agencies a ON a.id=i.agency_id WHERE i.hash=?",
                                (digest(code),)).fetchone() if code else None
            if status != 200 and code:
                if not invite:
                    detail["reason"] = "unrecognized_code"
                elif invite["used"]:
                    detail["reason"] = "already_used"
                elif invite["expires"] <= time.time():
                    detail["reason"] = "expired"
                elif not invite["active"]:
                    detail["reason"] = "agency_unavailable"
                else:
                    detail["reason"] = "active_code_rejected"
            if status == 429:
                detail["reason"] = "rate_limited"
            self.w.audit(db, "registration", "invitation-acceptance", json.dumps(detail, separators=(",", ":")),
                         agency_id=invite["agency_id"] if invite else DEFAULT_AGENCY)
        return detail["support_id"]

    def operator(self, user):
        with self.w.db() as db:
            row = self.agency(db, user["id"])
            if not row["platform_operator"]:
                fail(403, "Platform operator access required")
        return user

    def require_review(self, db, actor, owner):
        reviewer = self.agency(db, actor)
        target = db.execute("SELECT agency_id FROM users WHERE id=?", (owner,)).fetchone()
        if reviewer["role"] != "admin" or not target or target[0] != reviewer["agency_id"]:
            fail(404, "Content unavailable")

    def require_member(self, db, actor, target):
        admin = self.agency(db, actor)
        row = db.execute("SELECT id,platform_operator FROM users WHERE id=? AND agency_id=?", (target, admin["agency_id"])).fetchone()
        if admin["role"] != "admin" or not row or (row["platform_operator"] and not admin["platform_operator"]):
            fail(404, "Account unavailable")

    def require_consent(self, owner):
        with self.w.db() as db:
            row = db.execute("SELECT u.consent_version FROM users u JOIN agencies a ON a.id=u.agency_id WHERE u.id=? AND u.active=1 AND a.active=1", (owner,)).fetchone()
        if not row:
            fail(401, "Account unavailable")
        if self.w.config.require_ai_consent and row[0] != CONSENT_VERSION:
            fail(409, "Review and accept the current AI processing disclosure in Scribe Pilot Settings")

    def create_agency(self, name, actor):
        name = name.strip()
        if not 2 <= len(name) <= 100:
            fail(422, "Enter an agency name of 2-100 characters")
        self.operator(actor)
        agency_id = str(uuid.uuid4())
        with self.w.db() as db:
            db.execute("INSERT INTO agencies VALUES(?,?,1,?)", (agency_id, name, time.time()))
            self.w.audit(db, actor["id"], "agency-created", agency_id, agency_id=agency_id)
        return {"id": agency_id, "name": name, "active": 1}

    def consent(self, user, version, accepted):
        if version != CONSENT_VERSION:
            fail(409, "Refresh the processing disclosure before continuing")
        with self.w.db() as db:
            self.w.require_session(db, user)
            db.execute("UPDATE users SET consent_version=?,consented_at=? WHERE id=?", (version if accepted else "", time.time(), user["id"]))
            if not accepted:
                db.execute("DELETE FROM voice_devices WHERE owner=?", (user["id"],))
                db.execute("UPDATE voice_sessions SET state='ended' WHERE owner=?", (user["id"],))
                db.execute("UPDATE recordings SET state='failed',generation=generation+1 WHERE owner=? AND deleted=0 AND state IN ('queued','processing')", (user["id"],))
            self.w.audit(db, user["id"], "ai-consent-accepted" if accepted else "ai-consent-withdrawn", version)
        return {"version": CONSENT_VERSION, "accepted": accepted}

    def delete_account(self, user, password):
        self.w.rate_limit("account-delete:" + digest(user["id"]), 5)
        with self.w.db() as db:
            self.w.require_session(db, user)
            row = db.execute("SELECT * FROM users WHERE id=? AND active=1", (user["id"],)).fetchone()
            if not row or not self.w.password_matches(password, row["password"]):
                fail(401, "Password confirmation failed")
            if row["platform_operator"]:
                previous = db.execute("SELECT id FROM account_deletions WHERE user_id=? AND completed=0", (user["id"],)).fetchone()
                request_id = previous[0] if previous else str(uuid.uuid4())
                if not previous:
                    db.execute("INSERT INTO account_deletions VALUES(?,?,?,?,0)", (request_id, user["id"], row["agency_id"], time.time()))
                    self.w.audit(db, user["id"], "operator-account-deletion-requested", request_id)
                return {"id": request_id, "status": "pending_ownership_transfer", "support_email": self.w.config.support_email}
            owner, now = user["id"], time.time()
            # Authoritative tombstones stop late uploads/provider responses from
            # resurrecting content after account deletion.
            db.execute("DELETE FROM parts WHERE recording IN (SELECT id FROM recordings WHERE owner=?)", (owner,))
            db.execute("UPDATE recordings SET deleted=1,state='deleted',generation=generation+1,content=?,updated=? WHERE owner=?", (self.w.encode({}), now, owner))
            db.execute("DELETE FROM assistant_knowledge_chunks WHERE file_id IN (SELECT id FROM assistant_knowledge WHERE owner=?)", (owner,))
            db.execute("UPDATE assistant_knowledge SET deleted=1,state='deleted',content=?,file=NULL,updated=? WHERE owner=?", (self.w.encode({}), now, owner))
            db.execute("DELETE FROM assistant_knowledge_state WHERE owner=?", (owner,))
            db.execute("DELETE FROM assistants WHERE owner=?", (owner,))
            db.execute("UPDATE voice_conversations SET deleted=1,state='ended',content=?,updated=? WHERE owner=?", (self.w.encode({}), now, owner))
            db.execute("UPDATE voice_diagnostics SET deleted=1,content=?,updated=? WHERE owner=?", (self.w.encode({}), now, owner))
            db.execute("UPDATE voice_sessions SET state='ended' WHERE owner=?", (owner,))
            db.execute("DELETE FROM voice_preferences WHERE owner=?", (owner,))
            db.execute("DELETE FROM voice_devices WHERE owner=?", (owner,))
            db.execute("DELETE FROM sessions WHERE user_id=?", (owner,))
            db.execute("DELETE FROM invites WHERE username=?", (row["username"],))
            db.execute("UPDATE audit SET target=? WHERE target=?", (owner, row["username"]))
            db.execute("UPDATE users SET username=?,password=?,active=0,consent_version='',consented_at=0 WHERE id=?", ("deleted-" + owner, self.w.password_hash(secrets.token_urlsafe(32)), owner))
            request_id = str(uuid.uuid4())
            db.execute("INSERT INTO account_deletions VALUES(?,?,?,?,?)", (request_id, owner, row["agency_id"], now, now))
            self.w.audit(db, owner, "account-deleted", request_id)
        return {"id": request_id, "status": "completed", "security_audit_retained": True}
