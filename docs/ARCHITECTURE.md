# Architecture

## Relay Topology

`Scribe Pilot` is desktop-first.

- Apple Watch runs the native SwiftUI client.
- The watch talks to a desktop-accessible relay.
- The relay talks to `codex app-server` over JSON-RPC.
- The desktop Codex runtime remains the system of record for threads, turns, tools, and local filesystem context.

## Core API Mapping

- `GET /v1/watch/desktops`
  - Surfaces a single trusted desktop target with relay state and `D:` availability.
- `GET /v1/watch/desktops/{desktop_id}/threads`
  - Wraps `thread/list`.
- `GET /v1/watch/desktops/{desktop_id}/threads/{thread_id}`
  - Wraps `thread/read`.
- `POST /v1/watch/desktops/{desktop_id}/threads`
  - Calls `thread/start`, then optionally `turn/start`.
- `POST /v1/watch/desktops/{desktop_id}/threads/{thread_id}/turns`
  - Calls `turn/start`.
- `GET /v1/watch/questionnaires`
  - Returns pending `tool/requestUserInput` requests normalized for watch consumption.
- `POST /v1/watch/questionnaires/{request_id}/answers`
  - Responds to the pending tool request and resumes the active turn.
- `GET /v1/watch/desktops/{desktop_id}/folders/*`
  - Exposes allowlisted `D:\` directory metadata only.

## Folder Model

- The relay exposes directories, not files.
- Paths are restricted to `CODEX_WATCH_ALLOWED_ROOTS`.
- Recents come from existing Codex thread `cwd` values.
- Favorites are persisted in `data/watch_state.json`.
- Search is index-backed and stored in `data/folder_index.json`.

## Notification Model

Relay notifications are synthesized from Codex state changes and stored locally:

- `reply_ready`
- `question_waiting`
- `desktop_offline`

The watch client uses the stored deep link to reopen the relevant thread detail.

## Watch UX Model

- `HomeView`: launcher for continue, create, working folder, inbox, and pending questions.
- `ThreadListView`: recent and searched thread entry point.
- `ThreadDetailView`: reply summary, current turn state, workspace summary, and voice follow-up.
- `PromptComposerView`: dictation-first send flow.
- `WorkingFolderPickerView`: recents, favorites, browse, and voice search on approved `D:\` roots.
- `PlanQuestionnaireView`: tap-first answers with Crown-driven question and option focus.

## Known Limits

- The relay is tested locally; the live `codex app-server` integration path was not exercised end-to-end in this workspace.
- The watch source was not compiled on this Windows machine.
- True background streaming is not modeled; the intended production path is APNs plus snapshot refresh.
