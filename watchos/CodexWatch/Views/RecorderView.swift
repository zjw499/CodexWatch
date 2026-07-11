import SwiftUI

struct RecorderView: View {
    @EnvironmentObject private var recorder: AudioRecorderService
    @EnvironmentObject private var store: CodexWatchStore
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("Codex Watch")
                    .font(.headline)

                Text(recorder.isRecording ? "Recording" : recorder.statusMessage)
                    .font(.caption)
                    .foregroundStyle(recorder.isRecording ? .red : .white.opacity(0.7))
                    .multilineTextAlignment(.center)

                if recorder.isRecording {
                    Text(formatDuration(recorder.elapsedTime))
                        .font(.system(size: 30, weight: .semibold, design: .monospaced))

                    Button {
                        recorder.stopRecording()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .tint(.red)
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        Task { await recorder.startRecording() }
                    } label: {
                        Label("Record", systemImage: "record.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .tint(.red)
                    .buttonStyle(.borderedProminent)
                }

                if let recordingURL = recorder.lastRecordingURL, !recorder.isRecording {
                    Text(recordingURL.lastPathComponent)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(2)

                    Button {
                        Task { await recorder.uploadLastRecording() }
                    } label: {
                        Label("Send to PC", systemImage: "arrow.up.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(recorder.isUploading || !recorder.hasUploadConfiguration)
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)

                    Button("Delete Recording", role: .destructive) {
                        recorder.deleteLastRecording()
                    }
                    .disabled(recorder.isUploading)
                }

                if !recorder.hasUploadConfiguration {
                    Text("This build has no PC upload endpoint configured.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }

                NavigationLink("Codex Desktop") {
                    if store.selectedDesktop == nil {
                        DesktopPickerView()
                    } else {
                        HomeView()
                    }
                }
                .font(.caption2)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
        }
        .scrollIndicators(.hidden)
        .background(Color.black)
        .navigationTitle("Record")
        .onReceive(timer) { _ in
            recorder.updateElapsedTime()
        }
        .task {
            await recorder.prepare()
        }
        .alert("Recorder Error", isPresented: Binding(
            get: { recorder.errorMessage != nil },
            set: { if !$0 { recorder.errorMessage = nil } }
        )) {
            Button("OK") { recorder.errorMessage = nil }
        } message: {
            Text(recorder.errorMessage ?? "Unknown recorder error")
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration))
        return String(format: "%02d:%02d:%02d", totalSeconds / 3600, (totalSeconds / 60) % 60, totalSeconds % 60)
    }
}
