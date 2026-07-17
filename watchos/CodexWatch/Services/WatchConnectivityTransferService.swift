import Combine
import Foundation
import WatchConnectivity

private struct ImmediateWatchChunkEnvelope: Codable {
    let version: Int
    let filename: String
    let recordingID: String
    let chunkIndex: Int
    let isFinal: Bool
    let audioData: Data
}

final class WatchConnectivityTransferService: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchConnectivityTransferService()

    @Published private(set) var statusMessage = "Ready"
    @Published private(set) var queuedChunkCount = 0
    @Published private(set) var deliveredChunkCount = 0
    @Published private(set) var lastRecordingID = UserDefaults.standard.string(
        forKey: "CodexWatch.LastStreamRecordingID"
    )

    private var activated = false
    private struct PendingFile {
        let url: URL
        let metadata: [String: Any]
    }

    private var pendingFiles: [PendingFile] = []
    private var inFlightFiles: Set<String> = []
    private var countedDeliveredFiles: Set<String> = []
    private var counterRecordingID: String?
    private var finalChunkQueued = false
    private let sentFilesKey = "CodexWatch.SentWatchRecordings"
    private let lastRecordingIDKey = "CodexWatch.LastStreamRecordingID"

    private override init() {
        super.init()
        guard WCSession.isSupported() else {
            statusMessage = "iPhone transfer unavailable"
            return
        }
        DispatchQueue.main.async {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func enqueue(fileURL: URL) {
        pendingFiles.append(PendingFile(
            url: fileURL,
            metadata: ["kind": "audio-recording", "filename": fileURL.lastPathComponent]
        ))
        statusMessage = "Queued for iPhone"
        flushPendingFiles()
    }

    func beginRecording(recordingID: String) {
        discardOlderStreamTransfers(keeping: recordingID)
        removeOlderStreamChunks(keeping: recordingID)
        lastRecordingID = recordingID
        counterRecordingID = recordingID
        UserDefaults.standard.set(recordingID, forKey: lastRecordingIDKey)
        queuedChunkCount = 0
        deliveredChunkCount = 0
        countedDeliveredFiles.removeAll()
        finalChunkQueued = false
        statusMessage = "Recording \(recordingID.prefix(6))"
    }

    func retryLastRecording() {
        guard let recordingID = lastRecordingID else {
            statusMessage = "No recording available to retry"
            return
        }
        flushPendingFiles()
        WCSession.default.transferUserInfo([
            "command": "retry-recording",
            "recording_id": recordingID,
        ])
        statusMessage = "Checking iPhone and PC"
    }

    private func resendRecording(_ recordingID: String) {
        let matchingFiles = ((try? FileManager.default.contentsOfDirectory(
            at: recordingsDirectory(),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []).filter { $0.lastPathComponent.contains("_\(recordingID)_") }

        var sentFiles = UserDefaults.standard.stringArray(forKey: sentFilesKey) ?? []
        let matchingNames = Set(matchingFiles.map(\.lastPathComponent))
        sentFiles.removeAll { matchingNames.contains($0) }
        UserDefaults.standard.set(sentFiles, forKey: sentFilesKey)
        counterRecordingID = recordingID
        deliveredChunkCount = 0
        countedDeliveredFiles.subtract(matchingNames)
        queuedChunkCount = matchingFiles.count
        finalChunkQueued = matchingFiles.contains { $0.lastPathComponent.contains("_1.m4a") }
        pendingFiles.append(contentsOf: matchingFiles.map {
            PendingFile(url: $0, metadata: metadata(for: $0))
        })
        statusMessage = matchingFiles.isEmpty
            ? "No saved chunks remain on Watch"
            : "Resending \(matchingFiles.count) chunks"
        flushPendingFiles()
    }

    func enqueueChunk(fileURL: URL, recordingID: String, chunkIndex: Int, isFinal: Bool) {
        let metadata: [String: Any] = [
            "kind": "audio-recording-chunk",
            "filename": fileURL.lastPathComponent,
            "recording_id": recordingID,
            "chunk_index": chunkIndex,
            "is_final": isFinal,
        ]
        pendingFiles.append(PendingFile(
            url: fileURL,
            metadata: metadata
        ))
        queuedChunkCount += 1
        finalChunkQueued = finalChunkQueued || isFinal
        statusMessage = isFinal
            ? "Final chunk queued"
            : "Sending chunk \(chunkIndex + 1)"
        sendImmediateChunk(fileURL: fileURL, metadata: metadata)
        flushPendingFiles()
    }

    private func sendImmediateChunk(fileURL: URL, metadata: [String: Any]) {
        let session = WCSession.default
        guard activated, session.isReachable,
              let recordingID = metadata["recording_id"] as? String,
              let chunkIndex = metadata["chunk_index"] as? Int,
              let isFinal = metadata["is_final"] as? Bool else { return }

        do {
            let envelope = ImmediateWatchChunkEnvelope(
                version: 1,
                filename: fileURL.lastPathComponent,
                recordingID: recordingID,
                chunkIndex: chunkIndex,
                isFinal: isFinal,
                audioData: try Data(contentsOf: fileURL, options: .mappedIfSafe)
            )
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let payload = try encoder.encode(envelope)
            session.sendMessageData(payload) { [weak self] response in
                guard String(data: response, encoding: .utf8) == "accepted" else { return }
                DispatchQueue.main.async {
                    self?.markChunkDelivered(
                        filename: fileURL.lastPathComponent,
                        recordingID: recordingID,
                        isFinal: isFinal,
                        immediate: true
                    )
                }
            } errorHandler: { _ in
                // The queued file transfer remains the durable fallback.
            }
        } catch {
            // The queued file transfer remains the durable fallback.
        }
    }

    private func flushPendingFiles() {
        guard activated else { return }
        let recordedFiles = (try? FileManager.default.contentsOfDirectory(
            at: recordingsDirectory(),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.filter { !$0.lastPathComponent.hasPrefix("active_") } ?? []
        let sentFiles = UserDefaults.standard.stringArray(forKey: sentFilesKey) ?? []
        let recovered = recordedFiles.map { fileURL in
            PendingFile(url: fileURL, metadata: metadata(for: fileURL))
        }
        let candidates = (pendingFiles + recovered)
            .filter {
                !sentFiles.contains($0.url.lastPathComponent) &&
                !inFlightFiles.contains($0.url.lastPathComponent)
            }
            .reduce(into: [String: PendingFile]()) { result, pending in
                result[pending.url.lastPathComponent] = pending
            }

        for pending in candidates.values {
            inFlightFiles.insert(pending.url.lastPathComponent)
            WCSession.default.transferFile(pending.url, metadata: pending.metadata)
        }
        pendingFiles.removeAll()
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.activated = error == nil && activationState == .activated
            if let error {
                self.statusMessage = "iPhone transfer unavailable: \(error.localizedDescription)"
            } else {
                self.flushPendingFiles()
            }
        }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        DispatchQueue.main.async {
            let metadata = fileTransfer.file.metadata
            let transferRecordingID = metadata?["recording_id"] as? String
            if let error {
                self.inFlightFiles.remove(fileTransfer.file.fileURL.lastPathComponent)
                if transferRecordingID == self.counterRecordingID || transferRecordingID == nil {
                    self.statusMessage = "iPhone transfer failed: \(error.localizedDescription)"
                }
            } else {
                var sentFiles = UserDefaults.standard.stringArray(forKey: self.sentFilesKey) ?? []
                let filename = fileTransfer.file.fileURL.lastPathComponent
                if !sentFiles.contains(filename) {
                    sentFiles.append(filename)
                    UserDefaults.standard.set(sentFiles, forKey: self.sentFilesKey)
                }
                self.inFlightFiles.remove(filename)
                let isChunk = metadata?["kind"] as? String == "audio-recording-chunk"
                if isChunk {
                    self.markChunkDelivered(
                        filename: filename,
                        recordingID: transferRecordingID,
                        isFinal: metadata?["is_final"] as? Bool ?? false,
                        immediate: false
                    )
                } else {
                    self.statusMessage = "Delivered to iPhone"
                }
                self.flushPendingFiles()
            }
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard userInfo["command"] as? String == "resend-recording",
              let recordingID = userInfo["recording_id"] as? String else { return }
        DispatchQueue.main.async {
            self.resendRecording(recordingID)
        }
    }

    private func markChunkDelivered(
        filename: String,
        recordingID: String?,
        isFinal: Bool,
        immediate: Bool
    ) {
        guard recordingID == counterRecordingID,
              countedDeliveredFiles.insert(filename).inserted else { return }
        deliveredChunkCount += 1
        if finalChunkQueued && deliveredChunkCount >= queuedChunkCount {
            statusMessage = "Recording delivered to iPhone"
        } else if immediate {
            statusMessage = isFinal
                ? "Final chunk reached iPhone"
                : "Streaming \(deliveredChunkCount) of \(queuedChunkCount) chunks"
        } else {
            statusMessage = "Delivered \(deliveredChunkCount) of \(queuedChunkCount) chunks"
        }
    }

    private func metadata(for fileURL: URL) -> [String: Any] {
        let parts = fileURL.deletingPathExtension().lastPathComponent.split(separator: "_")
        if parts.count == 4,
           parts[0] == "stream",
           let index = Int(parts[2]),
           let finalFlag = Int(parts[3]) {
            return [
                "kind": "audio-recording-chunk",
                "filename": fileURL.lastPathComponent,
                "recording_id": String(parts[1]),
                "chunk_index": index,
                "is_final": finalFlag == 1,
            ]
        }
        return ["kind": "audio-recording", "filename": fileURL.lastPathComponent]
    }

    private func recordingsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    private func removeOlderStreamChunks(keeping recordingID: String) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: recordingsDirectory(),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        var removedNames = Set<String>()
        for fileURL in files where fileURL.lastPathComponent.hasPrefix("stream_") &&
            !fileURL.lastPathComponent.contains("_\(recordingID)_") {
            removedNames.insert(fileURL.lastPathComponent)
            try? FileManager.default.removeItem(at: fileURL)
        }
        if !removedNames.isEmpty {
            var sentFiles = UserDefaults.standard.stringArray(forKey: sentFilesKey) ?? []
            sentFiles.removeAll { removedNames.contains($0) }
            UserDefaults.standard.set(sentFiles, forKey: sentFilesKey)
        }
    }

    private func discardOlderStreamTransfers(keeping recordingID: String) {
        pendingFiles.removeAll { pending in
            guard pending.metadata["kind"] as? String == "audio-recording-chunk" else {
                return false
            }
            return pending.metadata["recording_id"] as? String != recordingID
        }
        for transfer in WCSession.default.outstandingFileTransfers {
            let metadata = transfer.file.metadata
            guard metadata?["kind"] as? String == "audio-recording-chunk",
                  metadata?["recording_id"] as? String != recordingID else { continue }
            inFlightFiles.remove(transfer.file.fileURL.lastPathComponent)
            transfer.cancel()
        }
    }
}
