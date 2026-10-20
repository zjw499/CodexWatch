# Apple account findings - October 20, 2026

Live Apple Developer membership: **Individual**, seller **Zachary Wyatt**.
Team ID: `HQURNU73BB`. App Store Connect app: `6789821399`.

Apple's [review guidance](https://developer.apple.com/app-store/review/)
calls for a legal-entity seller for sensitive-information/healthcare apps. The
current seller therefore needs to be resolved before submitting this healthcare
release. The exact registered company name and its legal-entity status are not
established by the app's brand or the OpenAI organization name.

For an existing registered organization, the founder/cofounder can request an
[individual-to-organization membership update](https://developer.apple.com/help/account/membership/updating-your-account-information/).
Apple asks for the organization's D-U-N-S number and may request business documents.
No conversion request or corporate registration has been submitted by this task.

The account also displays an updated Apple Developer Program License Agreement
requiring Account Holder review/acceptance, with an October 28, 2026 deadline to
maintain membership-resource access. The Business page says agreement acceptance
is required to update existing apps or submit new apps. No agreement was accepted.

Store preparation completed: Scribe Pilot name/subtitle; Medical/Productivity
categories; description, keywords, support/privacy/deletion links; manual release;
18+ age override (17+ on earlier operating systems), free download and United States
availability only. Mac and Vision Pro distribution are disabled. The app's intended function
is transcription and reviewed documentation, without independent diagnosis,
treatment or physiological monitoring. Apple medical-device declaration was
saved as No on that product scope; this is not regulatory clearance. Reassess
the declaration if clinical decision-making functionality or intended use changes.

App privacy: nine categories are configured as linked to the account, used for app
functionality, and not used for tracking. Final publication has an Apple accuracy
and applicable-law attestation and is awaiting user confirmation.

A separate synthetic-only review service now has a public HTTPS route, protected
review credentials and server-enforced consent. Live transcription and summary
processing passed with a synthetic recording; an external runner verified public
reachability and denied unauthenticated account/content/admin requests. The
production private-network workspace and its data were kept separate.

Keep the version on manual release until native/archive checks, updated-device
consent enforcement, review credentials entered in Apple, seller/account
requirements and Apple's unlisted approval are complete. The existing production
server's consent flag remains off for old-client compatibility until the updated
paired app is installed; external agency onboarding must wait for that flag to be
enabled and verified.
