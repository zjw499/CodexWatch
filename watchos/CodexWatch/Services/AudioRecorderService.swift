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
    @Published private(set) var isPausedForInterruption = false
    @Published var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var recordingID: String?
    private var chunkIndex = 0
    private var completedDuration: TimeInterval = 0
    private var rotationTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var audioInterrupted = false
    private var awaitingInterruptionEnd = false
    private var recoveryAttempts = 0
    private var pendingChunkIndex: Int?
    private let chunkInterval: TimeInterval = 30
    static let shared = AudioRecorderService()

    private let transferService = WatchConnectivityTransferService.shared

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func prepare() async {
        guard !isRecording else { return }
        let granted = await requestMicrophonePermission()
        statusMessage = granted ? "Ready to record" : "Microphone permission is required"
    }

    func startRecording() async {
        errorMessage = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        audioInterrupted = false
        awaitingInterruptionEnd = false
        isPausedForInterruption = false
        recoveryAttempts = 0
        pendingChunkIndex = nil

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
            elapsedTime = completedDuration + recorder.currentTime
            guard !awaitingInterruptionEnd else { return }
            if !audioInterrupted {
                audioInterrupted = true
                isPausedForInterruption = true
                statusMessage = "Audio paused; recovering"
            }
            scheduleRecovery()
            return
        }
        elapsedTime = completedDuration + recorder.currentTime
    }

    func stopRecording() {
        guard let recordingID else { return }
        guard let recorder else {
            // A segment restart may still be pending after a transient audio failure.
            // Keep the session alive so the queued chunks are not incorrectly marked final.
            statusMessage = "Audio paused; tap Resume"
            return
        }
        rotationTask?.cancel()
        rotationTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        audioInterrupted = false
        awaitingInterruptionEnd = false
        isPausedForInterruption = false
        recoveryAttempts = 0
        pendingChunkIndex = nil
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

    func resumeRecording() {
        guard isRecording else { return }
        awaitingInterruptionEnd = false
        audioInterrupted = true
        isPausedForInterruption = true
        statusMessage = "Resuming audio"
        scheduleRecovery()
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
        try? FileManager.default.removeItem(at: fileURL)
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
        guard isRecording, !audioInterrupted, let recorder, let recordingID else { return }
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
            transferService.enqueueChunk(
                fileURL: completedURL,
                recordingID: recordingID,
                chunkIndex: completedIndex,
                isFinal: false
            )
            pendingChunkIndex = nextIndex
            audioInterrupted = true
            isPausedForInterruption = true
            statusMessage = "Audio paused; restarting segment"
            scheduleRecovery()
        }
    }

    @objc private func handleAudioInterruption(_ notification: Notification) {
        guard isRecording,
              let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }

        switch type {
        case .began:
            audioInterrupted = true
            awaitingInterruptionEnd = true
            isPausedForInterruption = true
            statusMessage = "Audio interrupted; preserving recording"
        case .ended:
            awaitingInterruptionEnd = false
            audioInterrupted = true
            isPausedForInterruption = true
            statusMessage = "Audio interruption ended; recovering"
            scheduleRecovery()
        @unknown default:
            break
        }
    }

    private func scheduleRecovery() {
        guard isRecording, !awaitingInterruptionEnd, recoveryTask == nil else { return }

        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for attempt in 0..<10 {
                guard !Task.isCancelled, self.isRecording else { return }
                if attempt > 0 {
                    try? await Task.sleep(for: .seconds(1))
                }
                guard !Task.isCancelled, self.isRecording else { return }
                if self.tryToResumeRecording() {
                    self.recoveryTask = nil
                    return
                }
            }
            self.recoveryTask = nil
            guard self.isRecording else { return }
            self.statusMessage = "Audio paused; tap Resume"
        }
    }

    private func tryToResumeRecording() -> Bool {
        guard isRecording, !awaitingInterruptionEnd, let recordingID else { return false }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .default, options: [])
            try audioSession.setActive(true)

            if let pendingChunkIndex {
                let nextRecorder = try startChunk(recordingID: recordingID, index: pendingChunkIndex)
                self.recorder = nextRecorder
                self.chunkIndex = pendingChunkIndex
                self.chunkCount = pendingChunkIndex
                self.pendingChunkIndex = nil
                audioInterrupted = false
                isPausedForInterruption = false
                recoveryAttempts = 0
                statusMessage = "Recording resumed"
                startChunkRotation()
                return true
            }

            guard let recorder else { return false }
            if recorder.isRecording || recorder.record() {
                audioInterrupted = false
                isPausedForInterruption = false
                recoveryAttempts = 0
                statusMessage = "Recording resumed"
                startChunkRotation()
                return true
            }
        } catch {
            // The next recovery attempt will retry after the system releases the audio session.
        }

        recoveryAttempts += 1
        return false
    }

    private func completedChunkURL(recordingID: String, index: Int, isFinal: Bool) -> URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
        return directory.appendingPathComponent(
            String(format: "stream_%@_%06d_%d.m4a", recordingID, index, isFinal ? 1 : 0)
        )
    }
}
