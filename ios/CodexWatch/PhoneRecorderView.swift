import SwiftUI

struct PhoneRecorderView: View {
    @EnvironmentObject private var recorder: PhoneRecorderService
    @EnvironmentObject private var uploader: PhoneUploadService
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private let background = Color(red: 0.035, green: 0.045, blue: 0.065)
    private let coral = Color(red: 1.0, green: 0.38, blue: 0.24)
    private let aqua = Color(red: 0.25, green: 0.82, blue: 0.78)

    private var isWorking: Bool {
        recorder.isRecording || uploader.statusMessage == "Uploading to PC"
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [background, Color(red: 0.08, green: 0.06, blue: 0.11)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    recordingCard
                    pipelineCard
                    footerActions
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
        }
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

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("CODEX WATCH")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .tracking(2.5)
                    .foregroundStyle(.white.opacity(0.58))
                Text(recorder.isRecording ? "Stay in the moment." : "Capture clearly.")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }

            Spacer()

            HStack(spacing: 7) {
                Circle()
                    .fill(isWorking ? coral : aqua)
                    .frame(width: 8, height: 8)
                Text(isWorking ? "ACTIVE" : "READY")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.1)
                    .foregroundStyle(.white.opacity(0.82))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(.white.opacity(0.08), in: Capsule())
        }
    }

    private var recordingCard: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(coral.opacity(recorder.isRecording ? 0.16 : 0.09))
                    .frame(width: 218, height: 218)
                Circle()
                    .stroke(coral.opacity(recorder.isRecording ? 0.62 : 0.25), lineWidth: 1)
                    .frame(width: 190, height: 190)
                Circle()
                    .fill(recorder.isRecording ? coral : .white.opacity(0.12))
                    .frame(width: 148, height: 148)
                    .shadow(color: coral.opacity(recorder.isRecording ? 0.42 : 0.12), radius: 24)
                Image(systemName: recorder.isRecording ? "stop.fill" : "waveform")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(recorder.isRecording ? .white : coral)
            }
            .animation(.easeInOut(duration: 0.25), value: recorder.isRecording)

            VStack(spacing: 6) {
                Text(recorder.isRecording ? "Recording" : "Ready to record")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(recorder.isRecording ? "Your audio stays on this device until it is processed." : "Press once. Stop when you are done.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.58))
                    .multilineTextAlignment(.center)
            }

            if recorder.isRecording {
                Text(formatDuration(recorder.elapsedTime))
                    .font(.system(size: 42, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            }

            Button {
                if recorder.isRecording {
                    recorder.stopRecording()
                } else {
                    Task { await recorder.startRecording() }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: recorder.isRecording ? "stop.fill" : "record.circle.fill")
                    Text(recorder.isRecording ? "Finish recording" : "Start recording")
                }
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .tint(recorder.isRecording ? coral : aqua)
            .foregroundStyle(.black)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(.white.opacity(0.09), lineWidth: 1)
        }
    }

    private var pipelineCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Your private pipeline")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(aqua)
            }

            PipelineRow(
                number: "01",
                title: "Record",
                detail: recorder.isRecording ? "Capturing audio now" : "Watch or iPhone microphone",
                tint: recorder.isRecording ? coral : aqua
            )
            PipelineRow(
                number: "02",
                title: "Transcribe",
                detail: "Groq Whisper transcription",
                tint: .white.opacity(0.62)
            )
            PipelineRow(
                number: "03",
                title: "Deliver",
                detail: compactStatus(uploader.statusMessage, fallback: "Email sent from your PC"),
                tint: uploader.statusMessage == "Uploaded to PC" ? aqua : .white.opacity(0.62)
            )
        }
        .padding(18)
        .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var footerActions: some View {
        VStack(spacing: 12) {
            Button {
                uploader.retryPendingRecordings()
            } label: {
                Label("Retry pending recordings", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.white.opacity(0.72))

            Text("The watch can record independently. Your iPhone relays the audio, then the PC sends it to Groq for transcription and emails the result.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.42))
                .multilineTextAlignment(.center)
        }
    }

    private func compactStatus(_ status: String, fallback: String) -> String {
        let cleaned = status.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : cleaned
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration))
        return String(format: "%02d:%02d:%02d", totalSeconds / 3600, (totalSeconds / 60) % 60, totalSeconds % 60)
    }
}

private struct PipelineRow: View {
    let number: String
    let title: String
    let detail: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Text(number)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.24))
        }
    }
}
