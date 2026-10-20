# Apple account findings - October 20, 2026

Live Apple Developer membership: **Individual**, seller **Zachary Wyatt**.
Team ID: `HQURNU73BB`. App Store Connect app: `6789821399`.

Apple's [review guidance](https://developer.apple.com/app-store/review/)
calls for a legal-entity seller for sensitive-information/healthcare apps. The
current seller therefore needs to be resolved before submitting this healthcare
release. The owner supplied a filed October 20 reinstatement for SKY DATA SERVICES
LLC. Florida's live registry now confirms ACTIVE status and the reinstatement date.
The verified legal name and D-U-N-S number are entered in Apple's conversion form.
Dun & Bradstreet's direct lookup and email confirmed the number on October 20.
The original October 8, 2025 Articles of Organization were downloaded from Sunbiz
and visually inspected; they list the owner as an initial authorized member.
Florida's fictitious-name search found no registration linked to the LLC, and
the signed-in Apple account shows only the existing Individual team. These records
support the prepared founder/cofounder, no-DBA and no-separate-membership answers.
The Tax ID type associated with the current Individual membership is not displayed
in the accessible account pages. The owner approved submission of the prepared
membership-change request, but Apple requires the Tax ID-type answer before it
will accept the form. That factual answer remains pending; no actual Tax ID is
needed for this form.
The filing images, addresses, D-U-N-S lookup email and tax identifier are not
included in this repository.

For an existing registered organization, the founder/cofounder can request an
[individual-to-organization membership update](https://developer.apple.com/help/account/membership/updating-your-account-information/).
Apple asks for the organization's D-U-N-S number and may request business documents.
No conversion request or corporate registration has been submitted by this task.

The owner explicitly authorized acceptance of the updated Apple Developer Program
License Agreement on October 20, 2026. It was accepted through the account's Agree
control; the update warning and Review agreement control remained absent after a
fresh account reload. The account remains enrolled as Individual, so this does
not complete organization conversion.

Store preparation completed: Scribe Pilot name/subtitle; Medical/Productivity
categories; description, keywords, support/privacy/deletion links; manual release;
18+ age override (17+ on earlier operating systems), free download and United States
availability only. Mac and Vision Pro distribution are disabled. The app's intended function
is transcription and reviewed documentation, without independent diagnosis,
treatment or physiological monitoring. Apple medical-device declaration was
saved as No on that product scope; this is not regulatory clearance. Reassess
the declaration if clinical decision-making functionality or intended use changes.

App privacy: nine categories are published as linked to the account, used for app
functionality, and not used for tracking. The owner explicitly authorized Apple's
accuracy and applicable-law attestation before publication on October 20, 2026.

A separate synthetic-only review service now has a public HTTPS route, protected
review credentials and server-enforced consent. Live transcription and summary
processing passed with a synthetic recording; an external runner verified public
reachability and denied unauthenticated account/content/admin requests. The
production private-network workspace and its data were kept separate.

Keep the version on manual release until seller/account requirements, operational
and physical-device acceptance, App Review and Apple's unlisted approval are
complete. The owner reported updating both paired apps. Production consent
enforcement is now enabled, both services restarted successfully, and their health
endpoints returned 200. A live synthetic request referencing no existing recording
was rejected with 409 by the consent gate, without reading content or calling a
provider. The owner's acceptance receipt and matching consent audit event are now
recorded for version 2026-10-20. Live HTTPS /api/me reports consent_required=false
while server enforcement remains enabled. A second request referencing a
nonexistent recording passed the consent gate and returned 404, without reading
content or making a provider call. Both service health checks remain 200.
Existing proxy routes and the production service-account key were preserved.

Build 1.0 (168) has passed native verification and Apple's processing and is Testing
in the existing internal TestFlight group. It is selected in the App Store draft.
App Review instructions and the published company phone/Scribe Pilot support email
are saved. The owner authorized storing the synthetic-review account credentials
in Apple's protected review fields. Both fields were saved and remained populated
after reloading the draft; credentials are not included in this repository.

Content Rights is saved as having the necessary rights to third-party content,
following the owner's explicit confirmation that agencies will process only
authorized recordings and reference material. That authorization does not come
from an OpenAI BAA or a working API connection.

All six inspected screenshots are saved in App Store Connect. Native verification,
signed archive/upload, external release services and iPad capture workflows passed.
