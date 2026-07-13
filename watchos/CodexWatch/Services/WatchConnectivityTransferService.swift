import Combine
import Foundation
import WatchConnectivity

final class WatchConnectivityTransferService: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchConnectivityTransferService()

    @Published private(set) var statusMessage = "Ready"
    @Published private(set) var queuedChunkCount = 0
    @Published private(set) var deliveredChunkCount = 0

    private var activated = false
    private struct PendingFile {
        let url: URL
        let metadata: [String: Any]
    }

    private var pendingFiles: [PendingFile] = []
    private var inFlightFiles: Set<String> = []
    private var finalChunkQueued = false
    private let sentFilesKey = "CodexWatch.SentWatchRecordings"

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
        queuedChunkCount = 0
        deliveredChunkCount = 0
        finalChunkQueued = false
        statusMessage = "Recording \(recordingID.prefix(6))"
    }

    func enqueueChunk(fileURL: URL, recordingID: String, chunkIndex: Int, isFinal: Bool) {
        pendingFiles.append(PendingFile(
            url: fileURL,
            metadata: [
                "kind": "audio-recording-chunk",
                "filename": fileURL.lastPathComponent,
                "recording_id": recordingID,
                "chunk_index": chunkIndex,
                "is_final": isFinal,
            ]
        ))
        queuedChunkCount += 1
        finalChunkQueued = finalChunkQueued || isFinal
        statusMessage = isFinal
            ? "Final chunk queued"
            : "Sending chunk \(chunkIndex + 1)"
        flushPendingFiles()
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
            if let error {
                self.inFlightFiles.remove(fileTransfer.file.fileURL.lastPathComponent)
                self.statusMessage = "iPhone transfer failed: \(error.localizedDescription)"
            } else {
                var sentFiles = UserDefaults.standard.stringArray(forKey: self.sentFilesKey) ?? []
                let filename = fileTransfer.file.fileURL.lastPathComponent
                if !sentFiles.contains(filename) {
                    sentFiles.append(filename)
                    UserDefaults.standard.set(sentFiles, forKey: self.sentFilesKey)
                }
                self.inFlightFiles.remove(filename)
                let isChunk = fileTransfer.file.metadata?["kind"] as? String == "audio-recording-chunk"
                if isChunk {
                    self.deliveredChunkCount += 1
                    try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
                    if self.finalChunkQueued && self.deliveredChunkCount >= self.queuedChunkCount {
                        self.statusMessage = "Recording delivered to iPhone"
                    } else {
                        self.statusMessage = "Delivered \(self.deliveredChunkCount) of \(self.queuedChunkCount) chunks"
                    }
                } else {
                    self.statusMessage = "Delivered to iPhone"
                }
                self.flushPendingFiles()
            }
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
}
