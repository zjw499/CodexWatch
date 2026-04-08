from __future__ import annotations

import json
import os
from pathlib import Path
from threading import Lock

from .config import Settings
from .models import WatchThreadSummary, WorkingFolderNode
from .storage import StateStore


class FolderCatalog:
    def __init__(self, settings: Settings, state_store: StateStore) -> None:
        self.settings = settings
        self.state_store = state_store
        self._lock = Lock()
        self._index: list[str] | None = None

    def has_d_drive(self) -> bool:
        return any(root.drive.upper() == "D:" for root in self.settings.allowed_roots if root.exists())

    def is_allowed(self, path: Path) -> bool:
        normalized = path.resolve(strict=False)
        for root in self.settings.allowed_roots:
            try:
                normalized.relative_to(root.resolve(strict=False))
                return True
            except ValueError:
                continue
        return False

    def list_children(self, path: str | None = None) -> list[WorkingFolderNode]:
        target = Path(path) if path else self.settings.allowed_roots[0]
        if not self.is_allowed(target):
            raise ValueError(f"Path is outside allowed roots: {target}")
        if not target.exists() or not target.is_dir():
            raise ValueError(f"Path is not a directory: {target}")

        favorites = set(self.state_store.get_favorites())
        entries: list[WorkingFolderNode] = []
        with os.scandir(target) as it:
            for entry in it:
                if not entry.is_dir():
                    continue
                full_path = Path(entry.path)
                if not self.is_allowed(full_path):
                    continue
                entries.append(self._to_node(full_path, is_recent=False, is_pinned=str(full_path) in favorites))
        entries.sort(key=lambda item: item.display_name.lower())
        return entries

    def recent_nodes(self, threads: list[WatchThreadSummary], limit: int = 12) -> list[WorkingFolderNode]:
        favorites = set(self.state_store.get_favorites())
        seen: set[str] = set()
        entries: list[WorkingFolderNode] = []
        for thread in sorted(threads, key=lambda item: item.updated_at, reverse=True):
            if not thread.cwd:
                continue
            path = Path(thread.cwd)
            if str(path) in seen or not path.exists() or not path.is_dir() or not self.is_allowed(path):
                continue
            seen.add(str(path))
            entries.append(self._to_node(path, is_recent=True, is_pinned=str(path) in favorites))
            if len(entries) >= limit:
                break
        return entries

    def favorite_nodes(self) -> list[WorkingFolderNode]:
        entries: list[WorkingFolderNode] = []
        for raw_path in self.state_store.get_favorites():
            path = Path(raw_path)
            if not path.exists() or not path.is_dir() or not self.is_allowed(path):
                continue
            entries.append(self._to_node(path, is_recent=False, is_pinned=True))
        return entries

    def search(self, query: str, limit: int | None = None) -> list[WorkingFolderNode]:
        normalized_query = query.strip().lower()
        if not normalized_query:
            return []
        limit = limit or self.settings.folder_search_limit
        index = self._ensure_index()
        favorites = set(self.state_store.get_favorites())
        matches: list[WorkingFolderNode] = []
        for raw_path in index:
            if normalized_query not in raw_path.lower():
                continue
            path = Path(raw_path)
            matches.append(self._to_node(path, is_recent=False, is_pinned=str(path) in favorites))
            if len(matches) >= limit:
                break
        return matches

    def _ensure_index(self) -> list[str]:
        with self._lock:
            if self._index is not None:
                return list(self._index)
            if self.settings.folder_index_path.exists():
                try:
                    self._index = json.loads(self.settings.folder_index_path.read_text(encoding="utf-8"))
                    return list(self._index)
                except Exception:
                    self._index = None

            discovered: list[str] = []
            max_dirs = self.settings.folder_index_max_dirs
            for root in self.settings.allowed_roots:
                if not root.exists():
                    continue
                for current_root, dirs, _files in os.walk(root):
                    current_path = Path(current_root)
                    if self.is_allowed(current_path):
                        discovered.append(str(current_path))
                    if len(discovered) >= max_dirs:
                        break
                if len(discovered) >= max_dirs:
                    break
            self._index = discovered
            self.settings.folder_index_path.write_text(json.dumps(discovered, indent=2, ensure_ascii=True), encoding="utf-8")
            return list(discovered)

    @staticmethod
    def _to_node(path: Path, *, is_recent: bool, is_pinned: bool) -> WorkingFolderNode:
        parent_label = str(path.parent) if path.parent != path else None
        return WorkingFolderNode(
            token=str(path),
            absolute_path=str(path),
            display_name=path.name or str(path),
            parent_label=parent_label,
            is_pinned=is_pinned,
            is_recent=is_recent,
        )
