import AVFoundation
import Combine
import Foundation
import UIKit
import WatchConnectivity

/// Durable phone queue -> authenticated PC workspace. OpenAI credentials never enter this path.
@MainActor
final class PhoneOpenAIService: ObservableObject {
    static let shared = PhoneOpenAIService()
    @Published private(set) var activeID: String?
    private let queue = RecordingQueueStore.shared
    private var task: Task<Void, Never>?
    private var requestedIDs: [String] = []
    private var reconciling = false

    func receive(fileURL: URL, id: String, index: Int = 0, isFinal: Bool = true, source: String,
                 duration: TimeInterval? = nil, ownerID: String? = nil) {
        do {
            // Watch ownership is captured at record start, never inferred on arrival.
            let owner: String?
            if source == "Apple Watch" { owner = ownerID }
            else if let existing = queue.recording(id) { owner = existing.ownerID }
            else { owner = PhoneWorkspace.shared.user?.id }
            try queue.accept(fileURL: fileURL, id: id, index: index, isFinal: isFinal, source: source,
                             duration: duration, ownerID: owner)
            if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
            if queue.isRemoved(id) { return }
            notifyWatch(id: id, status: queue.recording(id)?.isComplete == true ? "Saved · review on iPhone" : "Receiving audio")
        } catch { queue.errorMessage = "Audio could not be saved to the queue. The original file has been kept." }
    }

    func process(_ ids: [String]) {
        let workspace = PhoneWorkspace.shared
        guard let owner = workspace.user?.id, workspace.ready, !workspace.selectedAssistantID.isEmpty else {
            queue.errorMessage = workspace.signedIn ? "Organization processing approval is pending, or no assistant is selected." : WorkspaceError.signIn.localizedDescription
            return
        }
        for id in ids {
            guard let item = queue.recording(id), item.ownerID == owner,
                  item.isComplete || item.serverUploaded == true else { continue }
            do {
                try queue.update(id) {
                    $0.processingRequested = true; $0.requestedAssistantID = workspace.selectedAssistantID
                    $0.requestedTranscriptionModel = workspace.transcriptionModel
                }
            } catch { queue.errorMessage = error.localizedDescription; continue }
            if id != activeID && !requestedIDs.contains(id) { requestedIDs.append(id) }
        }
        startRequests()
    }
    private func startRequests() {
        guard task == nil else { return }
        task = Task {
            while !requestedIDs.isEmpty && !Task.isCancelled {
                let id = requestedIDs.removeFirst(); activeID = id
                await processOne(id)
            }
            activeID = nil; task = nil
        }
    }
    func importRecording(_ id: String) async {
        guard queue.recording(id)?.ownerID == PhoneWorkspace.shared.user?.id else { return }
        sendWatchCommand(["command": "assign-recording", "recording_id": id, "owner_id": PhoneWorkspace.shared.user?.id ?? ""])
        do { try queue.update(id) { $0.importRequested = true; $0.processingRequested = false } }
        catch { queue.errorMessage = error.localizedDescription; return }
        if id != activeID && !requestedIDs.contains(id) { requestedIDs.append(id) }
        startRequests()
    }
    func remove(_ ids: Set<String>, notify: Bool = true) throws {
        guard ids.allSatisfy({ queue.recording($0)?.ownerID == PhoneWorkspace.shared.user?.id || queue.recording($0)?.ownerID == nil }) else { throw WorkspaceError.ownership }
        if let activeID, ids.contains(activeID) { task?.cancel() }
        requestedIDs.removeAll { ids.contains($0) }
        defer {
            let removed = Set(ids.filter { queue.isRemoved($0) })
            PhoneUploadService.shared.discardSavedRecordings(removed)
            if notify { for id in removed { sendWatchCommand(["command": "remove-recording", "recording_id": id]) } }
            Task { await reconcile() }
        }
        try queue.remove(ids)
    }
    func rename(_ id: String, title: String) throws {
        guard let item = queue.recording(id), item.ownerID == PhoneWorkspace.shared.user?.id || item.ownerID == nil else { throw WorkspaceError.ownership }
        try queue.rename(id, title: title)
        if item.ownerID != nil { try queue.update(id) { $0.pendingTitle = title } }
        sendWatchCommand(["command": "rename-recording", "recording_id": id, "title": title])
        Task { await reconcile() }
    }
    func saveResult(_ id: String, summary: String) throws {
        guard queue.recording(id)?.ownerID == PhoneWorkspace.shared.user?.id else { throw WorkspaceError.ownership }
        try queue.update(id) { $0.summary = summary; $0.pendingSummary = summary }
        Task { await reconcile() }
    }
    func configurationChanged() { task?.cancel(); requestedIDs.removeAll(); syncConfiguration() }
    func syncConfiguration() {
        let workspace = PhoneWorkspace.shared
        sendWatchCommand(["command": "processing-settings", "ready": workspace.ready, "protected": true,
                          "model": workspace.transcriptionModel, "owner_id": workspace.user?.id ?? ""])
    }
    func changeFromWatch(_ id: String, owner: String?, title: String? = nil, removing: Bool = false) throws {
        defer {
            if removing && queue.isRemoved(id) {
                if activeID == id { task?.cancel() }
                requestedIDs.removeAll { $0 == id }
                PhoneUploadService.shared.discardSavedRecordings([id])
            }
            Task { await reconcile() }
        }
        try queue.applyCompanionChange(id, owner: owner, title: title, removing: removing)
    }
    func reconcile() async {
        let workspace = PhoneWorkspace.shared
        guard !reconciling, let owner = workspace.user?.id, let token = workspace.credential?.token else { return }
        reconciling = true
        defer { reconciling = false }
        do {
            for (id, deletedOwner) in queue.removedOwners where deletedOwner == owner {
                let _: PhoneWorkspace.OK = try await workspace.request("recordings/\(id)", method: "DELETE")
                try checkSession(token); try queue.acknowledgeDeletion(id)
            }
            for item in queue.visibleRecordings where item.serverUploaded == true && (item.pendingTitle != nil || item.pendingSummary != nil) {
                var fields: [String: String] = [:]
                if let title = item.pendingTitle { fields["title"] = title }
                if let summary = item.pendingSummary { fields["summary"] = summary }
                let _: PhoneWorkspace.OK = try await workspace.request("recordings/\(item.id)", method: "PATCH", body: JSONEncoder().encode(fields))
                try checkSession(token)
                try queue.update(item.id) {
                    if $0.pendingTitle == item.pendingTitle { $0.pendingTitle = nil }
                    if $0.pendingSummary == item.pendingSummary { $0.pendingSummary = nil }
                }
            }
            let remote = try await workspace.remoteRecordings()
            try checkSession(token)
            let remoteIDs = Set(remote.map(\.id))
            for item in queue.visibleRecordings where item.serverUploaded == true && !remoteIDs.contains(item.id) && item.id != activeID {
                try queue.remove([item.id]); try queue.acknowledgeDeletion(item.id)
                sendWatchCommand(["command": "remove-recording", "recording_id": item.id])
            }
            for item in remote where !queue.isRemoved(item.id) {
                if item.id == activeID { continue }
                let state: RecordingState = item.state == "ready" ? .ready : (item.state == "failed" ? .failed :
                    (["queued", "processing"].contains(item.state) ? .processing : .queued))
                let previous = queue.recording(item.id)?.state
                try queue.mergeRemote(id: item.id, owner: item.owner, title: item.title, source: item.source,
                    created: Date(timeIntervalSince1970: item.created), state: state, transcript: item.transcript,
                    summary: item.summary, error: item.error, partCount: item.expected_parts, duration: item.duration, updated: item.updated)
                if state == .ready && previous != .ready {
                    sendWatchCommand(["command": "recording-complete", "recording_id": item.id, "delete_audio": false])
                }
            }
            if workspace.signedIn {
                for item in queue.visibleRecordings where (item.importRequested == true || (workspace.ready && item.processingRequested == true)) && item.id != activeID && !requestedIDs.contains(item.id) {
                    requestedIDs.append(item.id)
                }
                if !requestedIDs.isEmpty { startRequests() }
            }
        } catch { /* Offline edits and tombstones retry on the next foreground sync. */ }
    }
    private func checkSession(_ token: String) throws {
        try Task.checkCancellation()
        guard PhoneWorkspace.shared.credential?.token == token else { throw CancellationError() }
    }
    private func check(_ id: String, token: String) throws {
        try checkSession(token)
        guard !queue.isRemoved(id), queue.recording(id)?.ownerID == PhoneWorkspace.shared.user?.id else { throw CancellationError() }
    }
    private struct CreateRecording: Encodable {
        let title: String; let source: String; let expected_parts: Int; let duration: Double?
        let transcript: String; let summary: String
    }
    private struct ProcessRecording: Encodable { let assistant_id: String; let transcription_model: String }
    private func processOne(_ id: String) async {
        let workspace = PhoneWorkspace.shared
        guard let item = queue.recording(id), item.ownerID == workspace.user?.id, let token = workspace.credential?.token else { return }
        let isImport = item.importRequested == true && item.processingRequested != true
        let assistant = item.requestedAssistantID ?? workspace.selectedAssistantID
        let model = item.requestedTranscriptionModel ?? workspace.transcriptionModel
        let background = UIApplication.shared.beginBackgroundTask(withName: "ScribePilot workspace upload") { [weak self] in
            Task { @MainActor in self?.task?.cancel() }
        }
        defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
        do {
            try check(id, token: token)
            try queue.update(id) { $0.state = .processing; $0.error = nil; $0.protectedWorkflow = true }
            if item.serverUploaded != true {
                var slices: [URL] = []
                for part in item.parts.sorted(by: { $0.index < $1.index }) {
                    try check(id, token: token)
                    slices.append(contentsOf: try await prepareSlices(queue.audioURL(id, part: part), index: part.index))
                }
                guard !slices.isEmpty || !item.transcript.isEmpty else { throw RecordingQueueError.invalidRecording }
                let _: WorkspaceRecording = try await workspace.request("recordings/\(id)", method: "PUT", body: JSONEncoder().encode(
                    CreateRecording(title: queue.recording(id)?.title ?? item.title, source: item.source, expected_parts: slices.count,
                                    duration: item.duration, transcript: isImport ? item.transcript : "", summary: isImport ? item.summary ?? "" : "")))
                for (index, slice) in slices.enumerated() {
                    try check(id, token: token)
                    try await workspace.upload(slice, recordingID: id, index: index)
                    try check(id, token: token)
                    try queue.update(id) { $0.progress = Double(index + 1) / Double(slices.count) }
                }
                try queue.update(id) { $0.serverUploaded = true; $0.remotePartCount = slices.count }
            }
            if isImport {
                try check(id, token: token)
                try queue.update(id) { $0.importRequested = false; $0.state = item.transcript.isEmpty ? .queued : .ready; $0.error = nil }
                return
            }
            try check(id, token: token)
            let _: PhoneWorkspace.OK = try await workspace.request("recordings/\(id)/process", method: "POST", body: JSONEncoder().encode(
                ProcessRecording(assistant_id: assistant, transcription_model: model)))
            try check(id, token: token)
            try queue.update(id) { $0.processingRequested = false; $0.state = .processing; $0.error = nil }
            notifyWatch(id: id, status: "Processing on PC")
        } catch is CancellationError {
            try? queue.update(id) { $0.state = .queued; $0.error = "Upload paused. Reconnect to resume." }
        } catch {
            try? queue.update(id) {
                $0.state = .failed; $0.error = error.localizedDescription
                if !(error is URLError) { $0.processingRequested = false; $0.importRequested = false }
            }
            notifyWatch(id: id, status: "Needs attention on iPhone")
        }
    }
    private func prepareSlices(_ url: URL, index: Int) async throws -> [URL] {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        if size < 24 * 1024 * 1024 && url.pathExtension.lowercased() == "m4a" { return [url] }
        let asset = AVURLAsset(url: url)
        let seconds = try await asset.load(.duration).seconds
        guard seconds.isFinite && seconds > 0 else { throw OpenAIError.audioExport }
        let directory = url.deletingLastPathComponent().appendingPathComponent("Slices", isDirectory: true)
        try RecordingQueueStore.protectDirectory(directory)
        var slices: [URL] = []
        for start in stride(from: 0.0, to: seconds, by: 600.0) {
            try Task.checkCancellation()
            let destination = directory.appendingPathComponent("slice_\(index)_\(Int(start)).m4a")
            let savedSize = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if savedSize > 0 && savedSize < 24 * 1024 * 1024 { slices.append(destination); continue }
            try? FileManager.default.removeItem(at: destination)
            guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw OpenAIError.audioExport }
            exporter.outputURL = destination; exporter.outputFileType = .m4a
            exporter.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: min(600, seconds-start), preferredTimescale: 600))
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in exporter.exportAsynchronously { continuation.resume() } }
            } onCancel: { exporter.cancelExport() }
            guard exporter.status == .completed else {
                try? FileManager.default.removeItem(at: destination)
                throw OpenAIError.audioExport
            }
            try RecordingQueueStore.protectFile(destination); slices.append(destination)
        }
        return slices
    }
    private func notifyWatch(id: String, status: String) { sendWatchCommand(["command": "meeting-status", "recording_id": id, "status": status]) }
    private func sendWatchCommand(_ command: [String: Any]) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        WCSession.default.transferUserInfo(command)
    }
}
