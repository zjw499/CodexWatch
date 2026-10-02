import SwiftUI

struct PhoneSettingsView: View {
    @EnvironmentObject private var settings: PhoneOpenAISettings
    @Environment(\.dismiss) private var dismiss
    @State private var draft = OpenAIConfiguration()
    @State private var key = ""
    @State private var errorMessage: String?
    @State private var testing = false
    @State private var accessResult: String?
    @State private var confirmingKeyRemoval = false
    @State private var loaded = false

    var body: some View {
        settingsForm
            .scrollContentBackground(.hidden).background(ScribeTheme.background).tint(ScribeTheme.red)
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { key = ""; dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save", action: save).fontWeight(.semibold).disabled(testing)
                }
            }
            .task { draft = settings.configuration; loaded = true }
            .onChange(of: key) { _, _ in if loaded { resetConfirmations() } }
            .onChange(of: draft.projectID) { _, value in
                if loaded && value != settings.configuration.projectID { resetConfirmations() }
            }
            .onChange(of: draft.organizationID) { _, value in
                if loaded && value != settings.configuration.organizationID { resetConfirmations() }
            }
            .onChange(of: draft.retention) { _, value in
                if loaded && value != settings.configuration.retention { draft.retentionConfirmed = false }
            }
            .confirmationDialog("Remove your saved key?", isPresented: $confirmingKeyRemoval, titleVisibility: .visible) {
                Button("Remove key", role: .destructive, action: removeKey)
            } message: { Text("Saved recordings are kept. Processing will pause until a key is configured.") }
            .alert("OpenAI settings", isPresented: errorPresented) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "Please try again.") }
            .onDisappear { key = "" }
    }

    private var settingsForm: some View {
        Form {
            introduction
            connection
            privacy
            workflow
            previousWorkspace
            if settings.hasKey {
                Section { Button("Remove saved OpenAI key", role: .destructive) { confirmingKeyRemoval = true } }
            }
        }
    }
    private var introduction: some View {
        Section {
            Label("OpenAI on your iPhone", systemImage: "waveform").font(.headline)
            Text("Your Watch sends audio to this iPhone. Recordings are processed directly with OpenAI and saved here.")
                .font(.footnote).foregroundStyle(ScribeTheme.muted)
        }
    }
    private var connection: some View {
        Section {
            SecureField(settings.hasKey ? "Replace saved API key" : "OpenAI API key", text: $key)
                .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
            if settings.hasKey {
                Label("Key saved in this iPhone's Keychain", systemImage: "key.fill")
                    .font(.footnote).foregroundStyle(ScribeTheme.muted)
            }
            Picker("Transcription model", selection: $draft.model) {
                Text("Mini · efficient").tag("gpt-4o-mini-transcribe")
                Text("Full · higher accuracy").tag("gpt-4o-transcribe")
                Text("GPT Transcribe").tag("gpt-transcribe")
            }
            TextField("Project ID (optional)", text: $draft.projectID)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Organization ID (optional)", text: $draft.organizationID)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button(action: testConnection) {
                HStack {
                    Label("Test connection", systemImage: "antenna.radiowaves.left.and.right")
                    Spacer()
                    if testing { ProgressView() }
                }
            }.disabled(testing || (!settings.hasKey && key.isEmpty))
            if let accessResult { Text(accessResult).font(.footnote).foregroundStyle(ScribeTheme.muted) }
        } header: { Text("OpenAI connection") } footer: {
            Text("Keys are never embedded in the app, sent to the Watch, or included in backups. A connection test sends no recording or transcript.")
        }
    }
    private var privacy: some View {
        Section {
            Toggle("Protected workflow", isOn: $draft.protectedMode)
            if draft.protectedMode {
                Toggle("My organization has a signed OpenAI BAA", isOn: $draft.baaConfirmed)
                Picker("Approved account retention", selection: $draft.retention) {
                    Text("Modified Retention").tag("Modified Retention")
                    Text("Zero Data Retention").tag("Zero Data Retention")
                }
                Toggle("Retention is approved for this project", isOn: $draft.retentionConfirmed)
                Toggle("Device and access safeguards are approved", isOn: $draft.safeguardsConfirmed)
                Text("Processing stays blocked until all three confirmations are provided. This app cannot verify agreements or OpenAI account retention; these confirmations must match your organization's actual approval.")
                    .font(.footnote).foregroundStyle(ScribeTheme.muted)
            } else {
                Text("Use this setting only for recordings that do not contain protected health information.")
                    .font(.footnote).foregroundStyle(ScribeTheme.muted)
            }
            Link("OpenAI HIPAA requirements", destination: URL(string: "https://help.openai.com/en/articles/20001069-hipaa-eligible-products-and-functionality")!)
        } header: { Label("Privacy & safeguards", systemImage: "lock.shield") }
    }
    private var workflow: some View {
        Section("Recording workflow") {
            Toggle("Process automatically after recording", isOn: $draft.automaticProcessing)
            Toggle("Create meeting notes", isOn: $draft.createNotes)
            Toggle("Delete audio after processing", isOn: $draft.deleteAudioAfterProcessing)
            Text(draft.automaticProcessing
                 ? "Complete recordings process when OpenAI setup is ready. Keep the app open for long recordings."
                 : "Review, rename, or remove a recording in your queue before tapping Process.")
                .font(.footnote).foregroundStyle(ScribeTheme.muted)
            Text("Meeting notes use OpenAI with response storage disabled. Transcripts stay on this device. Audio cleanup also removes the saved Watch copy after it reconnects.")
                .font(.footnote).foregroundStyle(ScribeTheme.muted)
        }
    }
    private var previousWorkspace: some View {
        Section("Previous workspace") {
            NavigationLink { PhoneArchiveView() } label: { Label("Open previous PC meetings", systemImage: "archivebox") }
            Text("Older PC, email, and Notion copies remain in their original destinations. New recordings use the OpenAI workflow above.")
                .font(.footnote).foregroundStyle(ScribeTheme.muted)
        }
    }
    private var errorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }
    private func save() {
        do { try settings.save(draft, newKey: key); key = ""; dismiss() }
        catch { errorMessage = error.localizedDescription }
    }
    private func removeKey() {
        do { try settings.removeKey(); key = ""; draft = settings.configuration }
        catch { errorMessage = error.localizedDescription }
    }
    private func testConnection() {
        testing = true; accessResult = nil
        Task {
            defer { testing = false }
            do {
                let supplied = key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let credential = supplied.isEmpty ? OpenAIKeychain.read() : supplied, !credential.isEmpty else {
                    throw OpenAIError.invalidKey
                }
                try await PhoneOpenAIClient().testAccess(key: credential, configuration: draft)
                accessResult = "Connection works. This check does not verify your BAA or retention settings."
            } catch { errorMessage = error.localizedDescription }
        }
    }
    private func resetConfirmations() {
        draft.baaConfirmed = false; draft.retentionConfirmed = false; draft.safeguardsConfirmed = false
        accessResult = nil
    }
}

struct PhoneArchiveView: View {
    @EnvironmentObject private var memoService: PhoneMemoService
    var body: some View {
        List {
            Section {
                Text("These are your earlier PC recordings. Their original delivery and privacy settings apply.")
                    .font(.footnote).foregroundStyle(ScribeTheme.muted)
            }
            ForEach(memoService.memos) { memo in
                NavigationLink { PhoneMemoDetailView(memo: memo) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(memo.title).fontWeight(.semibold)
                        Text(memo.status.replacingOccurrences(of: "_", with: " "))
                            .font(.caption).foregroundStyle(ScribeTheme.muted)
                    }
                }
            }
            if memoService.memos.isEmpty {
                Text(memoService.errorMessage ?? "No previous meetings found.").foregroundStyle(ScribeTheme.muted)
            }
        }
        .scrollContentBackground(.hidden).background(ScribeTheme.background).navigationTitle("Previous meetings")
        .task { await memoService.refresh() }.refreshable { await memoService.refresh() }
    }
}
