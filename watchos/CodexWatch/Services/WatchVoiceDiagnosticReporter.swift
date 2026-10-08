import Combine
import Foundation
import WatchKit

@MainActor
final class WatchVoiceDiagnosticReporter: ObservableObject {
    static let shared = WatchVoiceDiagnosticReporter()
    @Published private(set) var status: String?
    @Published private(set) var hasPending = false
    private let client = WatchVoiceClient()
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var outbox = VoiceDiagnosticOutbox()
    private let file: URL?

    private init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        file = directory?.appendingPathComponent("voice-diagnostics-outbox.json")
        if let file, let data = try? Data(contentsOf: file), data.count <= 655360,
           let saved = try? JSONDecoder().decode(VoiceDiagnosticOutbox.self, from: data) { outbox = saved }
        outbox.accountChanged(RecordingQueueStore.shared.accountID)
        hasPending = !outbox.entries.isEmpty
    }

    static func report(kind: VoiceDiagnosticReport.Kind, completed: Bool,
                       results: [VoiceAudioDiagnosticResult], routeChanges: Int = 0,
                       interruptions: Int = 0, mediaResets: Int = 0) -> VoiceDiagnosticReport {
        VoiceDiagnosticReport(request_id: UUID().uuidString, kind: kind,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
            watch_os: WKInterfaceDevice.current().systemVersion, completed: completed,
            route_changes: routeChanges, interruptions: interruptions, media_resets: mediaResets, results: results)
    }

    func submit(_ report: VoiceDiagnosticReport) {
        guard let owner = RecordingQueueStore.shared.accountID else {
            status = "Report kept on this screen. Sign in on your iPhone to send it."; return
        }
        outbox.enqueue(report, owner: owner); persist(); retry()
    }

    func accountChanged(_ owner: String?) {
        generation = UUID(); task?.cancel(); task = nil
        outbox.accountChanged(owner); status = nil; persist()
    }

    func retry() {
        guard task == nil, !outbox.entries.isEmpty else { return }
        guard let credential = VoiceKeychain.read(), credential.valid,
              credential.owner_id == RecordingQueueStore.shared.accountID else {
            status = "Report waiting for iPhone voice setup."; return
        }
        outbox.accountChanged(credential.owner_id); persist()
        let run = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == run { self.task = nil } }
            while let entry = self.outbox.entries.first {
                guard self.generation == run, entry.owner == RecordingQueueStore.shared.accountID,
                      let credential = VoiceKeychain.read(), credential.valid, credential.owner_id == entry.owner else { return }
                self.status = "Sending audio report…"
                do {
                    let receipt = try await self.client.diagnostic(entry.report, credential: credential)
                    guard self.generation == run, credential.owner_id == RecordingQueueStore.shared.accountID else { return }
                    guard receipt.accepts(entry.report) else { throw VoiceError.connection }
                    self.outbox.acknowledge(receipt, owner: entry.owner); self.persist()
                    self.status = "Report sent to your PC workspace."
                } catch is CancellationError { return }
                catch {
                    guard self.generation == run else { return }
                    // No provider, credential or arbitrary server error enters this UI.
                    self.status = "Report saved on Watch; waiting to send. Check the connection and tap Send report again."
                    return
                }
            }
        }
    }

    private func persist() {
        hasPending = !outbox.entries.isEmpty
        guard let file else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if outbox.entries.isEmpty {
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            } else {
                try JSONEncoder().encode(outbox).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                var protected = file; var values = URLResourceValues(); values.isExcludedFromBackup = true
                try protected.setResourceValues(values)
            }
        } catch { status = "Report is held in memory until the Watch can save it." }
    }
}
