import SwiftUI

struct RecorderView: View {
    @EnvironmentObject private var recorder: AudioRecorderService
    @ObservedObject private var transfer = WatchConnectivityTransferService.shared
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private let coral = Color(red: 1.0, green: 0.36, blue: 0.24)
    private let aqua = Color(red: 0.25, green: 0.82, blue: 0.78)

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [Color.black, Color(red: 0.08, green: 0.04, blue: 0.06)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(spacing: 4) {
                    compactHeader
                    Spacer(minLength: 0)
                    recordControl(diameter: controlDiameter(for: proxy.size))
                    Spacer(minLength: 0)
                    transferStatus
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
            }
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

    private var compactHeader: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(recorder.isRecording ? coral : aqua)
                .frame(width: 6, height: 6)
                .shadow(color: (recorder.isRecording ? coral : aqua).opacity(0.8), radius: 4)

            Text("SCRIBE PILOT")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 2)

            Text(recorder.isRecording
                ? (recorder.isPausedForInterruption ? "PAUSED" : "RECORDING")
                : "READY")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(recorder.isPausedForInterruption ? .yellow : .white.opacity(0.62))
        }
        .frame(height: 15)
    }

    private func recordControl(diameter: CGFloat) -> some View {
        VStack(spacing: 2) {
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
                        .stroke((recorder.isRecording ? coral : aqua).opacity(0.3), lineWidth: 1)
                        .frame(width: diameter + 8, height: diameter + 8)
                    Circle()
                        .fill((recorder.isRecording ? coral : aqua).opacity(0.14))
                        .frame(width: diameter, height: diameter)
                    Circle()
                        .fill(recorder.isRecording ? coral : .white.opacity(0.12))
                        .frame(width: diameter - 12, height: diameter - 12)
                        .shadow(color: (recorder.isRecording ? coral : aqua).opacity(0.45), radius: 8)
                    Image(systemName: recorder.isRecording
                        ? (recorder.isPausedForInterruption ? "play.fill" : "stop.fill")
                        : "mic.fill")
                        .font(.system(size: max(18, diameter * 0.27), weight: .bold))
                        .foregroundStyle(recorder.isRecording ? .white : aqua)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(recorder.isRecording
                ? (recorder.isPausedForInterruption ? "Resume recording" : "Finish recording")
                : "Start recording")

            Text(recorder.isRecording ? formatDuration(recorder.elapsedTime) : "Tap to record")
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .animation(.easeInOut(duration: 0.2), value: recorder.isRecording)
    }

    private var transferStatus: some View {
        HStack(spacing: 5) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(aqua)

            Text(transferLabel)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.68))
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Spacer(minLength: 2)

            if let countLabel {
                Text(countLabel)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(aqua)
            }

            if recorder.isRecording && recorder.isPausedForInterruption {
                Button {
                    recorder.stopRecording()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.bordered)
                .tint(coral)
                .accessibilityLabel("Finish paused recording")
            } else if !recorder.isRecording && transfer.lastRecordingID != nil {
                Button {
                    transfer.retryLastRecording()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.bordered)
                .tint(aqua)
                .accessibilityLabel("Retry last upload")
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 25)
        .background(.white.opacity(0.08), in: Capsule())
    }

    private var transferLabel: String {
        if recorder.isRecording && recorder.isPausedForInterruption {
            return "Audio saved; tap play"
        }
        if transfer.statusMessage.isEmpty {
            return "Relay ready"
        }
        return transfer.statusMessage
    }

    private var countLabel: String? {
        guard transfer.queuedChunkCount > 0 else { return nil }
        return "\(min(transfer.deliveredChunkCount, transfer.queuedChunkCount))/\(transfer.queuedChunkCount)"
    }

    private func controlDiameter(for size: CGSize) -> CGFloat {
        min(76, max(68, size.height * 0.42))
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration))
        return String(format: "%02d:%02d:%02d", totalSeconds / 3600, (totalSeconds / 60) % 60, totalSeconds % 60)
    }
}
