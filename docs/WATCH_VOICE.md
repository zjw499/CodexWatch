# Watch voice assistants

Scribe Pilot now has a separate Watch voice conversation flow. Existing assistants
gain optional `voice` settings: enabled, approved Realtime model, and voice.
Recording-result models and recording-grounded follow-up chats retain their roles.
Old client saves preserve omitted voice settings. Old profiles default to voice off.

## User setup

1. In iPhone Settings, edit an assistant, enable voice conversations, and choose
   Marin or Cedar. The first voice-enabled assistant becomes the Watch default.
2. Keep Scribe Pilot open on your unlocked Watch. In iPhone Settings > Watch voice,
   choose the default and tap **Connect Watch voice**. The Watch needs a passcode.
   There is no setup code to receive or enter. The iPhone transfers access through
   WatchConnectivity and shows confirmation only after the Watch stores it securely.
   Provisioning requires the private workspace connection. If setup is waiting,
   tap **Sync from iPhone** on the Watch while both apps are open and nearby.
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

The voice screen shows a local microphone activity meter, whether captured audio
has reached the PC, and whether assistant audio has arrived. These indicators do
not retain audio or prove that the physical speaker was audible. If capture starts
without producing a PCM batch for five seconds, local frame counters distinguish
missing microphone samples (`MIC-01`) from conversion (`PCM-01`) or delivery
(`PCM-02`) failure. These are not treated as denied permission after authorization
has succeeded. Counters are not persisted or logged. The microphone connects directly
to an `AVAudioSinkNode`, independently of assistant playback. It has no connection
to the audible mixer. The receiver copies hardware-format PCM into preallocated,
bounded memory using lock-free atomics; a serial worker converts and delivers it.
The audio callback performs no allocation, blocking lock, dispatch or network work,
following [Apple's audio-thread guidance](https://developer.apple.com/videos/play/wwdc2019/510/).
Input is copied before the hardware reuses its buffers. Overflow ends the conversation
with `CAP-01`; an unexpected PCM layout or callback size ends it with `CAP-02`.
Stopping disables input, waits for the worker and engine, and clears queued samples.
Voice processing stays enabled and its microphone input is explicitly unmuted at
startup. The sink uses the input node's output format, as required by
[Apple's sink guidance](https://developer.apple.com/documentation/avfaudio/avaudiosinknode).
The main mixer keeps Apple's automatic output connection and follows the speaker's
format independently of microphone and provider PCM. Forcing the microphone's
rate/channel count onto output can prevent a physical route from starting; see
[Apple's main mixer format guidance](https://developer.apple.com/documentation/avfaudio/avaudioengine/mainmixernode).
Live conversion does not require preceding priming frames. Startup failures identify
session configuration (`SESSION-01`), activation (`SESSION-02`), voice processing
(`ECHO-01`), input/output availability (`INPUT-01`/`OUTPUT-01`), conversion (`PCM-01`),
or engine preparation/start (`START-01`), with the numeric Apple error when available.
Underlying error descriptions, payloads and device names are never displayed or logged.
Apple defines Mach status `-308` as `MIG_SERVER_DIED`, indicating the service connection
died, in its [system error definitions](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/mach/mig_errors.h).
The Watch audio error carries this code; it does not establish which startup operation
failed or why the service stopped.
Synthetic receiver/conversion tests cover callback copying, variable sizes and ordering,
bounded overflow, stopped input, planar/interleaved stereo, and worker delivery.
Native graph inspection verifies microphone-to-sink wiring. Offline rendering tests
cover only assistant output at different rates and mono/stereo routes: sinks and
voice-processing I/O cannot be exercised in manual rendering. Physical microphone,
echo cancellation and speaker acceptance remain required. Earlier physical tests
failed to deliver microphone batches and reported Apple startup error `-308`.
The owner confirmed build 145 still reports `MIC-01` on Apple Watch Ultra 2,
watchOS 26.6 (23U67), while ordinary Scribe Pilot meeting recordings capture voice
and produce transcripts. The microphone permission and basic recording route work;
the failing path is the separate voice conversation audio setup. Changing the receiver
to a sink did not resolve it. Build 147's physical diagnostic on that Watch narrowed
the failure to the combination of asynchronous activation, voice processing and idle
output: both the echo-processing tap (E) and current sink (R) received zero frames.
The same sink captured with active silent output (A) and with standard activation (S).
Normal voice now uses the measured S configuration: `setActive(true)`, `.playAndRecord`,
`.voiceChat`, voice processing enabled and unmuted, the existing sink receiver, and
idle output until an assistant reply. This is a configuration-level finding; the
underlying watchOS implementation cause remains unknown. Live conversation, echo,
interruption and independent-network acceptance remain pending.
Setup receipts contain only account/device/request identifiers and status;
they cannot confirm a different account or an earlier setup request.

Capture starts only after the voice screen is visible, active, and the provider is
ready. Normal voice activates synchronously with
[`setActive(true)`](https://developer.apple.com/documentation/avfaudio/avaudiosession/setactive(_:options:)),
as verified by the physical standard-activation comparison. Startup has no suspension
between activation and engine start, and checks cancellation before activation and
after it. There is no pending activation callback to revive audio after exit or stop
a newer startup. Voice ends on wrist-down screen dimming, leaving the active voice screen,
app backgrounding, explicit exit, a new audio interruption during capture, disconnection,
credential revocation, assistant deletion/disablement, or configured limits. Wrist
lowering and actual Watch lifecycle behavior must be tested on the physical device.
An interruption-ended notification does not end a conversation; Siri handoff before
capture is ready does not by itself terminate the launch.

## Local Watch audio test

In **Talk to Assistant > Test Watch audio**, tap **Run audio test** once. Speak
throughout the checks and keep the screen awake. The last check plays three short
tones; select Yes or No to record whether they were actually heard. Send the compact
comparison, `TEST-xx` finding, and speaker answer when reporting the failure.
This works without voice provisioning, the iPhone, the PC, or a provider connection.

The eight checks compare the working meeting category/default mode with a tap (M),
two-way default mode (D), voice chat mode without explicit voice processing (V),
voice processing with a tap (E), build 145's sink/idle playback graph (R), the same
graph with a continuously rendering silent player (A), the same graph with standard
instead of asynchronous activation (S), and separate speaker-tone playback (P).
The R profile retains the pre-fix configuration so comparisons remain meaningful;
normal voice now matches S. Both activation methods are supported by Apple; the
choice is based on the measured device result, not a claim that asynchronous
activation is unsupported. A local diagnostic alone does not establish live voice acceptance.

The owner completed build 147's diagnostic on October 6 on Ultra 2/watchOS 26.6:

| Check | Microphone frames | PCM batches | Result |
| --- | ---: | ---: | --- |
| M: meeting microphone | 153600 | 15 | Captured |
| D: duplex default | 148800 | 15 | Captured |
| V: voice chat without explicit processing | 148800 | 15 | Captured |
| E: echo processing, tap, asynchronous activation | 0 | 0 | No capture |
| R: original sink, idle output, asynchronous activation | 0 | 0 | No capture |
| A: sink, active output, asynchronous activation | 147936 | 15 | Captured |
| S: sink, idle output, standard activation | 151248 | 15 | Captured; selected fix |
| P: separate speaker tone | N/A | N/A | 74520 output frames rendered; owner heard tones |

The report selected `TEST-03` because the active-output finding precedes the
standard-activation finding; S also passed and supplies the smaller production
change. The complete run reported 22 route changes, zero interruptions and zero
audio resets. Route changes across different audio configurations alone do not
establish an external interruption. No raw audio or device identifiers were retained.

Details show engine state and category/mode at startup and after three seconds,
hardware/client PCM formats, input/output port types, explicit input mute and echo
processing state, microphone and converted frame counts, batches, receiver faults,
local peak level and rendered output frames. Output rendering never proves audibility.
Failures contain only a local startup stage and numeric Apple code. Reports exclude
device names, UIDs, serial numbers, raw error descriptions, userInfo and provider data.
Counters and the speaker answer remain only in the Watch process; no audio files,
network request, transcript, telemetry event or automatic upload is created.

Recording and voice launches refuse to start while a test owns audio. Cancelling or
leaving the screen stops capture and output. If activation is still pending, the test
keeps its reservation until the callback completes and the session is deactivated,
preventing a late callback from stopping a new activity. An existing recovered meeting
retains priority. Wrist lowering, app inactivity, interruption, audio-service reset
and route disconnection stop the test without automatic restart.

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
release. After Realtime retention confirmation, TestFlight can distribute an
administrator-only pilot so the physical Watch can be tested. Production voice
enablement and general release follow physical acceptance.

Signed release preparation is available before these gates pass. In **Build watchOS
and upload to TestFlight**, leave **archive_only** enabled to produce the signed
iPhone/Watch archive and a source/build/SHA-256 manifest as a 30-day workflow artifact.
Changes to that workflow on the Watch voice feature branch also prepare an archive.
Ordinary push-triggered runs use archive-only mode. Distribution requires archive-only
disabled and a retention confirmation/evidence reference. An administrator pilot
can be requested with **pilot_release** for physical-device testing; production
distribution also requires device acceptance. On this feature branch, an explicitly
authorized workflow commit marked `[watch-voice-pilot]` requests the pilot and
records its retention confirmation in the commit body.
Before distribution, supply **native_verification_run** (or record
`native-verification-run=RUN_ID` in an authorized pilot commit). Signed archive
preparation can run alongside native checks. The pilot requires completed successful
backend, native build, unit and phone UI test steps with matching app, shared, backend,
test and native-workflow source; signed archive checks separately validate Watch
intents and complications. A cancelled simulator preview/export does not invalidate
completed test results for a pilot. Missing, skipped, failed or cancelled required
tests block upload, as does different app source. Production distribution also
requires overall native workflow success. Uploaded builds are checked
for valid processing, export compliance, and internal-test access automatically.
These inputs document the operator's attestation; the backend's encrypted policy
remains the authority for enabling live voice. Archive creation does not establish
physical Watch acceptance.

For rollback, first turn off both production and pilot voice in organization policy,
then run `scripts/disable_watch_voice.ps1`. It disables the voice scheduled task,
stops only its verified process and removes only Funnel 8443. Existing private HTTPS,
recordings, and encrypted conversation history are retained. Database changes are additive.
