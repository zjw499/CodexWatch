from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

from fastapi.testclient import TestClient

from codex_watch_relay.app import create_app
from codex_watch_relay.codex_app_server import AbstractCodexBackend
from codex_watch_relay.config import Settings
from codex_watch_relay.folders import FolderCatalog
from codex_watch_relay.models import WatchOption, WatchQuestion, WatchQuestionnaire, WatchTurnState
from codex_watch_relay.storage import StateStore


class FakeBackend(AbstractCodexBackend):
    def __init__(self) -> None:
        self.online = True
        self.threads = {
            "thr_1": {
                "id": "thr_1",
                "name": "Bridge health",
                "preview": "Check the bridge status",
                "cwd": r"D:\Projects\Bridge",
                "updatedAt": 200,
                "createdAt": 100,
                "status": {"type": "idle"},
                "turns": [
                    {
                        "id": "turn_old",
                        "status": "completed",
                        "items": [
                            {"id": "m1", "type": "agentMessage", "text": "Bridge is healthy."},
                            {"id": "fc1", "type": "fileChange", "status": "completed", "changes": [{"path": "README.md", "kind": {"type": "update"}, "diff": "..."}]},
                            {"id": "cmd1", "type": "commandExecution", "status": "completed", "command": "pytest", "cwd": r"D:\Projects\Bridge", "commandActions": []},
                        ],
                    }
                ],
            }
        }
        self.turns: dict[str, WatchTurnState] = {}
        self.questionnaires: dict[str, WatchQuestionnaire] = {}

    def start(self) -> None:
        self.online = True

    def shutdown(self) -> None:
        self.online = False

    def is_online(self) -> bool:
        return self.online

    def list_threads(self, *, limit: int, search_term: str | None = None, cwd: str | None = None) -> list[dict]:
        threads = list(self.threads.values())
        if search_term:
            threads = [thread for thread in threads if search_term.lower() in thread["name"].lower()]
        if cwd:
            threads = [thread for thread in threads if thread.get("cwd") == cwd]
        return threads[:limit]

    def read_thread(self, thread_id: str) -> dict:
        return self.threads[thread_id]

    def start_thread(self, *, cwd: str | None) -> dict:
        thread = {
            "id": "thr_new",
            "name": "New thread",
            "preview": "Fresh prompt",
            "cwd": cwd,
            "updatedAt": 300,
            "createdAt": 300,
            "status": {"type": "idle"},
            "turns": [],
        }
        self.threads[thread["id"]] = thread
        return thread

    def start_turn(self, *, thread_id: str, prompt: str, cwd: str | None, plan_mode: bool) -> WatchTurnState:
        turn_id = f"turn_{len(self.turns) + 1}"
        state = WatchTurnState(
            turn_id=turn_id,
            thread_id=thread_id,
            status="question_waiting" if plan_mode else "running",
            snippet="Working on it",
            latest_message="Working on it",
            pending_questionnaire_id="rq_1" if plan_mode else None,
        )
        self.turns[turn_id] = state
        if plan_mode:
            self.questionnaires["rq_1"] = WatchQuestionnaire(
                request_id="rq_1",
                item_id="item_1",
                thread_id=thread_id,
                turn_id=turn_id,
                questions=[
                    WatchQuestion(
                        id="folder_mode",
                        header="Folder",
                        question="Which folder scope should I use?",
                        options=[WatchOption(label="Current repo", description="Stay in the selected folder.")],
                        supports_other_voice=True,
                    )
                ],
                created_at=datetime.now(timezone.utc),
            )
        return state

    def get_turn_state(self, turn_id: str) -> WatchTurnState | None:
        return self.turns.get(turn_id)

    def list_questionnaires(self, *, thread_id: str | None = None) -> list[WatchQuestionnaire]:
        items = list(self.questionnaires.values())
        if thread_id:
            items = [item for item in items if item.thread_id == thread_id]
        return items

    def answer_questionnaire(self, request_id: str, answers: dict[str, list[str]]) -> WatchTurnState | None:
        questionnaire = self.questionnaires[request_id]
        questionnaire.answered = True
        state = self.turns[questionnaire.turn_id]
        state.status = "running"
        state.pending_questionnaire_id = None
        return state


def build_app(tmp_path: Path) -> TestClient:
    root = tmp_path / "workspace"
    recent = root / "Bridge"
    favorite = root / "Favorite"
    nested = root / "Archive"
    recent.mkdir(parents=True)
    favorite.mkdir()
    nested.mkdir()

    settings = Settings(
        host="127.0.0.1",
        port=8790,
        relay_token=None,
        desktop_id="local-windows",
        desktop_name="Test PC",
        codex_binary="codex",
        codex_rpc_timeout_seconds=60,
        codex_startup_timeout_seconds=5,
        data_dir=tmp_path / "data",
        state_path=tmp_path / "data" / "watch_state.json",
        folder_index_path=tmp_path / "data" / "folder_index.json",
        allowed_roots=[root],
        folder_search_limit=25,
        folder_index_max_dirs=100,
    )
    state_store = StateStore(settings.state_path)
    state_store.add_favorite(str(favorite))
    backend = FakeBackend()
    folder_catalog = FolderCatalog(settings, state_store)
    app = create_app(settings=settings, backend=backend, state_store=state_store, folder_catalog=folder_catalog)
    return TestClient(app)


def test_desktops_and_threads_endpoint(tmp_path: Path) -> None:
    with build_app(tmp_path) as client:
        desktops = client.get("/v1/watch/desktops")
        assert desktops.status_code == 200
        assert desktops.json()[0]["id"] == "local-windows"

        threads = client.get("/v1/watch/desktops/local-windows/threads")
        assert threads.status_code == 200
        assert threads.json()["data"][0]["id"] == "thr_1"

        detail = client.get("/v1/watch/desktops/local-windows/threads/thr_1")
        assert detail.status_code == 200
        payload = detail.json()
        assert payload["latest_reply"] == "Bridge is healthy."
        assert payload["changed_files_count"] == 1
        assert payload["recent_tool_summary"] == "1 commands"


def test_create_thread_and_plan_mode_questionnaire_flow(tmp_path: Path) -> None:
    with build_app(tmp_path) as client:
        created = client.post(
            "/v1/watch/desktops/local-windows/threads",
            json={"cwd": r"D:\Projects\Foo", "plan_mode": True, "prompt": "Draft a plan"},
        )
        assert created.status_code == 200, created.text
        payload = created.json()
        assert payload["thread"]["id"] == "thr_new"
        assert payload["turn"]["status"] == "question_waiting"
        assert payload["turn"]["pending_questionnaire_id"] == "rq_1"

        questionnaires = client.get("/v1/watch/questionnaires")
        assert questionnaires.status_code == 200
        assert questionnaires.json()["data"][0]["request_id"] == "rq_1"

        answered = client.post(
            "/v1/watch/questionnaires/rq_1/answers",
            json={"answers": {"folder_mode": {"answers": ["Current repo"]}}},
        )
        assert answered.status_code == 200
        assert answered.json()["status"] == "running"


def test_folder_endpoints_and_inbox(tmp_path: Path) -> None:
    with build_app(tmp_path) as client:
        favorites = client.get("/v1/watch/desktops/local-windows/folders/favorites")
        assert favorites.status_code == 200
        assert favorites.json()["entries"][0]["is_pinned"] is True

        browse = client.get("/v1/watch/desktops/local-windows/folders/browse", params={"path": str(tmp_path / "workspace")})
        assert browse.status_code == 200
        names = [item["display_name"] for item in browse.json()["entries"]]
        assert "Bridge" in names

        search = client.get("/v1/watch/desktops/local-windows/folders/search", params={"q": "arch"})
        assert search.status_code == 200
        assert search.json()["entries"][0]["display_name"] == "Archive"

        inbox = client.get("/v1/watch/inbox")
        assert inbox.status_code == 200
        assert inbox.json()["data"] == []
