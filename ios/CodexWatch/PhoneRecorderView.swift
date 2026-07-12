import SwiftUI

struct PhoneRecorderView: View {
    @EnvironmentObject private var recorder: PhoneRecorderService
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: recorder.isRecording ? "waveform" : "mic.fill")
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(recorder.isRecording ? .red : .blue)

            Text(recorder.isRecording ? "Recording" : recorder.statusMessage)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

            if recorder.isRecording {
                Text(formatDuration(recorder.elapsedTime))
                    .font(.system(size: 40, weight: .semibold, design: .monospaced))
            }

            Button {
                if recorder.isRecording {
                    recorder.stopRecording()
                } else {
                    Task { await recorder.startRecording() }
                }
            } label: {
                Label(
                    recorder.isRecording ? "Stop Recording" : "Start Recording",
                    systemImage: recorder.isRecording ? "stop.fill" : "record.circle.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(recorder.isRecording ? .red : .blue)

            Text("Watch recordings arrive here and upload to your PC in the background.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding(24)
        .navigationTitle("Codex Watch")
        .onReceive(timer) { _ in
            recorder.updateElapsedTime()
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
