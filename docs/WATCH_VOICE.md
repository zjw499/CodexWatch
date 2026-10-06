# Watch voice assistants

Scribe Pilot now has a separate Watch voice conversation flow. Existing assistants
gain optional `voice` settings: enabled, approved Realtime model, and voice.
Recording-result models and recording-grounded follow-up chats retain their roles.
Old client saves preserve omitted voice settings. Old profiles default to voice off.

## User setup

1. In iPhone Settings, edit an assistant, enable voice conversations, and choose
   Marin or Cedar. The first voice-enabled assistant becomes the Watch default.
2. In Watch voice, choose the default and tap **Set up Watch voice**. The Watch
   needs a passcode. Provisioning requires the private workspace connection.
3. Open Talk to Assistant on Watch, use its App Shortcut (default or named
   assistant), or add a Talk to Assistant / named-assistant complication.
4. Speak normally. Mute pauses microphone transmission; End closes the conversation.
   Starting a meeting and starting voice are mutually exclusive, with an explicit
   message to end the current activity.

After setup, Watch live audio uses its own Wi-Fi/cellular connection. The iPhone
does not relay audio. The PC must be online. Quick launches are fresh; select a
conversation from Watch History to resume. Text history is also available in
iPhone Settings. Audio is never written by the voice gateway or Watch voice flow.
Interrupted replies are labelled; unheard replies are excluded from resumed context.
Incomplete input transcription may remain labelled as an incomplete turn.

Capture starts only after the voice screen is visible, active, and the provider is
ready. Voice ends on wrist-down screen dimming, leaving the active voice screen,
app backgrounding, explicit exit, audio interruption, disconnection,
credential revocation, assistant deletion/disablement, or configured limits. Wrist
lowering and actual Watch lifecycle behavior must be tested on the physical device.

## Runtime and API

The private workspace remains at `https://zwyattpc.tail488e93.ts.net/workspace`
on HTTPS 443. Only private `/api/voice/*` routes provision devices, set defaults,
and provide phone history. `/api/admin/voice/*` provides policy and audited review.

The separate `voice-serve` process binds `127.0.0.1:8791`, serving only
`/voice/v1/*`. Tailscale Funnel uses a separate HTTPS 8443 listener. It exposes no
workspace login, recording, upload, or administration routes. Tailscale Serve 443
and the legacy 8789 pipeline are preserved.

The Watch sends PCM16 little-endian mono 24 kHz in 200 ms HTTPS POST batches,
and receives versioned JSON events over a streaming HTTPS SSE response. The PC
holds the GA OpenAI Realtime WebSocket, organization/project headers, approved
model, voice, transcription, semantic VAD, and empty tools policy. It never forwards
the OpenAI key. Playback offsets drive interruption truncation. Fully played
answers remain available as context; unfinished or interrupted answers do not.
Both uplink and downlink buffers are bounded; insufficient throughput ends the
conversation instead of accumulating audio. No automatic conversation restart.

Voice-only Watch credentials are hashed in SQLite and bound to an active parent
workspace session, owner, device ID, and expiry (at most the current seven-day
workspace session). Watch stores the bearer in passcode-bound device-only Keychain.
Account changes clear credentials, metadata and queued voice launches. Named
launches carry owner and expiry; legacy recording commands continue to decode.
Complication metadata contains only assistant display metadata, never credentials,
instructions, or conversation text.

Conversation content and voice policy use existing Windows DPAPI. Deleted
conversations are tombstoned and cleared, preventing late events from restoring
them. Ordinary owner routes reject cross-account reads; administrator review has
separate routes and records access. No provider errors or payloads enter service
logs. Gateway startup recovers voice sessions only, never recording jobs.

## Deployment and acceptance

Voice is disabled by default. Organization administration includes a voice policy
bound to the configured organization/project: Realtime Modified Retention evidence,
physical Watch acceptance, and limits (600 seconds per session, 120 seconds idle,
one live session per account by default). Administrators can adjust all three limits;
an already-active conversation cannot be resumed on a second connection.
Start creation is limited to 60 requests per 15
minutes per account; PCM uploads are limited to real-time rate and body size.

An administrator-only pilot permits physical-device testing once Realtime retention
is verified, before enabling voice for ordinary users. Do not mark device acceptance
passed based on simulator results. Neither pilot nor production is enabled by deployment.

Deploy from a clean, verified source commit:

```powershell
.\scripts\deploy_workspace.ps1 -Version <verified-40-character-SHA> -InstallVoiceGateway -ExposeVoiceGateway
```

Funnel may require the owner to authorize the PC node in Tailscale; do not broaden
tailnet permissions automatically. Separate Windows scheduled tasks supervise
workspace and voice processes, with separate locks, PID files, health checks and
logs. Install the backend before the new app so new clients receive additive APIs.
Run `python scripts/verify_voice_gateway.py` from an external connection to check
public TLS, authentication and route isolation without credentials or provider
requests. The **Verify public voice gateway** workflow can run the same check from
a hosted runner; the PC and Funnel must be online.

Physical acceptance: test Watch mic and speaker with no headphones; repeat using
headphones; verify echo does not trigger self-responses; interrupt an answer and
check the saved label; mute/unmute; launch default and named shortcuts from a cold
app and each supported complication family. Disconnect the iPhone using Settings
(not only Control Center), test Watch Wi-Fi and cellular if available, and repeat
wrist lowering, app exit, permissions, expired credentials, account changes,
assistant deletion and PC/network loss. Run a ten-minute session and check latency,
buffer health and concurrent recording transcription on PC. Confirm ordinary-user
isolation and explicitly audited administrator review.

The native verification workflow compiles iPhone and Watch, runs native and backend
tests, and captures the Watch voice preview. The existing TestFlight workflow must
verify TalkWatchAssistantIntent metadata and the four complication families before
release. Production enablement and release follow physical acceptance.

Signed release preparation is available before these gates pass. In **Build watchOS
and upload to TestFlight**, leave **archive_only** enabled to produce the signed
iPhone/Watch archive and a source/build/SHA-256 manifest as a 30-day workflow artifact.
Changes to that workflow on the Watch voice feature branch also prepare an archive.
Push-triggered runs always use archive-only mode. Distribution requires a manual
run with archive-only disabled, both retention and device-acceptance confirmations,
and a non-sensitive reference to the recorded evidence. Those inputs document the
operator's attestation; the backend's encrypted policy remains the authority for
enabling live voice. Archive creation does not establish physical Watch acceptance.

For rollback, first turn off both production and pilot voice in organization policy,
then run `scripts/disable_watch_voice.ps1`. It disables the voice scheduled task,
stops only its verified process and removes only Funnel 8443. Existing private HTTPS,
recordings, and encrypted conversation history are retained. Database changes are additive.
