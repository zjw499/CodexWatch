"""Invitation acceptance uses synthetic agencies, accounts, and credentials."""
import time
from concurrent.futures import ThreadPoolExecutor
from threading import Barrier

import pytest
from fastapi import HTTPException

from server_workspace.tests.test_workspace import setup


def agency_invite(client, headers, username="new-admin", role="admin", agency=None):
    if agency is None:
        response = client.post("/api/operator/agencies", headers=headers, json={"name": "Invite Test Agency"})
        assert response.status_code == 200
        agency = response.json()["id"]
    response = client.post(f"/api/operator/agencies/{agency}/invitations", headers=headers,
                           json={"username": username, "role": role})
    assert response.status_code == 200
    return agency, response.json()["code"]


@pytest.mark.parametrize("use_first", [True, False])
def test_reshared_agency_admin_invitation_preserves_both_codes_until_registration(setup, use_first):
    workspace, client, _, (_, headers), _, _ = setup
    agency, original = agency_invite(client, headers)
    _, latest = agency_invite(client, headers, agency=agency)
    assert original != latest
    response = client.post("/api/register", json={"code": original if use_first else latest,
                                                "password": "long-test-password"})
    assert response.status_code == 200
    user = response.json()["user"]
    assert user["agency_id"] == agency and user["role"] == "admin"
    assert not user["platform_operator"]
    with workspace.db() as db:
        assert db.execute("SELECT count(*) FROM users WHERE username='new-admin'").fetchone()[0] == 1
        assert db.execute("SELECT count(*) FROM invites WHERE username='new-admin' AND used=0").fetchone()[0] == 0
    for code in (original, latest):
        assert client.post("/api/register", json={"code": code, "password": "long-test-password"}).status_code == 400


@pytest.mark.parametrize("formatting", ["code", "label", "message", "single-line", "wrapped", "invisible"])
def test_accepts_copied_code_or_shared_invitation(setup, formatting):
    _, client, _, (_, headers), _, _ = setup
    agency, code = agency_invite(client, headers)
    message = ("Scribe Pilot invitation\nAgency: Invite Test Agency\n"
               "Server: https://synthetic.ts.net/workspace\nUsername: new-admin\n"
               f"Invitation code: {code}\nExpires in 7 days. In Settings choose Accept invitation and set your password.")
    inputs = {"code": "  " + code + "\n", "label": "Invitation code: " + code,
              "message": message, "single-line": message.replace("\n", " "),
              "wrapped": code[:16] + "\n" + code[16:],
              "invisible": "\u200e" + code[:12] + "\u200b" + code[12:] + "\u200f"}
    response = client.post("/api/register", json={"code": inputs[formatting], "password": "long-test-password"})
    assert response.status_code == 200
    assert response.json()["user"]["agency_id"] == agency


def test_role_change_revokes_earlier_admin_invitation(setup):
    _, client, _, (_, headers), _, _ = setup
    agency, original = agency_invite(client, headers)
    _, replacement = agency_invite(client, headers, role="user", agency=agency)
    assert client.post("/api/register", json={"code": original, "password": "long-test-password"}).status_code == 400
    response = client.post("/api/register", json={"code": replacement, "password": "long-test-password"})
    assert response.status_code == 200 and response.json()["user"]["role"] == "user"


def test_simultaneous_redemption_creates_only_one_account(setup):
    workspace, client, _, (_, headers), _, _ = setup
    agency, first = agency_invite(client, headers)
    _, second = agency_invite(client, headers, agency=agency)
    barrier = Barrier(2)

    def redeem(code):
        barrier.wait(timeout=10)
        try:
            workspace.register(code, "long-test-password")
            return 200
        except HTTPException as error:
            return error.status_code

    with ThreadPoolExecutor(max_workers=2) as executor:
        assert sorted(executor.map(redeem, (first, second))) == [200, 400]
    with workspace.db() as db:
        assert db.execute("SELECT count(*) FROM users WHERE username='new-admin'").fetchone()[0] == 1


@pytest.mark.parametrize("invalid", ["expired", "inactive-agency", "wrong-case", "ambiguous", "too-long"])
def test_invalid_invitation_never_creates_an_account(setup, invalid):
    workspace, client, _, (_, headers), _, _ = setup
    agency, code = agency_invite(client, headers)
    if invalid == "expired":
        with workspace.db() as db:
            db.execute("UPDATE invites SET expires=? WHERE username='new-admin'", (time.time() - 1,))
    elif invalid == "inactive-agency":
        with workspace.db() as db:
            db.execute("UPDATE agencies SET active=0 WHERE id=?", (agency,))
    elif invalid == "wrong-case":
        # Guarantee a different case-sensitive credential even for random codes
        # that happen to contain only digits and punctuation.
        code = code.swapcase() if code.swapcase() != code else "A" + code[1:]
    elif invalid == "ambiguous":
        code = f"Invitation code: {code}\nInvitation code: {code}"
    else:
        code += "A"
    response = client.post("/api/register", json={"code": code, "password": "long-test-password"})
    assert response.status_code == 400
    with workspace.db() as db:
        assert not db.execute("SELECT 1 FROM users WHERE username='new-admin'").fetchone()
