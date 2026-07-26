import SwiftUI

struct PhoneSettingsView: View {
    @EnvironmentObject private var memoService: PhoneMemoService
    @Environment(\.dismiss) private var dismiss
    @State private var draft = PhonePreferences()
    @State private var isSaving = false

    private var recipientIsValid: Bool {
        let value = draft.recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        return !draft.sendEmail || (value.contains("@") && value.contains("."))
    }

    var body: some View {
        Form {
            Section("Transcription") {
                Toggle("Identify speakers", isOn: $draft.speakerLabelsEnabled)
                Toggle("Auto paragraphs", isOn: $draft.autoParagraphs)
                Toggle("AI-generated memo title", isOn: $draft.generateTitle)
                Toggle("Local summary", isOn: $draft.summaryEnabled)
                LabeledContent("Language") { Text(draft.language) }
            }

            Section("Email delivery") {
                Toggle("Send transcript email", isOn: $draft.sendEmail)
                Toggle("Include summary", isOn: $draft.autoEmailSummary)
                TextField("Your transcript email", text: $draft.recipient)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                Text("This address is saved on this phone and attached to every recording. Each beta tester should enter their own address.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Subject prefix", text: $draft.emailPrefix)
                    .textInputAutocapitalization(.never)
                Toggle("Remove local footer", isOn: $draft.removeFooter)
            }

            Section("Privacy") {
                Toggle("Private mode", isOn: $draft.privateMode)
                Text("SMTP credentials stay on the PC. This app stores only memo preferences and the PC API connection settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isSaving = true
                    Task {
                        await memoService.savePreferences(draft)
                        isSaving = false
                        dismiss()
                    }
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text("Save").fontWeight(.bold)
                    }
                }
                .disabled(isSaving || !recipientIsValid)
            }
        }
        .task {
            await memoService.loadPreferences()
            draft = memoService.preferences
        }
    }
}
