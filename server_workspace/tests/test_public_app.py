"""Public native-app access: synthetic content, no provider/network calls."""
import asyncio
import re

from fastapi.testclient import TestClient

from server_workspace.public_app import ENABLE_FILE, HEADERS, MAX_BYTES, create_public_app
from server_workspace.tests.test_workspace import setup, upload, process_body
from server_workspace.tests.test_agencies import second_agency
from server_workspace.workspace import Workspace


def public_client(workspace):
    (workspace.config.root / ENABLE_FILE).write_text("enabled", encoding="utf-8")
    return TestClient(create_public_app(workspace))


def test_public_app_flag_fails_closed_and_does_not_disable_private_access(setup):
    w, private, _, _, (_, ah), _ = setup
    public = TestClient(create_public_app(w))
    assert public.get('/api/health').status_code == 503
    assert private.get('/api/me', headers=ah).status_code == 200
    (w.config.root / ENABLE_FILE).write_text('enabled', encoding='utf-8')
    assert public.get('/api/health').json()['ok'] is True
    assert public.get('/api/me', headers=ah).status_code == 200
    (w.config.root / ENABLE_FILE).write_text('disabled', encoding='utf-8')
    assert public.get('/api/me', headers=ah).status_code == 503
    assert private.get('/api/me', headers=ah).status_code == 200


def test_every_protected_public_route_requires_a_session_before_reading_body(setup):
    w, _, _, _, _, _ = setup
    public = public_client(w)
    from server_workspace.public_app import ANONYMOUS
    for route in public.app.routes:
        if route.path in ANONYMOUS:
            continue
        path = re.sub(r'\{[^}]+\}', 'probe', route.path)
        for method in route.methods:
            response = public.request(method, path)
            assert response.status_code == 401, (method, route.path, response.text)
            for key, value in HEADERS.items():
                assert response.headers[key] == value
    for path in ('/docs', '/openapi.json', '/upload', '/workspace/api/me', '/voice/v1/health', '/workspace.sqlite3'):
        assert public.get(path).status_code == 404


def test_existing_session_login_invitation_and_revocation_work_through_public_api(setup):
    w, private, _, (_, oh), (alice, ah), _ = setup
    public = public_client(w)
    assert public.get('/api/me', headers=ah).json()['user']['id'] == alice['user']['id']
    login = public.post('/api/login', json={'username': 'alice', 'password': 'long-test-password'})
    assert login.status_code == 200
    assert login.json()['user']['id'] == alice['user']['id']
    invitation = public.post('/api/admin/invitations', headers=oh,
                             json={'username': 'public-user', 'role': 'user'}).json()
    joined = public.post('/api/register', json={'code': invitation['code'], 'password': 'long-test-password'})
    assert joined.status_code == 200 and joined.json()['user']['agency_id'] == alice['user']['agency_id']
    assert public.delete('/api/session', headers=ah).status_code == 200
    assert public.get('/api/me', headers=ah).status_code == 401
    assert private.get('/api/me', headers=ah).status_code == 401


def test_public_recordings_preserve_ownership_agency_review_and_audit(setup):
    w, private, _, (_, oh), (_, ah), (_, bh) = setup
    public = public_client(w)
    _, _, other_admin = second_agency(private, oh)
    upload(public, ah)
    assert public.get('/api/recordings', headers=bh).json()['recordings'] == []
    assert public.get('/api/recordings/recording-1', headers=bh).status_code == 404
    assert public.get('/api/recordings/recording-1', headers=oh).status_code == 404
    assert public.get('/api/recordings/recording-1?review=true', headers=other_admin).status_code == 404
    assert public.get('/api/recordings/recording-1?review=true', headers=oh).status_code == 200
    assert public.get('/api/recordings/recording-1/parts/0', headers=ah).content == b'audio0'
    events = public.get('/api/admin/audit', headers=oh).json()['events']
    assert any(e['action'] == 'admin-content-reviewed' for e in events)


def test_public_listener_startup_leaves_active_jobs_and_private_worker_untouched(setup):
    w, private, provider, _, (_, ah), _ = setup
    upload(private, ah)
    assert private.post('/api/recordings/recording-1/process', headers=ah,
                        json=process_body(private, ah)).status_code == 200
    with w.db() as db:
        db.execute("UPDATE recordings SET state='processing' WHERE id='recording-1'")
        before = dict(db.execute("SELECT * FROM recordings WHERE id='recording-1'").fetchone())
    fresh = Workspace(w.config, w.cipher, provider, w.audio_preparer, recover_jobs=False)
    with public_client(fresh) as public:
        assert public.app.state.worker is None
        assert public.get('/api/health').status_code == 200
    with w.db() as db:
        assert dict(db.execute("SELECT * FROM recordings WHERE id='recording-1'").fetchone()) == before
    assert provider.calls == []


def test_public_uploads_still_feed_the_existing_private_processing_worker(setup):
    w, private, provider, _, (_, ah), _ = setup
    public = public_client(w)
    upload(public, ah)
    assert public.post('/api/recordings/recording-1/process', headers=ah,
                       json=process_body(public, ah)).status_code == 200
    assert asyncio.run(w.run_next()) is True
    assert public.get('/api/recordings/recording-1', headers=ah).json()['state'] == 'ready'
    assert private.get('/api/recordings/recording-1', headers=ah).json()['state'] == 'ready'
    assert len(provider.calls) == 2


def test_public_body_bounds_apply_to_declared_and_chunked_requests_without_echoing_secrets(setup):
    w, _, _, _, (_, ah), _ = setup
    public = public_client(w)
    assert public.post('/api/login', content=b'x' * 16385).status_code == 413
    assert public.post('/api/login', content=iter([b'x' * 8192, b'y' * 8193])).status_code == 413
    response = public.post('/api/register', json={'code': 'synthetic-code', 'password': 'tiny-secret'})
    assert response.status_code == 422 and 'tiny-secret' not in response.text and 'synthetic-code' not in response.text
    path = '/api/assistants/probe/knowledge/probe/content'
    assert public.put(path, headers={**ah, 'Content-Length': str(MAX_BYTES + 1)}, content=b'x').status_code == 413
    # The full existing 100 MB file limit is still accepted by the ingress bound;
    # a missing assistant is then rejected by the ordinary account-owned handler.
    assert public.put(path, headers={**ah, 'Content-Length': str(MAX_BYTES)}, content=b'x').status_code == 404


def test_public_login_keeps_username_rate_limits(setup):
    w, _, _, _, _, _ = setup
    public = public_client(w)
    for _ in range(10):
        assert public.post('/api/login', json={'username': 'no-such-user', 'password': 'wrong'}).status_code == 401
    assert public.post('/api/login', json={'username': 'no-such-user', 'password': 'wrong'}).status_code == 429
    assert public.post('/api/login', json={'username': 'alice', 'password': 'long-test-password'}).status_code == 200
