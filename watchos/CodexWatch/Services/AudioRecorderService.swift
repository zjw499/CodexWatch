import AVFoundation
import Combine
import Foundation

private struct PersistedRecordingState: Codable {
    let recordingID: String
    let nextChunkIndex: Int
    let completedDuration: TimeInterval
}

@MainActor
final class AudioRecorderService: NSObject, ObservableObject, AVAudioRecorderDelegate {
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
    private var recoveryTask: Task<Void, Never>?
    private var audioInterrupted = false
    private var awaitingInterruptionEnd = false
    private var recoveryAttempts = 0
    private var pendingChunkIndex: Int?
    private var durationLimitedRecorder: AVAudioRecorder?
    private let chunkInterval: TimeInterval = 30
    private let persistedRecordingKey = "CodexWatch.ActiveRecordingState"
    static let shared = AudioRecorderService()

    private let transferService = WatchConnectivityTransferService.shared

    override init() {
        super.init()
        let audioSession = AVAudioSession.sharedInstance()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: audioSession
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: audioSession
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMediaServicesReset(_:)),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: audioSession
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func prepare() async {
        guard !isRecording else { return }
        let granted = await requestMicrophonePermission()
        guard granted else {
            statusMessage = "Microphone permission is required"
            return
        }
        restoreInterruptedRecordingIfNeeded()
        if !isRecording {
            statusMessage = "Ready to record"
        }
    }

    func startRecording() async {
        guard !isRecording else {
            statusMessage = "Already recording"
            return
        }
        errorMessage = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        audioInterrupted = false
        awaitingInterruptionEnd = false
        isPausedForInterruption = false
        recoveryAttempts = 0
        pendingChunkIndex = nil
        durationLimitedRecorder = nil

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
            persistRecordingState()
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
        guard isRecording else { return }
        guard let recorder else {
            if !awaitingInterruptionEnd {
                scheduleRecovery()
            }
            return
        }
        guard recorder.isRecording else {
            elapsedTime = completedDuration + recorder.currentTime
            if durationLimitedRecorder === recorder,
               recorder.currentTime >= chunkInterval - 0.5 {
                // The system is about to deliver the duration-limit callback.
                return
            }
            guard !awaitingInterruptionEnd else { return }
            preserveCurrentChunkForRecovery()
            audioInterrupted = true
            isPausedForInterruption = true
            statusMessage = "Audio paused; recording preserved"
            scheduleRecovery()
            return
        }
        elapsedTime = completedDuration + recorder.currentTime
    }

    func stopRecording() {
        guard let recordingID else { return }
        recoveryTask?.cancel()
        recoveryTask = nil
        audioInterrupted = false
        awaitingInterruptionEnd = false
        isPausedForInterruption = false
        recoveryAttempts = 0
        pendingChunkIndex = nil
        durationLimitedRecorder = nil

        if let recorder {
            let finalDuration = recorder.currentTime
            let currentIndex = chunkIndex
            recorder.stop()
            self.recorder = nil
            completedDuration += finalDuration
            elapsedTime = completedDuration
            chunkCount = currentIndex + 1
            let transferURL = finalizeChunk(
                recorderURL: recorder.url,
                recordingID: recordingID,
                index: currentIndex,
                isFinal: true
            )
            transferService.enqueueChunk(
                fileURL: transferURL,
                recordingID: recordingID,
                chunkIndex: currentIndex,
                isFinal: true
            )
        } else {
            // If audio is unavailable, promote the last preserved partial chunk
            // to final instead of losing the recording or waiting for Resume.
            finalizePreservedChunks(recordingID: recordingID)
        }

        isRecording = false
        self.recordingID = nil
        clearPersistedRecordingState()
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

    func appDidEnterBackground() {
        guard isRecording else { return }
        // The audio background mode keeps AVAudioRecorder alive; this manifest
        // protects the session if watchOS suspends or terminates the UI process.
        persistRecordingState()
        transferService.recoverSavedTransfers()
    }

    func appDidBecomeActive() {
        guard isRecording else { return }
        persistRecordingState()
        if recorder == nil, !awaitingInterruptionEnd {
            scheduleRecovery()
        }
        transferService.recoverSavedTransfers()
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
        recorder.delegate = self
        recorder.prepareToRecord()
        guard recorder.record(forDuration: chunkInterval) else {
            throw NSError(
                domain: "CodexWatch",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The watch could not start an audio segment."]
            )
        }
        durationLimitedRecorder = recorder
        return recorder
    }

    private func rotateChunk() {
        guard isRecording, !audioInterrupted, let recorder, let recordingID else { return }
        let completedChunkDuration = recorder.currentTime
        let completedIndex = chunkIndex
        durationLimitedRecorder = nil
        recorder.stop()
        self.recorder = nil
        completedDuration += completedChunkDuration

        let completedURL = finalizeChunk(
            recorderURL: recorder.url,
            recordingID: recordingID,
            index: completedIndex,
            isFinal: false
        )
        transferService.enqueueChunk(
            fileURL: completedURL,
            recordingID: recordingID,
            chunkIndex: completedIndex,
            isFinal: false
        )

        let nextIndex = completedIndex + 1
        chunkIndex = nextIndex
        chunkCount = nextIndex
        pendingChunkIndex = nextIndex
        persistRecordingState()

        do {
            self.recorder = try startChunk(recordingID: recordingID, index: nextIndex)
            pendingChunkIndex = nil
            audioInterrupted = false
            isPausedForInterruption = false
            statusMessage = "Recording and sending chunk \(completedIndex + 1)"
            persistRecordingState()
        } catch {
            audioInterrupted = true
            isPausedForInterruption = true
            statusMessage = "Audio paused; recording preserved"
            scheduleRecovery()
        }
    }

    nonisolated func audioRecorderDidFinishRecording(
        _ recorder: AVAudioRecorder,
        successfully flag: Bool
    ) {
        Task { @MainActor [weak self] in
            self?.handleAutomaticChunkCompletion(recorder, successfully: flag)
        }
    }

    private func handleAutomaticChunkCompletion(
        _ finishedRecorder: AVAudioRecorder,
        successfully: Bool
    ) {
        guard isRecording,
              recorder === finishedRecorder,
              durationLimitedRecorder === finishedRecorder else { return }

        durationLimitedRecorder = nil
        guard successfully else {
            preserveCurrentChunkForRecovery()
            audioInterrupted = true
            isPausedForInterruption = true
            statusMessage = "Audio paused; recording preserved"
            scheduleRecovery()
            return
        }
        rotateChunk()
    }

    @objc private func handleAudioInterruption(_ notification: Notification) {
        guard isRecording,
              let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }

        switch type {
        case .began:
            awaitingInterruptionEnd = true
            preserveCurrentChunkForRecovery()
            audioInterrupted = true
            isPausedForInterruption = true
            statusMessage = "Audio interrupted; recording preserved"
            scheduleRecovery()
        case .ended:
            awaitingInterruptionEnd = false
            audioInterrupted = true
            isPausedForInterruption = true
            statusMessage = "Audio interruption ended; recovering"
            scheduleRecovery()
        @unknown default:
            preserveCurrentChunkForRecovery()
            audioInterrupted = true
            isPausedForInterruption = true
            statusMessage = "Audio interruption; recording preserved"
        }
    }

    @objc private func handleAudioRouteChange(_ notification: Notification) {
        guard isRecording,
              let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason),
              reason != .categoryChange else { return }
        preserveCurrentChunkForRecovery()
        audioInterrupted = true
        isPausedForInterruption = true
        statusMessage = "Audio route changed; recording preserved"
        scheduleRecovery()
    }

    @objc private func handleMediaServicesReset(_ notification: Notification) {
        guard isRecording else { return }
        awaitingInterruptionEnd = false
        preserveCurrentChunkForRecovery()
        audioInterrupted = true
        isPausedForInterruption = true
        statusMessage = "Audio service reset; recording preserved"
        scheduleRecovery()
    }

    private func scheduleRecovery() {
        guard isRecording, recoveryTask == nil else { return }

        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.isRecording {
                if !self.awaitingInterruptionEnd, self.tryToResumeRecording() {
                    self.recoveryTask = nil
                    return
                }
                self.statusMessage = self.awaitingInterruptionEnd
                    ? "Interruption active; recording saved"
                    : "Audio unavailable; recording saved"
                try? await Task.sleep(for: .seconds(2))
            }
            self.recoveryTask = nil
        }
    }

    private func tryToResumeRecording() -> Bool {
        guard isRecording, !awaitingInterruptionEnd, let recordingID else { return false }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .default, options: [])
            try audioSession.setActive(true)

            let nextIndex = pendingChunkIndex ?? chunkIndex
            let nextRecorder = try startChunk(recordingID: recordingID, index: nextIndex)
            self.recorder = nextRecorder
            self.chunkIndex = nextIndex
            self.chunkCount = nextIndex
            self.pendingChunkIndex = nil
            audioInterrupted = false
            isPausedForInterruption = false
            recoveryAttempts = 0
            statusMessage = "Recording resumed"
            persistRecordingState()
            return true
        } catch {
            recoveryAttempts += 1
            return false
        }
    }

    private func preserveCurrentChunkForRecovery() {
        guard let recorder, let recordingID else {
            persistRecordingState()
            return
        }

        let partialDuration = recorder.currentTime
        let interruptedIndex = chunkIndex
        durationLimitedRecorder = nil
        recorder.stop()
        self.recorder = nil
        completedDuration += partialDuration

        let transferURL = finalizeChunk(
            recorderURL: recorder.url,
            recordingID: recordingID,
            index: interruptedIndex,
            isFinal: false
        )
        transferService.enqueueChunk(
            fileURL: transferURL,
            recordingID: recordingID,
            chunkIndex: interruptedIndex,
            isFinal: false
        )
        let nextIndex = interruptedIndex + 1
        chunkIndex = nextIndex
        chunkCount = nextIndex
        pendingChunkIndex = nextIndex
        persistRecordingState()
    }

    private func finalizeChunk(
        recorderURL: URL,
        recordingID: String,
        index: Int,
        isFinal: Bool
    ) -> URL {
        let preferredURL = completedChunkURL(
            recordingID: recordingID,
            index: index,
            isFinal: isFinal
        )
        try? FileManager.default.removeItem(at: preferredURL)
        guard recorderURL != preferredURL else { return recorderURL }
        do {
            try FileManager.default.moveItem(at: recorderURL, to: preferredURL)
            return preferredURL
        } catch {
            do {
                try FileManager.default.copyItem(at: recorderURL, to: preferredURL)
                return preferredURL
            } catch {
                errorMessage = "Could not finalize audio chunk \(index + 1): \(error.localizedDescription)"
                return recorderURL
            }
        }
    }

    private func finalizePreservedChunks(recordingID: String) {
        let directory = (try? recordingsDirectory()) ?? FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Recordings", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let prefix = "stream_\(recordingID)_"
        let candidates = files.filter {
            $0.lastPathComponent.hasPrefix(prefix) &&
            $0.lastPathComponent.hasSuffix("_0.m4a")
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let lastPartial = candidates.last else {
            return
        }
        let parts = lastPartial.deletingPathExtension().lastPathComponent.split(separator: "_")
        guard parts.count == 4, let index = Int(parts[2]) else {
            return
        }
        let finalURL = completedChunkURL(recordingID: recordingID, index: index, isFinal: true)
        try? FileManager.default.removeItem(at: finalURL)
        do {
            try FileManager.default.copyItem(at: lastPartial, to: finalURL)
            transferService.enqueueChunk(
                fileURL: finalURL,
                recordingID: recordingID,
                chunkIndex: index,
                isFinal: true
            )
        } catch {
            errorMessage = "Could not finalize the preserved audio: \(error.localizedDescription)"
        }
    }

    private func persistRecordingState() {
        guard let recordingID else { return }
        let state = PersistedRecordingState(
            recordingID: recordingID,
            nextChunkIndex: chunkIndex,
            completedDuration: completedDuration
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: persistedRecordingKey)
    }

    private func clearPersistedRecordingState() {
        UserDefaults.standard.removeObject(forKey: persistedRecordingKey)
    }

    private func restoreInterruptedRecordingIfNeeded() {
        guard !isRecording else { return }
        let state: PersistedRecordingState
        if let data = UserDefaults.standard.data(forKey: persistedRecordingKey),
           let persisted = try? JSONDecoder().decode(PersistedRecordingState.self, from: data) {
            state = persisted
        } else if let orphanID = orphanRecordingID() {
            // The manifest is written before recording starts, but recover an
            // orphaned active file too if termination happened during startup.
            state = PersistedRecordingState(
                recordingID: orphanID,
                nextChunkIndex: 0,
                completedDuration: 0
            )
        } else {
            return
        }

        recordingID = state.recordingID
        chunkIndex = state.nextChunkIndex
        chunkCount = state.nextChunkIndex
        completedDuration = state.completedDuration
        pendingChunkIndex = state.nextChunkIndex
        audioInterrupted = true
        isPausedForInterruption = true
        isRecording = true
        transferService.restoreRecording(recordingID: state.recordingID)
        recoverActiveChunks(recordingID: state.recordingID)
        elapsedTime = completedDuration
        statusMessage = "Recovered recording; restoring audio"
        scheduleRecovery()
    }

    private func orphanRecordingID() -> String? {
        guard let directory = try? recordingsDirectory() else { return nil }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for fileURL in files where fileURL.lastPathComponent.hasPrefix("active_") {
            let parts = fileURL.deletingPathExtension().lastPathComponent.split(separator: "_")
            if parts.count == 3 {
                return String(parts[1])
            }
        }
        return nil
    }

    private func recoverActiveChunks(recordingID: String) {
        guard let directory = try? recordingsDirectory() else { return }
        let prefix = "active_\(recordingID)_"
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        var highestIndex = chunkIndex - 1
        for fileURL in files.filter({ $0.lastPathComponent.hasPrefix(prefix) }) {
            let parts = fileURL.deletingPathExtension().lastPathComponent.split(separator: "_")
            guard let index = Int(parts.last ?? "") else { continue }
            let streamURL = completedChunkURL(recordingID: recordingID, index: index, isFinal: false)
            try? FileManager.default.removeItem(at: streamURL)
            do {
                try FileManager.default.moveItem(at: fileURL, to: streamURL)
                transferService.enqueueChunk(
                    fileURL: streamURL,
                    recordingID: recordingID,
                    chunkIndex: index,
                    isFinal: false
                )
                highestIndex = max(highestIndex, index)
            } catch {
                errorMessage = "Could not recover audio chunk \(index + 1): \(error.localizedDescription)"
            }
        }
        chunkIndex = max(chunkIndex, highestIndex + 1)
        chunkCount = chunkIndex
        pendingChunkIndex = chunkIndex
        persistRecordingState()
    }

    private func completedChunkURL(recordingID: String, index: Int, isFinal: Bool) -> URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
        return directory.appendingPathComponent(
            String(format: "stream_%@_%06d_%d.m4a", recordingID, index, isFinal ? 1 : 0)
        )
    }
}
