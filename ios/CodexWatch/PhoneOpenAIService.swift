import AVFoundation
import Combine
import Foundation
import UIKit
import WatchConnectivity

@MainActor
final class PhoneOpenAIService: ObservableObject {
    static let shared = PhoneOpenAIService()
    @Published private(set) var activeID: String?
    private let queue = RecordingQueueStore.shared
    private let client = PhoneOpenAIClient()
    private var task: Task<Void, Never>?
    private var requestedIDs: [String] = []

    func receive(fileURL: URL, id: String, index: Int = 0, isFinal: Bool = true, source: String, duration: TimeInterval? = nil) {
        do {
            try queue.accept(fileURL: fileURL, id: id, index: index, isFinal: isFinal, source: source, duration: duration)
            // The protected queue now owns the durable copy. Do not leave duplicate audio in the legacy folders.
            if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
            if queue.isRemoved(id) { return }
            let complete = queue.recording(id)?.isComplete == true
            notifyWatch(id: id, status: complete ? "Saved · review on iPhone" : "Receiving audio")
            if complete && PhoneOpenAISettings.shared.configuration.automaticProcessing { process([id]) }
        } catch {
            queue.errorMessage = "Audio could not be saved to the queue. The original file has been kept."
        }
    }

    func process(_ ids: [String]) {
        for id in ids where queue.recording(id)?.canProcess == true && id != activeID && !requestedIDs.contains(id) {
            requestedIDs.append(id)
        }
        guard task == nil else { return }
        task = Task {
            while !requestedIDs.isEmpty && !Task.isCancelled {
                let id = requestedIDs.removeFirst()
                activeID = id
                await processOne(id)
            }
            activeID = nil
            task = nil
        }
    }

    func remove(_ ids: Set<String>, notify: Bool = true) throws {
        if let activeID, ids.contains(activeID) { task?.cancel() }
        requestedIDs.removeAll { ids.contains($0) }
        defer {
            let removed = Set(ids.filter { queue.isRemoved($0) })
            PhoneUploadService.shared.discardSavedRecordings(removed)
            if notify {
                for id in removed { sendWatchCommand(["command": "remove-recording", "recording_id": id]) }
            }
        }
        try queue.remove(ids)
    }

    func rename(_ id: String, title: String) throws {
        try queue.rename(id, title: title)
        sendWatchCommand(["command": "rename-recording", "recording_id": id, "title": title])
    }

    func configurationChanged() {
        task?.cancel()
        requestedIDs.removeAll()
        syncConfiguration()
    }

    func syncConfiguration() {
        let settings = PhoneOpenAISettings.shared
        sendWatchCommand(["command": "processing-settings", "ready": settings.ready,
                          "protected": settings.configuration.protectedMode,
                          "model": settings.configuration.model])
    }

    private func check(_ id: String, revision: String) throws {
        try Task.checkCancellation()
        guard !queue.isRemoved(id), queue.recording(id) != nil,
              revision == PhoneOpenAISettings.shared.configuration.revision else { throw CancellationError() }
    }

    private func processOne(_ id: String) async {
        guard let recording = queue.recording(id), recording.canProcess else { return }
        let settings = PhoneOpenAISettings.shared
        let configuration = settings.configuration
        guard settings.ready, let key = OpenAIKeychain.read(), !key.isEmpty else {
            try? queue.update(id) { $0.error = OpenAIError.setupRequired.localizedDescription }
            notifyWatch(id: id, status: "Complete setup on iPhone")
            return
        }
        let background = UIApplication.shared.beginBackgroundTask(withName: "ScribePilot transcription") { [weak self] in
            Task { @MainActor in self?.task?.cancel() }
        }
        defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
        do {
            try queue.update(id) { $0.state = .processing; $0.error = nil; $0.protectedWorkflow = configuration.protectedMode }
            let parts = recording.parts.sorted { $0.index < $1.index }
            for (offset, part) in parts.enumerated() {
                try check(id, revision: configuration.revision)
                let audio = queue.audioURL(id, part: part)
                let slices = try await prepareSlices(audio, recordingID: id, index: part.index)
                defer { for slice in slices where slice.url != audio { try? FileManager.default.removeItem(at: slice.url) } }
                for (sliceIndex, slice) in slices.enumerated() {
                    let checkpoint = "\(part.index):\(sliceIndex)"
                    if queue.recording(id)?.transcripts[checkpoint] != nil { continue }
                    try check(id, revision: configuration.revision)
                    let text = try await client.transcribe(slice.url, key: key, configuration: configuration)
                    try check(id, revision: configuration.revision)
                    try queue.update(id) { $0.transcripts[checkpoint] = text }
                }
                try queue.update(id) { $0.progress = Double(offset + 1) / Double(parts.count) }
            }
            try check(id, revision: configuration.revision)
            guard let saved = queue.recording(id) else { throw CancellationError() }
            let transcript = saved.transcripts.keys.sorted { lhs, rhs in
                let left = lhs.split(separator: ":").compactMap { Int($0) }
                let right = rhs.split(separator: ":").compactMap { Int($0) }
                return left.lexicographicallyPrecedes(right)
            }.compactMap { saved.transcripts[$0] }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            var notes: String?
            var noteError: String?
            if configuration.createNotes && !transcript.isEmpty {
                do { notes = try await client.notes(transcript: transcript, key: key, configuration: configuration) }
                catch is CancellationError { throw CancellationError() }
                catch { noteError = "Transcript saved. Meeting notes were unavailable."
                }
            }
            try check(id, revision: configuration.revision)
            try queue.update(id) {
                $0.transcript = transcript; $0.summary = notes; $0.error = noteError
                $0.state = .ready; $0.progress = 1; $0.transcripts = [:]
            }
            if configuration.deleteAudioAfterProcessing {
                do { try queue.purgeAudio(id) }
                catch { try queue.update(id) { $0.error = "Transcript saved. Audio cleanup could not finish; remove the recording to retry cleanup." } }
            }
            sendWatchCommand(["command": "recording-complete", "recording_id": id,
                              "delete_audio": configuration.deleteAudioAfterProcessing])
        } catch is CancellationError {
            try? queue.update(id) { $0.state = .queued; $0.error = "Processing paused. Tap Process to continue." }
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                try? queue.update(id) { $0.state = .queued; $0.error = "Processing paused. Tap Process to continue." }
            } else {
                try? queue.update(id) { $0.state = .failed; $0.error = error.localizedDescription }
                notifyWatch(id: id, status: "Needs attention on iPhone")
            }
        }
    }

    private struct AudioSlice { let url: URL }
    private func prepareSlices(_ url: URL, recordingID: String, index: Int) async throws -> [AudioSlice] {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        if size < 24 * 1024 * 1024 && url.pathExtension.lowercased() != "caf" { return [AudioSlice(url: url)] }
        let asset = AVURLAsset(url: url)
        let seconds = try await asset.load(.duration).seconds
        guard seconds.isFinite && seconds > 0 else { throw OpenAIError.audioExport }
        let directory = url.deletingLastPathComponent().appendingPathComponent("Slices", isDirectory: true)
        try RecordingQueueStore.protectDirectory(directory)
        var slices: [AudioSlice] = []
        do {
            for start in stride(from: 0.0, to: seconds, by: 600.0) {
                try Task.checkCancellation()
                let destination = directory.appendingPathComponent("slice_\(index)_\(Int(start)).m4a")
                try? FileManager.default.removeItem(at: destination)
                guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                    throw OpenAIError.audioExport
                }
                exporter.outputURL = destination
                exporter.outputFileType = .m4a
                exporter.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                                 duration: CMTime(seconds: min(600, seconds - start), preferredTimescale: 600))
                await withTaskCancellationHandler {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        exporter.exportAsynchronously { continuation.resume() }
                    }
                } onCancel: { exporter.cancelExport() }
                try Task.checkCancellation()
                guard exporter.status == .completed else { throw OpenAIError.audioExport }
                try RecordingQueueStore.protectFile(destination)
                slices.append(AudioSlice(url: destination))
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return slices
    }

    private func notifyWatch(id: String, status: String) {
        sendWatchCommand(["command": "meeting-status", "recording_id": id, "status": status])
    }
    private func sendWatchCommand(_ command: [String: Any]) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        // Persisted user info, rather than replaceable application context, survives offline devices.
        WCSession.default.transferUserInfo(command)
    }
}
