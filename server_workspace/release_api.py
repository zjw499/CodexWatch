"""Public disclosures and authenticated agency/account release endpoints."""
from __future__ import annotations

from html import escape

from fastapi import Depends
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field

from .identity import CONSENT_VERSION


DISCLOSURE = (
    "When you choose Process or start an assistant conversation, Scribe Pilot sends "
    "the relevant recording audio, transcript, conversation, and any selected assistant "
    "reference material to OpenAI to produce a transcript or draft response. Sky Data "
    "Services operates the service for your agency. OpenAI processes this information "
    "under the organization's API agreement and approved retention settings. This is "
    "not a promise of zero data retention. Only submit information your agency authorizes "
    "you to process. Review and correct every generated clinical draft before use."
)


class AgencyBody(BaseModel):
    model_config = {"extra": "forbid"}
    name: str = Field(min_length=2, max_length=100)


class AgencyInvitationBody(BaseModel):
    model_config = {"extra": "forbid"}
    username: str = Field(min_length=3, max_length=64)
    role: str = "admin"


class ConsentBody(BaseModel):
    model_config = {"extra": "forbid"}
    version: str = Field(max_length=30)
    accepted: bool


class DeleteAccountBody(BaseModel):
    model_config = {"extra": "forbid"}
    password: str = Field(min_length=1, max_length=256)
    confirmation: str = Field(pattern="^DELETE$")


def document(title, body, support_email):
    contact = escape(support_email, quote=True)
    return ("<!doctype html><html lang='en'><meta charset='utf-8'>"
            "<meta name='viewport' content='width=device-width,initial-scale=1'>"
            f"<title>{escape(title)} | Scribe Pilot</title><style>"
            "body{font:17px/1.65 system-ui,sans-serif;max-width:760px;margin:48px auto;padding:0 24px;color:#20252b}"
            "h1,h2{line-height:1.25}h2{margin-top:2em}a{color:#a41e28}footer{margin-top:3em;border-top:1px solid #ddd;padding-top:1em}"
            "</style><main><p>Sky Data Services</p>"
            f"<h1>{escape(title)}</h1>{body}</main><footer>"
            f"<a href='mailto:{contact}'>Contact Sky Data Services</a></footer></html>")


def install_release_routes(app, workspace, account, admin, operator):
    @app.get("/api/disclosure")
    def disclosure():
        base = workspace.config.public_base_url.rstrip("/")
        return {"version": CONSENT_VERSION, "provider": "OpenAI", "text": DISCLOSURE,
                "privacy_url": base + "/privacy", "support_url": base + "/support",
                "deletion_url": base + "/account-deletion", "support_email": workspace.config.support_email}

    @app.get("/privacy", response_class=HTMLResponse)
    def privacy():
        return document("Scribe Pilot Privacy Policy", """
        <p>Effective October 20, 2026. Scribe Pilot is an invitation-only recording,
        transcription, and documentation service operated by Sky Data Services for
        authorized agency users.</p>
        <h2>Information processed</h2><p>The service processes your account and agency
        membership, voice recordings, transcripts, assistant instructions and reference
        files you select, generated drafts, conversations, and limited security and
        operational records. Recordings may contain patient or other sensitive information.
        Submit only information you are authorized to use.</p>
        <h2>Purpose and access</h2><p>Information is used to provide the features you
        request, administer your agency workspace, protect accounts, and respond to support
        requests. Agency administrators can review records within their agency. Authorized
        service operators can access infrastructure for support and security; access is
        restricted. Routine application logs do not include recording or transcript bodies.</p>
        <h2>OpenAI processing</h2><p>When you request AI processing, relevant audio,
        transcripts, selected reference material, and conversation context are sent to
        OpenAI through the approved API organization and project. The app asks you to
        accept the processing disclosure. Responses requests disable application storage.
        OpenAI's approved Modified Retention setting may still retain encrypted
        abuse-monitoring data. This service does not promise zero data retention. API
        input/output sharing for model training is disabled in the configured organization.</p>
        <h2>Storage and retention</h2><p>Saved audio, transcripts, results and reference
        files are encrypted on the service and protected on supported devices. They remain
        available until deleted through the service. Deleted content is removed from active
        storage; minimal identifier-only tombstones and security audit events remain to
        prevent resurrection and document access. Historical backups and previously
        exported copies are subject to their separate retention and access controls.
        Deleting an app alone does not delete the service account or server records.</p>
        <h2>Your controls</h2><p>You can remove recordings and reference files, withdraw
        AI-processing permission, sign out, and initiate account deletion in Settings.
        Withdrawing permission stops new AI requests, but cannot recall information already
        submitted. Account deletion requires password confirmation. A platform operator
        must transfer infrastructure ownership before deletion can be completed.</p>
        <h2>Sharing and other services</h2><p>We do not sell this information or use it
        for targeted advertising. Choosing to export, copy or email content sends it to
        destinations you select; your agency must authorize those destinations. The app
        does not automatically send recordings to Notion, Gemini or a server mail service.
        Do not include patient information in support messages.</p>
        <h2>Clinical use</h2><p>AI results are drafts and may be inaccurate or incomplete.
        An authorized clinician must verify the source and correct the draft before using
        it in documentation or care. Scribe Pilot does not independently diagnose, recommend
        treatment or replace clinical judgment.</p>
        <h2>Changes and contact</h2><p>Material changes to AI processing require a new
        disclosure version. Use the contact link below for privacy, access, deletion or
        security questions. This policy does not replace your agency's privacy obligations
        or its agreements with Sky Data Services.</p>""", workspace.config.support_email)

    @app.get("/support", response_class=HTMLResponse)
    def support():
        return document("Scribe Pilot Support", """
        <p>Scribe Pilot is available to invited agency users. Ask your agency administrator
        for an invitation and access to the approved service.</p>
        <h2>Getting started</h2><ol><li>Install Scribe Pilot on your iPhone and paired
        Apple Watch.</li><li>In Settings choose Accept invitation, enter the invitation code
        and choose your password.</li><li>Review the privacy policy and processing disclosure
        before sending information for AI processing.</li><li>Record on either device,
        select the recording and choose Process. Review and edit the generated draft.</li></ol>
        <h2>Help with access or recordings</h2><p>Contact your agency administrator for
        invitation, membership or password help. Contact Sky Data Services using the link
        below for technical support. Include the app version, device type, approximate
        time and a short description. Do not send patient information, recordings,
        transcripts, passwords or API keys.</p>
        <h2>Connection interruptions</h2><p>Keep queued recordings until processing is
        complete. Reconnect to the service and retry the affected item. An offline Watch
        may need time to reconnect with the phone before its saved audio transfers.</p>
        <h2>Account deletion</h2><p>Open Settings, Privacy and account, then Delete account.
        Follow the confirmation steps. Uninstalling the app or signing out does not delete
        your account. See the account-deletion information page for details.</p>""", workspace.config.support_email)

    @app.get("/account-deletion", response_class=HTMLResponse)
    def deletion_information():
        return document("Account deletion", """
        <p>In Scribe Pilot open Settings, Privacy and account, then Delete account.
        Confirm your password and the deletion action. This deletes your active account,
        recordings, transcripts, results, assistant files and saved conversations, and
        revokes phone and Watch sessions. Minimal pseudonymous security audit records and
        deletion tombstones remain. Previously exported copies and historical backups
        are not recalled by this action.</p>
        <p>If you own the service's platform-operator account, initiate the request in
        the app and contact support to transfer infrastructure ownership first. If you
        cannot sign in, use the support contact below. Do not include patient information.</p>""", workspace.config.support_email)

    @app.get("/api/operator/agencies")
    def agencies(user=Depends(operator)):
        with workspace.db() as db:
            return {"agencies": [dict(r) for r in db.execute("SELECT a.*,COUNT(u.id) AS member_count FROM agencies a LEFT JOIN users u ON u.agency_id=a.id AND u.active=1 GROUP BY a.id ORDER BY a.name")]}

    @app.post("/api/operator/agencies")
    def create_agency(body: AgencyBody, user=Depends(operator)):
        return workspace.access.create_agency(body.name, user)

    @app.post("/api/operator/agencies/{agency_id}/invitations")
    def agency_invitation(agency_id: str, body: AgencyInvitationBody, user=Depends(operator)):
        return workspace.invite(body.username, body.role, user["id"], agency_id=agency_id)

    @app.post("/api/account/consent")
    def consent(body: ConsentBody, user=Depends(account)):
        return workspace.access.consent(user, body.version, body.accepted)

    @app.post("/api/account/deletion")
    def delete_account(body: DeleteAccountBody, user=Depends(account)):
        return workspace.access.delete_account(user, body.password)
