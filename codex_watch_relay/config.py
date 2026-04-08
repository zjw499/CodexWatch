from __future__ import annotations

import os
import secrets
from dataclasses import dataclass
from pathlib import Path


def _resolve_path(raw_value: str, cwd: Path) -> Path:
    path = Path(raw_value)
    if not path.is_absolute():
        path = cwd / path
    return path


@dataclass(frozen=True)
class Settings:
    host: str
    port: int
    relay_token: str | None
    desktop_id: str
    desktop_name: str
    codex_binary: str
    codex_rpc_timeout_seconds: float
    codex_startup_timeout_seconds: float
    data_dir: Path
    state_path: Path
    folder_index_path: Path
    allowed_roots: list[Path]
    folder_search_limit: int
    folder_index_max_dirs: int

    @classmethod
    def from_env(cls) -> "Settings":
        cwd = Path.cwd()
        data_dir = _resolve_path(os.environ.get("CODEX_WATCH_DATA_DIR", "data"), cwd)
        data_dir.mkdir(parents=True, exist_ok=True)

        raw_roots = (os.environ.get("CODEX_WATCH_ALLOWED_ROOTS") or r"D:\\").split(";")
        allowed_roots = [Path(root.strip()) for root in raw_roots if root.strip()]
        if not allowed_roots:
            allowed_roots = [Path(r"D:\\")]

        relay_token = (os.environ.get("CODEX_WATCH_RELAY_TOKEN") or "").strip() or None
        if relay_token == "auto":
            relay_token = secrets.token_urlsafe(24)

        return cls(
            host=os.environ.get("CODEX_WATCH_HOST", "127.0.0.1"),
            port=int(os.environ.get("CODEX_WATCH_PORT", "8790")),
            relay_token=relay_token,
            desktop_id=os.environ.get("CODEX_WATCH_DESKTOP_ID", "local-windows"),
            desktop_name=os.environ.get("CODEX_WATCH_DESKTOP_NAME", os.environ.get("COMPUTERNAME", "This PC")),
            codex_binary=os.environ.get("CODEX_WATCH_CODEX_BIN", "codex").strip() or "codex",
            codex_rpc_timeout_seconds=float(os.environ.get("CODEX_WATCH_RPC_TIMEOUT_SECONDS", "60")),
            codex_startup_timeout_seconds=float(os.environ.get("CODEX_WATCH_STARTUP_TIMEOUT_SECONDS", "20")),
            data_dir=data_dir,
            state_path=data_dir / "watch_state.json",
            folder_index_path=data_dir / "folder_index.json",
            allowed_roots=allowed_roots,
            folder_search_limit=int(os.environ.get("CODEX_WATCH_FOLDER_SEARCH_LIMIT", "25")),
            folder_index_max_dirs=int(os.environ.get("CODEX_WATCH_FOLDER_INDEX_MAX_DIRS", "20000")),
        )
