# OpenAI recording workflow

Scribe Pilot captures on iPhone or Watch, saves a durable queue on the phone, and processes complete recordings directly with OpenAI. The queue supports renaming, processing, retrying, selecting multiple items, and removing audio and transcripts. The Watch has capture, recording queue, and processing status pages.

New recordings do not use the old PC/Groq/Notion/email pipeline. Previous PC meetings remain accessible from Settings and retain their original delivery/privacy settings. An upload that was already sent cannot be recalled.

## Configuration on iPhone

Settings provides a secure API key field, transcription model, optional project/organization IDs, a content-free connection check, review/automatic processing, meeting notes, and audio cleanup. Keys use `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` in Keychain. No key is bundled in the binary, sent to the Watch, or stored in UserDefaults. Users supply the key on the phone; development environment credentials are not distributed to devices or beta testers.

Protected workflow is enabled by default. Processing is blocked until the user confirms the organization's executed OpenAI BAA, approved retention configuration for the selected project, and device/access safeguards. These are user attestations, not independent verification. Changing the key, project, or organization clears the draft attestations. The connection check verifies key/model access only. Protected mode requires device authentication to open the app and locks again after backgrounding. Inactive screens conceal recording contents.

HIPAA eligibility depends on the actual BAA and account configuration. Code/toggles cannot establish a BAA or activate Modified Retention. Deployment must still follow organizational safeguards, access policies, retention policies, and risk assessment. See [OpenAI HIPAA eligible products](https://help.openai.com/en/articles/20001069-hipaa-eligible-products-and-functionality) and [API data controls](https://developers.openai.com/api/docs/guides/your-data).

## Data handling

- Audio and transcripts use Apple file protection after first unlock and are excluded from device/cloud backups. Durable transcription checkpoints survive interrupted processing.
- The API host is fixed to `https://api.openai.com`. Audio uses `/v1/audio/transcriptions`; optional notes use `/v1/responses` with `store: false`. Provider errors expose safe status descriptions without response content.
- Audio parts below 24 MiB are sent directly. Larger phone recordings are exported into ten-minute M4A parts, each checked against the upload limit. Watch recordings wait for every index from zero through the final part.
- Audio cleanup is enabled by default. After saving a transcript, the phone deletes its audio and queues Watch cleanup. Offline Watch cleanup takes effect after reconnecting.
- Removal persists a tombstone, cancels processing/retry work, deletes saved audio/transcript, and queues companion removal. Late chunks/provider responses cannot recreate a removed item. Removal cannot undo an API request already sent.
- Automatic processing is off by default. iOS may suspend long requests; the recording and completed checkpoints remain queued for explicit retry.
- No recording/transcript is logged, automatically emailed, or sent to Gemini. Sharing is an explicit user action; its destination must satisfy organizational requirements.

## Verification

Native tests check persistent deletion, duplicate/out-of-order transfers, missing parts, corrupted storage, resume checkpoints, protected setup, API host/project scoping, safe provider errors, and disabled Responses storage. UI tests exercise queue rename/removal and capture screenshots. `.github/workflows/native-verify.yml` compiles both apps on macOS and runs iPhone simulator tests. Non-sensitive preview fixtures are Debug-only and require `-scribe-ui-preview`.
