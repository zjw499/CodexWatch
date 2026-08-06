import SwiftUI

struct RecorderView: View {
    @EnvironmentObject private var recorder: AudioRecorderService
    @ObservedObject private var transfer = WatchConnectivityTransferService.shared
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private let coral = Color(red: 1.0, green: 0.36, blue: 0.24)
    private let aqua = Color(red: 0.25, green: 0.82, blue: 0.78)

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color(red: 0.08, green: 0.04, blue: 0.06)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 7) {
                header
                recordControl
                transferStatus
                retryAction
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
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

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text("SCRIBE PILOT")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.5)
                    .foregroundStyle(.white.opacity(0.55))
                Text(recorder.isRecording
                    ? (recorder.isPausedForInterruption ? "Paused" : "Recording")
                    : "Ready")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
            }
            Spacer(minLength: 0)
            Circle()
                .fill(recorder.isRecording ? coral : aqua)
                .frame(width: 8, height: 8)
                .shadow(color: (recorder.isRecording ? coral : aqua).opacity(0.8), radius: 5)
        }
        .padding(.horizontal, 5)
    }

    private var recordControl: some View {
        VStack(spacing: 4) {
            Button {
                if recorder.isRecording {
                    if recorder.isPausedForInterruption {
                        recorder.resumeRecording()
                    } else {
                        recorder.stopRecording()
                    }
                } else {
                    Task { await recorder.startRecording() }
                }
            } label: {
                ZStack {
                    Circle()
                        .stroke((recorder.isRecording ? coral : aqua).opacity(0.24), lineWidth: 1)
                        .frame(width: 116, height: 116)
                    Circle()
                        .fill((recorder.isRecording ? coral : aqua).opacity(0.13))
                        .frame(width: 96, height: 96)
                    Circle()
                        .fill(recorder.isRecording ? coral : .white.opacity(0.12))
                        .frame(width: 78, height: 78)
                        .shadow(color: (recorder.isRecording ? coral : aqua).opacity(0.45), radius: 12)
                    Image(systemName: recorder.isRecording
                        ? (recorder.isPausedForInterruption ? "play.fill" : "stop.fill")
                        : "mic.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(recorder.isRecording ? .white : aqua)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(recorder.isRecording
                ? (recorder.isPausedForInterruption ? "Resume recording" : "Finish recording")
                : "Start recording")

            Text(recorder.isRecording ? formatDuration(recorder.elapsedTime) : "Tap to record")
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .minimumScaleFactor(0.75)

            if recorder.isRecording && recorder.isPausedForInterruption {
                HStack(spacing: 5) {
                    Text("Audio paused; capture preserved")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.yellow.opacity(0.9))
                    Button("Finish") {
                        recorder.stopRecording()
                    }
                    .font(.caption2.weight(.bold))
                    .buttonStyle(.bordered)
                    .tint(coral)
                }
            } else {
                Text(recorder.isRecording ? "Tap to finish" : "Watch microphone ready")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: recorder.isRecording)
    }

    private var transferStatus: some View {
        HStack(spacing: 7) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.caption.weight(.bold))
                .foregroundStyle(aqua)
            VStack(alignment: .leading, spacing: 0) {
                Text("Relay")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                Text(transfer.statusMessage)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if transfer.queuedChunkCount > 0 {
                Text("\(min(transfer.deliveredChunkCount, transfer.queuedChunkCount))/\(transfer.queuedChunkCount)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(aqua)
            } else {
                Image(systemName: transfer.statusMessage.contains("delivered")
                    ? "checkmark.circle.fill" : "arrow.up.circle")
                    .foregroundStyle(transfer.statusMessage.contains("delivered") ? aqua : .white.opacity(0.45))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var retryAction: some View {
        if !recorder.isRecording, transfer.lastRecordingID != nil {
            Button {
                transfer.retryLastRecording()
            } label: {
                Label("Retry last send", systemImage: "arrow.clockwise")
                    .font(.caption.weight(.bold))
            }
            .buttonStyle(.bordered)
            .tint(aqua)
            .frame(height: 28)
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration))
        return String(format: "%02d:%02d:%02d", totalSeconds / 3600, (totalSeconds / 60) % 60, totalSeconds % 60)
    }
}
