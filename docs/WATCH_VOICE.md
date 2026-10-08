# Watch voice assistants

Scribe Pilot now has a separate Watch voice conversation flow. Existing assistants
gain optional `voice` settings: enabled, approved Realtime model, voice, local
calculations/time, and public web search.
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
without a full PCM batch, counters distinguish missing hardware samples (`MIC-01`),
short capture (`MIC-02`), a receiver fault (`CAP-01`/`CAP-02`), an undrained worker
(`CAP-03`), and an actual converter error (`PCM-01`). A format change can stop the
engine, so startup observes configuration-change notifications and rebuilds with
fresh hardware formats at most twice, before sending any audio. Startup is bounded
to five seconds and becomes ready only after a running engine produces a full batch.
Queued batches from abandoned attempts are discarded; the successful attempt keeps
its first packets in order. Established conversations end if a configuration change
stops the engine; they do not restart automatically. See
[Apple's configuration-change guidance](https://developer.apple.com/documentation/avfaudio/avaudioengineconfigurationchangenotification).
The microphone connects directly
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
cover silent-clock looping, prompt replies, reply pause/interruption and clock cleanup
at different rates and mono/stereo routes. They cover output only: sinks and
voice-processing I/O cannot be exercised in manual rendering. Physical microphone,
echo cancellation and speaker acceptance remain required. Earlier physical tests
failed to deliver microphone batches and reported Apple startup error `-308`.
The owner confirmed build 145 still reports `MIC-01` on Apple Watch Ultra 2,
watchOS 26.6 (23U67), while ordinary Scribe Pilot meeting recordings capture voice
and produce transcripts. The microphone permission and basic recording route work;
the failing path is the separate voice conversation audio setup. Changing the receiver
to a sink did not resolve it. Build 147's local diagnostic captured with active
silent output (A) and standard activation (S), while the asynchronous idle-output
echo tap (E) and original sink (R) received zero frames. Build 148 changed only to
standard activation, but the owner confirmed a normal conversation still ended
with `MIC-01`. S ran after A; earlier output activity might have influenced its
success. That is a hypothesis, not a proven watchOS implementation cause.
Build 149 kept output rendering continuously through a separate silent
24 kHz mono player alongside the reply player. It retains synchronous activation,
voice processing, unmuted input and sink capture; output graph setup precedes
input format inspection, matching the comparison's setup order. Silent output
never enters the reply ledger, queues ahead of replies or stops when a reply is
interrupted. End stops both players and clears capture. This follows the successful
A comparison's continuous-output principle; the separate-player implementation
and full conversation still require physical acceptance. A new first diagnostic
uses the actual normal conversation audio implementation without a provider connection.
Setup receipts contain only account/device/request identifiers and status;
they cannot confirm a different account or an earlier setup request.

Capture starts only after the voice screen is visible, active, and the provider is
ready. Normal voice activates synchronously with
[`setActive(true)`](https://developer.apple.com/documentation/avfaudio/avaudiosession/setactive(_:options:)),
with a continuous silent output clock. Standard activation alone failed in build 148.
Activation and initial engine start do not suspend. Subsequent startup checks
yield to route notifications, check cancellation and audio ownership at each wait,
and invalidate old attempts before cleanup. There is no pending activation callback to revive audio after exit or stop
a newer startup. Voice ends on wrist-down screen dimming, leaving the active voice screen,
app backgrounding, explicit exit, a new audio interruption during capture, disconnection,
credential revocation, assistant deletion/disablement, or configured limits. Wrist
lowering and actual Watch lifecycle behavior must be tested on the physical device.
An interruption-ended notification does not end a conversation; Siri handoff before
capture is ready does not by itself terminate the launch.

## Local Watch audio test

In **Talk to Assistant > Test Watch audio**, tap **Run audio test** once. Speak
throughout the checks and keep the screen awake. The last check plays three short
tones; select Yes or No to record whether they were actually heard. Test counters
send automatically to the authenticated PC workspace; the screen shows sent or
waiting status and offers a retry. No audio is uploaded by the test. Local checks
still work without provisioning or networking. A provisioned Watch credential,
internet and the PC are required to deliver the report. You do not need to read out
counters. Normal conversation audio startup failures send the same safe details.
On iPhone, Settings > Watch voice > Watch audio reports provides review/deletion.
The administrator review screen is explicit and audited.

The first check (N) runs the actual `WatchVoiceAudio` implementation, before any
comparison can warm the route. Its microphone meter, batch counts, safe session
snapshots and silent-output frame count come from that instance. Eight retained
comparison checks follow: the working meeting category/default mode with a tap (M),
two-way default mode (D), voice chat mode without explicit voice processing (V),
voice processing with a tap (E), build 145's sink/idle playback graph (R), the same
graph with a continuously rendering silent player (A), the same graph with standard
instead of asynchronous activation (S), and separate speaker-tone playback (P).
R is labelled **Original voice input** and retains the earlier configuration.
Findings assess N as normal voice; successful later comparisons cannot claim normal
startup succeeded. Both activation methods are supported by Apple; the change does
not imply asynchronous activation is unsupported. A local diagnostic alone does
not establish live voice acceptance.

The owner completed build 147's diagnostic on October 6 on Ultra 2/watchOS 26.6:

| Check | Microphone frames | PCM batches | Result |
| --- | ---: | ---: | --- |
| M: meeting microphone | 153600 | 15 | Captured |
| D: duplex default | 148800 | 15 | Captured |
| V: voice chat without explicit processing | 148800 | 15 | Captured |
| E: echo processing, tap, asynchronous activation | 0 | 0 | No capture |
| R: original sink, idle output, asynchronous activation | 0 | 0 | No capture |
| A: sink, active output, asynchronous activation | 147936 | 15 | Captured |
| S: sink, idle output, standard activation | 151248 | 15 | Captured locally; build 148 normal startup later failed |
| P: separate speaker tone | N/A | N/A | 74520 output frames rendered; owner heard tones |

The report selected `TEST-03` because the active-output finding precedes the
standard-activation finding. S also passed in that sequence, but changing only
activation did not resolve the normal conversation. The complete run reported
22 route changes, zero interruptions and zero
audio resets. Route changes across different audio configurations alone do not
establish an external interruption. No raw audio or device identifiers were retained.

Details show engine state and category/mode at startup and after three seconds,
hardware/client PCM formats, input/output port types, explicit input mute and echo
processing state, microphone and converted frame counts, batches, receiver faults,
local peak level and rendered output frames. Output rendering never proves audibility.
Failures contain only a local startup stage and numeric Apple code. Reports exclude
device names, UIDs, serial numbers, raw error descriptions, userInfo and provider data.
Reports contain only allowlisted formats/port types, OS/build numbers, numeric
counters/errors and at most twelve startup events. Local microphone levels are
excluded. Credential/account metadata is not part of the report body. The server
binds ownership to the authenticated, unexpired parent session and encrypts content
with workspace DPAPI. JSON rejects unknown fields, including audio, transcripts,
credentials and arbitrary device names. Request UUIDs and monotonic revisions make
lost acknowledgements and speaker feedback safe to retry. Each account retains at
most 100 recent reports. Deleted report tombstones reject delayed retries. Up to ten
unsent reports are protected on Watch, excluded from backup and cleared on account
changes. Reports use POST `/voice/v1/diagnostics`; private owner read/delete routes
are `/api/voice/diagnostics`, and audited administrator reads use
`/api/admin/voice/diagnostics`.

The explicit host support command reads only the selected account's latest safe
report and audits the access. It never recovers recording jobs:

```powershell
$env:PYTHONPATH = Get-Content D:\watch-audio-pipeline\.runtime\scribe-workspace\voice-active-source.txt
D:\watch-audio-pipeline\.venv\Scripts\python.exe -m server_workspace.run --config D:\watch-audio-pipeline\.runtime\scribe-workspace\workspace-config.json voice-diagnostics --username admin
```

Use `--report-id <UUID>` for an earlier report. Substitute the intended account's
username; this local support interface is not exposed on HTTPS.

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
model, voice, transcription, semantic VAD, and allowlisted tool definitions. It never forwards
the OpenAI key. Playback offsets drive interruption truncation. Fully played
answers remain available as context; unfinished or interrupted answers do not.
Both uplink and downlink buffers are bounded; insufficient throughput ends the
conversation instead of accumulating audio. No automatic conversation restart.

## Conversational assistant and tools

Voice instructions add a natural spoken style, direct answers, short default replies,
and follow-up context. Custom assistant instructions still apply; recording-summary
directions apply when notes are requested. VAD commits speech, while the PC explicitly
requests one response per completed user turn. A newer question waits for an old
response's cancellation acknowledgement instead of losing its response request.
Delayed playback reports refer to the known item, and cannot interrupt a newer reply.

Calculations use a bounded arithmetic parser, and current time uses IANA timezones
on the PC. Public search uses the approved Responses model and `web_search` with
`store=false`. Only an isolated public query is sent, never history or recordings.
A query privacy check runs without tools inside the approved Responses boundary
before any search; failed checks and private queries do not enable search. This
model check supplements the public-only restriction; it is not a guarantee of PHI
redaction. Live web search is outside the OpenAI BAA, even when Realtime has Modified
Retention. Both the organization's `public_web_search_enabled` policy and the
assistant's `web_search` setting must permit search. Existing profiles default to
search off. A separate General conversation profile is appropriate for public topics.
See [OpenAI data controls](https://developers.openai.com/api/docs/guides/your-data).

Tool work runs separately from the provider reader, times out within 25 seconds,
and is cancelled by a newer user turn or session termination. There are at most
four tool invocations per user turn and 32 per session. Results return as Realtime
function-call outputs followed by a spoken response. Search activity appears on
Watch; clickable sources remain with the encrypted transcript on Watch and iPhone.
Tool failures are explained in conversation, with provider bodies kept private.
Tools cannot access recordings, execute code, send messages, or modify accounts.
Older clients preserve omitted nested tool settings and the organization web policy.

The bounded live check `scripts/verify_voice_conversation.py --config <path> --live`
uses only fixed synthetic public questions. It verifies a calculator answer, a
follow-up using that context, and a web-backed answer with citations. It does not
recover recording jobs or prove physical Watch turn-taking acceptance. Completed
sessions save encrypted counts of VAD commits, replies, interruptions, and tool
success/failure for support without retaining queries or provider payloads in logs.

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


## Build 149 physical result and next pilot

The owner reported PCM-01 in a normal conversation and completed diagnostic test 2
on Ultra 2/watchOS 26.6: N received 1104 frames/zero batches; M received 153600/15;
D and V each received 148800/15; E received zero; R and S were stopped with zero;
A was stopped after 1104/zero; P rendered 75072 frames and the owner heard tones.
There were 26 route changes, zero interruptions and zero media resets.

1104 input frames are shorter than a 200 ms batch at the likely hardware rates.
The prior message conflated a converter error with capture stopping before batching.
Engine configuration changes are a plausible cause, not established by these counters.
The next pilot adds bounded startup stabilization plus automatically delivered worker,
converter and engine-event evidence. It retains echo processing and the silent output
clock. Full physical Watch microphone, playback, interruption and independent-network
acceptance remain pending; build 149 did not pass.


For gateway-only updates, use `deploy_workspace.ps1 -Version <verified-source-SHA>
-InstallVoiceGateway -VoiceGatewayOnly`. The voice supervisor uses its own release
pointer, falling back to the main pointer for older installations. This leaves the
recording worker and private HTTPS listener running. The diagnostic table is
additive and voice startup uses `recover_jobs=False`. Deploy private read/review
routes separately in a quiescent workspace window; verify no recording processing
jobs are active before restarting the private worker. Rollback changes only the
selected service's pointer and retains encrypted reports/history.

## Build 150 physical audio and interrupted replies

On October 7 the automatically delivered build 150 report on Ultra 2/watchOS 26.6
showed N production capture running: 158976 input/drained frames, 79488 converted
frames, 16 batches and zero receiver/converter faults. It reached ready on the
first attempt at 923 ms. Separate speaker tones were heard. The owner then tried
a normal conversation: speech reached the assistant and part of its reply was
audible, but the conversation ended with the generic slow-connection message.
Full physical acceptance remains incomplete.

The prior implementation used the same slow message for three different bounds.
The PC event queue ended at 256000 base64 audio bytes (about four seconds), and
Watch playback ended when over four seconds were scheduled ahead. A fast
six-second reply burst reproduces the PC limit without requiring a slow network.
The separate microphone path uploaded each 200 ms packet in a serial HTTP
request; sustained acknowledgement latency above 200 ms would fill its queue.
Build 150 did not report transport counters, so which of those guards ended this
specific physical conversation is unknown.

The corrected gateway keeps a bounded 30-second PCM reservoir only in memory and
streams at most 200 ms of audio per event, paced at 24000 mono PCM16 frames/second.
It does not send a catch-up burst after a stalled transport. Provider reading
continues while audio is paced, so speech interruptions can clear buffered output
promptly. Pending caption snapshots coalesce while preserving question/answer
order. Provider listening is deferred until buffered audio has been sent, while
interrupt/end controls remain prompt. Watch playback/truncation still uses actual
heard progress as required by [Realtime interruption handling](https://developers.openai.com/api/docs/guides/realtime-conversations#interruption-and-truncation).

The build 151 Watch pilot combined queued microphone packets into uploads of at most
one second, retaining byte/sequence identity on a lost-ack retry. Unsent audio
remains bounded to two seconds, with one request in flight. It sends safe capture,
upload timing/byte-count and playback queue reports at conversation end; NET-01,
NET-02 and NET-03 distinguish upload, Watch playback and PC output limits. Reports
contain no audio, text, credentials, provider payloads or device identifiers.
Deploy the extended strict receiver before distributing this pilot. Private review
routes and the recording worker need no restart for this voice-only update.

## Builds 153-154: continuous reply playback and request jitter

Recent build 152 reports identified upload-buffer overflow during brief request
stalls. Healthy capture and received reply bytes did not establish audible
playback. The earlier reply player paused whenever a packet queue emptied and
scheduled the next packet at a sampled player time, which could already be past
when the audio thread handled it.

`VoiceReplyPlayer` queues contiguous PCM with native immediate/append scheduling,
keeps the player clock running between packets and replies, and uses a bounded
half-second startup buffer for jitter. Provider `audio_done` markers follow their
own queued PCM; each reply, including a tool preamble, acknowledges its own
completed playback. Interrupted/stopped node callbacks cannot count discarded
samples as played. Delayed interrupts for older replies cannot stop newer audio.

Microphone requests now combine at least 400 ms and at most one second. The
in-memory upload bound is eight seconds, with one serial upload and one identical
sequence/byte retry. A three-second request deadline and ten-second control
grace tolerate a transient lost acknowledgement while audio still flows; access
errors stop immediately. The PC disconnect grace is fifteen seconds, while its
authorization/revocation checks still run every second. Capture never silently
restarts after actual stream loss. SSE uses a separate URLSession connection pool.

Automatic owner-scoped reports include scheduled/completed reply frames, item
completion counts, buffer gaps, control failures, retries and within-reply arrival
gaps. They bind a report to its owner's session. Encrypted conversation counters
distinguish generated, handed-to-stream and acknowledged audio per assistant
turn; no raw audio, speech, query, credential or provider payload enters logs.
Older clients/reports remain compatible. Recording workers and private APIs need
no restart for the separately supervised voice-only deployment.

Build 154 also waits for final playback acknowledgements and End before creating
a new conversation. Repeated fresh launches cannot race the previous session's
single active-conversation slot while its HTTP close is still in flight.

Native tests render PCM through AVAudioEngine across empty queues, later replies,
short tails, interruptions and tool continuations. These tests and synthetic
spoken API checks do not establish physical Watch speaker audibility, echo
quality, independent networking or conversational quality. TestFlight device
acceptance remains necessary.
