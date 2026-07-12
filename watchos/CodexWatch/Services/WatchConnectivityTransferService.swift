import Combine
import Foundation
import WatchConnectivity

final class WatchConnectivityTransferService: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchConnectivityTransferService()

    @Published private(set) var statusMessage = "Ready"

    private var activated = false
    private var pendingFiles: [URL] = []

    private override init() {
        super.init()
        guard WCSession.isSupported() else {
            statusMessage = "iPhone transfer unavailable"
            return
        }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func enqueue(fileURL: URL) {
        pendingFiles.append(fileURL)
        statusMessage = "Queued for iPhone"
        flushPendingFiles()
    }

    private func flushPendingFiles() {
        guard activated else { return }
        for fileURL in pendingFiles {
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
                self.statusMessage = "Delivered to iPhone"
            }
        }
    }
}
