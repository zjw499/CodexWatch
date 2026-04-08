from __future__ import annotations

from pathlib import Path

from codex_watch_relay.config import Settings
from codex_watch_relay.folders import FolderCatalog
from codex_watch_relay.models import WatchThreadSummary
from codex_watch_relay.storage import StateStore


def test_recent_and_favorite_folder_nodes(tmp_path: Path) -> None:
    root = tmp_path / "workspace"
    alpha = root / "Alpha"
    beta = root / "Beta"
    alpha.mkdir(parents=True)
    beta.mkdir()

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
    state_store.add_favorite(str(beta))
    catalog = FolderCatalog(settings, state_store)

    threads = [
        WatchThreadSummary(id="thr_1", name="Alpha", preview="", cwd=str(alpha), updated_at=20, status="idle"),
        WatchThreadSummary(id="thr_2", name="Beta", preview="", cwd=str(beta), updated_at=10, status="idle"),
    ]
    recents = catalog.recent_nodes(threads)
    assert recents[0].display_name == "Alpha"
    assert recents[1].is_pinned is True

    favorites = catalog.favorite_nodes()
    assert favorites[0].display_name == "Beta"

    search = catalog.search("alp")
    assert search[0].absolute_path == str(alpha)
