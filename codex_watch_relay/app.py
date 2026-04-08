from __future__ import annotations

from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, HTTPException, Query, Request, status

from . import __version__
from .codex_app_server import AbstractCodexBackend, CodexAppServerBackend, CodexBackendError
from .config import Settings
from .folders import FolderCatalog
from .models import (
    DesktopTarget,
    FavoriteFolderRequest,
    FolderListResponse,
    HealthResponse,
    InboxListResponse,
    QuestionnaireAnswerRequest,
    QuestionnaireListResponse,
    ThreadCreateRequest,
    ThreadListResponse,
    ThreadStartEnvelope,
    TurnSubmissionRequest,
    WatchThreadDetail,
    WatchThreadSummary,
)
from .storage import StateStore


def _status_to_string(raw_status: dict | str | None) -> str:
    if isinstance(raw_status, str):
        return raw_status
    if isinstance(raw_status, dict):
        status_type = raw_status.get("type")
        if status_type == "active":
            flags = raw_status.get("activeFlags") or []
            if "waitingOnUserInput" in flags:
                return "question_waiting"
            if "waitingOnApproval" in flags:
                return "waiting_on_approval"
            return "running"
        return status_type or "unknown"
    return "unknown"


def _last_agent_message(thread: dict) -> str | None:
    latest: str | None = None
    for turn in thread.get("turns", []):
        for item in turn.get("items", []):
            if item.get("type") == "agentMessage":
                latest = item.get("text") or latest
    return latest


def _changed_files_count(thread: dict) -> int:
    total = 0
    for turn in thread.get("turns", []):
        for item in turn.get("items", []):
            if item.get("type") == "fileChange":
                total += len(item.get("changes", []))
    return total


def _recent_tool_summary(thread: dict) -> str | None:
    command_count = 0
    tool_count = 0
    for turn in thread.get("turns", []):
        for item in turn.get("items", []):
            if item.get("type") == "commandExecution":
                command_count += 1
            if item.get("type") in {"mcpToolCall", "dynamicToolCall"}:
                tool_count += 1
    if command_count == 0 and tool_count == 0:
        return None
    parts: list[str] = []
    if command_count:
        parts.append(f"{command_count} commands")
    if tool_count:
        parts.append(f"{tool_count} tool calls")
    return ", ".join(parts)


def _build_summary(thread: dict, state_store: StateStore) -> WatchThreadSummary:
    thread_id = thread["id"]
    context = state_store.get_thread_context(thread_id)
    name = thread.get("name") or thread.get("preview") or "Untitled thread"
    return WatchThreadSummary(
        id=thread_id,
        name=name,
        preview=thread.get("preview") or "",
        cwd=thread.get("cwd") or context.cwd,
        updated_at=int(thread.get("updatedAt", thread.get("createdAt", 0))),
        status=_status_to_string(thread.get("status")),
        unread_reply=thread_id in state_store.unread_thread_ids(),
        plan_mode_enabled=context.plan_mode,
    )


def _build_detail(thread: dict, state_store: StateStore) -> WatchThreadDetail:
    summary = _build_summary(thread, state_store)
    return WatchThreadDetail(
        **summary.model_dump(),
        latest_reply=_last_agent_message(thread),
        latest_snippet=_last_agent_message(thread),
        changed_files_count=_changed_files_count(thread),
        recent_tool_summary=_recent_tool_summary(thread),
    )


def _assert_desktop_id(desktop_id: str, settings: Settings) -> None:
    if desktop_id != settings.desktop_id:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"Unknown desktop: {desktop_id}")


def create_app(
    settings: Settings | None = None,
    backend: AbstractCodexBackend | None = None,
    state_store: StateStore | None = None,
    folder_catalog: FolderCatalog | None = None,
) -> FastAPI:
    settings = settings or Settings.from_env()
    state_store = state_store or StateStore(settings.state_path)
    backend = backend or CodexAppServerBackend(settings=settings, state_store=state_store)
    folder_catalog = folder_catalog or FolderCatalog(settings=settings, state_store=state_store)

    @asynccontextmanager
    async def lifespan(_app: FastAPI):
        try:
            backend.start()
        except Exception:
            pass
        try:
            yield
        finally:
            backend.shutdown()

    app = FastAPI(title="Codex Watch Relay", version=__version__, lifespan=lifespan)
    app.state.settings = settings
    app.state.backend = backend
    app.state.state_store = state_store
    app.state.folder_catalog = folder_catalog

    def require_token(request: Request) -> None:
        token = request.app.state.settings.relay_token
        if not token:
            return
        auth = request.headers.get("Authorization", "")
        if auth != f"Bearer {token}":
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing or invalid relay token")

    @app.get("/health", response_model=HealthResponse)
    def health() -> HealthResponse:
        return HealthResponse(ok=True, service="codex-watch-relay", desktop_online=backend.is_online(), version=__version__)

    @app.get("/v1/watch/desktops", response_model=list[DesktopTarget], dependencies=[Depends(require_token)])
    def list_desktops() -> list[DesktopTarget]:
        return [
            DesktopTarget(
                id=settings.desktop_id,
                name=settings.desktop_name,
                platform="windows",
                online=backend.is_online(),
                has_d_drive=folder_catalog.has_d_drive(),
                relay_state="ready" if backend.is_online() else "offline",
            )
        ]

    @app.get("/v1/watch/desktops/{desktop_id}/threads", response_model=ThreadListResponse, dependencies=[Depends(require_token)])
    def list_threads(
        desktop_id: str,
        limit: int = Query(default=20, ge=1, le=100),
        search: str | None = None,
        cwd: str | None = None,
    ) -> ThreadListResponse:
        _assert_desktop_id(desktop_id, settings)
        try:
            data = backend.list_threads(limit=limit, search_term=search, cwd=cwd)
        except CodexBackendError as exc:
            raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(exc)) from exc
        return ThreadListResponse(data=[_build_summary(thread, state_store) for thread in data])

    @app.get("/v1/watch/desktops/{desktop_id}/threads/{thread_id}", response_model=WatchThreadDetail, dependencies=[Depends(require_token)])
    def read_thread(desktop_id: str, thread_id: str) -> WatchThreadDetail:
        _assert_desktop_id(desktop_id, settings)
        try:
            thread = backend.read_thread(thread_id)
        except CodexBackendError as exc:
            raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(exc)) from exc
        if not thread:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Thread not found")
        return _build_detail(thread, state_store)

    @app.post("/v1/watch/desktops/{desktop_id}/threads", response_model=ThreadStartEnvelope, dependencies=[Depends(require_token)])
    def create_thread(desktop_id: str, body: ThreadCreateRequest) -> ThreadStartEnvelope:
        _assert_desktop_id(desktop_id, settings)
        try:
            thread = backend.start_thread(cwd=body.cwd)
        except CodexBackendError as exc:
            raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(exc)) from exc
        summary = _build_summary(thread, state_store)
        state_store.set_thread_context(summary.id, cwd=body.cwd or summary.cwd, plan_mode=body.plan_mode)
        turn = None
        if body.prompt:
            turn = backend.start_turn(thread_id=summary.id, prompt=body.prompt, cwd=body.cwd or summary.cwd, plan_mode=body.plan_mode)
        return ThreadStartEnvelope(thread=summary, turn=turn)

    @app.post("/v1/watch/desktops/{desktop_id}/threads/{thread_id}/turns", response_model=dict, dependencies=[Depends(require_token)])
    def submit_turn(desktop_id: str, thread_id: str, body: TurnSubmissionRequest) -> dict:
        _assert_desktop_id(desktop_id, settings)
        try:
            turn = backend.start_turn(thread_id=thread_id, prompt=body.prompt, cwd=body.cwd, plan_mode=body.plan_mode)
        except CodexBackendError as exc:
            raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(exc)) from exc
        state_store.set_thread_context(thread_id, cwd=body.cwd, plan_mode=body.plan_mode)
        return turn.model_dump()

    @app.get("/v1/watch/turns/{turn_id}", response_model=dict, dependencies=[Depends(require_token)])
    def get_turn(turn_id: str) -> dict:
        turn = backend.get_turn_state(turn_id)
        if turn is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Turn not found")
        return turn.model_dump()

    @app.get("/v1/watch/questionnaires", response_model=QuestionnaireListResponse, dependencies=[Depends(require_token)])
    def list_questionnaires(thread_id: str | None = None) -> QuestionnaireListResponse:
        return QuestionnaireListResponse(data=backend.list_questionnaires(thread_id=thread_id))

    @app.post("/v1/watch/questionnaires/{request_id}/answers", response_model=dict, dependencies=[Depends(require_token)])
    def answer_questionnaire(request_id: str, body: QuestionnaireAnswerRequest) -> dict:
        try:
            turn = backend.answer_questionnaire(
                request_id,
                answers={key: value.answers for key, value in body.answers.items()},
            )
        except CodexBackendError as exc:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc)) from exc
        if turn is None:
            return {"ok": True}
        return turn.model_dump()

    @app.get("/v1/watch/desktops/{desktop_id}/folders/recents", response_model=FolderListResponse, dependencies=[Depends(require_token)])
    def list_recent_folders(desktop_id: str, limit: int = Query(default=12, ge=1, le=50)) -> FolderListResponse:
        _assert_desktop_id(desktop_id, settings)
        raw_threads = backend.list_threads(limit=max(limit * 3, 20))
        threads = [_build_summary(thread, state_store) for thread in raw_threads]
        return FolderListResponse(entries=folder_catalog.recent_nodes(threads, limit=limit))

    @app.get("/v1/watch/desktops/{desktop_id}/folders/favorites", response_model=FolderListResponse, dependencies=[Depends(require_token)])
    def list_favorites(desktop_id: str) -> FolderListResponse:
        _assert_desktop_id(desktop_id, settings)
        return FolderListResponse(entries=folder_catalog.favorite_nodes())

    @app.post("/v1/watch/desktops/{desktop_id}/folders/favorites", response_model=FolderListResponse, dependencies=[Depends(require_token)])
    def add_favorite(desktop_id: str, body: FavoriteFolderRequest) -> FolderListResponse:
        _assert_desktop_id(desktop_id, settings)
        state_store.add_favorite(body.path)
        return FolderListResponse(entries=folder_catalog.favorite_nodes())

    @app.delete("/v1/watch/desktops/{desktop_id}/folders/favorites", response_model=FolderListResponse, dependencies=[Depends(require_token)])
    def remove_favorite(desktop_id: str, path: str = Query(...)) -> FolderListResponse:
        _assert_desktop_id(desktop_id, settings)
        state_store.remove_favorite(path)
        return FolderListResponse(entries=folder_catalog.favorite_nodes())

    @app.get("/v1/watch/desktops/{desktop_id}/folders/browse", response_model=FolderListResponse, dependencies=[Depends(require_token)])
    def browse_folders(desktop_id: str, path: str | None = None) -> FolderListResponse:
        _assert_desktop_id(desktop_id, settings)
        try:
            entries = folder_catalog.list_children(path)
        except ValueError as exc:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
        return FolderListResponse(entries=entries)

    @app.get("/v1/watch/desktops/{desktop_id}/folders/search", response_model=FolderListResponse, dependencies=[Depends(require_token)])
    def search_folders(desktop_id: str, q: str = Query(..., min_length=1), limit: int = Query(default=25, ge=1, le=100)) -> FolderListResponse:
        _assert_desktop_id(desktop_id, settings)
        return FolderListResponse(entries=folder_catalog.search(q, limit=limit))

    @app.get("/v1/watch/inbox", response_model=InboxListResponse, dependencies=[Depends(require_token)])
    def list_inbox(unread_only: bool = False) -> InboxListResponse:
        return InboxListResponse(data=state_store.list_notifications(unread_only=unread_only))

    @app.post("/v1/watch/inbox/{notification_id}/read", response_model=dict, dependencies=[Depends(require_token)])
    def mark_inbox_read(notification_id: str) -> dict:
        notification = state_store.mark_notification_read(notification_id)
        if notification is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Notification not found")
        return notification.model_dump(mode="json")

    return app


app = create_app()
