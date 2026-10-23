"""Internet entry point for the native app, using the existing account boundary."""
from __future__ import annotations

from fastapi import HTTPException
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.routing import Match

from .knowledge import MAX_BYTES, UPLOAD_CHUNK_BYTES
from .workspace import create_app


PUBLIC_APP_URL = "https://zwyattpc.tail488e93.ts.net:8443/app"
ENABLE_FILE = "public-app.enabled"
ANONYMOUS = frozenset({"/api/health", "/api/login", "/api/register", "/api/disclosure",
                       "/privacy", "/support", "/account-deletion"})
# Deliberate native-app surface. New private endpoints require an explicit decision
# before they become internet-accessible; no filesystem or legacy receiver routes.
ACCOUNT_ROUTES = frozenset({
    "/api/session", "/api/me", "/api/account/consent", "/api/account/deletion",
    "/api/operator/agencies", "/api/operator/agencies/{agency_id}/invitations",
    "/api/admin/users", "/api/admin/invitations", "/api/admin/users/{user_id}/sessions",
    "/api/admin/users/{user_id}/disable", "/api/admin/policy", "/api/admin/audit",
    "/api/assistants", "/api/assistants/{assistant_id}",
    "/api/assistants/{assistant_id}/knowledge", "/api/assistants/{assistant_id}/knowledge/{file_id}",
    "/api/assistants/{assistant_id}/knowledge/{file_id}/chunks/{index}",
    "/api/assistants/{assistant_id}/knowledge/{file_id}/complete",
    "/api/assistants/{assistant_id}/knowledge/{file_id}/content",
    "/api/recordings", "/api/recordings/{record_id}", "/api/recordings/{record_id}/parts/{index}",
    "/api/recordings/{record_id}/process", "/api/recordings/{record_id}/chat", "/api/admin/recordings",
    "/api/voice/config", "/api/voice/preferences", "/api/voice/devices", "/api/voice/devices/{device_id}",
    "/api/voice/conversations", "/api/voice/conversations/{conversation_id}",
    "/api/voice/diagnostics", "/api/voice/diagnostics/{report_id}",
    "/api/admin/voice/conversations", "/api/admin/voice/conversations/{conversation_id}",
    "/api/admin/voice/diagnostics", "/api/admin/voice/diagnostics/{report_id}", "/api/admin/voice/policy",
})
HEADERS = {"Cache-Control": "no-store", "X-Content-Type-Options": "nosniff",
           "X-Frame-Options": "DENY", "Referrer-Policy": "no-referrer",
           "Strict-Transport-Security": "max-age=31536000"}


def enabled(workspace):
    try:
        return (workspace.config.root / ENABLE_FILE).read_text(encoding="utf-8-sig").strip() == "enabled"
    except OSError:
        return False


class PublicAppGuard:
    def __init__(self, app, workspace, routes):
        self.app, self.workspace, self.routes = app, workspace, routes

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)

        async def protected_send(message):
            if message["type"] == "http.response.start":
                headers = [(k, v) for k, v in message.get("headers", [])
                           if k.lower() not in {x.lower().encode() for x in HEADERS}]
                message = {**message, "headers": headers + [(k.encode(), v.encode()) for k, v in HEADERS.items()]}
            await send(message)

        async def reject(code, text):
            await JSONResponse({"detail": text}, status_code=code)(scope, receive, protected_send)

        if not enabled(self.workspace):
            return await reject(503, "Internet access is temporarily unavailable")
        if len(scope.get("path", "")) + len(scope.get("query_string", b"")) > 4096:
            return await reject(414, "Request address is too long")
        route = next((r for r in self.routes if r.matches(scope)[0] == Match.FULL), None)
        if route is None:
            return await reject(404, "Not found")
        headers = dict(scope.get("headers", []))
        if route.path not in ANONYMOUS:
            authorization = headers.get(b"authorization", b"")
            if not authorization.lower().startswith(b"bearer ") or not authorization[7:].strip():
                return await reject(401, "Sign in required")
        limit = 16 * 1024 * 1024  # Bounded transcript imports, including multibyte text.
        if route.path in {"/api/login", "/api/register"}:
            limit = 16384
        elif route.path == "/api/recordings/{record_id}/parts/{index}":
            limit = 24 * 1024 * 1024
        elif route.path.endswith("/knowledge/{file_id}/content"):
            limit = MAX_BYTES
        elif route.path.endswith("/knowledge/{file_id}/chunks/{index}"):
            limit = UPLOAD_CHUNK_BYTES
        lengths = [v for k, v in scope.get("headers", []) if k.lower() == b"content-length"]
        if lengths:
            try:
                if len(lengths) != 1 or int(lengths[0]) < 0:
                    return await reject(400, "Invalid request length")
                if int(lengths[0]) > limit:
                    return await reject(413, "Request is too large")
            except ValueError:
                return await reject(400, "Invalid request length")
        received = 0

        async def bounded_receive():
            nonlocal received
            message = await receive()
            if message["type"] == "http.request":
                received += len(message.get("body", b""))
                if received > limit:
                    raise HTTPException(413, "Request is too large")
            return message

        media = route.path == "/api/recordings/{record_id}/parts/{index}" or route.path.endswith(
            ("/knowledge/{file_id}/content", "/knowledge/{file_id}/chunks/{index}"))
        if not media and scope["method"] in {"POST", "PUT", "PATCH", "DELETE"}:
            # FastAPI can translate a receive exception during JSON parsing into
            # a generic 400. Bound these small bodies before invoking its parser.
            chunks = []
            try:
                while True:
                    message = await bounded_receive()
                    if message["type"] == "http.disconnect":
                        return
                    chunks.append(message.get("body", b""))
                    if not message.get("more_body", False):
                        break
            except HTTPException:
                return await reject(413, "Request is too large")
            body = b"".join(chunks)
            delivered = False

            async def replay():
                nonlocal delivered
                if not delivered:
                    delivered = True
                    return {"type": "http.request", "body": body, "more_body": False}
                return await receive()

            return await self.app(scope, replay, protected_send)
        await self.app(scope, bounded_receive, protected_send)


def create_public_app(workspace):
    # The private workspace remains the sole transcription worker. Opening or
    # restarting this listener must not recover/reset jobs or launch another worker.
    workspace.config.public_base_url = PUBLIC_APP_URL
    app = create_app(workspace, run_worker=False)
    app.router.routes = [r for r in app.routes if r.path in ANONYMOUS | ACCOUNT_ROUTES]
    app.add_middleware(PublicAppGuard, workspace=workspace, routes=tuple(app.routes))

    @app.exception_handler(RequestValidationError)
    async def invalid_request(request, error):
        # Validation responses must not echo passwords, invitation codes or content.
        return JSONResponse({"detail": "Check the request fields"}, status_code=422)

    return app
