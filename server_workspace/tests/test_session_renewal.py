import asyncio
import time

import pytest

from server_workspace.workspace import digest, OpenAIProvider
from server_workspace.voice import OpenAIRealtimePeer, VoiceServiceUnavailable
from server_workspace.tests.test_voice import voice, start


def test_watch_activity_renews_same_parent_and_live_devices_only(voice):
    w, private, public, people, _, device, headers, _ = voice
    account, phone_headers = people["alice"]
    owner, parent = account["user"]["id"], digest(account["token"])
    now = time.time()
    with w.db() as db:
        db.execute("UPDATE sessions SET expires=? WHERE hash=?", (now + 60, parent))
        db.execute("UPDATE voice_devices SET expires=? WHERE hash=?", (now + 60, digest(device["token"])))
        db.execute("INSERT INTO voice_devices VALUES(?,?,?,?,?)", ("expired-device", owner, parent, "old-watch", now - 1))
        other_expiry = db.execute("SELECT expires FROM sessions WHERE user_id=?", (people["bobby"][0]["user"]["id"],)).fetchone()[0]
    response = public.get("/voice/v1/config", headers=headers)
    assert response.status_code == 200
    renewed = float(response.headers["X-Scribe-Session-Expires"])
    assert renewed > now + 29 * 86400
    with w.db() as db:
        assert db.execute("SELECT expires FROM sessions WHERE hash=?", (parent,)).fetchone()[0] == renewed
        assert db.execute("SELECT expires FROM voice_devices WHERE hash=?", (digest(device["token"]),)).fetchone()[0] == renewed
        assert db.execute("SELECT expires FROM voice_devices WHERE hash='expired-device'").fetchone()[0] == now - 1
        assert db.execute("SELECT expires FROM sessions WHERE user_id=?", (people["bobby"][0]["user"]["id"],)).fetchone()[0] == other_expiry
    assert float(private.get("/api/me", headers=phone_headers).headers["X-Scribe-Session-Expires"]) == renewed
    assert float(public.get("/voice/v1/config", headers=headers).headers["X-Scribe-Session-Expires"]) == renewed
    # A renewed Watch token still cannot access the private account API.
    assert private.get("/api/me", headers=headers).status_code == 401


@pytest.mark.parametrize("expired", ["parent", "device", "account"])
def test_activity_cannot_revive_expired_or_disabled_access(voice, expired):
    w, private, public, people, _, device, headers, _ = voice
    account, phone_headers = people["alice"]
    with w.db() as db:
        if expired == "parent":
            db.execute("UPDATE sessions SET expires=0 WHERE hash=?", (digest(account["token"]),))
        elif expired == "device":
            db.execute("UPDATE voice_devices SET expires=0 WHERE hash=?", (digest(device["token"]),))
        else:
            db.execute("UPDATE users SET active=0 WHERE id=?", (account["user"]["id"],))
    rejected = public.get("/voice/v1/config", headers=headers)
    assert rejected.status_code == 401
    assert "X-Scribe-Session-Expires" not in rejected.headers
    if expired != "device":
        assert private.get("/api/me", headers=phone_headers).status_code == 401


def test_passive_watchdog_does_not_extend_a_session(voice):
    info = start(voice)
    w = voice[0]
    parent = digest(voice[3]["alice"][0]["token"])
    expiry = time.time() + 60
    with w.db() as db:
        db.execute("UPDATE sessions SET expires=? WHERE hash=?", (expiry, parent))
    voice[2].portal.call(asyncio.sleep, 1.1)
    assert voice[2].app.state.voice.sessions[info["id"]].state != "ended"
    with w.db() as db:
        assert db.execute("SELECT expires FROM sessions WHERE hash=?", (parent,)).fetchone()[0] == expiry


def test_missing_provider_key_is_reported_as_service_configuration(voice):
    w = voice[0]
    w.provider = OpenAIProvider(w.config)
    with pytest.raises(VoiceServiceUnavailable, match="PC voice service cannot read"):
        asyncio.run(OpenAIRealtimePeer.open(w, "gpt-realtime-2.1", voice[3]["alice"][0]["user"]["id"]))
    async def unavailable(*_):
        raise VoiceServiceUnavailable("The PC voice service needs its organization API key restored.")
    voice[2].app.state.voice.peer_factory = unavailable
    info = start(voice)
    assert info["state"] == "ended"
    assert "PC voice service" in info["message"]
    assert "unused-key" not in info["message"]


def test_private_activity_renews_only_its_parent_devices(voice):
    w, private, public, people, _, device, headers, _ = voice
    account, phone_headers = people["alice"]
    parent = digest(account["token"])
    with w.db() as db:
        db.execute("UPDATE sessions SET expires=? WHERE hash=?", (time.time() + 60, parent))
    response = private.get("/api/me", headers=phone_headers)
    assert response.status_code == 200
    expiry = float(response.headers["X-Scribe-Session-Expires"])
    with w.db() as db:
        assert db.execute("SELECT expires FROM voice_devices WHERE hash=?", (digest(device["token"]),)).fetchone()[0] == expiry
    assert private.delete("/api/session", headers=phone_headers).status_code == 200
    assert public.get("/voice/v1/config", headers=headers).status_code == 401


def test_reopening_phone_preserves_token_renewed_by_watch_and_active_conversation(voice):
    w, private, public, people, _, device, headers, _ = voice
    info = start(voice)
    with w.db() as db:
        db.execute("UPDATE sessions SET expires=? WHERE hash=?", (time.time() + 60, digest(people["alice"][0]["token"])))
    renewed = public.get("/voice/v1/config", headers=headers)
    assert renewed.status_code == 200
    confirmed = private.post("/api/voice/devices", headers=people["alice"][1],
                             json={"device_id": device["device_id"], "existing_token": device["token"]})
    assert confirmed.status_code == 200
    assert confirmed.json()["token"] == device["token"]
    assert confirmed.json()["expires"] == float(renewed.headers["X-Scribe-Session-Expires"])
    public.portal.call(asyncio.sleep, 1.1)
    assert public.app.state.voice.sessions[info["id"]].state != "ended"


@pytest.mark.parametrize("other", ["expired", "different-parent", "different-owner"])
def test_cached_provisioning_token_requires_live_owner_and_parent_binding(voice, other):
    w, private, public, people, _, device, headers, _ = voice
    if other == "expired":
        with w.db() as db:
            db.execute("UPDATE voice_devices SET expires=0 WHERE hash=?", (digest(device["token"]),))
        phone_headers = people["alice"][1]
    elif other == "different-parent":
        replacement = private.post("/api/login", json={"username": "alice", "password": "long-test-password"}).json()
        phone_headers = {"Authorization": "Bearer " + replacement["token"]}
    else:
        phone_headers = people["bobby"][1]
    response = private.post("/api/voice/devices", headers=phone_headers,
                            json={"device_id": device["device_id"], "existing_token": device["token"]})
    assert response.status_code == 200
    assert response.json()["token"] != device["token"]
    assert response.json()["owner_id"] == people["bobby" if other == "different-owner" else "alice"][0]["user"]["id"]
