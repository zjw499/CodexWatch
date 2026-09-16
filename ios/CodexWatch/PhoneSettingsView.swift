import SwiftUI

struct PhoneSettingsView: View {
    @EnvironmentObject private var memoService: PhoneMemoService
    @Environment(\.dismiss) private var dismiss
    @State private var draft = PhonePreferences()
    @State private var isSaving = false
    @State private var saveError: String?

    private var isNotion: Bool { memoService.destination?.isNotion == true }

    private var recipientIsValid: Bool {
        let value = draft.recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        return isNotion || !draft.sendEmail || (value.contains("@") && value.contains("."))
    }

    var body: some View {
        Form {
            Section("Destination") {
                LabeledContent("Save meetings to", value: isNotion ? "Notion" : "Email")
                if isNotion {
                    Text(memoService.destination?.name ?? "Meeting notes")
                    if let raw = memoService.destination?.url, let url = URL(string: raw) {
                        Link("Open meeting library", destination: url)
                    }
                    Text("Your meeting becomes a page with a summary, action items, decisions, topics, and the full transcript. Delivery retries automatically if the connection is interrupted.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Toggle("Send transcript email", isOn: $draft.sendEmail)
                    TextField("Your transcript email", text: $draft.recipient)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                    Toggle("Include summary when available", isOn: $draft.autoEmailSummary)
                }
            }

            Section("Recording") {
                Label("Start from your Watch or iPhone", systemImage: "mic.fill")
                Text("Watch recordings transfer through your iPhone in the background. Keep the PC running and your configured connection available to finish processing.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button {
                    PhoneUploadService.shared.retryPendingRecordings()
                } label: {
                    Label("Retry saved recordings", systemImage: "arrow.clockwise")
                }
            }

            Section("Processing") {
                LabeledContent("Transcription", value: "Groq Whisper")
                if isNotion {
                    LabeledContent("Meeting notes", value: "Local AI on your PC")
                    Text("Audio is transcribed using Groq. Meeting notes are generated on the PC, then the notes and transcript are sent to your Notion workspace.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Meeting settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if !isNotion { Button("Cancel") { dismiss() } }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if isNotion { dismiss(); return }
                    isSaving = true
                    Task {
                        let saved = await memoService.savePreferences(draft)
                        isSaving = false
                        if saved { dismiss() }
                        else { saveError = memoService.errorMessage }
                    }
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text(isNotion ? "Done" : "Save").fontWeight(.bold)
                    }
                }
                .disabled(isSaving || !recipientIsValid)
            }
        }
        .task {
            await memoService.loadDestination()
            await memoService.loadPreferences()
            draft = memoService.preferences
        }
        .alert("Settings could not be saved", isPresented: Binding(
            get: { saveError != nil }, set: { if !$0 { saveError = nil } }
        )) {
            Button("OK") { saveError = nil }
        } message: { Text(saveError ?? "Please try again.") }
    }
}
