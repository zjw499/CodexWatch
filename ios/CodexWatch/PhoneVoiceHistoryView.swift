import SwiftUI

struct PhoneVoiceHistoryView: View {
    var review = false
    @ObservedObject private var workspace = PhoneWorkspace.shared
    @State private var conversations: [VoiceConversation] = []
    @State private var message: String?
    var body: some View {
        List {
            ForEach(conversations) { conversation in
                NavigationLink { PhoneVoiceConversationView(conversationID: conversation.id, review: review) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(conversation.title).privacySensitive()
                        Text(conversation.assistant_name).font(.caption).foregroundStyle(ScribeTheme.muted)
                        Text(Date(timeIntervalSince1970: conversation.updated), style: .date).font(.caption)
                        if review { Text("Account: \(conversation.owner)").font(.caption).foregroundStyle(ScribeTheme.muted) }
                    }
                }
            }
            if conversations.count >= 100 { Button("Load older conversations") { Task { await load(offset: conversations.count) } } }
            if conversations.isEmpty && message == nil { Text("Your Watch conversations will appear here.").foregroundStyle(ScribeTheme.muted) }
            if let message { Text(message).font(.footnote) }
        }
        .scrollContentBackground(.hidden).background(ScribeTheme.background).tint(ScribeTheme.red)
        .navigationTitle(review ? "Organization voice" : "Voice history")
        .task { await load() }.refreshable { await load() }
        .onChange(of: workspace.user?.id) { _, _ in conversations = []; message = nil }
    }
    private func load(offset: Int = 0) async {
        do {
            let page: VoiceHistory = try await workspace.request("\(review ? "admin/voice" : "voice")/conversations?offset=\(offset)")
            if offset == 0 { conversations = page.conversations } else { conversations += page.conversations }
        } catch { message = error.localizedDescription }
    }
}

struct PhoneVoiceConversationView: View {
    let conversationID: String
    var review = false
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var workspace = PhoneWorkspace.shared
    @State private var conversation: VoiceConversation?
    @State private var message: String?
    @State private var deleting = false
    var body: some View {
        List {
            if let conversation {
                Section(conversation.assistant_name) {
                    ForEach(conversation.turns ?? []) { turn in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(turn.role == "user" ? "You" : "Assistant").font(.caption.bold()).foregroundStyle(ScribeTheme.red)
                            Text(turn.text).privacySensitive().textSelection(.enabled)
                            if turn.interrupted { Text("Interrupted reply · some words may not have been played").font(.caption).foregroundStyle(ScribeTheme.muted) }
                            else if !turn.final { Text("Incomplete turn").font(.caption).foregroundStyle(ScribeTheme.muted) }
                        }
                    }
                }
                if !review { Button("Delete conversation", role: .destructive) { deleting = true } }
            }
            if let message { Text(message).font(.footnote) }
        }
        .scrollContentBackground(.hidden).background(ScribeTheme.background).tint(ScribeTheme.red)
        .navigationTitle("Conversation")
        .task {
            do { conversation = try await workspace.request("\(review ? "admin/voice" : "voice")/conversations/\(conversationID)") }
            catch { message = error.localizedDescription }
        }
        .onChange(of: workspace.user?.id) { _, _ in conversation = nil; dismiss() }
        .confirmationDialog("Delete this conversation?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    do { let _: PhoneWorkspace.OK = try await workspace.request("voice/conversations/\(conversationID)", method: "DELETE"); dismiss() }
                    catch { message = error.localizedDescription }
                }
            }
        }
    }
}
