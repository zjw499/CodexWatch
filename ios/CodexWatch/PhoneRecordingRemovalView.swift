import SwiftUI

struct PhoneRecordingRemovalRequest: Identifiable {
    let id = UUID()
    let ids: Set<String>
}

struct PhoneRecordingRemovalView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?
    let ids: Set<String>
    let onRemoved: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: "trash").font(.system(size: 32)).foregroundStyle(ScribeTheme.red)
                    Text(ids.count == 1 ? "Remove this recording?" : "Remove these recordings?")
                        .font(.title2.bold())
                    Text("Saved audio and transcripts will be removed from this iPhone. Watch copies will be removed when it reconnects. Already processed OpenAI requests cannot be recalled.")
                        .font(.subheadline).foregroundStyle(ScribeTheme.muted)
                    Button("Remove \(ids.count) recording\(ids.count == 1 ? "" : "s")", role: .destructive, action: remove)
                        .buttonStyle(.borderedProminent).tint(ScribeTheme.red).disabled(ids.isEmpty)
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(ScribeTheme.background).foregroundStyle(.white)
            .navigationTitle("Remove recording").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } } }
            .alert("Recording removal", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "Please try again.") }
        }.preferredColorScheme(.dark).presentationDetents([.medium, .large])
    }
    private func remove() {
        do {
            try PhoneOpenAIService.shared.remove(ids)
            dismiss()
            onRemoved()
        } catch { errorMessage = error.localizedDescription }
    }
}
