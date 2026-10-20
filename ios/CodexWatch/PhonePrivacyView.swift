import SwiftUI

struct WorkspaceDisclosure: Decodable {
    let version: String
    let provider: String
    let text: String
    let privacy_url: String
    let support_url: String
    let deletion_url: String
    let support_email: String
}

struct WorkspaceDeletion: Decodable {
    let id: String
    let status: String
    let support_email: String?
}

extension PhoneWorkspace {
    func updateProcessingConsent(accepted: Bool) async throws {
        guard let disclosure else { throw WorkspaceError.server }
        struct Body: Encodable { let version: String; let accepted: Bool }
        struct Receipt: Decodable { let accepted: Bool }
        let _: Receipt = try await request("account/consent", method: "POST",
            body: JSONEncoder().encode(Body(version: disclosure.version, accepted: accepted)))
        await refresh()
    }

    func deleteMyAccount(password: String) async throws -> WorkspaceDeletion {
        guard let owner = user?.id, !PhoneRecorderService.shared.isRecording else { throw RecordingQueueError.stillRecording }
        struct Body: Encodable { let password: String; let confirmation = "DELETE" }
        let result: WorkspaceDeletion = try await request("account/deletion", method: "POST",
            body: JSONEncoder().encode(Body(password: password)))
        guard result.status == "completed" else { return result }
        // A durable receipt lets a later launch finish device cleanup if the app
        // is interrupted after the server has confirmed deletion.
        try WorkspaceKeychain.save(owner, account: "deleted-account-cleanup")
        try finishDeletedAccountCleanup(owner)
        try await signOut()
        return result
    }

    func finishDeletedAccountCleanup(_ owner: String) throws {
        let queue = RecordingQueueStore.shared
        let ids = Set(queue.recordings.filter { $0.ownerID == owner }.map(\.id))
        PhoneOpenAIService.shared.configurationChanged()
        try queue.deleteAccount(owner)
        PhoneUploadService.shared.discardSavedRecordings(ids)
        let cache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScribePilot", isDirectory: true).appendingPathComponent("assistants-\(owner).json")
        if FileManager.default.fileExists(atPath: cache.path) { try FileManager.default.removeItem(at: cache) }
        for prefix in ["ScribePilot.Assistant.", "ScribePilot.Transcription.", "ScribePilot.TranscriptionContext.", "ScribePilot.VoiceRepairRequests."] {
            UserDefaults.standard.removeObject(forKey: prefix + owner)
        }
        VoiceDescriptorCache.clear()
        try? WorkspaceKeychain.remove(account: "watch-voice")
        syncWatchAccount()
        try WorkspaceKeychain.remove(account: "deleted-account-cleanup")
    }
}

struct PhonePrivacyView: View {
    @ObservedObject private var workspace = PhoneWorkspace.shared
    @EnvironmentObject private var recorder: PhoneRecorderService
    @State private var password = ""
    @State private var consentChecked = false
    @State private var confirmingDeletion = false
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        Form {
            Section("Privacy") {
                Link("Privacy policy", destination: publicURL("privacy"))
                Link("Support", destination: publicURL("support"))
                Text("Your agency administrators can review records within your agency. Use only information your agency authorizes.")
                    .font(.footnote).foregroundStyle(ScribeTheme.muted)
            }
            if workspace.signedIn {
                Section("OpenAI processing permission") {
                    if let disclosure = workspace.disclosure {
                        Text(disclosure.text).font(.footnote)
                        Text("Disclosure version: \(disclosure.version)").font(.caption).foregroundStyle(ScribeTheme.muted)
                        if workspace.consentRequired {
                            Toggle("I understand and allow this information to be sent to OpenAI when I request AI processing", isOn: $consentChecked)
                                .accessibilityIdentifier("ai-processing-permission")
                            Button("Allow AI processing") { run { try await workspace.updateProcessingConsent(accepted: true) } }
                                .disabled(!consentChecked || busy)
                        } else {
                            Label("Permission accepted", systemImage: "checkmark.shield")
                            Button("Withdraw AI processing permission", role: .destructive) {
                                run { try await workspace.updateProcessingConsent(accepted: false); consentChecked = false }
                            }.disabled(busy || recorder.isRecording)
                        }
                    } else {
                        Text("Connect to your workspace to load the processing disclosure.")
                        Button("Refresh disclosure") { run { await workspace.refresh() } }.disabled(busy)
                    }
                    Text("Transcripts and responses are drafts. Review and correct them before using them in clinical documentation. Withdrawing permission stops new AI requests and cancels queued processing; previously submitted requests cannot be recalled.")
                        .font(.footnote).foregroundStyle(ScribeTheme.muted)
                }
                Section("Delete account") {
                    Text("This removes your account and its active recordings, transcripts, results, reference files and conversations from the service. Phone copies are removed after confirmation; your Watch receives the removal when it reconnects. Minimal security records and deletion markers remain. Previously exported copies and historical backups are not recalled.")
                        .font(.footnote)
                    if workspace.user?.isOperator == true {
                        Text("As platform operator, your request starts an ownership-transfer process with support before account deletion can finish.").font(.footnote)
                    }
                    SecureField("Confirm your account password", text: $password).textContentType(.password)
                    Button("Delete account", role: .destructive) { confirmingDeletion = true }
                        .disabled(password.isEmpty || busy || recorder.isRecording)
                    Link("Account deletion details", destination: publicURL("account-deletion"))
                }
            }
            if let message { Section { Text(message).font(.footnote).textSelection(.enabled) } }
        }
        .scrollContentBackground(.hidden).background(ScribeTheme.background).tint(ScribeTheme.red)
        .navigationTitle("Privacy and account").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete your Scribe Pilot account?", isPresented: $confirmingDeletion, titleVisibility: .visible) {
            Button("Delete account and content", role: .destructive) {
                run {
                    defer { password = "" }
                    let result = try await workspace.deleteMyAccount(password: password)
                    message = result.status == "completed" ? "Your account and active content have been deleted." :
                        "Deletion request \(result.id) is saved. Contact \(result.support_email ?? "support") to transfer platform ownership and complete deletion."
                }
            }
        } message: { Text("This action cannot be undone. Finish any recording before continuing.") }
        .onDisappear { password = "" }
    }

    private func publicURL(_ path: String) -> URL {
        URL(string: "https://www.skydataservice.com/scribe-pilot/\(path).html")!
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        busy = true; message = nil
        Task { defer { busy = false }; do { try await operation() } catch { message = error.localizedDescription } }
    }
}
