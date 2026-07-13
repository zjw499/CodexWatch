import AVFoundation
import Combine
import Foundation

@MainActor
final class AudioRecorderService: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var statusMessage = "Ready to record"
    @Published private(set) var chunkCount = 0
    @Published var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var recordingID: String?
    private var chunkIndex = 0
    private var completedDuration: TimeInterval = 0
    private var rotationTask: Task<Void, Never>?
    private let chunkInterval: TimeInterval = 30
    static let shared = AudioRecorderService()

    private let transferService = WatchConnectivityTransferService.shared

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

            let recordingID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            self.recordingID = recordingID
            chunkIndex = 0
            chunkCount = 0
            completedDuration = 0
            self.recorder = try startChunk(recordingID: recordingID, index: chunkIndex)
            transferService.beginRecording(recordingID: recordingID)
            lastRecordingURL = nil
            elapsedTime = 0
            isRecording = true
            statusMessage = "Recording"
            startChunkRotation()
        } catch {
            try? AVAudioSession.sharedInstance().setActive(false)
            errorMessage = error.localizedDescription
            statusMessage = "Ready to record"
        }
    }

    func updateElapsedTime() {
        guard isRecording, let recorder else { return }
        guard recorder.isRecording else {
            stopRecording()
            errorMessage = "Recording was interrupted. The audio captured so far was saved and queued."
            return
        }
        elapsedTime = completedDuration + recorder.currentTime
    }

    func stopRecording() {
        guard let recorder, let recordingID else { return }
        rotationTask?.cancel()
        rotationTask = nil
        let finalDuration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        isRecording = false
        elapsedTime = completedDuration + finalDuration
        chunkCount = chunkIndex + 1
        let preferredFinalURL = completedChunkURL(
            recordingID: recordingID,
            index: chunkIndex,
            isFinal: true
        )
        try? FileManager.default.removeItem(at: preferredFinalURL)
        var transferURL = recorder.url
        do {
            try FileManager.default.moveItem(at: recorder.url, to: preferredFinalURL)
            transferURL = preferredFinalURL
        } catch {
            errorMessage = "Could not finalize the last audio chunk: \(error.localizedDescription)"
        }
        transferService.enqueueChunk(
            fileURL: transferURL,
            recordingID: recordingID,
            chunkIndex: chunkIndex,
            isFinal: true
        )
        self.recordingID = nil
        lastRecordingURL = nil
        statusMessage = "Final chunk queued"
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    func queueLastRecording() {
        guard let lastRecordingURL else { return }
        errorMessage = nil
        transferService.enqueue(fileURL: lastRecordingURL)
        statusMessage = "Queued for iPhone"
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

    private func startChunk(recordingID: String, index: Int) throws -> AVAudioRecorder {
        let directory = try recordingsDirectory()
        let fileURL = directory.appendingPathComponent(
            String(format: "active_%@_%06d.m4a", recordingID, index)
        )
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
            throw NSError(
                domain: "CodexWatch",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The watch could not start an audio segment."]
            )
        }
        return recorder
    }

    private func startChunkRotation() {
        rotationTask?.cancel()
        rotationTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(self?.chunkInterval ?? 30))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.rotateChunk()
            }
        }
    }

    private func rotateChunk() {
        guard isRecording, let recorder, let recordingID else { return }
        let completedChunkDuration = recorder.currentTime
        recorder.stop()
        completedDuration += completedChunkDuration
        let completedIndex = chunkIndex
        let preferredCompletedURL = completedChunkURL(
            recordingID: recordingID,
            index: completedIndex,
            isFinal: false
        )
        try? FileManager.default.removeItem(at: preferredCompletedURL)
        var completedURL = recorder.url
        do {
            try FileManager.default.moveItem(at: recorder.url, to: preferredCompletedURL)
            completedURL = preferredCompletedURL
        } catch {
            errorMessage = "Audio chunk \(completedIndex + 1) will transfer without renaming: \(error.localizedDescription)"
        }
        let nextIndex = completedIndex + 1
        do {
            let nextRecorder = try startChunk(recordingID: recordingID, index: nextIndex)
            self.recorder = nextRecorder
            chunkIndex = nextIndex
            chunkCount = nextIndex
            transferService.enqueueChunk(
                fileURL: completedURL,
                recordingID: recordingID,
                chunkIndex: completedIndex,
                isFinal: false
            )
            statusMessage = "Recording and sending chunk \(completedIndex + 1)"
        } catch {
            self.recorder = nil
            isRecording = false
            rotationTask?.cancel()
            let finalURL = completedChunkURL(
                recordingID: recordingID,
                index: completedIndex,
                isFinal: true
            )
            try? FileManager.default.removeItem(at: finalURL)
            var finalTransferURL = completedURL
            if (try? FileManager.default.moveItem(at: completedURL, to: finalURL)) != nil {
                finalTransferURL = finalURL
            }
            transferService.enqueueChunk(
                fileURL: finalTransferURL,
                recordingID: recordingID,
                chunkIndex: completedIndex,
                isFinal: true
            )
            self.recordingID = nil
            errorMessage = "Recording stopped after chunk \(completedIndex + 1): \(error.localizedDescription)"
            statusMessage = "Final chunk queued"
            try? AVAudioSession.sharedInstance().setActive(false)
        }
    }

    private func completedChunkURL(recordingID: String, index: Int, isFinal: Bool) -> URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
        return directory.appendingPathComponent(
            String(format: "stream_%@_%06d_%d.m4a", recordingID, index, isFinal ? 1 : 0)
        )
    }
}
