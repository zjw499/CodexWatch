import AVFoundation
import Combine
import Foundation

@MainActor
final class PhoneRecorderService: NSObject, ObservableObject {
    static let shared = PhoneRecorderService()

    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var audioLevel: CGFloat = 0
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var statusMessage = "Ready to record"
    @Published var errorMessage: String?

    private var recorder: AVAudioRecorder?

    func startRecording() async {
        guard !isRecording else {
            statusMessage = "Already recording"
            return
        }
        errorMessage = nil
        guard await requestMicrophonePermission() else {
            statusMessage = "Allow microphone access in Settings"
            return
        }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .default, options: [.allowBluetooth])
            try audioSession.setActive(true)

            let directory = try recordingsDirectory()
            let fileURL = directory.appendingPathComponent("phone_\(UUID().uuidString.lowercased()).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 48_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
            recorder.isMeteringEnabled = true
            recorder.prepareToRecord()
            guard recorder.record() else {
                throw NSError(
                    domain: "CodexWatch",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The iPhone could not start recording."]
                )
            }

            self.recorder = recorder
            elapsedTime = 0
            isRecording = true
            isPaused = false
            statusMessage = "Recording"
        } catch {
            try? AVAudioSession.sharedInstance().setActive(false)
            errorMessage = error.localizedDescription
            statusMessage = "Ready to record"
        }
    }

    func updateElapsedTime() {
        guard let recorder, recorder.isRecording else { return }
        elapsedTime = recorder.currentTime
        recorder.updateMeters()
        audioLevel = CGFloat(max(0, min(1, pow(10, recorder.averagePower(forChannel: 0) / 25))))
    }

    func pauseRecording() {
        guard isRecording, !isPaused else { return }
        recorder?.pause()
        isPaused = true
        audioLevel = 0
    }

    func resumeRecording() {
        guard isRecording, isPaused else { return }
        if recorder?.record() == true { isPaused = false }
        else { errorMessage = "Recording could not resume. Finish this recording to keep the saved audio." }
    }

    func stopRecording() {
        guard let recorder else { return }
        recorder.stop()
        self.recorder = nil
        isRecording = false
        isPaused = false
        audioLevel = 0
        elapsedTime = recorder.currentTime
        statusMessage = "Saved to recording queue"
        try? AVAudioSession.sharedInstance().setActive(false)
        PhoneOpenAIService.shared.receive(fileURL: recorder.url,
            id: recorder.url.deletingPathExtension().lastPathComponent,
            source: "iPhone", duration: elapsedTime)
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func recordingsDirectory() throws -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
        try RecordingQueueStore.protectDirectory(directory)
        return directory
    }
}
