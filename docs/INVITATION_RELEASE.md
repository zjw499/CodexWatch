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

Production enforcement was enabled on October 20 after the owner reported updating
the paired apps. The workspace and voice gateway both returned healthy after
restart. An authenticated request using a nonexistent recording was denied with
409 at the consent gate before content access or a provider call. The owner account
subsequently accepted disclosure version 2026-10-20 in the app. Its receipt and audit
event were verified, and the live API now reports consent_required=false while
enforcement remains enabled. A nonexistent-record probe passed consent checking
and returned 404 without content access or a provider call. No acceptance was
inserted by release tooling.

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

The October 20 review environment uses a separate SQLite database with DPAPI-protected
content fields at
`D:\watch-audio-pipeline\.runtime\scribe-app-review`, served by the separate
`Scribe Pilot Apple Review` scheduled task on loopback port 8792. Only
`https://zwyattpc.tail488e93.ts.net:8443/app-review` routes to it. No production
content or sessions were copied. Review credentials are stored in the restricted
directory as `review-credentials.dpapi`; enter them only in Apple's protected
review fields. Review accounts are scoped to the synthetic review agency and are
not platform operators. The review server enforces AI consent and disables voice.
Existing private workspace, legacy upload, voice and other proxy routes were
compared with the saved route configuration and remain unchanged.

A synthetic spoken recording passed upload, OpenAI transcription and summary
generation. The disclosure was reset so the reviewer must explicitly consent.
The public policy pages and review health/authentication boundary passed the
external [release service check](https://github.com/zjw499/CodexWatch/actions/runs/39372143037).
The signed [build 167 archive](https://github.com/zjw499/CodexWatch/actions/runs/39371362304)
passed validation with matching privacy manifests in all three app bundles. This
archive-only run did not upload to TestFlight or establish physical-device acceptance.

The subsequent [build 168 pilot](https://github.com/zjw499/CodexWatch/actions/runs/39372248203)
uploaded successfully, reached VALID with export compliance complete, and appears
as Testing in the existing Personal Internal Testing group. Native verification
passed 101 unit tests and 5 interface tests, in addition to 184 backend tests and
10 release-gate tests. Build 168 is selected in the manually released App Store
draft. This establishes internal beta availability; App Review and unlisted
approval have not been submitted or granted.

`release/screenshots/manifest.json` records six inspected, unedited synthetic-data
screenshots: three iPhone, one iPad and two Watch. The iPad capture comes from the
verified simulator app, with [separate capture evidence](https://github.com/zjw499/CodexWatch/actions/runs/39372701669).
`release/testflight-notes.txt` contains the saved pilot testing instructions.

Apple's nine-category privacy declaration is published with the owner's approval.
Content Rights is saved following confirmation of authorized content only. The
synthetic review login is saved in Apple's protected fields and remained populated
after a draft reload. Credentials stay outside the repository. The owner confirmed
a registered LLC/corporation and supplied a filed reinstatement for SKY DATA
SERVICES LLC. Florida's live registry confirms ACTIVE status as of October 20.
Apple's seller is still Individual pending membership conversion. The company
D-U-N-S number has been retrieved directly from Dun & Bradstreet and entered in
the submitted conversion form. Original formation records and available Apple
teams were checked. After the owner approved submission and supplied the remaining
required answer, Apple accepted the conversion request on October 20, 2026 and
stated it would respond within one business day. Conversion approval remains
pending. The updated Apple
Developer Program License Agreement was accepted with separate owner approval;
its warning remained cleared after a fresh account reload.

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
