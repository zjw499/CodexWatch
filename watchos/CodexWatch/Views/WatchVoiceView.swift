import SwiftUI

struct WatchVoiceHomeView: View {
    @ObservedObject private var voice = WatchVoiceService.shared
    @State private var assistantID = ""
    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Label("Talk to Assistant", systemImage: "waveform").font(.headline)
                Label(voice.setupState == .ready ? "Watch connected" : "Setup needed", systemImage: voice.setupState == .ready ? "checkmark.circle" : "iphone")
                    .font(.caption).foregroundStyle(ScribeTheme.muted)
                if let config = voice.configuration {
                    Picker("Assistant", selection: $assistantID) {
                        Text("Default assistant").tag("")
                        ForEach(config.assistants) { Text($0.name).tag($0.id) }
                    }
                    Button { Task { await voice.open(assistantID: assistantID.isEmpty ? nil : assistantID) } } label: {
                        Label(voice.isActive ? "Open conversation" : "Talk", systemImage: "mic.fill")
                    }.tint(ScribeTheme.red).disabled(!config.enabled || config.assistants.isEmpty || voice.setupState != .ready)
                }
                NavigationLink("Voice history") { WatchVoiceHistoryView() }
                NavigationLink("Test Watch audio") { WatchAudioDiagnosticView() }
                if let message = voice.message { Text(message).font(.caption).foregroundStyle(ScribeTheme.muted) }
                if voice.setupState != .ready { Text(voice.setupState.message).font(.caption) }
                Button("Sync from iPhone") { WatchConnectivityTransferService.shared.requestVoiceSetup() }.font(.caption)
                Button("Refresh voice settings") { Task { await voice.refresh() } }.font(.caption)
                Text("Watch build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown")")
                    .font(.caption2).foregroundStyle(ScribeTheme.muted)
            }.padding(.horizontal, 8)
        }.task { await voice.refresh() }
        .background(ScribeTheme.background).tint(ScribeTheme.red)
    }
}

struct WatchVoiceView: View {
    @ObservedObject private var reporter = WatchVoiceDiagnosticReporter.shared
    @ObservedObject private var voice = WatchVoiceService.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text(voice.assistantName).font(.headline).lineLimit(2)
                if voice.usesPublicWeb { Text("Public topics · Web enabled").font(.caption2).foregroundStyle(ScribeTheme.muted) }
                Label(voice.state.capitalized, systemImage: voice.muted ? "mic.slash.fill" : "waveform")
                    .font(.caption.bold()).foregroundStyle(ScribeTheme.red)
                    .accessibilityLabel("Voice status: \(voice.state)")
                if let message = voice.message { Text(message).font(.caption).foregroundStyle(ScribeTheme.muted) }
                if let tool = voice.toolMessage { Text(tool).font(.caption).foregroundStyle(ScribeTheme.muted) }
                if voice.isActive {
                    HStack {
                        Button { voice.toggleMute() } label: { Image(systemName: voice.muted ? "mic.fill" : "mic.slash.fill") }
                            .accessibilityLabel(voice.muted ? "Unmute" : "Mute").disabled(voice.state == "connecting")
                        Button("End", role: .destructive) { voice.end() }.tint(ScribeTheme.red)
                    }
                } else { Button("New conversation") { Task { await voice.newConversation() } } }
                if !voice.isActive, let status = reporter.status { Text(status).font(.caption2) }
                if !voice.isActive, reporter.hasPending { Button("Send report again") { reporter.retry() }.font(.caption) }
                if voice.isActive || voice.capturedBatches > 0 {
                    VStack(spacing: 4) {
                        ProgressView(value: voice.microphoneLevel).tint(ScribeTheme.red)
                            .accessibilityLabel("Microphone activity")
                        Text(voice.muted ? "Microphone muted" : (voice.capturedBatches > 0 ? (voice.isActive ? "Microphone active" : "Microphone captured audio") : "Waiting for microphone"))
                        Text(voice.uploadedBatches > 0 ? "Audio reached PC" : "Waiting to send audio")
                        Text(voice.receivedAudio ? "Assistant audio received" : "Waiting for assistant audio")
                    }.font(.caption2).foregroundStyle(ScribeTheme.muted)
                }
                ForEach(Array(voice.turns.suffix(4).reversed())) { turn in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(turn.role == "user" ? "You" : "Assistant").font(.caption2.bold()).foregroundStyle(ScribeTheme.muted)
                        Text(turn.text).font(.caption).privacySensitive().lineLimit(6)
                        ForEach(turn.sources ?? []) { source in
                            if let url = source.link { Link(source.title, destination: url).font(.caption2) }
                        }
                        if turn.interrupted { Text("Interrupted reply").font(.caption2).foregroundStyle(ScribeTheme.muted) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(.horizontal, 6)
        }
        .background(ScribeTheme.background).tint(ScribeTheme.red)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { voice.end(); voice.isPresented = false } } }
        .onAppear { voice.setVoiceScreenReady(scenePhase == .active && !isLuminanceReduced) }
        .onChange(of: scenePhase) { _, phase in voice.setVoiceScreenReady(phase == .active && !isLuminanceReduced) }
        .onChange(of: isLuminanceReduced) { _, reduced in voice.setVoiceScreenReady(scenePhase == .active && !reduced) }
        .onDisappear { voice.setVoiceScreenReady(false); voice.end() }
    }
}

struct WatchVoiceHistoryView: View {
    @ObservedObject private var voice = WatchVoiceService.shared
    @State private var conversations: [VoiceConversation] = []
    @State private var message: String?
    var body: some View {
        List {
            ForEach(conversations) { conversation in
                NavigationLink { WatchVoiceHistoryDetailView(id: conversation.id) } label: {
                    VStack(alignment: .leading) {
                        Text(conversation.title).privacySensitive()
                        Text(conversation.assistant_name).font(.caption).foregroundStyle(ScribeTheme.muted)
                    }
                }
            }
            if conversations.count >= 100 { Button("Load older") { Task { await load(offset: conversations.count) } } }
            if conversations.isEmpty { Text(message ?? "No voice conversations yet.").font(.caption) }
        }.navigationTitle("Voice history").tint(ScribeTheme.red)
        .task { await load() }.refreshable { await load() }
    }
    private func load(offset: Int = 0) async {
        do {
            let page = try await voice.history(offset: offset)
            if offset == 0 { conversations = page } else { conversations += page }
        } catch { message = error.localizedDescription }
    }
}

struct WatchVoiceHistoryDetailView: View {
    let id: String
    @ObservedObject private var voice = WatchVoiceService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var conversation: VoiceConversation?
    @State private var message: String?
    @State private var deleting = false
    var body: some View {
        List {
            if let conversation {
                Button("Resume with \(conversation.assistant_name)") { Task { await voice.open(conversationID: id) } }
                ForEach(conversation.turns ?? []) { turn in
                    VStack(alignment: .leading) {
                        Text(turn.role == "user" ? "You" : "Assistant").font(.caption.bold()).foregroundStyle(ScribeTheme.red)
                        Text(turn.text).font(.caption).privacySensitive()
                        ForEach(turn.sources ?? []) { source in
                            if let url = source.link { Link(source.title, destination: url).font(.caption2) }
                        }
                        if turn.interrupted { Text("Interrupted reply").font(.caption2).foregroundStyle(ScribeTheme.muted) }
                    }
                }
                Button("Delete", role: .destructive) { deleting = true }
            }
            if let message { Text(message).font(.caption) }
        }.navigationTitle("Conversation").tint(ScribeTheme.red)
        .task {
            do { conversation = try await voice.detail(id) } catch { message = error.localizedDescription }
        }
        .confirmationDialog("Delete conversation?", isPresented: $deleting) {
            Button("Delete", role: .destructive) {
                Task { do { try await voice.delete(id); dismiss() } catch { message = error.localizedDescription } }
            }
        }
    }
}
