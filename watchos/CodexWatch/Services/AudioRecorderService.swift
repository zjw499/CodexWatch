import AVFoundation
import Combine
import Foundation

@MainActor
final class AudioRecorderService: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isUploading = false
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var statusMessage = "Ready to record"
    @Published var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private let uploader = AudioUploadClient()

    var hasUploadConfiguration: Bool {
        CodexWatchConfiguration.audioUploadURL != nil
    }

    func prepare() async {
        guard !isRecording else { return }
        let granted = await requestMicrophonePermission()
        statusMessage = granted ? "Ready to record" : "Microphone permission is required"
    }

    func startRecording() async {
        errorMessage = nil
        guard await requestMicrophonePermission() else {
            statusMessage = "Allow microphone access in Watch Settings"
            return
        }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .default, options: [])
            try audioSession.setActive(true)

            let directory = try recordingsDirectory()
            let formatter = ISO8601DateFormatter()
            let name = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let fileURL = directory.appendingPathComponent("watch-\(name)-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 48_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
            recorder.prepareToRecord()
            guard recorder.record() else {
                throw NSError(domain: "CodexWatch", code: 1, userInfo: [NSLocalizedDescriptionKey: "The watch could not start recording."])
            }

            self.recorder = recorder
            lastRecordingURL = nil
            elapsedTime = 0
            isRecording = true
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
    }

    func stopRecording() {
        guard let recorder else { return }
        recorder.stop()
        self.recorder = nil
        isRecording = false
        elapsedTime = recorder.currentTime
        lastRecordingURL = recorder.url
        statusMessage = "Recording saved"
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    func uploadLastRecording() async {
        guard let lastRecordingURL else { return }
        isUploading = true
        errorMessage = nil
        statusMessage = "Sending to PC"
        defer { isUploading = false }

        do {
            try await uploader.upload(fileURL: lastRecordingURL)
            statusMessage = "Sent to PC"
        } catch {
            statusMessage = "Upload failed"
            errorMessage = error.localizedDescription
        }
    }

    func deleteLastRecording() {
        guard let lastRecordingURL else { return }
        try? FileManager.default.removeItem(at: lastRecordingURL)
        self.lastRecordingURL = nil
        elapsedTime = 0
        statusMessage = "Ready to record"
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func recordingsDirectory() throws -> URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
