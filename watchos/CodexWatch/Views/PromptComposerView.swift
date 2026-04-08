import SwiftUI

struct PromptComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: CodexWatchStore

    let threadID: String?
    let threadName: String?

    @State private var prompt = ""
    @State private var planMode = false
    @State private var isSubmitting = false
    @State private var requestedInitialDictation = false

    init(threadID: String? = nil, threadName: String? = nil) {
        self.threadID = threadID
        self.threadName = threadName
    }

    private var isNewThread: Bool {
        threadID == nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                CodexCard(
                    title: isNewThread ? "New Thread" : (threadName ?? "Follow-Up"),
                    subtitle: store.selectedDesktop?.name
                ) {
                    HStack {
                        if let currentFolder = store.currentFolder {
                            FolderChip(label: currentFolder.displayName)
                        }
                        if planMode {
                            FolderChip(label: "Plan Mode")
                        }
                    }
                }

                Toggle("Plan Mode", isOn: $planMode)
                    .tint(.white)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Prompt")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))

                    Text(prompt.isEmpty ? "Use dictation to capture your request." : prompt)
                        .font(.body)
                        .foregroundStyle(prompt.isEmpty ? .white.opacity(0.45) : .white)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        )
                }

                Button("Dictate Prompt") {
                    Task {
                        await capturePrompt()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.18))

                HStack {
                    Button("Redo") {
                        Task {
                            await capturePrompt()
                        }
                    }
                    .disabled(isSubmitting)

                    Spacer()

                    Button(isSubmitting ? "Sending..." : "Send") {
                        Task {
                            await submit()
                        }
                    }
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
        }
        .background(Color.black)
        .task {
            if !requestedInitialDictation {
                requestedInitialDictation = true
                planMode = store.defaultPlanMode
                await capturePrompt()
            }
        }
    }

    private func capturePrompt() async {
        do {
            let dictated = try await DictationService.requestTextInput(suggestions: [
                "Continue the current thread",
                "Draft a plan",
                "Check the latest reply",
            ])
            let trimmed = dictated.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                prompt = trimmed
            }
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    private func submit() async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSubmitting = true
        defer { isSubmitting = false }

        if let threadID {
            await store.submitPrompt(to: threadID, prompt: trimmed, planMode: planMode)
        } else {
            await store.createThread(prompt: trimmed, planMode: planMode)
        }

        dismiss()
    }
}
