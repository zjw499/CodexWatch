# Scribe Pilot

`CodexWatch` is an MVP workspace for the Scribe Pilot Apple Watch companion.

It has two parts:

- `codex_watch_relay/`: a FastAPI relay that talks to `codex app-server`, exposes a watch-shaped API, tracks plan questionnaires, and scopes folder access to approved `D:\` roots.
- `watchos/CodexWatch/`: native SwiftUI source for the watch experience, including thread selection, new thread creation, working folder browsing, Plan Mode questionnaires, dictation-first prompting, and inbox reopen flows.

## What Is Implemented

- Desktop discovery with `D:` capability status.
- Existing thread list and thread detail.
- New thread creation with optional working folder and Plan Mode toggle.
- Follow-up prompt submission into an existing thread.
- Plan Mode questionnaire rendering with Crown-aware question and answer focus.
- Voice dictation for the main prompt and `Other` answers.
- Recent, favorite, browse, and search flows for approved `D:\` folders.
- Inbox and notification reopen plumbing.
- Relay tests for the Python backend surface.

## Workspace Layout

- `server.py`: relay entrypoint.
- `codex_watch_relay/app.py`: watch-facing HTTP routes.
- `codex_watch_relay/codex_app_server.py`: `codex app-server` JSON-RPC client.
- `codex_watch_relay/folders.py`: allowlisted `D:\` browsing and search index.
- `codex_watch_relay/storage.py`: local relay state for favorites, notifications, and thread context.
- `watchos/CodexWatch/`: source files to drop into an Xcode watchOS app target.
- `project.yml`: XcodeGen spec for the native watchOS app target on macOS.
- `macos/CodexWatch/`: signing config, Info.plist, and Xcode resources for the Mac build host.
- `scripts/mac/`: Mac bootstrap, project generation, and build helpers.
- `scripts/windows/`: Windows relay LAN helpers.
- `tests/`: relay tests.
- `docs/ARCHITECTURE.md`: flow and integration notes.

## Run The Relay

1. Create and activate a Python environment.
2. Install dependencies:

```powershell
python -m pip install -r D:\CodexWatch\requirements.txt
```

3. Configure environment variables:

```powershell
$env:CODEX_WATCH_ALLOWED_ROOTS='D:\Projects;D:\Repos'
$env:CODEX_WATCH_DESKTOP_ID='home-ultra-pc'
$env:CODEX_WATCH_DESKTOP_NAME='Home PC'
$env:CODEX_WATCH_RELAY_TOKEN='replace-me'
```

4. Start the relay:

```powershell
python D:\CodexWatch\server.py
```

The relay defaults to `http://127.0.0.1:8790`.

## Watch App Integration

The watch source is in `watchos/CodexWatch/`, and the Mac-side project generator is now in `project.yml`. On the Mac:

```bash
chmod +x scripts/mac/*.sh
./scripts/mac/bootstrap-mac.sh
cp macos/CodexWatch/Config/Local.example.xcconfig macos/CodexWatch/Config/Local.xcconfig
./scripts/mac/generate-project.sh
```

Then fill in `macos/CodexWatch/Config/Local.xcconfig` with:

- `DEVELOPMENT_TEAM`
- `PRODUCT_BUNDLE_IDENTIFIER`
- `CODEX_WATCH_RELAY_BASE_URL`
- `CODEX_WATCH_RELAY_TOKEN`

For device builds, `CODEX_WATCH_RELAY_BASE_URL` must point to a relay host the watch can actually reach. `127.0.0.1` only works for simulator-only local testing.

## Constraints

- Watch dictation is converted to text before sending to Codex.
- Folder browsing is relay-backed; the watch never reads `D:\` directly.
- Live turn updates are foreground-first. Background flow is notification-driven.
- The Swift source was written for a native watchOS target but was not compiled in this Windows environment.

## Tests

```powershell
cd D:\CodexWatch
python -m pytest -q
```
