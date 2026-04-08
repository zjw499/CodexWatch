from __future__ import annotations

import json
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from threading import Lock

from .models import InboxNotification


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


@dataclass
class ThreadContext:
    cwd: str | None = None
    plan_mode: bool = False


class StateStore:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = Lock()
        self._state = self._load()

    def _load(self) -> dict:
        if not self.path.exists():
            return {
                "favorites": [],
                "thread_context": {},
                "notifications": [],
                "last_selected_desktop": None,
            }
        try:
            return json.loads(self.path.read_text(encoding="utf-8"))
        except Exception:
            return {
                "favorites": [],
                "thread_context": {},
                "notifications": [],
                "last_selected_desktop": None,
            }

    def _save(self) -> None:
        self.path.write_text(json.dumps(self._state, indent=2, ensure_ascii=True), encoding="utf-8")

    def get_favorites(self) -> list[str]:
        with self._lock:
            return list(self._state.get("favorites", []))

    def add_favorite(self, path: str) -> None:
        with self._lock:
            favorites = set(self._state.get("favorites", []))
            favorites.add(path)
            self._state["favorites"] = sorted(favorites)
            self._save()

    def remove_favorite(self, path: str) -> None:
        with self._lock:
            self._state["favorites"] = [value for value in self._state.get("favorites", []) if value != path]
            self._save()

    def get_thread_context(self, thread_id: str) -> ThreadContext:
        with self._lock:
            raw = self._state.get("thread_context", {}).get(thread_id, {})
        return ThreadContext(cwd=raw.get("cwd"), plan_mode=bool(raw.get("plan_mode", False)))

    def set_thread_context(self, thread_id: str, *, cwd: str | None, plan_mode: bool) -> None:
        with self._lock:
            thread_context = self._state.setdefault("thread_context", {})
            thread_context[thread_id] = {"cwd": cwd, "plan_mode": plan_mode}
            self._save()

    def add_notification(
        self,
        *,
        notification_type: str,
        desktop_id: str,
        thread_id: str,
        summary: str,
        status: str,
        turn_id: str | None = None,
    ) -> InboxNotification:
        notification = InboxNotification(
            id=str(uuid.uuid4()),
            type=notification_type,
            desktop_id=desktop_id,
            thread_id=thread_id,
            turn_id=turn_id,
            summary=summary,
            status=status,
            deep_link=f"codexwatch://thread/{thread_id}?desktop={desktop_id}",
            created_at=now_utc(),
            read=False,
        )
        with self._lock:
            notifications = self._state.setdefault("notifications", [])
            notifications.insert(0, notification.model_dump(mode="json"))
            self._state["notifications"] = notifications[:100]
            self._save()
        return notification

    def list_notifications(self, unread_only: bool = False) -> list[InboxNotification]:
        with self._lock:
            raw_notifications = list(self._state.get("notifications", []))
        notifications = [InboxNotification.model_validate(item) for item in raw_notifications]
        if unread_only:
            notifications = [item for item in notifications if not item.read]
        return notifications

    def mark_notification_read(self, notification_id: str) -> InboxNotification | None:
        with self._lock:
            for item in self._state.get("notifications", []):
                if item.get("id") == notification_id:
                    item["read"] = True
                    self._save()
                    return InboxNotification.model_validate(item)
        return None

    def unread_thread_ids(self) -> set[str]:
        return {item.thread_id for item in self.list_notifications(unread_only=True) if item.type == "reply_ready"}
