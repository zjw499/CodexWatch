import SwiftUI

struct RecorderView: View {
    @EnvironmentObject private var recorder: AudioRecorderService
    @EnvironmentObject private var store: CodexWatchStore
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

            ScrollView {
                VStack(spacing: 12) {
                    header
                    recordControl
                    transferStatus

                    if !recorder.isRecording, transfer.lastRecordingID != nil {
                        Button {
                            transfer.retryLastRecording()
                        } label: {
                            Label("Retry last send", systemImage: "arrow.clockwise")
                                .font(.caption.weight(.bold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(aqua)
                    }

                    if let recordingURL = recorder.lastRecordingURL, !recorder.isRecording {
                        pendingRecording(url: recordingURL)
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "desktopcomputer")
                            .foregroundStyle(aqua)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("PC processing")
                                .font(.caption.weight(.semibold))
                            Text("iPhone relays the audio automatically")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        Spacer()
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(aqua.opacity(0.8))
                    }
                    .foregroundStyle(.white.opacity(0.76))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
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
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("CODEX")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(.white.opacity(0.5))
                Text(recorder.isRecording ? "Recording" : "Ready")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
            }
            Spacer()
            Circle()
                .fill(recorder.isRecording ? coral : aqua)
                .frame(width: 9, height: 9)
                .shadow(color: (recorder.isRecording ? coral : aqua).opacity(0.7), radius: 5)
        }
        .padding(.horizontal, 6)
    }

    private var recordControl: some View {
        VStack(spacing: 9) {
            ZStack {
                Circle()
                    .stroke((recorder.isRecording ? coral : aqua).opacity(0.22), lineWidth: 1)
                    .frame(width: 142, height: 142)
                Circle()
                    .fill((recorder.isRecording ? coral : aqua).opacity(0.13))
                    .frame(width: 118, height: 118)
                Circle()
                    .fill(recorder.isRecording ? coral : .white.opacity(0.12))
                    .frame(width: 92, height: 92)
                    .shadow(color: (recorder.isRecording ? coral : aqua).opacity(0.4), radius: 14)
                Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(recorder.isRecording ? .white : aqua)
            }
            .animation(.easeInOut(duration: 0.2), value: recorder.isRecording)

            if recorder.isRecording {
                Text(formatDuration(recorder.elapsedTime))
                    .font(.system(size: 25, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            } else {
                Text("Tap to capture")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.65))
            }

            Button {
                if recorder.isRecording {
                    recorder.stopRecording()
                } else {
                    Task { await recorder.startRecording() }
                }
            } label: {
                Text(recorder.isRecording ? "Finish" : "Record")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(recorder.isRecording ? coral : aqua)
        }
        .padding(.vertical, 9)
    }

    private var transferStatus: some View {
        HStack(spacing: 8) {
            Image(systemName: "iphone.and.arrow.forward")
                .foregroundStyle(aqua)
            VStack(alignment: .leading, spacing: 1) {
                Text("To iPhone")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                Text(transfer.statusMessage)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer()
            if transfer.queuedChunkCount > 0 {
                Text("\(transfer.deliveredChunkCount)/\(transfer.queuedChunkCount)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(aqua)
            } else {
                Image(systemName: transfer.statusMessage.contains("delivered") ? "checkmark.circle.fill" : "arrow.up.circle")
                    .foregroundStyle(transfer.statusMessage.contains("delivered") ? aqua : .white.opacity(0.4))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private func pendingRecording(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Last capture", systemImage: "waveform")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(formatDuration(recorder.elapsedTime))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
            }
            Text(url.deletingPathExtension().lastPathComponent)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.48))
                .lineLimit(1)

            HStack(spacing: 8) {
                Button {
                    recorder.queueLastRecording()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(aqua)

                Button(role: .destructive) {
                    recorder.deleteLastRecording()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(coral.opacity(0.1), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(coral.opacity(0.22), lineWidth: 1)
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration))
        return String(format: "%02d:%02d:%02d", totalSeconds / 3600, (totalSeconds / 60) % 60, totalSeconds % 60)
    }
}
