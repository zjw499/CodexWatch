import SwiftUI

struct PhoneSettingsView: View {
    @EnvironmentObject private var memoService: PhoneMemoService
    @Environment(\.dismiss) private var dismiss
    @State private var draft = PhonePreferences()
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var geminiURL = PhoneGeminiSettings.defaultURLString

    private var isNotion: Bool { memoService.destination?.isNotion == true }

    private var recipientIsValid: Bool {
        let value = draft.recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        return isNotion || !draft.sendEmail || (value.contains("@") && value.contains("."))
    }

    private var geminiURLIsValid: Bool {
        PhoneGeminiSettings.validatedURL(geminiURL) != nil
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
                    Text("Groq creates the full transcript and Scribe Pilot saves that transcript in Notion. Delivery retries automatically if the connection is interrupted.")
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
                LabeledContent("Transcription", value: memoService.destination?.usesNativeNotion == true ? "Notion AI" : "Groq Whisper")
                if memoService.destination?.usesNativeNotion == true {
                    LabeledContent("Meeting notes", value: "Notion AI")
                    Text("Your watch sends audio while you record. When you finish, the PC combines the audio and uploads it to Notion. Notion generates the full transcript and meeting notes. Audio is stored on the PC and in your Notion workspace.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if isNotion {
                    LabeledContent("Notion content", value: "Full transcript only")
                    Text("Audio is transcribed using Groq Whisper. Scribe Pilot stores the complete transcript in the app and sends the same transcript to your Notion workspace.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section("Gemini handoff") {
                TextField("Gemini or Gem link", text: $geminiURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Text("Completed meetings include a button that copies the full transcript for five minutes and opens this Gemini destination.")
                    .font(.footnote).foregroundStyle(.secondary)
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
                    PhoneGeminiSettings.save(geminiURL)
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
                .disabled(isSaving || !recipientIsValid || !geminiURLIsValid)
            }
        }
        .task {
            await memoService.loadDestination()
            await memoService.loadPreferences()
            draft = memoService.preferences
            geminiURL = PhoneGeminiSettings.savedURLString
                ?? memoService.destination?.geminiURL
                ?? PhoneGeminiSettings.defaultURLString
        }
        .alert("Settings could not be saved", isPresented: Binding(
            get: { saveError != nil }, set: { if !$0 { saveError = nil } }
        )) {
            Button("OK") { saveError = nil }
        } message: { Text(saveError ?? "Please try again.") }
    }
}
