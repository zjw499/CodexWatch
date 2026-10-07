import SwiftUI

struct PhoneSettingsView: View {
    @ObservedObject private var workspace = PhoneWorkspace.shared
    @EnvironmentObject private var recorder: PhoneRecorderService
    @Environment(\.dismiss) private var dismiss
    @State private var server = PhoneWorkspace.defaultServer
    @State private var invitation = false
    @State private var username = ""
    @State private var password = ""
    @State private var repeatedPassword = ""
    @State private var working = false
    @State private var errorMessage: String?
    @State private var editingAssistant: WorkspaceAssistant?
    @State private var signingOut = false

    var body: some View {
        Form {
            Section {
                Label("Your AI workspace", systemImage: "waveform").font(.headline)
                Text("Your organization provides the OpenAI connection. Configure assistants for recordings and Watch conversations.")
                    .font(.footnote).foregroundStyle(ScribeTheme.muted)
            }
            if let user = workspace.user {
                account(user)
                models
                assistants
                watchVoice
                Section("Recording workflow") {
                    Label("Review, then tap Process", systemImage: "checkmark.circle")
                    Label("Audio and results kept until deleted", systemImage: "tray.full")
                    Text("Record offline on your phone or Watch. Connect to the private network to upload and process on your PC.")
                        .font(.footnote).foregroundStyle(ScribeTheme.muted)
                }
                if !RecordingQueueStore.shared.unassigned.isEmpty {
                    Section("Existing recordings") {
                        NavigationLink("Assign earlier recordings to my account") { PhoneRecordingImportView() }
                        Text("Earlier recordings stay unassigned until you choose to import them.")
                            .font(.footnote).foregroundStyle(ScribeTheme.muted)
                    }
                }
                if user.isAdmin {
                    Section("Organization") {
                        NavigationLink { PhoneWorkspaceAdminView() } label: { Label("Administrator workspace", systemImage: "person.badge.key") }
                    }
                }
            } else { login }
        }
        .scrollContentBackground(.hidden).background(ScribeTheme.background).tint(ScribeTheme.red)
        .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Done") { clearPasswords(); workspace.savePreferences(); dismiss() } } }
        .task { server = workspace.credential?.server ?? PhoneWorkspace.defaultServer; await workspace.refresh() }
        .sheet(item: $editingAssistant) { assistant in NavigationStack { PhoneAssistantEditor(assistant: assistant) } }
        .confirmationDialog("Sign out of this workspace?", isPresented: $signingOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { run { try await workspace.signOut() } }
        } message: { Text("Your recordings stay protected under their original account. Offline server-session revocation retries when the PC is reachable.") }
        .alert("Scribe Pilot", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "Please try again.") }
        .onDisappear { clearPasswords() }
    }
    private func account(_ user: WorkspaceUser) -> some View {
        Section("Account") {
            Label(user.username, systemImage: "person.crop.circle")
            Text(user.isAdmin ? "Administrator · organization review enabled" : "Private recording workspace")
                .font(.footnote).foregroundStyle(ScribeTheme.muted)
            Label(workspace.processingEnabled ? "Organization connection ready" : "Organization approval pending",
                  systemImage: workspace.processingEnabled ? "lock.shield" : "clock")
                .font(.footnote)
            if let message = workspace.connectionMessage { Text(message).font(.footnote).foregroundStyle(ScribeTheme.muted) }
            Button("Refresh connection") { run { await workspace.refresh() } }.disabled(working)
            Button("Sign out", role: .destructive) { signingOut = true }.disabled(recorder.isRecording || working)
        }
    }
    private var login: some View {
        Section("Account") {
            Picker("Access", selection: $invitation) { Text("Sign in").tag(false); Text("Accept invitation").tag(true) }.pickerStyle(.segmented)
            TextField("Private workspace address", text: $server).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            TextField(invitation ? "Invitation code" : "Username", text: $username)
                .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
            SecureField(invitation ? "Choose password (12+ characters)" : "Password", text: $password)
                .textContentType(invitation ? .newPassword : .password)
            if invitation { SecureField("Repeat password", text: $repeatedPassword).textContentType(.newPassword) }
            Button {
                if invitation && password != repeatedPassword { errorMessage = "The passwords don't match."; return }
                run {
                    try await workspace.signIn(server: server, username: username, password: password, invitation: invitation)
                    clearPasswords(); username = ""
                }
            } label: {
                HStack { Text(invitation ? "Create my account" : "Sign in"); Spacer(); if working { ProgressView() } }
            }.disabled(working || recorder.isRecording || username.isEmpty || password.isEmpty)
            Text("Connect to your organization's private network first. Your administrator provides the invitation and access.")
                .font(.footnote).foregroundStyle(ScribeTheme.muted)
        }
    }
    private var models: some View {
        Section("Models") {
            Picker("Transcription", selection: $workspace.transcriptionModel) {
                ForEach(workspace.transcriptionModels, id: \.self) { Text($0).tag($0) }
            }
            Text("Use gpt-4o-transcribe for difficult recordings. Clear microphone placement still matters.")
                .font(.footnote).foregroundStyle(ScribeTheme.muted)
            TextField("Names, acronyms, and vocabulary", text: $workspace.transcriptionContext, axis: .vertical)
                .lineLimit(2...5).privacySensitive()
                .onChange(of: workspace.transcriptionContext) { _, value in
                    if value.count > 2000 { workspace.transcriptionContext = String(value.prefix(2000)) }
                }
            Text("Optional words to help speech recognition. Assistant instructions below control the results.")
                .font(.footnote).foregroundStyle(ScribeTheme.muted)
            Picker("Default assistant", selection: $workspace.selectedAssistantID) {
                ForEach(workspace.assistants) { Text($0.name).tag($0.id) }
            }
            if let assistant = workspace.selectedAssistant { Text("Results model: \(assistant.model)").font(.footnote).foregroundStyle(ScribeTheme.muted) }
        }
    }
    private var assistants: some View {
        Section("Assistants & instructions") {
            ForEach(workspace.assistants) { assistant in
                Button { editingAssistant = assistant } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(assistant.name).foregroundStyle(.white)
                        Text(assistant.model).font(.caption).foregroundStyle(ScribeTheme.muted)
                    }
                }
            }
            Button { editingAssistant = WorkspaceAssistant(id: UUID().uuidString, name: "", instructions: "", model: workspace.generationModels.first ?? "gpt-4.1-mini") } label: {
                Label("Create assistant", systemImage: "plus.circle")
            }
            Text("Give each assistant a purpose, model, and custom instructions. Choose it before processing a recording or regenerating results.")
                .font(.footnote).foregroundStyle(ScribeTheme.muted)
        }
    }
    private var watchVoice: some View {
        Section("Watch voice") {
            if let config = workspace.voiceConfiguration {
                Picker("Default Watch assistant", selection: Binding(get: { config.default_assistant_id }, set: { id in
                    run { try await workspace.setDefaultVoiceAssistant(id) }
                })) {
                    if config.assistants.isEmpty { Text("Enable voice on an assistant").tag("") }
                    ForEach(config.assistants) { Text($0.name).tag($0.id) }
                }
                Button("Connect Watch voice") { run { try await workspace.provisionWatchVoice() } }
                    .disabled(working || !config.enabled || config.assistants.isEmpty)
            }
            NavigationLink("Voice conversation history") { PhoneVoiceHistoryView() }
            NavigationLink("Watch audio reports") { PhoneVoiceDiagnosticsView() }
            if let message = workspace.voiceMessage { Text(message).font(.footnote).foregroundStyle(ScribeTheme.muted) }
            Text("No code to enter. Keep Scribe Pilot open on your unlocked Watch during setup; the iPhone transfers access automatically and shows confirmation here. After setup, your Watch needs internet and the PC must be online. Text is saved; audio is not retained.")
                .font(.footnote).foregroundStyle(ScribeTheme.muted)
        }
    }
    private func clearPasswords() { password = ""; repeatedPassword = "" }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        working = true
        Task { defer { working = false }; do { try await operation() } catch { errorMessage = error.localizedDescription } }
    }
}

struct PhoneAssistantEditor: View {
    @ObservedObject private var workspace = PhoneWorkspace.shared
    @Environment(\.dismiss) private var dismiss
    @State var assistant: WorkspaceAssistant
    @State private var working = false
    @State private var errorMessage: String?
    @State private var deleting = false
    var body: some View {
        Form {
            Section("Assistant") {
                TextField("Name", text: $assistant.name)
                Picker("Results model", selection: $assistant.model) {
                    ForEach(workspace.generationModels, id: \.self) { Text($0).tag($0) }
                }
            }
            Section("Custom instructions") {
                TextEditor(text: $assistant.instructions).frame(minHeight: 240).privacySensitive()
                Text("Describe this assistant's purpose, tone, and instructions. These also apply when you enable Watch voice conversations.")
                    .font(.footnote).foregroundStyle(ScribeTheme.muted)
            }
            Section("Watch voice") {
                Toggle("Enable voice conversations", isOn: $assistant.voiceSettings.enabled)
                if assistant.voiceSettings.enabled {
                    Picker("Voice", selection: $assistant.voiceSettings.voice) {
                        ForEach(workspace.voiceConfiguration?.voices ?? ["marin", "cedar"], id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    .accessibilityIdentifier("assistant-voice-picker")
                    Toggle("Calculations and current time", isOn: $assistant.voiceSettings.tools_enabled)
                    if assistant.voiceSettings.tools_enabled {
                        Toggle("Search the public web", isOn: $assistant.voiceSettings.web_search)
                            .accessibilityIdentifier("assistant-web-search-toggle")
                        if assistant.voiceSettings.web_search {
                            Text("Use this assistant for public, non-sensitive topics. Live web search is outside the organization's BAA. Recording content is never included in search.")
                                .font(.footnote).foregroundStyle(ScribeTheme.muted)
                            if workspace.voiceConfiguration?.public_web_search_enabled != true {
                                Text("An administrator must enable public web search in Watch voice policy.")
                                    .font(.footnote).foregroundStyle(ScribeTheme.muted)
                            }
                        }
                    }
                    if let models = workspace.voiceConfiguration?.models, models.count > 1 {
                        Picker("Voice model", selection: $assistant.voiceSettings.model) {
                            ForEach(models, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    Text("Quick launches start a fresh conversation. Resume a saved conversation from History.")
                        .font(.footnote).foregroundStyle(ScribeTheme.muted)
                }
            }
            if workspace.assistants.contains(where: { $0.id == assistant.id }) {
                Section { Button("Delete assistant", role: .destructive) { deleting = true } }
            }
            if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(ScribeTheme.muted) }
        }
        .scrollContentBackground(.hidden).background(ScribeTheme.background).tint(ScribeTheme.red)
        .navigationTitle(assistant.name.isEmpty ? "New assistant" : assistant.name).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { run { try await workspace.saveAssistant(assistant) } }
                    .disabled(working || assistant.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || assistant.instructions.isEmpty)
            }
        }
        .confirmationDialog("Delete this assistant?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete assistant", role: .destructive) { run { try await workspace.deleteAssistant(assistant.id) } }
        } message: { Text("Existing results remain available.") }
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        working = true
        Task { defer { working = false }; do { try await operation(); dismiss() } catch { errorMessage = error.localizedDescription } }
    }
}

struct PhoneRecordingImportView: View {
    @ObservedObject private var queue = RecordingQueueStore.shared
    @ObservedObject private var workspace = PhoneWorkspace.shared
    @State private var selected: Set<String> = []
    @State private var confirming = false
    @State private var message: String?
    var body: some View {
        List {
            Section {
                Text("Select only recordings that belong in your account. Imported audio and results will sync to your organization's PC; existing external copies keep their original settings.")
                    .font(.footnote).foregroundStyle(ScribeTheme.muted)
            }
            ForEach(queue.unassigned) { item in
                Button {
                    if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
                } label: { Label(item.title, systemImage: selected.contains(item.id) ? "checkmark.circle.fill" : "circle") }
            }
            Button("Import \(selected.count) recordings") { confirming = true }.disabled(selected.isEmpty || workspace.user == nil)
            if let message { Text(message).font(.footnote) }
        }
        .scrollContentBackground(.hidden).background(ScribeTheme.background).tint(ScribeTheme.red).navigationTitle("Import recordings")
        .confirmationDialog("Assign selected recordings to \(workspace.user?.username ?? "your account")?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Import recordings") {
                guard let owner = workspace.user?.id else { return }
                do {
                    for id in selected { try queue.assign(id, owner: owner) }
                    let imported = selected; selected = []
                    Task { for id in imported { await PhoneOpenAIService.shared.importRecording(id) } }
                } catch { message = error.localizedDescription }
            }
        }
    }
}
