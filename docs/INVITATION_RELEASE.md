# Scribe Pilot invitation release

The initial App Store target is an unlisted, manually released app. Installation
requires its link; using the service requires an agency invitation and account.
An unlisted link is shareable, so authorization is enforced by the backend.

## Agency access

Existing accounts and content migrate into **Sky Data Services** without changing
encrypted content or ownership. The first active administrator becomes the platform
operator. Each account has one agency; usernames are unique across the service.
The operator creates agencies and their first administrator invitations in Settings
> Administrator workspace > Manage agencies. Agency administrators invite members,
revoke sessions, disable accounts and review content within their own agency.
They cannot alter OpenAI or global voice policy, administer the platform owner,
or review another agency's records. Platform operator status does not grant review
access to another agency's content through application endpoints.

Invitations expire after seven days and work once. Share them through an approved
channel; the app's Share invitation action lets the administrator choose it.
There is no automatic email sender and no API key per app user.

## Production OpenAI credential

The project-owned service account is `scribe-pilot-production` in the existing
approved project. Its tracking ID is `key_A2LSylz4nbxrptml`. Its restricted key permits
model listing and model requests; Files, Threads, vector stores, fine tuning, agents
and other management resources are disabled. The key is outside Git and client apps,
under the protected runtime directory. Do not copy it into a build, browser app,
support message, CI log or screenshot. Rotation must validate Responses,
transcription and Realtime before changing the configured key file. Do not revoke
an old personal key until its other workloads have been identified.

The approved organization/project and retention setting do not establish compliance
for the app, devices, hosting, backups, exports or each agency agreement. The API
project uses approved Modified Retention, not zero data retention.

## Consent and deletion

The new phone app requires disclosure acceptance before AI processing. New backend
installations enforce it with `require_ai_consent=true`. An existing installation
must update the paired app before that server flag is enabled; otherwise older
clients cannot reach the new consent screen. Do not release to external agency
users until server enforcement is enabled and verified. Consent is versioned;
withdrawal revokes Watch tokens, ends sessions and cancels queued processing.

Ordinary account deletion checks the current password, revokes sessions, erases
active encrypted content and retains identifier-only tombstones/security audit.
Phone and Watch queues persist deleted-owner markers so late transfers cannot
restore content. The Watch applies deletion when it reconnects. The platform owner
starts a durable support request and transfers ownership before deletion finishes.
Backups and exports have separate retention; confirm agency retention obligations
before onboarding clinical records. There is no automatic legal-hold workflow.

## Release evidence and remaining gates

`release/app-store-metadata.json`, `release/review-notes.txt` and
`release/unlisted-request.txt` contain submission material. The public pages are
exported from the backend source with:

```powershell
$env:PYTHONPATH='D:\CodexWatch'
& 'D:\watch-audio-pipeline\.venv\Scripts\python.exe' scripts\export_release_pages.py --out release\public\scribe-pilot
```

The company website serves those static pages only; workspace content does not go
to that website. Keep its current production source unchanged when adding pages.

Before App Review: confirm the legal-entity seller, privacy and age ratings, category,
review credentials and reachable synthetic-data-only backend, signed archive and
screenshots, consent enforcement, operational backup/deletion practices, and physical
device acceptance for enabled features. Run the existing native verification and
signed-archive workflows for the exact source. Keep manual release selected. Submit
the completed app, then request unlisted distribution; Apple decides approval.

Official references: [unlisted distribution](https://developer.apple.com/support/unlisted-app-distribution/),
[review guidelines](https://developer.apple.com/app-store/review/guidelines/),
[account deletion](https://developer.apple.com/help/app-review/guideline-reference/5-1-1-account-deletion),
[privacy details](https://developer.apple.com/app-store/app-privacy-details/).
