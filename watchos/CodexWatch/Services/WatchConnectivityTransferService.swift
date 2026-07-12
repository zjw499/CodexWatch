import Combine
import Foundation
import WatchConnectivity

final class WatchConnectivityTransferService: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchConnectivityTransferService()

    @Published private(set) var statusMessage = "Ready"

    private var activated = false
    private var pendingFiles: [URL] = []
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
        pendingFiles.append(fileURL)
        statusMessage = "Queued for iPhone"
        flushPendingFiles()
    }

    private func flushPendingFiles() {
        guard activated else { return }
        let recordedFiles = (try? FileManager.default.contentsOfDirectory(
            at: recordingsDirectory(),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let sentFiles = UserDefaults.standard.stringArray(forKey: sentFilesKey) ?? []
        let candidates = (pendingFiles + recordedFiles)
            .filter { !sentFiles.contains($0.lastPathComponent) }
            .reduce(into: [String: URL]()) { result, url in
                result[url.lastPathComponent] = url
            }

        for fileURL in candidates.values {
            WCSession.default.transferFile(
                fileURL,
                metadata: [
                    "kind": "audio-recording",
                    "filename": fileURL.lastPathComponent,
                ]
            )
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
                self.statusMessage = "iPhone transfer failed: \(error.localizedDescription)"
            } else {
                var sentFiles = UserDefaults.standard.stringArray(forKey: self.sentFilesKey) ?? []
                let filename = fileTransfer.file.fileURL.lastPathComponent
                if !sentFiles.contains(filename) {
                    sentFiles.append(filename)
                    UserDefaults.standard.set(sentFiles, forKey: self.sentFilesKey)
                }
                self.statusMessage = "Delivered to iPhone"
            }
        }
    }

    private func recordingsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
    }
}
