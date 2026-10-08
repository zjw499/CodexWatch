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
    let ownerID: String?
}

final class WatchConnectivityTransferService: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchConnectivityTransferService()

    @Published private(set) var statusMessage = "Ready"
    @Published private(set) var queuedChunkCount = 0
    @Published private(set) var deliveredChunkCount = 0
    @Published private(set) var meetingStatus: String?
    @Published private(set) var openAIReady = UserDefaults.standard.bool(forKey: "ScribePilot.OpenAIReady")
    @Published private(set) var protectedWorkflow = UserDefaults.standard.object(forKey: "ScribePilot.ProtectedWorkflow") as? Bool ?? true
    private var removedRecordingIDs = Set(UserDefaults.standard.stringArray(forKey: "ScribePilot.RemovedWatchRecordings") ?? [])
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
    private var queuedChunkIndexes: Set<Int> = []
    private var deliveredChunkIndexes: Set<Int> = []
    private var counterRecordingID: String?
    private var finalChunkQueued = false
    private var retryAttemptsByFilename: [String: Int] = [:]
    private let fileQueue = DispatchQueue(
        label: "com.zachwyatt.codexwatch.watch-transfer-files",
        qos: .utility
    )
    private let maxConcurrentFileTransfers = 2
    private let retryDelays: [TimeInterval] = [5, 15, 45, 120, 300]
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
            for id in self.removedRecordingIDs {
                do { try self.purgeOriginalAudio(id) }
                catch { self.statusMessage = "Removed audio cleanup will retry when the app reopens" }
            }
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
        var owners = UserDefaults.standard.dictionary(forKey: "ScribePilot.WatchOwners") as? [String: String] ?? [:]
        owners[recordingID] = UserDefaults.standard.string(forKey: "ScribePilot.WorkspaceOwner") ?? "unassigned"
        UserDefaults.standard.set(owners, forKey: "ScribePilot.WatchOwners")
        lastRecordingID = recordingID
        counterRecordingID = recordingID
        UserDefaults.standard.set(recordingID, forKey: lastRecordingIDKey)
        queuedChunkCount = 0
        deliveredChunkCount = 0
        queuedChunkIndexes.removeAll()
        deliveredChunkIndexes.removeAll()
        finalChunkQueued = false
        meetingStatus = nil
        statusMessage = "Recording \(recordingID.prefix(6))"
        Task { @MainActor in
            do {
                try RecordingQueueStore.shared.begin(id: recordingID, source: "Apple Watch")
                try RecordingQueueStore.shared.update(recordingID) { $0.ownerID = self.owner(for: recordingID) }
            }
            catch { RecordingQueueStore.shared.errorMessage = error.localizedDescription }
        }
    }

    func restoreRecording(recordingID: String) {
        lastRecordingID = recordingID
        counterRecordingID = recordingID
        UserDefaults.standard.set(recordingID, forKey: lastRecordingIDKey)
        statusMessage = "Recovering recording \(recordingID.prefix(6))"
        recoverSavedTransfers()
    }

    func recoverSavedTransfers() {
        let directory = recordingsDirectory()
        fileQueue.async { [weak self] in
            guard let self else { return }
            let sentFiles = Set(UserDefaults.standard.stringArray(forKey: self.sentFilesKey) ?? [])
            let recovered = ((try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []).filter {
                !$0.lastPathComponent.hasPrefix("active_") &&
                !sentFiles.contains($0.lastPathComponent)
            }.map { fileURL in
                PendingFile(url: fileURL, metadata: self.metadata(for: fileURL))
            }
            DispatchQueue.main.async {
                self.pendingFiles.append(contentsOf: recovered)
                self.flushPendingFiles()
            }
        }
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

    private func resendRecording(_ recordingID: String, chunkIndexes: Set<Int>? = nil) {
        guard !removedRecordingIDs.contains(recordingID) else { return }
        let directory = recordingsDirectory()
        fileQueue.async { [weak self] in
            guard let self else { return }
            let allMatchingFiles = ((try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []).filter { $0.lastPathComponent.contains("_\(recordingID)_") }
            let matchingFiles = allMatchingFiles.filter { fileURL in
                guard let chunkIndexes else { return true }
                guard let index = self.metadata(for: fileURL)["chunk_index"] as? Int else {
                    return false
                }
                return chunkIndexes.contains(index)
            }
            let matchingNames = Set(matchingFiles.map(\.lastPathComponent))
            DispatchQueue.main.async {
                var sentFiles = UserDefaults.standard.stringArray(forKey: self.sentFilesKey) ?? []
                sentFiles.removeAll { matchingNames.contains($0) }
                UserDefaults.standard.set(sentFiles, forKey: self.sentFilesKey)
                self.counterRecordingID = recordingID
                self.queuedChunkIndexes = Set(matchingFiles.compactMap {
                    self.metadata(for: $0)["chunk_index"] as? Int
                })
                self.deliveredChunkIndexes.removeAll()
                self.queuedChunkCount = self.queuedChunkIndexes.count
                self.deliveredChunkCount = 0
                self.finalChunkQueued = matchingFiles.contains {
                    $0.lastPathComponent.contains("_1.m4a")
                }
                self.pendingFiles.append(contentsOf: matchingFiles.map {
                    PendingFile(url: $0, metadata: self.metadata(for: $0))
                })
                self.statusMessage = matchingFiles.isEmpty
                    ? "No saved chunks remain on Watch"
                    : "Resending \(matchingFiles.count) chunks"
                self.flushPendingFiles()
            }
        }
    }

    func enqueueChunk(fileURL: URL, recordingID: String, chunkIndex: Int, isFinal: Bool) {
        guard !removedRecordingIDs.contains(recordingID) else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        Task { @MainActor in
            do {
                try RecordingQueueStore.shared.accept(fileURL: fileURL, id: recordingID, index: chunkIndex,
                    isFinal: isFinal, source: "Apple Watch", ownerID: self.owner(for: recordingID))
            } catch { RecordingQueueStore.shared.errorMessage = error.localizedDescription }
        }
        let metadata: [String: Any] = [
            "kind": "audio-recording-chunk",
            "filename": fileURL.lastPathComponent,
            "recording_id": recordingID,
            "chunk_index": chunkIndex,
            "is_final": isFinal,
            "owner_id": owner(for: recordingID) ?? "",
        ]
        pendingFiles.append(PendingFile(
            url: fileURL,
            metadata: metadata
        ))
        queuedChunkIndexes.insert(chunkIndex)
        queuedChunkCount = queuedChunkIndexes.count
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

        fileQueue.async { [weak self] in
            do {
                let envelope = ImmediateWatchChunkEnvelope(
                    version: 2,
                    filename: fileURL.lastPathComponent,
                    recordingID: recordingID,
                    chunkIndex: chunkIndex,
                    isFinal: isFinal,
                    audioData: try Data(contentsOf: fileURL, options: .mappedIfSafe),
                    ownerID: metadata["owner_id"] as? String
                )
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                let payload = try encoder.encode(envelope)
                session.sendMessageData(payload) { response in
                    guard String(data: response, encoding: .utf8) == "accepted" else { return }
                    DispatchQueue.main.async {
                        self?.markChunkDelivered(
                            recordingID: recordingID,
                            chunkIndex: chunkIndex,
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
    }

    private func flushPendingFiles() {
        guard activated else { return }
        let availableSlots = max(0, maxConcurrentFileTransfers - inFlightFiles.count)
        guard availableSlots > 0 else { return }
        let sentFiles = Set(UserDefaults.standard.stringArray(forKey: sentFilesKey) ?? [])
        var uniqueNames: Set<String> = []
        let candidates = pendingFiles
            .filter {
                FileManager.default.fileExists(atPath: $0.url.path) &&
                !sentFiles.contains($0.url.lastPathComponent) &&
                !inFlightFiles.contains($0.url.lastPathComponent) &&
                uniqueNames.insert($0.url.lastPathComponent).inserted
            }
        let selected = Array(candidates.prefix(availableSlots))
        let selectedNames = Set(selected.map { $0.url.lastPathComponent })
        pendingFiles.removeAll { selectedNames.contains($0.url.lastPathComponent) }
        for pending in selected {
            inFlightFiles.insert(pending.url.lastPathComponent)
            WCSession.default.transferFile(pending.url, metadata: pending.metadata)
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.activated = error == nil && activationState == .activated
            if let error {
                self.statusMessage = "iPhone transfer unavailable: \(error.localizedDescription)"
            } else {
                self.session(session, didReceiveApplicationContext: session.receivedApplicationContext)
                self.recoverSavedTransfers()
            }
        }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        DispatchQueue.main.async {
            let metadata = fileTransfer.file.metadata
            let transferRecordingID = metadata?["recording_id"] as? String
            if let error {
                let filename = fileTransfer.file.fileURL.lastPathComponent
                self.inFlightFiles.remove(filename)
                if transferRecordingID == self.counterRecordingID || transferRecordingID == nil {
                    self.statusMessage = "iPhone transfer interrupted; retrying"
                }
                self.scheduleRetry(
                    fileURL: fileTransfer.file.fileURL,
                    metadata: metadata,
                    error: error
                )
            } else {
                var sentFiles = UserDefaults.standard.stringArray(forKey: self.sentFilesKey) ?? []
                let filename = fileTransfer.file.fileURL.lastPathComponent
                if !sentFiles.contains(filename) {
                    sentFiles.append(filename)
                    UserDefaults.standard.set(sentFiles, forKey: self.sentFilesKey)
                }
                self.inFlightFiles.remove(filename)
                self.retryAttemptsByFilename.removeValue(forKey: filename)
                let isChunk = metadata?["kind"] as? String == "audio-recording-chunk"
                if isChunk {
                    self.markChunkDelivered(
                        recordingID: transferRecordingID,
                        chunkIndex: metadata?["chunk_index"] as? Int,
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

    private func scheduleRetry(
        fileURL: URL,
        metadata: [String: Any]?,
        error: Error
    ) {
        let filename = fileURL.lastPathComponent
        let attempt = retryAttemptsByFilename[filename, default: 0]
        guard attempt < retryDelays.count else {
            retryAttemptsByFilename[filename] = 0
            statusMessage = "iPhone transfer waiting: \(error.localizedDescription)"
            return
        }
        retryAttemptsByFilename[filename] = attempt + 1
        let delay = retryDelays[attempt]
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  FileManager.default.fileExists(atPath: fileURL.path) else { return }
            self.pendingFiles.append(PendingFile(
                url: fileURL,
                metadata: metadata ?? self.metadata(for: fileURL)
            ))
            self.flushPendingFiles()
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        handleQueueMessage(userInfo)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleQueueMessage(message)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        if message["command"] as? String == "workspace-account" {
            Task { @MainActor in replyHandler(self.applyWorkspaceAccount(message)) }
        } else {
            handleQueueMessage(message)
            replyHandler(["ok": true])
        }
    }

    @MainActor
    func requestVoiceSetup() {
        let watch = WCSession.default
        guard watch.activationState == .activated, watch.isReachable else {
            WatchVoiceService.shared.showSetupMessage("Open Scribe Pilot on your iPhone and keep your Watch nearby, then tap Sync from iPhone again. No code is needed.")
            return
        }
        WatchVoiceService.shared.showSetupMessage("Checking voice setup with your iPhone…")
        watch.sendMessage(["command": "voice-setup-request"], replyHandler: { reply in
            Task { @MainActor in
                guard reply["command"] as? String == "workspace-account" else { return }
                _ = self.applyWorkspaceAccount(reply)
            }
        }, errorHandler: { _ in
            Task { @MainActor in WatchVoiceService.shared.showSetupMessage("The iPhone did not respond. Open Scribe Pilot on your iPhone, then tap Sync from iPhone again.") }
        })
    }

    @MainActor
    private func applyWorkspaceAccount(_ context: [String: Any]) -> [String: Any] {
        let raw = context["owner_id"] as? String ?? ""
        let owner = RecordingQueueStore.validID(raw) ? raw : nil
        if RecordingQueueStore.shared.accountID != owner {
            meetingStatus = nil; lastRecordingID = nil
        }
        RecordingQueueStore.shared.setAccount(owner)
        let result = WatchVoiceService.shared.applyAccount(owner: owner,
            configurationData: context["voice_config"] as? Data, credentialData: context["voice_credential"] as? Data)
        UserDefaults.standard.set(context["username"] as? String ?? "", forKey: "ScribePilot.WorkspaceUsername")
        openAIReady = context["ready"] as? Bool ?? false
        if let status = context["meeting_status"] as? [String: String], status["recording_id"] == lastRecordingID {
            meetingStatus = status["status"]
        }
        guard let owner, let request = context["voice_setup_request"] as? String, VoiceWire.validID(request),
              let credentialData = context["voice_credential"] as? Data,
              let credential = try? JSONDecoder().decode(VoiceDeviceCredential.self, from: credentialData),
              credential.owner_id == owner else { return ["ok": true] }
        let receipt = VoiceSetupReceipt(version: 1, requestID: request, ownerID: owner, deviceID: credential.device_id, state: result)
        guard let data = try? JSONEncoder().encode(receipt) else { return ["ok": false] }
        let reply: [String: Any] = ["command": "voice-setup-receipt", "voice_setup_receipt": data]
        // Durable, non-secret acknowledgment also works when the phone is suspended.
        let session = WCSession.default
        if !session.outstandingUserInfoTransfers.contains(where: { ($0.userInfo["voice_setup_receipt"] as? Data) == data }) {
            session.transferUserInfo(reply)
        }
        return reply
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        if applicationContext["command"] as? String == "workspace-account" {
            Task { @MainActor in _ = self.applyWorkspaceAccount(applicationContext) }
            return
        }
        guard applicationContext["command"] as? String == "meeting-status",
              let recordingID = applicationContext["recording_id"] as? String,
              let message = applicationContext["status"] as? String else { return }
        DispatchQueue.main.async {
            guard recordingID == self.lastRecordingID else { return }
            self.meetingStatus = message
        }
    }

    private func handleResendRequest(_ userInfo: [String: Any]) {
        guard userInfo["command"] as? String == "resend-recording",
              let recordingID = userInfo["recording_id"] as? String else { return }
        let requestedIndexes: Set<Int>?
        if let indexes = userInfo["chunk_indexes"] as? [Int] {
            requestedIndexes = Set(indexes)
        } else if let indexes = userInfo["chunk_indexes"] as? [NSNumber] {
            requestedIndexes = Set(indexes.map(\.intValue))
        } else {
            requestedIndexes = nil
        }
        DispatchQueue.main.async {
            self.resendRecording(recordingID, chunkIndexes: requestedIndexes)
        }
    }

    private func handleQueueMessage(_ message: [String: Any]) {
        if message["command"] as? String == "workspace-account" {
            Task { @MainActor in _ = self.applyWorkspaceAccount(message) }
            return
        }
        if message["command"] as? String == "resend-recording" { handleResendRequest(message); return }
        Task { @MainActor in
            if message["command"] as? String == "processing-settings" {
                let owner = message["owner_id"] as? String ?? ""
                guard owner == (RecordingQueueStore.shared.accountID ?? "") else { return }
                self.openAIReady = message["ready"] as? Bool ?? false
                self.protectedWorkflow = message["protected"] as? Bool ?? true
                UserDefaults.standard.set(self.openAIReady, forKey: "ScribePilot.OpenAIReady")
                UserDefaults.standard.set(self.protectedWorkflow, forKey: "ScribePilot.ProtectedWorkflow")
                return
            }
            guard let id = message["recording_id"] as? String, RecordingQueueStore.validID(id) else { return }
            do {
                switch message["command"] as? String {
                case "assign-recording":
                    guard let owner = message["owner_id"] as? String, RecordingQueueStore.validID(owner),
                          self.owner(for: id) == nil else { return }
                    var owners = UserDefaults.standard.dictionary(forKey: "ScribePilot.WatchOwners") as? [String: String] ?? [:]
                    owners[id] = owner; UserDefaults.standard.set(owners, forKey: "ScribePilot.WatchOwners")
                    if RecordingQueueStore.shared.recording(id)?.ownerID == nil, RecordingQueueStore.shared.recording(id) != nil {
                        try RecordingQueueStore.shared.assign(id, owner: owner)
                    }
                case "remove-recording": try self.removeRecording(id, notifyPhone: false)
                case "rename-recording":
                    if let title = message["title"] as? String { try RecordingQueueStore.shared.rename(id, title: title) }
                case "recording-complete":
                    try RecordingQueueStore.shared.update(id) { $0.state = .ready; $0.progress = 1; $0.error = nil }
                    if message["delete_audio"] as? Bool == true {
                        try RecordingQueueStore.shared.purgeAudio(id)
                        try self.purgeOriginalAudio(id)
                    }
                    if id == self.lastRecordingID { self.meetingStatus = "Transcript ready on iPhone" }
                case "meeting-status":
                    if id == self.lastRecordingID { self.meetingStatus = message["status"] as? String }
                default: break
                }
            } catch { RecordingQueueStore.shared.errorMessage = error.localizedDescription }
        }
    }

    @MainActor
    func retryRecording(_ id: String) {
        guard !removedRecordingIDs.contains(id) else { return }
        resendRecording(id)
        WCSession.default.transferUserInfo(["command": "retry-recording", "recording_id": id])
        statusMessage = "Requested processing on iPhone"
    }

    @MainActor
    func renameRecording(_ id: String, title: String) throws {
        try RecordingQueueStore.shared.rename(id, title: title)
        WCSession.default.transferUserInfo(["command": "rename-recording", "recording_id": id, "title": title, "owner_id": owner(for: id) ?? ""])
    }

    @MainActor
    func removeRecording(_ id: String, notifyPhone: Bool = true) throws {
        if AudioRecorderService.shared.isRecording && id == lastRecordingID {
            AudioRecorderService.shared.stopRecording()
            try RecordingQueueStore.shared.update(id) { $0.state = .receiving }
        }
        defer {
            // Notify the companion even when audio cleanup fails after the deletion was saved.
            if RecordingQueueStore.shared.isRemoved(id) {
                removedRecordingIDs.insert(id)
                UserDefaults.standard.set(removedRecordingIDs.sorted(), forKey: "ScribePilot.RemovedWatchRecordings")
                pendingFiles.removeAll { ($0.metadata["recording_id"] as? String) == id }
                for transfer in WCSession.default.outstandingFileTransfers where transfer.file.metadata?["recording_id"] as? String == id {
                    inFlightFiles.remove(transfer.file.fileURL.lastPathComponent)
                    transfer.cancel()
                }
                if notifyPhone { WCSession.default.transferUserInfo(["command": "remove-recording", "recording_id": id, "owner_id": owner(for: id) ?? ""]) }
                if id == lastRecordingID { meetingStatus = nil; statusMessage = "Recording removed" }
            }
        }
        try RecordingQueueStore.shared.remove([id])
        try purgeOriginalAudio(id)
    }

    private func purgeOriginalAudio(_ id: String) throws {
        let directory = recordingsDirectory()
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files where file.lastPathComponent.contains("_\(id)_") {
            try FileManager.default.removeItem(at: file)
        }
    }

    private func markChunkDelivered(
        recordingID: String?,
        chunkIndex: Int?,
        isFinal: Bool,
        immediate: Bool
    ) {
        guard recordingID == counterRecordingID,
              let chunkIndex,
              deliveredChunkIndexes.insert(chunkIndex).inserted else { return }
        deliveredChunkCount = deliveredChunkIndexes.count
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
                "owner_id": owner(for: String(parts[1])) ?? "",
            ]
        }
        return ["kind": "audio-recording", "filename": fileURL.lastPathComponent]
    }

    private func owner(for id: String) -> String? {
        let owners = UserDefaults.standard.dictionary(forKey: "ScribePilot.WatchOwners") as? [String: String] ?? [:]
        guard let value = owners[id], value != "unassigned", RecordingQueueStore.validID(value) else { return nil }
        return value
    }

    private func recordingsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
    }

}
