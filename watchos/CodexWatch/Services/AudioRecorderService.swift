import AVFoundation
import Combine
import Foundation

private struct PersistedRecordingState: Codable {
    let recordingID: String
    let nextChunkIndex: Int
    let completedDuration: TimeInterval
}

private struct CompletedAudioChunk: Sendable {
    let recordingID: String
    let index: Int
    let url: URL
    let duration: TimeInterval
}

private enum AudioChunkWriterEvent: Sendable {
    case chunksReady
    case failed(String)
}

private final class ContinuousAudioChunkWriter: @unchecked Sendable {
    typealias EventHandler = @Sendable (ContinuousAudioChunkWriter, AudioChunkWriterEvent) -> Void

    private let lock = NSLock()
    private let recordingID: String
    private let directory: URL
    private let inputFormat: AVAudioFormat
    private let outputSettings: [String: Any]
    private let targetFrameCount: AVAudioFramePosition
    private let eventHandler: EventHandler

    private var currentFile: AVAudioFile?
    private var currentURL: URL?
    private var currentIndex: Int
    private var currentFrameCount: AVAudioFramePosition = 0
    private var pendingChunks: [CompletedAudioChunk] = []
    private var stopped = false

    init(
        recordingID: String,
        startingIndex: Int,
        directory: URL,
        inputFormat: AVAudioFormat,
        chunkInterval: TimeInterval,
        eventHandler: @escaping EventHandler
    ) throws {
        self.recordingID = recordingID
        self.currentIndex = startingIndex
        self.directory = directory
        self.inputFormat = inputFormat
        self.targetFrameCount = max(
            1,
            AVAudioFramePosition(inputFormat.sampleRate * chunkInterval)
        )
        self.eventHandler = eventHandler
        self.outputSettings = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: Int(inputFormat.channelCount),
            AVEncoderBitRateKey: 48_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        try openChunkFile(index: startingIndex)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        var event: AudioChunkWriterEvent?

        lock.lock()
        if !stopped, let currentFile {
            do {
                try currentFile.write(from: buffer)
                currentFrameCount += AVAudioFramePosition(buffer.frameLength)
                if currentFrameCount >= targetFrameCount {
                    closeCurrentChunkLocked()
                    currentIndex += 1
                    do {
                        try openChunkFile(index: currentIndex)
                        event = .chunksReady
                    } catch {
                        stopped = true
                        event = .failed("Could not open the next audio chunk: \(error.localizedDescription)")
                    }
                }
            } catch {
                closeCurrentChunkLocked()
                stopped = true
                event = .failed("Could not write the audio chunk: \(error.localizedDescription)")
            }
        }
        lock.unlock()

        if let event {
            eventHandler(self, event)
        }
    }

    func drainCompletedChunks() -> [CompletedAudioChunk] {
        lock.lock()
        let chunks = pendingChunks
        pendingChunks.removeAll(keepingCapacity: true)
        lock.unlock()
        return chunks
    }

    func finishAndDrain() -> [CompletedAudioChunk] {
        lock.lock()
        stopped = true
        closeCurrentChunkLocked()
        let chunks = pendingChunks
        pendingChunks.removeAll()
        lock.unlock()
        return chunks
    }

    func bufferedDuration() -> TimeInterval {
        lock.lock()
        let pendingDuration = pendingChunks.reduce(0) { $0 + $1.duration }
        let currentDuration = Double(currentFrameCount) / inputFormat.sampleRate
        lock.unlock()
        return pendingDuration + currentDuration
    }

    private func openChunkFile(index: Int) throws {
        let fileURL = directory.appendingPathComponent(
            String(format: "active_%@_%06d.m4a", recordingID, index)
        )
        try? FileManager.default.removeItem(at: fileURL)
        let file = try AVAudioFile(
            forWriting: fileURL,
            settings: outputSettings,
            commonFormat: inputFormat.commonFormat,
            interleaved: inputFormat.isInterleaved
        )
        currentURL = fileURL
        currentFile = file
        currentFrameCount = 0
    }

    private func closeCurrentChunkLocked() {
        guard let currentURL else { return }
        let frameCount = currentFrameCount
        currentFile = nil
        self.currentURL = nil
        currentFrameCount = 0

        guard frameCount > 0 else {
            try? FileManager.default.removeItem(at: currentURL)
            return
        }
        pendingChunks.append(CompletedAudioChunk(
            recordingID: recordingID,
            index: currentIndex,
            url: currentURL,
            duration: Double(frameCount) / inputFormat.sampleRate
        ))
    }
}

@MainActor
final class AudioRecorderService: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var statusMessage = "Ready to record"
    @Published private(set) var chunkCount = 0
    @Published private(set) var isPausedForInterruption = false
    @Published var errorMessage: String?

    private var audioEngine: AVAudioEngine?
    private var chunkWriter: ContinuousAudioChunkWriter?
    private var recordingID: String?
    private var chunkIndex = 0
    private var completedDuration: TimeInterval = 0
    private var recoveryTask: Task<Void, Never>?
    private var awaitingInterruptionEnd = false
    private var recoveryAttempts = 0
    private var pendingChunkIndex: Int?
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
        awaitingInterruptionEnd = false
        isPausedForInterruption = false
        recoveryAttempts = 0
        pendingChunkIndex = nil

        guard await requestMicrophonePermission() else {
            statusMessage = "Allow microphone access in Watch Settings"
            return
        }

        let newRecordingID = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        recordingID = newRecordingID
        chunkIndex = 0
        chunkCount = 0
        completedDuration = 0
        elapsedTime = 0
        isRecording = true
        transferService.beginRecording(recordingID: newRecordingID)
        persistRecordingState()

        do {
            try activateAudioSession()
            try startContinuousCapture(recordingID: newRecordingID, startingIndex: 0)
            lastRecordingURL = nil
            statusMessage = "Recording"
        } catch {
            _ = stopCaptureAndCollectChunks()
            isRecording = false
            recordingID = nil
            clearPersistedRecordingState()
            try? AVAudioSession.sharedInstance().setActive(false)
            errorMessage = error.localizedDescription
            statusMessage = "Ready to record"
        }
    }

    func updateElapsedTime() {
        guard isRecording else { return }
        if let chunkWriter {
            elapsedTime = completedDuration + chunkWriter.bufferedDuration()
        }
        if let audioEngine, !audioEngine.isRunning, !awaitingInterruptionEnd {
            isPausedForInterruption = true
            statusMessage = "Audio paused; restoring"
            scheduleRecovery()
        }
    }

    func stopRecording() {
        guard let recordingID else { return }
        recoveryTask?.cancel()
        recoveryTask = nil
        awaitingInterruptionEnd = false
        isPausedForInterruption = false
        recoveryAttempts = 0

        let remainingChunks = stopCaptureAndCollectChunks()
        if remainingChunks.isEmpty {
            finalizePreservedChunks(recordingID: recordingID)
        } else {
            processCompletedChunks(remainingChunks, finalChunkIndex: remainingChunks.count - 1)
        }

        elapsedTime = completedDuration
        isRecording = false
        self.recordingID = nil
        pendingChunkIndex = nil
        clearPersistedRecordingState()
        lastRecordingURL = nil
        statusMessage = "Final chunk queued"
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    func resumeRecording() {
        guard isRecording else { return }
        awaitingInterruptionEnd = false
        isPausedForInterruption = true
        statusMessage = "Resuming audio"
        scheduleRecovery()
    }

    func appDidEnterBackground() {
        guard isRecording else { return }
        persistRecordingState()
        transferService.recoverSavedTransfers()
    }

    func appDidBecomeActive() {
        guard isRecording else { return }
        persistRecordingState()
        awaitingInterruptionEnd = false
        if audioEngine?.isRunning == true {
            isPausedForInterruption = false
            statusMessage = "Recording"
        } else {
            isPausedForInterruption = true
            statusMessage = "Restoring recording"
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

    private func activateAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .default, options: [])
        try audioSession.setActive(true)
    }

    private func startContinuousCapture(recordingID: String, startingIndex: Int) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(
                domain: "CodexWatch",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The watch microphone is unavailable."]
            )
        }

        let writer = try ContinuousAudioChunkWriter(
            recordingID: recordingID,
            startingIndex: startingIndex,
            directory: try recordingsDirectory(),
            inputFormat: inputFormat,
            chunkInterval: chunkInterval
        ) { [weak self] writer, event in
            Task { @MainActor [weak self] in
                self?.handleWriterEvent(writer, event: event)
            }
        }

        inputNode.installTap(
            onBus: 0,
            bufferSize: 2_048,
            format: inputFormat
        ) { [weak writer] buffer, _ in
            writer?.append(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            _ = writer.finishAndDrain()
            throw error
        }

        audioEngine = engine
        chunkWriter = writer
        chunkIndex = startingIndex
        pendingChunkIndex = nil
        persistRecordingState()
    }

    private func handleWriterEvent(
        _ writer: ContinuousAudioChunkWriter,
        event: AudioChunkWriterEvent
    ) {
        let completed = writer.drainCompletedChunks()
        processCompletedChunks(completed, finalChunkIndex: nil)

        guard writer === chunkWriter else { return }
        switch event {
        case .chunksReady:
            statusMessage = "Recording and sending chunk \(chunkCount)"
        case .failed(let message):
            errorMessage = message
            preserveCurrentChunkForRecovery()
            isPausedForInterruption = true
            statusMessage = "Audio saved; restoring"
            scheduleRecovery()
        }
    }

    private func processCompletedChunks(
        _ chunks: [CompletedAudioChunk],
        finalChunkIndex: Int?
    ) {
        guard !chunks.isEmpty else { return }
        for (offset, chunk) in chunks.enumerated() {
            let isFinal = finalChunkIndex == offset
            let transferURL = finalizeChunk(
                recorderURL: chunk.url,
                recordingID: chunk.recordingID,
                index: chunk.index,
                isFinal: isFinal
            )
            transferService.enqueueChunk(
                fileURL: transferURL,
                recordingID: chunk.recordingID,
                chunkIndex: chunk.index,
                isFinal: isFinal
            )
            if chunk.recordingID == recordingID {
                completedDuration += chunk.duration
                chunkIndex = max(chunkIndex, chunk.index + 1)
                chunkCount = max(chunkCount, chunk.index + 1)
                pendingChunkIndex = chunkIndex
            }
        }
        persistRecordingState()
    }

    private func stopCaptureAndCollectChunks() -> [CompletedAudioChunk] {
        if let audioEngine {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        self.audioEngine = nil
        let writer = chunkWriter
        chunkWriter = nil
        return writer?.finishAndDrain() ?? []
    }

    private func preserveCurrentChunkForRecovery() {
        let completed = stopCaptureAndCollectChunks()
        processCompletedChunks(completed, finalChunkIndex: nil)
        pendingChunkIndex = chunkIndex
        persistRecordingState()
    }

    @objc private func handleAudioInterruption(_ notification: Notification) {
        guard isRecording,
              let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }

        switch type {
        case .began:
            awaitingInterruptionEnd = true
            isPausedForInterruption = true
            // Closing the current M4A writes its container metadata before
            // watchOS suspends or reclaims the audio route.
            preserveCurrentChunkForRecovery()
            statusMessage = "Audio interruption; recording held"
            persistRecordingState()
        case .ended:
            awaitingInterruptionEnd = false
            isPausedForInterruption = true
            statusMessage = "Audio interruption ended; restoring"
            scheduleRecovery()
        @unknown default:
            awaitingInterruptionEnd = false
            isPausedForInterruption = true
            scheduleRecovery()
        }
    }

    @objc private func handleAudioRouteChange(_ notification: Notification) {
        guard isRecording,
              let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) else { return }
        switch reason {
        case .oldDeviceUnavailable, .wakeFromSleep:
            awaitingInterruptionEnd = false
            isPausedForInterruption = true
            statusMessage = "Audio route changed; restoring"
            scheduleRecovery()
        default:
            return
        }
    }

    @objc private func handleMediaServicesReset(_ notification: Notification) {
        guard isRecording else { return }
        awaitingInterruptionEnd = false
        preserveCurrentChunkForRecovery()
        isPausedForInterruption = true
        statusMessage = "Audio service reset; restoring"
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
                    ? "Interruption active; recording held"
                    : "Audio unavailable; recording saved"
                try? await Task.sleep(for: .seconds(2))
            }
            self.recoveryTask = nil
        }
    }

    private func tryToResumeRecording() -> Bool {
        guard isRecording, !awaitingInterruptionEnd, let recordingID else { return false }

        do {
            try activateAudioSession()
            if let audioEngine, chunkWriter != nil {
                if !audioEngine.isRunning {
                    try audioEngine.start()
                }
            } else {
                let nextIndex = pendingChunkIndex ?? chunkIndex
                try startContinuousCapture(recordingID: recordingID, startingIndex: nextIndex)
            }
            isPausedForInterruption = false
            recoveryAttempts = 0
            statusMessage = "Recording resumed"
            persistRecordingState()
            return true
        } catch {
            recoveryAttempts += 1
            if recoveryAttempts == 3, chunkWriter != nil {
                preserveCurrentChunkForRecovery()
            }
            return false
        }
    }

    private func recordingsDirectory() throws -> URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
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
        guard let lastPartial = candidates.last else { return }
        let parts = lastPartial.deletingPathExtension().lastPathComponent.split(separator: "_")
        guard parts.count == 4, let index = Int(parts[2]) else { return }

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
        awaitingInterruptionEnd = false
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
