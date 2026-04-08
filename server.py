from codex_watch_relay.app import app
from codex_watch_relay.config import Settings


if __name__ == "__main__":
    import uvicorn

    settings = Settings.from_env()
    uvicorn.run("server:app", host=settings.host, port=settings.port, log_level="info")
