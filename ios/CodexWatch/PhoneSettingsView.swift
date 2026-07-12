import SwiftUI

struct PhoneSettingsView: View {
    @EnvironmentObject private var memoService: PhoneMemoService
    @Environment(\.dismiss) private var dismiss
    @State private var draft = PhonePreferences()
    @State private var isSaving = false

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
                TextField("Recipient email", text: $draft.recipient)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
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
                .disabled(isSaving)
            }
        }
        .task {
            await memoService.loadPreferences()
            draft = memoService.preferences
        }
    }
}
