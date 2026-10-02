import SwiftUI

struct PhoneLocalRecordingView: View {
    @EnvironmentObject private var queue: RecordingQueueStore
    @Environment(\.dismiss) private var dismiss
    let recordingID: String
    @State private var removing = false
    @State private var renameTitle = ""
    @State private var renaming = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            if let item = queue.recording(recordingID) {
                VStack(alignment: .leading, spacing: 24) {
                    Text(item.title).font(.largeTitle.weight(.bold))
                    HStack {
                        Label(item.source, systemImage: item.isWatch ? "applewatch" : "iphone")
                        Spacer()
                        Text(item.createdAt, style: .date)
                    }.font(.caption).foregroundStyle(ScribeTheme.muted)
                    Label(item.protectedWorkflow ? "Processed with protected workflow" : "Processed with OpenAI", systemImage: "lock.shield")
                        .font(.footnote).foregroundStyle(ScribeTheme.muted)
                    if let error = item.error { Text(error).font(.footnote).foregroundStyle(ScribeTheme.muted) }
                    if let notes = item.summary, !notes.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Meeting notes", systemImage: "text.alignleft").font(.headline).foregroundStyle(ScribeTheme.red)
                            Text(notes).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading).scribePanel()
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Full transcript", systemImage: "text.quote").font(.headline).foregroundStyle(ScribeTheme.red)
                        Text(item.transcript.isEmpty ? "No speech was detected." : item.transcript).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading).scribePanel()
                    if !item.transcript.isEmpty {
                        ShareLink(item: item.transcript) {
                            Label("Share transcript", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered)
                        Text("Choose an approved destination for recordings with protected health information.")
                            .font(.caption).foregroundStyle(ScribeTheme.muted)
                    }
                }.padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }
        }
        .background(ScribeTheme.background.ignoresSafeArea()).foregroundStyle(.white).privacySensitive()
        .navigationTitle("Recording").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { renameTitle = queue.recording(recordingID)?.title ?? ""; renaming = true } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) { removing = true } label: { Label("Remove recording", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .confirmationDialog("Remove this recording?", isPresented: $removing, titleVisibility: .visible) {
            Button("Remove recording", role: .destructive) {
                do { try PhoneOpenAIService.shared.remove([recordingID]); dismiss() }
                catch { errorMessage = error.localizedDescription }
            }
        } message: {
            Text("Audio, transcript, and notes are removed from this iPhone. Saved Watch audio will be removed when it reconnects.")
        }
        .alert("Rename recording", isPresented: $renaming) {
            TextField("Title", text: $renameTitle)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                do { try PhoneOpenAIService.shared.rename(recordingID, title: renameTitle) }
                catch { errorMessage = error.localizedDescription }
            }
        }
        .alert("Scribe Pilot", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "Please try again.") }
    }
}
