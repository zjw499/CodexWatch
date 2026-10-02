import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PhoneMemoDetailView: View {
    @EnvironmentObject private var memoService: PhoneMemoService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let memo: MemoSummary
    @State private var detail: MemoDetail?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var recoveryProgress: AudioRecoveryProgress?
    @State private var requestingRecovery = false
    @State private var showingDeleteConfirmation = false
    @State private var copiedForGemini = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let detail {
                    Text(detail.title)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    HStack(spacing: 8) {
                        Text(detail.source.lowercased().contains("watch") ? "Apple Watch" : "iPhone")
                        Text("•")
                        Text(detail.notionURL != nil ? "Saved in Notion" : detail.status.replacingOccurrences(of: "_", with: " ").capitalized)
                        if let count = detail.speakerCount, count > 1 {
                            Text("•")
                            Text("\(count) speakers")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))

                    if let raw = detail.notionURL, let url = URL(string: raw) {
                        Link(destination: url) {
                            Label("Open in Notion", systemImage: "arrow.up.right.square")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(ScribeTheme.red)
                        .foregroundStyle(.white)
                    }

                    if let summary = detail.summary, !summary.isEmpty {
                        section(title: "Summary", icon: "sparkles") {
                            Text(summary)
                        }
                    }

                    if let items = detail.actionItems, !items.isEmpty {
                        section(title: "Action items", icon: "checklist") {
                            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                                Label(item, systemImage: "square")
                            }
                        }
                    }
                    if let decisions = detail.decisions, !decisions.isEmpty {
                        section(title: "Decisions", icon: "checkmark.seal") {
                            ForEach(Array(decisions.enumerated()), id: \.offset) { _, item in Text(item) }
                        }
                    }

                    section(title: "Transcript", icon: "text.quote") {
                        Text(detail.transcript.isEmpty ? "Transcript is not available yet." : detail.transcript)
                            .textSelection(.enabled)
                    }

                    if !detail.transcript.isEmpty {
                        Button {
                            copyTranscriptAndOpenGemini(detail.transcript)
                        } label: {
                            Label("Copy Transcript & Open Gemini", systemImage: "sparkles.rectangle.stack")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(ScribeTheme.red)
                        .foregroundStyle(.white)

                        if copiedForGemini {
                            Label("Full transcript copied. Paste it into Gemini.", systemImage: "checkmark.circle.fill")
                                .font(.footnote)
                                .foregroundStyle(.mint)
                        }
                    }

                    if ["failed", "email_failed", "notion_failed"].contains(detail.status) {
                        if detail.status == "notion_failed" {
                            Text("Your transcript is saved. Notion delivery is retrying automatically.")
                                .font(.footnote).foregroundStyle(.orange)
                        }
                        Button {
                            Task {
                                await memoService.retry(memo)
                                self.detail = try? await PhoneMemoAPIClient.shared.getMemo(id: memo.id)
                            }
                        } label: {
                            Label("Retry processing", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if !detail.transcript.isEmpty {
                        ShareLink(item: detail.transcript) {
                            Label("Share transcript", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    if detail.status == "done", let recordingID = originalRecordingID {
                        section(title: "Original audio", icon: "waveform") {
                            Text("Recover saved audio from your Watch to your PC. Keep Scribe Pilot open on your Watch and keep your iPhone nearby.")
                                .font(.footnote)
                            Text("Your existing meeting notes stay in place.")
                                .font(.footnote)
                            if let recoveryProgress {
                                Text(recoveryProgress.status == "complete"
                                    ? "Original audio saved on your PC."
                                    : "\(recoveryProgress.receivedChunks) of \(recoveryProgress.expectedChunks) audio parts saved.")
                                    .font(.footnote)
                                if recoveryProgress.receivedChunks == 0 {
                                    Text("If the Watch says no saved chunks remain, its original copy is no longer available.")
                                        .font(.footnote)
                                }
                            }
                            Button {
                                requestingRecovery = true
                                Task {
                                    defer { requestingRecovery = false }
                                    do {
                                        recoveryProgress = try await PhoneUploadService.shared.recoverOriginalAudio(recordingID: recordingID)
                                    } catch {
                                        errorMessage = "Could not start audio recovery: \(error.localizedDescription)"
                                    }
                                }
                            } label: {
                                Label(requestingRecovery ? "Requesting audio…" : "Recover original audio", systemImage: "arrow.down.circle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(requestingRecovery || recoveryProgress?.status == "complete")
                        }
                    }
                } else if isLoading {
                    ProgressView("Loading meeting")
                        .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .padding(20)
        }
        .background(ScribeTheme.background.ignoresSafeArea())
        .foregroundStyle(.white)
        .navigationTitle("Meeting")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("Remove local copy", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Remove this local meeting copy?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("Remove local copy", role: .destructive) {
                Task {
                    await memoService.delete(memo)
                    if memoService.errorMessage == nil { dismiss() }
                    else { errorMessage = memoService.errorMessage }
                }
            }
        } message: {
            Text("The meeting page already saved in Notion will be kept.")
        }
        .task {
            while !Task.isCancelled {
                do {
                    detail = try await PhoneMemoAPIClient.shared.getMemo(id: memo.id)
                    errorMessage = nil
                } catch is CancellationError {
                    return
                } catch {
                    errorMessage = error.localizedDescription
                    isLoading = false
                    return
                }
                isLoading = false
                if detail?.status == "done" || detail?.status == "failed" { return }
                do { try await Task.sleep(for: .seconds(10)) }
                catch { return }
            }
        }
        .task(id: recoveryProgress?.recordingID) {
            guard let recordingID = recoveryProgress?.recordingID else { return }
            while !Task.isCancelled && recoveryProgress?.status != "complete" {
                do {
                    try await Task.sleep(for: .seconds(4))
                    recoveryProgress = try await PhoneMemoAPIClient.shared.getAudioRecovery(id: recordingID)
                } catch is CancellationError {
                    return
                } catch {
                    // Background uploads retain their own retry state.
                    // Leaving and reopening this view does not discard audio.
                    return
                }
            }
        }
        .alert("Scribe Pilot", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private var originalRecordingID: String? {
        let parts = memo.originalFilename.split(separator: "_")
        guard parts.count == 4, parts[0] == "stream",
              parts[1].count == 32, parts[1].allSatisfy(\.isHexDigit) else { return nil }
        return String(parts[1])
    }

    private func copyTranscriptAndOpenGemini(_ transcript: String) {
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: transcript]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(5 * 60),
            ]
        )
        copiedForGemini = true
        openURL(PhoneGeminiSettings.resolvedURL(serverURL: memoService.destination?.geminiURL))
    }

    private func section<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline.weight(.bold))
                .foregroundStyle(.cyan)
            content()
                .font(.body)
                .foregroundStyle(.white.opacity(0.86))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
