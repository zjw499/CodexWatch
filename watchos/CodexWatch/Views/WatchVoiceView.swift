import SwiftUI

struct WatchVoiceHomeView: View {
    @ObservedObject private var voice = WatchVoiceService.shared
    @State private var assistantID = ""
    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Label("Talk to Assistant", systemImage: "waveform").font(.headline)
                if let config = voice.configuration {
                    Picker("Assistant", selection: $assistantID) {
                        Text("Default assistant").tag("")
                        ForEach(config.assistants) { Text($0.name).tag($0.id) }
                    }
                    Button { Task { await voice.open(assistantID: assistantID.isEmpty ? nil : assistantID) } } label: {
                        Label(voice.isActive ? "Open conversation" : "Talk", systemImage: "mic.fill")
                    }.tint(ScribeTheme.red).disabled(!config.enabled || config.assistants.isEmpty)
                }
                NavigationLink("Voice history") { WatchVoiceHistoryView() }
                if let message = voice.message { Text(message).font(.caption).foregroundStyle(ScribeTheme.muted) }
                if voice.configuration == nil { Text("Set up Watch voice in iPhone Settings.").font(.caption) }
                Button("Refresh voice settings") { Task { await voice.refresh() } }.font(.caption)
            }.padding(.horizontal, 8)
        }.task { await voice.refresh() }
        .background(ScribeTheme.background).tint(ScribeTheme.red)
    }
}

struct WatchVoiceView: View {
    @ObservedObject private var voice = WatchVoiceService.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text(voice.assistantName).font(.headline).lineLimit(2)
                Label(voice.state.capitalized, systemImage: voice.muted ? "mic.slash.fill" : "waveform")
                    .font(.caption.bold()).foregroundStyle(ScribeTheme.red)
                    .accessibilityLabel("Voice status: \(voice.state)")
                if let message = voice.message { Text(message).font(.caption).foregroundStyle(ScribeTheme.muted) }
                if voice.isActive {
                    HStack {
                        Button { voice.toggleMute() } label: { Image(systemName: voice.muted ? "mic.fill" : "mic.slash.fill") }
                            .accessibilityLabel(voice.muted ? "Unmute" : "Mute").disabled(voice.state == "connecting")
                        Button("End", role: .destructive) { voice.end() }.tint(ScribeTheme.red)
                    }
                } else { Button("New conversation") { Task { await voice.newConversation() } } }
                ForEach(Array(voice.turns.suffix(4))) { turn in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(turn.role == "user" ? "You" : "Assistant").font(.caption2.bold()).foregroundStyle(ScribeTheme.muted)
                        Text(turn.text).font(.caption).privacySensitive().lineLimit(6)
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
