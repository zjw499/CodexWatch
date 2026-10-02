import AVFoundation
import MessageUI
import SwiftUI

struct PhoneRemoteRecordingView: View {
    let recordingID: String
    var review = false
    @ObservedObject private var workspace = PhoneWorkspace.shared
    @ObservedObject private var queue = RecordingQueueStore.shared
    @State private var remote: WorkspaceRecording?
    @State private var prompt = ""
    @State private var busy = false
    @State private var message: String?
    @State private var mailText: String?
    @State private var choosingMail = false
    @State private var editingResult = false
    @State private var resultDraft = ""
    @State private var player: AVAudioPlayer?
    @State private var regenerating = false
    private var title: String { remote?.title ?? (review ? nil : queue.recording(recordingID)?.title) ?? "Recording" }
    private var transcript: String { review ? remote?.transcript ?? "" : queue.recording(recordingID)?.transcript ?? remote?.transcript ?? "" }
    private var summary: String { review ? remote?.summary ?? "" : queue.recording(recordingID)?.summary ?? remote?.summary ?? "" }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(title).font(.largeTitle.bold())
                if review { Label("Administrator review Â· access recorded", systemImage: "person.badge.shield.checkmark").font(.caption).foregroundStyle(ScribeTheme.muted) }
                if let model = remote?.result_model {
                    Text("\(remote?.assistant_name ?? "Assistant") Â· \(model)").font(.caption).foregroundStyle(ScribeTheme.muted)
                }
                if let count = remote?.expected_parts ?? queue.recording(recordingID)?.remotePartCount, count > 0 {
                    audioControls(count)
                } else if let local = queue.recording(recordingID), !local.parts.isEmpty { audioControls(local.parts.count) }
                contentPanel("Results", icon: "text.alignleft", text: summary.isEmpty ? "Results will appear after processing." : summary)
                if !review {
                    HStack {
                        Button("Edit results") { resultDraft = summary; editingResult = true }
                            .disabled(summary.isEmpty || busy || queue.recording(recordingID)?.state == .processing)
                        Spacer()
                        Button("Regenerate") { regenerating = true }.disabled(!workspace.ready || busy)
                    }.font(.subheadline)
                }
                contentPanel("Full transcript", icon: "text.quote", text: transcript.isEmpty ? "No transcript is available yet." : transcript)
                Button { choosingMail = true } label: {
                    Label("Email reviewed results", systemImage: "envelope").frame(maxWidth: .infinity).padding(.vertical, 8)
                }.buttonStyle(.bordered).disabled(summary.isEmpty && transcript.isEmpty)
                if !review && remote?.state == "ready" {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("Ask your assistant", systemImage: "bubble.left.and.bubble.right").font(.headline).foregroundStyle(ScribeTheme.red)
                        ForEach(remote?.chat ?? []) { turn in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(turn.role == "user" ? "You" : "Assistant").font(.caption.bold()).foregroundStyle(ScribeTheme.muted)
                                Text(turn.content).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .background(turn.role == "user" ? ScribeTheme.raised : ScribeTheme.background, in: RoundedRectangle(cornerRadius: 12))
                        }
                        TextField("Ask about this recordingâ€¦", text: $prompt, axis: .vertical).lineLimit(2...5)
                            .padding(12).background(ScribeTheme.background, in: RoundedRectangle(cornerRadius: 12))
                        Button("Send message") { chat() }.buttonStyle(.borderedProminent).tint(ScribeTheme.red)
                            .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy || !workspace.processingEnabled)
                    }.scribePanel()
                }
                if busy { ProgressView().tint(ScribeTheme.red).frame(maxWidth: .infinity) }
                if let message { Text(message).font(.footnote).foregroundStyle(ScribeTheme.muted) }
            }.padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }
        .background(ScribeTheme.background.ignoresSafeArea()).foregroundStyle(.white).privacySensitive()
        .navigationTitle(review ? "Organization review" : "Recording").navigationBarTitleDisplayMode(.inline)
        .task { await load() }.refreshable { await load() }
        .onDisappear { player?.stop(); player = nil }
        .sheet(isPresented: Binding(get: { mailText != nil }, set: { if !$0 { mailText = nil } })) {
            PhoneMailComposer(subject: title, bodyText: mailText ?? "") { message = $0; mailText = nil }
        }
        .sheet(isPresented: $editingResult) {
            NavigationStack {
                TextEditor(text: $resultDraft).padding().scrollContentBackground(.hidden).background(ScribeTheme.background)
                    .navigationTitle("Edit results").toolbar {
                        ToolbarItem(placement: .topBarLeading) { Button("Cancel") { editingResult = false } }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Save") {
                                do { try PhoneOpenAIService.shared.saveResult(recordingID, summary: resultDraft); editingResult = false }
                                catch { message = error.localizedDescription }
                            }
                        }
                    }
            }.preferredColorScheme(.dark)
        }
        .confirmationDialog("Choose content for the email draft", isPresented: $choosingMail, titleVisibility: .visible) {
            Button("Results only") { prepareMail(summary) }
            Button("Transcript only") { prepareMail(transcript) }
            Button("Results and transcript") { prepareMail(summary + "\n\nTranscript\n" + transcript) }
        } message: { Text("Review the recipient and use an email account approved for this information. You send the draft from Mail.") }
        .confirmationDialog("Regenerate with a selected assistant", isPresented: $regenerating, titleVisibility: .visible) {
            ForEach(workspace.assistants) { assistant in
                Button(assistant.name + " Â· " + assistant.model) {
                    workspace.selectedAssistantID = assistant.id; workspace.savePreferences()
                    PhoneOpenAIService.shared.process([recordingID]); message = "Regeneration queued. Your updated results will appear in the library."
                }
            }
        } message: { Text("This replaces the results and starts a fresh conversation. Source audio remains saved.") }
    }
    private func contentPanel(_ label: String, icon: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(label, systemImage: icon).font(.headline).foregroundStyle(ScribeTheme.red)
            Text(text).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading).scribePanel()
    }
    private func audioControls(_ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Source audio", systemImage: "waveform").font(.headline)
            if player?.isPlaying == true { Button("Stop playback") { player?.stop(); player = nil } }
            Menu("Play audio") {
                ForEach(0..<count, id: \.self) { index in Button(count == 1 ? "Play recording" : "Part \(index + 1)") { play(index) } }
            }.disabled(busy)
        }.frame(maxWidth: .infinity, alignment: .leading).scribePanel()
    }
    private func play(_ index: Int) {
        busy = true; message = nil
        Task {
            defer { busy = false }
            do {
                guard !PhoneRecorderService.shared.isRecording else { message = "Finish the active recording before playing audio."; return }
                let data: Data
                if !review, let local = queue.recording(recordingID), remote == nil, index < local.parts.count {
                    data = try Data(contentsOf: queue.audioURL(recordingID, part: local.parts.sorted { $0.index < $1.index }[index]))
                } else {
                    data = try await workspace.rawRequest("recordings/\(recordingID)/parts/\(index)\(review ? "?review=true" : "")")
                }
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                try AVAudioSession.sharedInstance().setActive(true)
                player?.stop(); player = try AVAudioPlayer(data: data); player?.play()
            } catch { message = error.localizedDescription }
        }
    }
    private func prepareMail(_ content: String) {
        guard MFMailComposeViewController.canSendMail() else { message = "Set up an approved account in Apple's Mail app to send an email draft."; return }
        mailText = content
    }
    private func load() async {
        do {
            remote = try await workspace.request("recordings/\(recordingID)\(review ? "?review=true" : "")")
            if !review { await PhoneOpenAIService.shared.reconcile() }
            message = nil
        } catch { message = review ? error.localizedDescription : "Showing saved results. Connect to your private network for chat and sync." }
    }
    private func chat() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true; message = nil
        Task {
            defer { busy = false }
            do {
                remote = try await workspace.request("recordings/\(recordingID)/chat", method: "POST", body: JSONEncoder().encode(
                    ["message": text, "request_id": UUID().uuidString]))
                prompt = ""
            } catch { message = error.localizedDescription }
        }
    }
}

struct PhoneMailComposer: UIViewControllerRepresentable {
    let subject: String
    let bodyText: String
    let completion: (String?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setSubject(subject); controller.setMessageBody(bodyText, isHTML: false)
        return controller
    }
    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}
    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let completion: (String?) -> Void
        init(completion: @escaping (String?) -> Void) { self.completion = completion }
        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            completion(result == .failed ? "Mail could not send this draft." : (result == .sent ? "Mail accepted your message for sending." : nil))
        }
    }
}
