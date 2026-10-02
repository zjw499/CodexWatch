# Scribe Pilot shared workspace

Invited users sign in to private accounts. The iPhone and Watch record offline,
and the phone uploads to the Windows PC over private-network HTTPS when the user
chooses Process. Only the PC calls OpenAI, through Sky Data Services' configured
organization and project. Device API keys and shared receiver credentials are no
longer part of this workflow.

## First administrator and invited users

The deployment writes a one-use administrator invitation into the restricted
PC workspace folder. In iPhone Settings, choose **Accept invitation**, enter the
code, and choose a password of at least 12 characters. The initial username is
`admin`. Subsequent sign-ins use the username and password.

Use **Settings → Administrator workspace → Invite a user** to create invitations.
Each invitation expires after seven days and can be accepted once. Share it with
the intended person through an appropriate channel. Users also need access to
the existing Tailscale network/device share; an app invitation does not grant
network access. The PC must be online and its service account logged in.

Administrators can review other users' recordings through Organization review.
That access is recorded. Ordinary library routes do not grant administrators
implicit cross-user access. Administrators may revoke sessions or disable users.
The PC operator retains physical and operating-system access to stored data.

## Assistants, models, results, and email

Create an assistant with a name, approved results model, and custom instructions.
Choose the transcription model separately. Process opens an assistant picker;
results identify the assistant/model used. Follow-up chat uses that assistant and
the recording's transcript. Regenerate replaces results and starts a new chat.
Instructions, model selection, and chat do not enable external tools.

Edit results before delivery. **Email reviewed results** lets users select notes,
transcript, or both, then opens Apple's Mail composer. The user reviews the
recipient and sends through their approved account. No server SMTP is involved.
Mail accepting a message does not prove recipient delivery.

Audio is retained for replay/reprocessing until deletion. The server retains
encrypted audio parts, which may be converted ten-minute M4A segments for long
recordings. The phone retains original parts as well. A protected local assistant
cache supports selecting an assistant while offline after a successful sync.

Earlier recordings require explicit account assignment. Import preserves existing
transcripts/results and uploads available audio; transcript-only recordings can
be regenerated without inventing missing source audio. External legacy copies
are unaffected. Incomplete recordings need missing audio before processing.

## Processing approval and storage

The OpenAI key remains in the existing external key file. Runtime configuration
contains its path, the approved organization/project, and model allowlists.
The application never returns the key to clients. All new AI requests use
`/v1/audio/transcriptions` and foreground `/v1/responses` with `store:false`.
Conversation history and assistant definitions remain on the PC.

The signed BAA has been verified. On October 2, 2026, the owner confirmed that
retention and PC safeguards are verified for the configured organization/project.
That confirmation is recorded centrally and processing is enabled on this PC.
New installations start with processing blocked until their approvals are recorded.
Users cannot change these approvals. Administrators record evidence under
Organization approval; this does not itself provision OpenAI retention. See
[OpenAI's HIPAA requirements](https://help.openai.com/en/articles/20001069-hipaa-eligible-products-and-functionality)
and [data controls](https://developers.openai.com/api/docs/guides/your-data).

Windows current-user DPAPI encrypts recording content, audio, transcripts, chats,
assistant instructions, and approval evidence before writing them to disk. The
database/runtime folder is restricted to the service user and SYSTEM. Content
does not enter request/access logs. Audit events contain actor/action/record IDs
and timestamps. Passwords use salted scrypt; session/invitation tokens are hashed
on the server. Phone sessions use passcode-bound, device-only Keychain storage.

The PC's OS, patching, recovery, audit oversight, network access policy, device
controls, and backup handling remain the organization's responsibility. Keep
encrypted backups restricted, backed by a recoverable Windows DPAPI profile,
and subject to the organization's deletion/retention process. Application deletion
does not erase exported emails, earlier provider copies, or historical backups.

## Operations and rollback

`scripts/deploy_workspace.ps1 -Version <verified source commit>` installs only
the new workspace module into a versioned release. It leaves the legacy receiver
and its active-release pointer intact. Tailscale routes `/workspace` to loopback
port 8790; its existing `/` handler continues to reach the legacy service.

The **Scribe Pilot Workspace** scheduled task starts a hidden supervisor at the
current service user's logon and restarts the worker after failures. Database
jobs and part checkpoints survive service restarts. Failed jobs require retry;
unfinished uploads resume from retained phone audio while the app is active.
There is no promise of unlimited iOS background execution.

For rollback, restore `previous-source.txt` to `active-source.txt` under the private
workspace directory, then stop only the PID listed in `service.pid` after verifying
its command is `server_workspace.run` for that configuration. The supervisor
restarts the selected version. Preserve the encrypted database; do not substitute
the legacy shared-auth API for account-scoped access.

Local account recovery: from the installed release directory run the existing
Python environment with `-m server_workspace.run --config <private config path>
reset-password --username <username>`. Password entry is hidden and existing
sessions are revoked. Never place a password or key in command arguments.

Deletion persists a tombstone before discarding audio/content, cancels future
processing, and ignores late uploads/results. An already submitted OpenAI request
cannot be recalled. Offline device deletions and session revocations retry when
the PC becomes reachable. The phone hides other accounts' caches immediately.
