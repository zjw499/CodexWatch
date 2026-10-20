"""Release authorization and deletion acceptance with synthetic records only."""
import asyncio
import time
import uuid

from server_workspace.identity import CONSENT_VERSION, DEFAULT_AGENCY
from server_workspace.tests.test_workspace import setup, upload, process_body
from server_workspace.voice import VoiceStore


def second_agency(c, operator_headers):
    agency = c.post('/api/operator/agencies', headers=operator_headers, json={'name': 'Synthetic Agency Two'})
    assert agency.status_code == 200, agency.text
    aid = agency.json()['id']
    invite = c.post(f'/api/operator/agencies/{aid}/invitations', headers=operator_headers,
                    json={'username': 'second-admin', 'role': 'admin'}).json()
    person = c.post('/api/register', json={'code': invite['code'], 'password': 'long-test-password'}).json()
    return aid, person, {'Authorization': 'Bearer ' + person['token']}


def test_agency_admin_isolation_invitations_and_operator_boundary(setup):
    w, c, _, (operator, oh), (alice, ah), _ = setup
    aid, admin, sh = second_agency(c, oh)
    assert admin['user']['agency_id'] == aid
    assert not admin['user']['platform_operator']
    users = c.get('/api/admin/users', headers=sh).json()['users']
    assert [u['id'] for u in users] == [admin['user']['id']]
    assert all(u['agency_id'] == DEFAULT_AGENCY for u in c.get('/api/admin/users', headers=oh).json()['users'])
    invitation = c.post('/api/admin/invitations', headers=sh, json={'username': 'second-user', 'role': 'user'})
    assert invitation.status_code == 200
    assert invitation.json()['agency_id'] == aid
    assert c.post('/api/admin/invitations', headers=sh, json={'username': 'injected', 'agency_id': DEFAULT_AGENCY}).status_code == 422
    assert c.post('/api/operator/agencies', headers=sh, json={'name': 'Forbidden agency'}).status_code == 403
    assert c.put('/api/admin/policy', headers=sh, json={}).status_code == 403
    assert c.put('/api/admin/voice/policy', headers=sh, json={}).status_code == 403
    for headers, target in ((sh, alice['user']['id']), (oh, admin['user']['id'])):
        assert c.delete(f'/api/admin/users/{target}/sessions', headers=headers).status_code == 404
        assert c.post(f'/api/admin/users/{target}/disable', headers=headers).status_code == 404
    assert c.get('/api/me', headers=ah).status_code == 200
    assert c.get('/api/me', headers=sh).status_code == 200
    peer_invitation = c.post('/api/admin/invitations', headers=oh, json={'username': 'agency-peer', 'role': 'admin'}).json()
    peer = c.post('/api/register', json={'code': peer_invitation['code'], 'password': 'long-test-password'}).json()
    ph = {'Authorization': 'Bearer ' + peer['token']}
    assert c.post(f"/api/admin/users/{operator['user']['id']}/disable", headers=ph).status_code == 404
    assert c.delete(f"/api/admin/users/{operator['user']['id']}/sessions", headers=ph).status_code == 404
    assert all(e['agency_id'] == aid for e in c.get('/api/admin/audit', headers=sh).json()['events'])
    # Another agency cannot invalidate a still-pending invitation by reusing its username.
    assert c.post('/api/admin/invitations', headers=oh, json={'username': 'second-user', 'role': 'user'}).status_code == 409
    person = c.post('/api/register', json={'code': invitation.json()['code'], 'password': 'long-test-password'})
    assert person.status_code == 200 and person.json()['user']['agency_id'] == aid


def test_recording_voice_and_diagnostic_review_stay_inside_agency(setup):
    w, c, _, (_, oh), (alice, ah), _ = setup
    _, admin, sh = second_agency(c, oh)
    upload(c, ah)
    upload(c, sh, 'second-recording')
    assert [r['id'] for r in c.get('/api/admin/recordings', headers=sh).json()['recordings']] == ['second-recording']
    assert [r['id'] for r in c.get('/api/admin/recordings', headers=oh).json()['recordings']] == ['recording-1']
    assert c.get('/api/recordings/recording-1?review=true', headers=sh).status_code == 404
    assert c.get('/api/recordings/second-recording?review=true', headers=oh).status_code == 404
    for owner, cid in ((alice['user']['id'], 'first-conversation'), (admin['user']['id'], 'second-conversation')):
        with w.db() as db:
            db.execute('INSERT INTO voice_conversations VALUES(?,?,?,?,0,?,?,?)',
                       (cid, owner, 'assistant', 'ended', time.time(), time.time(), w.encode({'turns': [], 'assistant_name': 'Synthetic', 'title': 'Synthetic conversation'})))
            db.execute('INSERT INTO voice_diagnostics VALUES(?,?,1,0,?,?,?)',
                       (cid, owner, time.time(), time.time(), w.encode({'kind': 'audio-test'})))
    assert [v['id'] for v in c.get('/api/admin/voice/conversations', headers=sh).json()['conversations']] == ['second-conversation']
    assert c.get('/api/admin/voice/conversations/first-conversation', headers=sh).status_code == 404
    assert c.get('/api/admin/voice/conversations/second-conversation', headers=oh).status_code == 404
    assert [v['id'] for v in c.get('/api/admin/voice/diagnostics', headers=sh).json()['reports']] == ['second-conversation']
    assert c.get('/api/admin/voice/diagnostics/first-conversation', headers=sh).status_code == 404
    assert c.get('/api/admin/voice/diagnostics/second-conversation', headers=oh).status_code == 404


def test_consent_blocks_provider_and_revocation_invalidates_queued_job(setup):
    w, c, provider, _, (alice, ah), _ = setup
    w.config.require_ai_consent = True
    upload(c, ah)
    body = process_body(c, ah)
    assert c.get('/api/me', headers=ah).json()['consent_required'] is True
    assert c.post('/api/recordings/recording-1/process', headers=ah, json=body).status_code == 409
    assert not provider.calls
    assert c.post('/api/account/consent', headers=ah, json={'version': 'old', 'accepted': True}).status_code == 409
    assert c.post('/api/account/consent', headers=ah, json={'version': CONSENT_VERSION, 'accepted': True}).status_code == 200
    assert c.get('/api/me', headers=ah).json()['consent_required'] is False
    assert c.post('/api/recordings/recording-1/process', headers=ah, json=body).status_code == 200
    assert c.post('/api/account/consent', headers=ah, json={'version': CONSENT_VERSION, 'accepted': False}).status_code == 200
    assert asyncio.run(w.run_next()) is False
    assert not provider.calls
    assert VoiceStore(w).available(alice['user']['id']) is False


def test_account_deletion_erases_content_revokes_access_and_preserves_other_users(setup):
    w, c, provider, (_, oh), (alice, ah), (_, bh) = setup
    upload(c, ah)
    upload(c, bh, 'keep-bobby')
    body = process_body(c, ah)
    assert c.post('/api/recordings/recording-1/process', headers=ah, json=body).status_code == 200
    assert c.post('/api/account/deletion', headers=ah, json={'password': 'wrong', 'confirmation': 'DELETE'}).status_code == 401
    assert c.post('/api/account/deletion', headers=ah, json={'password': 'long-test-password', 'confirmation': 'DELETE'}).json()['status'] == 'completed'
    assert c.get('/api/me', headers=ah).status_code == 401
    assert c.post('/api/login', json={'username': 'alice', 'password': 'long-test-password'}).status_code == 401
    assert c.get('/api/recordings/keep-bobby', headers=bh).status_code == 200
    assert c.get('/api/recordings/recording-1?review=true', headers=oh).status_code == 404
    assert asyncio.run(w.run_next()) is False and not provider.calls
    with w.db() as db:
        row = db.execute('SELECT * FROM recordings WHERE id=?', ('recording-1',)).fetchone()
        assert row['deleted'] == 1 and w.decode(row['content']) == {}
        assert not db.execute('SELECT 1 FROM parts WHERE recording=?', ('recording-1',)).fetchone()
        assert not db.execute('SELECT 1 FROM assistants WHERE owner=?', (alice['user']['id'],)).fetchone()
        assert db.execute('SELECT username FROM users WHERE id=?', (alice['user']['id'],)).fetchone()[0].startswith('deleted-')
    assert c.post('/api/account/deletion', headers=ah, json={'password': 'long-test-password', 'confirmation': 'DELETE'}).status_code == 401


def test_platform_owner_deletion_starts_a_durable_request(setup):
    w, c, _, (owner, oh), _, _ = setup
    args = {'password': 'long-test-password', 'confirmation': 'DELETE'}
    first = c.post('/api/account/deletion', headers=oh, json=args).json()
    second = c.post('/api/account/deletion', headers=oh, json=args).json()
    assert first == second and first['status'] == 'pending_ownership_transfer'
    assert c.get('/api/me', headers=oh).status_code == 200
    with w.db() as db:
        assert db.execute('SELECT COUNT(*) FROM account_deletions WHERE user_id=?', (owner['user']['id'],)).fetchone()[0] == 1
        # Idempotent migrations do not promote a later agency administrator.
        w.access.migrate(db)
        assert db.execute('SELECT COUNT(*) FROM users WHERE platform_operator=1').fetchone()[0] == 1


def test_public_release_disclosures_do_not_require_account(setup):
    _, c, _, _, _, _ = setup
    for path in ('/privacy', '/support', '/account-deletion'):
        response = c.get(path)
        assert response.status_code == 200 and response.headers['cache-control'] == 'no-store'
    disclosure = c.get('/api/disclosure').json()
    assert disclosure['provider'] == 'OpenAI' and disclosure['version'] == CONSENT_VERSION
    assert 'zero data retention' in disclosure['text']
