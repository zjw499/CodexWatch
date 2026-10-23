# Internet app connection

The native app connects to `https://zwyattpc.tail488e93.ts.net:8443/app`.
Users install Scribe Pilot and sign in or accept their agency invitation. They
need internet connectivity; they do not install or connect to Tailscale.
Tailscale remains installed on the hosting PC for its existing HTTPS Funnel.
The PC must be awake with the storage owner signed in. This does not move
hosting to AWS or change provider processing/retention approval.

Existing production `/workspace` session addresses are mapped to the internet
address at the native request boundary. Tokens, owner bindings, saved assistants,
pending sign-outs and queued audio retain their identities. Requests refuse
redirects. Other organizations' private workspace addresses are not migrated.
The connection address is under advanced settings rather than in the main login
flow. Initial Watch provisioning follows phone sign-in as before; Watch voice
already uses its own internet-accessible listener.

## Server boundary

`public-serve` binds loopback 8793. Funnel adds only the `/app` handler on 8443.
The existing private workspace on 443, voice root on 8443 and isolated review
workspace under `/app-review` keep their routes. The public app uses an explicit
allowlist of native API routes, not the legacy receiver or filesystem. New private
API routes require an allowlist decision before exposure.

The same session, invitation, consent, owner, agency, administrator-review and
audit handlers serve the app. The listener starts no transcription worker and
opens Workspace with `recover_jobs=False`; only the existing private service
recovers and processes recording jobs. Uploads write to the same encrypted store
and durable queue. The organization key stays on the PC.

The protected `public-app.enabled` flag must contain `enabled`. Removing or
disabling it denies new public requests. Request bodies and addresses are bounded,
including chunked requests. Raw media remains streamed through existing encrypted
upload handlers; the existing 100 MB knowledge-file limit and smaller resumable
batches remain supported. Responses disable caching; validation failures do not
echo credentials or content. Access/request-body logging is disabled.

## Deployment and verification

From a clean, verified source commit:

```powershell
./scripts/deploy_workspace.ps1 -Version <source-sha> -InstallAppGateway -AppGatewayOnly -ExposeAppGateway
```

This installs only the separate app task, flag, source pointer and HTTPS path.
It does not restart the private worker or voice gateway. Confirm their PIDs,
active job states and existing HTTPS routes before and after deployment.

Run backend public-boundary and agency tests, native endpoint/session migration
tests, and the existing required build/UI checks. Run the public release-services
workflow with `public_app=true` after deployment: its GitHub runner has no
Tailscale client and must reach app health while anonymous content/admin requests
remain denied. Verify invitation acceptance, upload/replay and explicit audited
review with synthetic content; never put tokens or passwords into workflow inputs
or logs. Publish the native update through the existing gated TestFlight pilot.

## Rollback

Run `scripts/disable_public_app.ps1`. It disables the public-app flag, stops only
the app gateway task/process and removes only `/app`. Existing private/voice
routes, encrypted content and recording jobs remain available. Restore
`app-previous-source.txt` to `app-active-source.txt` to select an earlier gateway
release; do not reset the database or repoint the private worker.
