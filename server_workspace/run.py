"""Workspace launcher and local administrator recovery; never prints credentials."""
from __future__ import annotations

import argparse
import getpass
import json
from pathlib import Path

import uvicorn

from server_workspace.workspace import Workspace, WorkspaceConfig, create_app


def load(path: Path) -> WorkspaceConfig:
    values = json.loads(path.read_text(encoding="utf-8-sig"))
    values["root"] = Path(values["root"])
    values["key_file"] = Path(values["key_file"])
    for key in ("transcription_models", "generation_models", "voice_models", "voice_voices"):
        if key in values:
            values[key] = tuple(values[key])
    return WorkspaceConfig(**values, config_file=path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("command", choices=["serve", "voice-serve", "bootstrap", "reset-password"])
    parser.add_argument("--username", default="admin")
    parser.add_argument("--port", type=int)
    args = parser.parse_args()
    workspace = Workspace(load(args.config), recover_jobs=args.command == "serve")
    if args.command == "bootstrap":
        with workspace.db() as db:
            if db.execute("SELECT 1 FROM users WHERE role='admin' AND active=1").fetchone():
                raise SystemExit("An administrator already exists; use local password recovery if needed")
        invitation = workspace.invite(args.username, "admin")
        destination = workspace.config.root / "administrator-invitation.txt"
        destination.write_text("Scribe Pilot administrator setup\n\nServer: https://zwyattpc.tail488e93.ts.net/workspace\nUsername: "
                               + invitation["username"] + "\nInvitation code: " + invitation["code"]
                               + "\n\nOpen Account > Accept invitation on your phone. Choose a password of at least 12 characters.\n"
                               + "This invitation expires in 7 days and can be used once. Keep this file private.\n", encoding="utf-8")
        print("Administrator invitation saved to:", destination)
    elif args.command == "reset-password":
        password = getpass.getpass("New password (12 or more characters): ")
        if len(password) < 12 or len(password) > 256:
            raise SystemExit("Password must contain 12–256 characters")
        if getpass.getpass("Repeat password: ") != password:
            raise SystemExit("Passwords do not match")
        with workspace.db() as db:
            user = db.execute("SELECT id FROM users WHERE username=?", (args.username.lower(),)).fetchone()
            if not user:
                raise SystemExit("Account not found")
            db.execute("UPDATE users SET password=? WHERE id=?", (workspace.password_hash(password), user[0]))
            db.execute("DELETE FROM sessions WHERE user_id=?", (user[0],))
            workspace.audit(db, "local-recovery", "password-reset", user[0])
        print("Password updated; existing sessions revoked")
    elif args.command == "voice-serve":
        from server_workspace.voice import create_voice_app
        uvicorn.run(create_voice_app(workspace), host="127.0.0.1", port=args.port or 8791, access_log=False, log_level="critical")
    else:
        uvicorn.run(create_app(workspace), host="127.0.0.1", port=args.port or 8790, access_log=False, log_level="warning")


if __name__ == "__main__":
    main()
