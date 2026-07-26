from __future__ import annotations

import json
import subprocess
import threading
from abc import ABC, abstractmethod
from dataclasses import dataclass
from queue import Empty, Queue
from typing import Any

from . import __version__
from .config import Settings
from .models import WatchOption, WatchQuestion, WatchQuestionnaire, WatchTurnState
from .storage import StateStore, now_utc


class CodexBackendError(RuntimeError):
    pass


class AbstractCodexBackend(ABC):
    @abstractmethod
    def start(self) -> None: ...

    @abstractmethod
    def shutdown(self) -> None: ...

    @abstractmethod
    def is_online(self) -> bool: ...

    @abstractmethod
    def list_threads(self, *, limit: int, search_term: str | None = None, cwd: str | None = None) -> list[dict[str, Any]]: ...

    @abstractmethod
    def read_thread(self, thread_id: str) -> dict[str, Any]: ...

    @abstractmethod
    def start_thread(self, *, cwd: str | None) -> dict[str, Any]: ...

    @abstractmethod
    def start_turn(self, *, thread_id: str, prompt: str, cwd: str | None, plan_mode: bool) -> WatchTurnState: ...

    @abstractmethod
    def get_turn_state(self, turn_id: str) -> WatchTurnState | None: ...

    @abstractmethod
    def list_questionnaires(self, *, thread_id: str | None = None) -> list[WatchQuestionnaire]: ...

    @abstractmethod
    def answer_questionnaire(self, request_id: str, answers: dict[str, list[str]]) -> WatchTurnState | None: ...


@dataclass
class PendingQuestion:
    rpc_id: str | int
    questionnaire: WatchQuestionnaire


class JsonRpcProcessClient:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self._process: subprocess.Popen[str] | None = None
        self._reader_thread: threading.Thread | None = None
        self._response_queues: dict[str, Queue[dict[str, Any]]] = {}
        self._events: Queue[dict[str, Any]] = Queue()
        self._write_lock = threading.Lock()
        self._state_lock = threading.Lock()
        self._request_id = 0

    def start(self) -> None:
        with self._state_lock:
            if self._process is not None:
                return
            self._process = subprocess.Popen(
                [self.settings.codex_binary, "app-server"],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1,
            )
            self._reader_thread = threading.Thread(target=self._reader_loop, daemon=True, name="codex-watch-rpc-reader")
            self._reader_thread.start()

    def stop(self) -> None:
        with self._state_lock:
            process = self._process
            self._process = None
        if process is not None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()

    def request(self, method: str, params: dict[str, Any], timeout: float | None = None) -> dict[str, Any]:
        request_id = self._next_request_id()
        queue: Queue[dict[str, Any]] = Queue()
        self._response_queues[str(request_id)] = queue
        self._send({"id": request_id, "method": method, "params": params})
        timeout = timeout or self.settings.codex_rpc_timeout_seconds
        try:
            message = queue.get(timeout=timeout)
        except Empty as exc:
            self._response_queues.pop(str(request_id), None)
            raise CodexBackendError(f"Timed out waiting for {method}") from exc

        if "error" in message:
            error = message["error"]
            raise CodexBackendError(f"{method} failed: {error.get('message', error)}")
        return message["result"]

    def notify(self, method: str, params: dict[str, Any]) -> None:
        self._send({"method": method, "params": params})

    def respond(self, request_id: str | int, result: dict[str, Any]) -> None:
        self._send({"id": request_id, "result": result})

    def next_event(self, timeout: float = 0.25) -> dict[str, Any] | None:
        try:
            return self._events.get(timeout=timeout)
        except Empty:
            return None

    def _reader_loop(self) -> None:
        process = self._process
        if process is None or process.stdout is None:
            return
        for line in process.stdout:
            raw = line.strip()
            if not raw:
                continue
            try:
                message = json.loads(raw)
            except json.JSONDecodeError:
                continue

            if "id" in message and "method" not in message:
                queue = self._response_queues.pop(str(message["id"]), None)
                if queue is not None:
                    queue.put(message)
                continue

            self._events.put(message)

    def _send(self, message: dict[str, Any]) -> None:
        self.start()
        process = self._process
        if process is None or process.stdin is None:
            raise CodexBackendError("codex app-server process is not available")
        encoded = json.dumps(message, ensure_ascii=True)
        with self._write_lock:
            process.stdin.write(encoded + "\n")
            process.stdin.flush()

    def _next_request_id(self) -> int:
        with self._state_lock:
            self._request_id += 1
            return self._request_id


class CodexAppServerBackend(AbstractCodexBackend):
    def __init__(self, settings: Settings, state_store: StateStore, client: JsonRpcProcessClient | None = None) -> None:
        self.settings = settings
        self.state_store = state_store
        self.client = client or JsonRpcProcessClient(settings)
        self._started = False
        self._start_lock = threading.Lock()
        self._stop_event = threading.Event()
        self._event_thread: threading.Thread | None = None
        self._turn_states: dict[str, WatchTurnState] = {}
        self._pending_questionnaires: dict[str, PendingQuestion] = {}
        self._online = False
        self._plan_mask: dict[str, Any] | None = None

    def start(self) -> None:
        with self._start_lock:
            if self._started:
                return
            self.client.start()
            self.client.request(
                "initialize",
                {
                    "clientInfo": {
                        "name": "codex_watch_relay",
                        "title": "Scribe Pilot Relay",
                        "version": __version__,
                    },
                    "capabilities": {"experimentalApi": True},
                },
                timeout=self.settings.codex_startup_timeout_seconds,
            )
            self.client.notify("initialized", {})
            self._stop_event.clear()
            self._event_thread = threading.Thread(target=self._event_loop, daemon=True, name="codex-watch-events")
            self._event_thread.start()
            self._started = True
            self._online = True

    def shutdown(self) -> None:
        self._stop_event.set()
        self.client.stop()

    def is_online(self) -> bool:
        return self._online

    def list_threads(self, *, limit: int, search_term: str | None = None, cwd: str | None = None) -> list[dict[str, Any]]:
        self.start()
        params: dict[str, Any] = {"limit": limit, "sortKey": "updated_at"}
        if search_term:
            params["searchTerm"] = search_term
        if cwd:
            params["cwd"] = cwd
        return self.client.request("thread/list", params).get("data", [])

    def read_thread(self, thread_id: str) -> dict[str, Any]:
        self.start()
        return self.client.request("thread/read", {"threadId": thread_id, "includeTurns": True}).get("thread", {})

    def start_thread(self, *, cwd: str | None) -> dict[str, Any]:
        self.start()
        params: dict[str, Any] = {}
        if cwd:
            params["cwd"] = cwd
        result = self.client.request("thread/start", params)
        return result.get("thread", {})

    def start_turn(self, *, thread_id: str, prompt: str, cwd: str | None, plan_mode: bool) -> WatchTurnState:
        self.start()
        params: dict[str, Any] = {
            "threadId": thread_id,
            "input": [{"type": "text", "text": prompt}],
        }
        if cwd:
            params["cwd"] = cwd
        if plan_mode:
            params["collaborationMode"] = self._build_plan_collaboration_mode()

        result = self.client.request("turn/start", params)
        turn = result.get("turn", {})
        turn_id = turn.get("id")
        if not turn_id:
            raise CodexBackendError("turn/start did not return a turn id")

        turn_state = WatchTurnState(
            turn_id=turn_id,
            thread_id=thread_id,
            status=self._normalize_turn_status(turn.get("status", "inProgress")),
            snippet=None,
            latest_message=None,
            pending_questionnaire_id=None,
            error_message=None,
        )
        self._turn_states[turn_id] = turn_state
        return turn_state

    def get_turn_state(self, turn_id: str) -> WatchTurnState | None:
        return self._turn_states.get(turn_id)

    def list_questionnaires(self, *, thread_id: str | None = None) -> list[WatchQuestionnaire]:
        questionnaires = [pending.questionnaire for pending in self._pending_questionnaires.values() if not pending.questionnaire.answered]
        if thread_id:
            questionnaires = [item for item in questionnaires if item.thread_id == thread_id]
        questionnaires.sort(key=lambda item: item.created_at, reverse=True)
        return questionnaires

    def answer_questionnaire(self, request_id: str, answers: dict[str, list[str]]) -> WatchTurnState | None:
        pending = self._pending_questionnaires.get(request_id)
        if pending is None:
            raise CodexBackendError(f"Unknown questionnaire request id: {request_id}")

        payload = {"answers": {key: {"answers": value} for key, value in answers.items()}}
        self.client.respond(pending.rpc_id, payload)
        pending.questionnaire.answered = True

        turn_state = self._turn_states.get(pending.questionnaire.turn_id)
        if turn_state is not None:
            turn_state.status = "running"
            turn_state.pending_questionnaire_id = None
        return turn_state

    def _build_plan_collaboration_mode(self) -> dict[str, Any]:
        if self._plan_mask is None:
            data = self.client.request("collaborationMode/list", {}).get("data", [])
            self._plan_mask = next((item for item in data if item.get("mode") == "plan"), None) or {"mode": "plan", "model": "gpt-5.4"}
        return {
            "mode": "plan",
            "settings": {
                "model": self._plan_mask.get("model") or "gpt-5.4",
                "reasoning_effort": self._plan_mask.get("reasoning_effort"),
                "developer_instructions": None,
            },
        }

    def _event_loop(self) -> None:
        while not self._stop_event.is_set():
            message = self.client.next_event(timeout=0.25)
            if message is None:
                continue
            try:
                self._handle_message(message)
                self._online = True
            except Exception:
                self._online = False

    def _handle_message(self, message: dict[str, Any]) -> None:
        if "id" in message and "method" in message:
            if message["method"] == "tool/requestUserInput":
                self._handle_request_user_input(message)
            return

        method = message.get("method")
        params = message.get("params", {})
        if method == "item/agentMessage/delta":
            self._handle_agent_message_delta(params)
        elif method == "turn/completed":
            self._handle_turn_completed(params)
        elif method == "thread/status/changed":
            self._handle_thread_status(params)

    def _handle_request_user_input(self, message: dict[str, Any]) -> None:
        params = message.get("params", {})
        questions = []
        for item in params.get("questions", []):
            options = [
                WatchOption(label=option["label"], description=option["description"])
                for option in item.get("options", []) or []
            ]
            questions.append(
                WatchQuestion(
                    id=item["id"],
                    header=item["header"],
                    question=item["question"],
                    options=options,
                    supports_other_voice=bool(item.get("isOther", False)),
                )
            )

        questionnaire = WatchQuestionnaire(
            request_id=str(message["id"]),
            item_id=params["itemId"],
            thread_id=params["threadId"],
            turn_id=params["turnId"],
            questions=questions,
            created_at=now_utc(),
            answered=False,
        )
        self._pending_questionnaires[questionnaire.request_id] = PendingQuestion(rpc_id=message["id"], questionnaire=questionnaire)

        turn_state = self._turn_states.get(questionnaire.turn_id)
        if turn_state is not None:
            turn_state.status = "question_waiting"
            turn_state.pending_questionnaire_id = questionnaire.request_id

        self.state_store.add_notification(
            notification_type="question_waiting",
            desktop_id=self.settings.desktop_id,
            thread_id=questionnaire.thread_id,
            turn_id=questionnaire.turn_id,
            summary=questions[0].question if questions else "Codex needs more input.",
            status="waitingOnUserInput",
        )

    def _handle_agent_message_delta(self, params: dict[str, Any]) -> None:
        turn_id = params.get("turnId")
        if not turn_id:
            return
        state = self._turn_states.get(turn_id)
        if state is None:
            state = WatchTurnState(turn_id=turn_id, thread_id=params.get("threadId", ""), status="running")
            self._turn_states[turn_id] = state
        delta = params.get("delta") or ""
        combined = (state.latest_message or "") + delta
        state.latest_message = combined[-4000:]
        state.snippet = combined.strip()[-240:] or state.snippet
        if state.status not in {"completed", "failed", "interrupted", "question_waiting"}:
            state.status = "running"

    def _handle_turn_completed(self, params: dict[str, Any]) -> None:
        thread_id = params.get("threadId", "")
        turn = params.get("turn", {})
        turn_id = turn.get("id")
        if not turn_id:
            return
        state = self._turn_states.get(turn_id) or WatchTurnState(turn_id=turn_id, thread_id=thread_id, status="completed")
        state.status = self._normalize_turn_status(turn.get("status", "completed"))
        error = turn.get("error") or {}
        state.error_message = error.get("message")
        self._turn_states[turn_id] = state

        if state.status == "completed":
            self.state_store.add_notification(
                notification_type="reply_ready",
                desktop_id=self.settings.desktop_id,
                thread_id=thread_id,
                turn_id=turn_id,
                summary=state.snippet or "Codex replied.",
                status="completed",
            )

    def _handle_thread_status(self, params: dict[str, Any]) -> None:
        status = params.get("status", {})
        thread_id = params.get("threadId", "")
        if status.get("type") != "active":
            return
        active_flags = set(status.get("activeFlags", []))
        if "waitingOnUserInput" not in active_flags:
            for state in self._turn_states.values():
                if state.thread_id == thread_id and state.status == "question_waiting":
                    state.status = "running"

    @staticmethod
    def _normalize_turn_status(status: str) -> str:
        return {
            "inProgress": "running",
            "completed": "completed",
            "failed": "failed",
            "interrupted": "interrupted",
        }.get(status, status)
