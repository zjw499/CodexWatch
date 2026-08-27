import Combine
import Foundation
import Security
import WatchConnectivity

private struct ImmediateWatchChunkEnvelope: Codable {
    let version: Int
    let filename: String
    let recordingID: String
    let chunkIndex: Int
    let isFinal: Bool
    let audioData: Data
}

final class PhoneUploadService: NSObject, ObservableObject, WCSessionDelegate, URLSessionDelegate, URLSessionTaskDelegate {
    static let shared = PhoneUploadService()
    static let backgroundIdentifier = "com.zachwyatt.codexwatch.audio-upload"
    private static let statusDefaultsKey = "CodexWatch.PhoneUploadStatus"
    private static let pendingCompletionDefaultsKey = "CodexWatch.PendingPCCompletions"

    @Published private(set) var statusMessage: String
    @Published private(set) var activeRecordingID: String?
    @Published private(set) var receivedChunkCount = 0
    @Published private(set) var uploadedChunkCount = 0
    @Published private(set) var finalChunkReceived = false
    @Published private(set) var finalUploadSequence = 0

    private struct ChunkContext {
        let recordingID: String
        let chunkIndex: Int
        let isFinal: Bool
    }

    private struct PersistedTaskContext {
        let bodyURL: URL
        let sourceURL: URL?
        let chunk: ChunkContext?
        let attempt: Int
        let recipient: String
    }

    private struct PendingUpload {
        let fileURL: URL
        let chunk: ChunkContext?
        let attempt: Int
        let recipient: String
    }

    private let stateQueue = DispatchQueue(label: "com.zachwyatt.codexwatch.upload-state")
    private let maxConcurrentUploads = 2
    private let retryDelays: [TimeInterval] = [5, 15, 45, 120, 300]
    private var uploadSession: URLSession?
    private var bodyURLs: [Int: URL] = [:]
    private var sourceURLs: [Int: URL] = [:]
    private var chunkContexts: [Int: ChunkContext] = [:]
    private var activeTaskIDsByKey: [String: Int] = [:]
    private var pendingUploadsByKey: [String: PendingUpload] = [:]
    private var pendingUploadOrder: [String] = []
    private var scheduledRetryAttempts: [String: Int] = [:]
    private var completionHandlers: [String: () -> Void] = [:]
    private var immediateChunkKeys: Set<String> = []
    private var receivedChunkKeys: Set<String> = []
    private var uploadedChunkKeys: Set<String> = []
    private var completionPollingRecordingIDs: Set<String> = []
    private var started = false
    private var isRestoringBackgroundTasks = false

    override init() {
        statusMessage = UserDefaults.standard.string(forKey: Self.statusDefaultsKey) ?? "Ready"
        super.init()
    }

    var configurationStatus: String {
        CodexWatchPhoneConfiguration.isConfigured
            ? "PC upload configured"
            : "PC upload configuration missing"
    }

    func start() {
        var shouldStart = false
        stateQueue.sync {
            guard !self.started else { return }
            self.started = true

            let configuration = URLSessionConfiguration.background(withIdentifier: Self.backgroundIdentifier)
            configuration.sessionSendsLaunchEvents = true
            configuration.isDiscretionary = false
            configuration.waitsForConnectivity = true
            configuration.allowsCellularAccess = true
            configuration.timeoutIntervalForRequest = 180
            configuration.timeoutIntervalForResource = 900
            self.uploadSession = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.isRestoringBackgroundTasks = true
            shouldStart = true
        }

        guard shouldStart else { return }
        uploadSession?.getAllTasks { [weak self] tasks in
            self?.stateQueue.async {
                self?.restoreBackgroundTasks(tasks)
            }
        }
        guard WCSession.isSupported() else {
            setStatus("Watch transfer unavailable")
            return
        }
        DispatchQueue.main.async {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func enqueue(fileURL: URL) {
        start()
        stateQueue.async {
            self.queueUpload(fileURL: fileURL, recipient: PhoneRecipientSettings.recipient)
        }
    }

    func retryPendingRecordings() {
        start()
        stateQueue.async {
            self.recoverSavedUploads(manual: true)
            self.resumeCompletionPolling()
        }
    }

    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void, for identifier: String) {
        stateQueue.async {
            self.completionHandlers[identifier] = handler
        }
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        do {
            let metadata = file.metadata ?? [:]
            let isChunk = metadata["kind"] as? String == "audio-recording-chunk"
            let context = chunkContext(from: metadata)
            let directory = isChunk ? try streamChunksDirectory() : try recordingsDirectory()
            let destination: URL
            if let context {
                destination = directory.appendingPathComponent(
                    String(
                        format: "stream_%@_%06d_%d.m4a",
                        context.recordingID,
                        context.chunkIndex,
                        context.isFinal ? 1 : 0
                    )
                )
            } else {
                destination = directory.appendingPathComponent(file.fileURL.lastPathComponent)
            }
            if let context, immediateChunkKeys.contains(chunkKey(context)) {
                return
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: file.fileURL, to: destination)
            if let context {
                markChunkReceived(context)
                stateQueue.async {
                    self.queueChunkUpload(fileURL: destination, context: context)
                }
            } else {
                setStatus("Watch recording received; uploading to PC")
                enqueue(fileURL: destination)
            }
        } catch {
            setStatus("Could not receive watch recording: \(error.localizedDescription)")
        }
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error {
            setStatus("Watch transfer unavailable: \(error.localizedDescription)")
        } else if activationState == .activated {
            setStatus("Ready for watch recordings")
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        stateQueue.async {
            let persisted = self.persistedTaskContext(from: task.taskDescription)
            let bodyURL = self.bodyURLs.removeValue(forKey: task.taskIdentifier) ?? persisted?.bodyURL
            let sourceURL = self.sourceURLs.removeValue(forKey: task.taskIdentifier) ?? persisted?.sourceURL
            let chunkContext = self.chunkContexts.removeValue(forKey: task.taskIdentifier) ?? persisted?.chunk
            let attempt = persisted?.attempt ?? 0
            let recipient = persisted?.recipient ?? PhoneRecipientSettings.recipient
            let statusCode = (task.response as? HTTPURLResponse)?.statusCode
            let key = sourceURL.map { self.uploadKey(fileURL: $0, chunk: chunkContext) }

            if let bodyURL {
                try? FileManager.default.removeItem(at: bodyURL)
            }

            guard let key,
                  self.activeTaskIDsByKey[key] == task.taskIdentifier else {
                self.pumpUploads()
                return
            }
            self.activeTaskIDsByKey.removeValue(forKey: key)

            if let error {
                if let sourceURL, self.isRetryable(error: error) {
                    self.scheduleRetry(
                        PendingUpload(
                            fileURL: sourceURL,
                            chunk: chunkContext,
                            attempt: attempt + 1,
                            recipient: recipient
                        ),
                        key: key
                    )
                } else {
                    self.setStatus("PC upload stopped; recording remains saved: \(error.localizedDescription)")
                }
                self.pumpUploads()
                return
            }

            guard let statusCode, (200..<300).contains(statusCode) else {
                if let sourceURL, self.isRetryable(statusCode: statusCode) {
                    self.scheduleRetry(
                        PendingUpload(
                            fileURL: sourceURL,
                            chunk: chunkContext,
                            attempt: attempt + 1,
                            recipient: recipient
                        ),
                        key: key
                    )
                } else {
                    self.setStatus("PC rejected the upload (HTTP \(statusCode ?? 0)); recording remains saved")
                }
                self.pumpUploads()
                return
            }

            if let sourceURL {
                try? FileManager.default.removeItem(at: sourceURL)
            }
            if let chunkContext {
                DispatchQueue.main.async {
                    let key = self.chunkKey(chunkContext)
                    guard self.uploadedChunkKeys.insert(key).inserted else { return }
                    self.uploadedChunkCount += 1
                    if chunkContext.isFinal {
                        self.finalUploadSequence += 1
                        self.statusMessage = "Final chunk uploaded; PC is finishing the transcript"
                        UserDefaults.standard.set(self.statusMessage, forKey: Self.statusDefaultsKey)
                        self.beginCompletionPolling(recordingID: chunkContext.recordingID)
                    } else {
                        self.statusMessage = "Uploaded \(self.uploadedChunkCount) of \(self.receivedChunkCount) chunks"
                        UserDefaults.standard.set(self.statusMessage, forKey: Self.statusDefaultsKey)
                    }
                }
            } else {
                self.setStatus("Uploaded to PC")
            }
            self.pumpUploads()
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        stateQueue.async {
            let identifier = session.configuration.identifier ?? Self.backgroundIdentifier
            let handler = self.completionHandlers.removeValue(forKey: identifier)
            DispatchQueue.main.async {
                handler?()
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handleAuthenticationChallenge(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handleAuthenticationChallenge(challenge, completionHandler: completionHandler)
    }

    private func handleAuthenticationChallenge(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let host = challenge.protectionSpace.host as CFString
        guard SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host)) == errSecSuccess else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        if SecTrustEvaluateWithError(trust, nil) {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        guard let rootCertificate = bundledRootCertificate(),
              SecTrustSetAnchorCertificates(trust, [rootCertificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    private func bundledRootCertificate() -> SecCertificate? {
        guard let certificateURL = Bundle.main.url(forResource: "watch-audio-ca", withExtension: "crt"),
              let certificateData = try? Data(contentsOf: certificateURL) else {
            return nil
        }

        if let certificate = SecCertificateCreateWithData(nil, certificateData as CFData) {
            return certificate
        }

        guard let pem = String(data: certificateData, encoding: .utf8) else { return nil }
        let base64 = pem
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let decoded = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            return nil
        }
        return SecCertificateCreateWithData(nil, decoded as CFData)
    }

    private func setStatus(_ message: String) {
        UserDefaults.standard.set(message, forKey: Self.statusDefaultsKey)
        DispatchQueue.main.async {
            self.statusMessage = message
        }
    }

    private func queueUpload(fileURL: URL, recipient: String) {
        enqueueUpload(fileURL: fileURL, chunk: nil, recipient: recipient)
    }

    private func queueChunkUpload(fileURL: URL, context: ChunkContext) {
        enqueueUpload(
            fileURL: fileURL,
            chunk: context,
            recipient: PhoneRecipientSettings.recipient
        )
    }

    private func enqueueUpload(
        fileURL: URL,
        chunk: ChunkContext?,
        recipient: String,
        attempt: Int = 0,
        manual: Bool = false
    ) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let key = uploadKey(fileURL: fileURL, chunk: chunk)
        if manual {
            scheduledRetryAttempts.removeValue(forKey: key)
        } else if scheduledRetryAttempts[key] != nil {
            return
        }
        guard activeTaskIDsByKey[key] == nil else { return }
        if pendingUploadsByKey[key] != nil {
            if manual {
                pendingUploadsByKey[key] = PendingUpload(
                    fileURL: fileURL,
                    chunk: chunk,
                    attempt: 0,
                    recipient: recipient
                )
            }
            return
        }
        pendingUploadsByKey[key] = PendingUpload(
            fileURL: fileURL,
            chunk: chunk,
            attempt: attempt,
            recipient: recipient
        )
        pendingUploadOrder.append(key)
        pumpUploads()
    }

    private func pumpUploads() {
        guard !isRestoringBackgroundTasks else { return }
        while activeTaskIDsByKey.count < maxConcurrentUploads, !pendingUploadOrder.isEmpty {
            let key = pendingUploadOrder.removeFirst()
            guard let upload = pendingUploadsByKey.removeValue(forKey: key),
                  FileManager.default.fileExists(atPath: upload.fileURL.path) else { continue }
            startUpload(upload, key: key)
        }
    }

    private func startUpload(_ upload: PendingUpload, key: String) {
        do {
            let fields: [String: String]
            let uploadURL: URL?
            if let context = upload.chunk {
                fields = [
                    "recording_id": context.recordingID,
                    "chunk_index": String(context.chunkIndex),
                    "is_final": context.isFinal ? "true" : "false",
                    "source": "apple-watch-stream",
                    "client_id": PhoneRecipientSettings.clientID,
                    "recipient": upload.recipient,
                ]
                uploadURL = CodexWatchPhoneConfiguration.chunkUploadURL
            } else {
                fields = [
                    "source": "iphone-app",
                    "client_id": PhoneRecipientSettings.clientID,
                    "recipient": upload.recipient,
                ]
                uploadURL = CodexWatchPhoneConfiguration.audioUploadURL
            }
            guard !upload.recipient.isEmpty else {
                setStatus("Add your transcript email in Settings; recording remains saved")
                return
            }
            guard let uploadURL,
                  let username = CodexWatchPhoneConfiguration.audioUploadUsername,
                  let password = CodexWatchPhoneConfiguration.audioUploadPassword,
                  !username.isEmpty,
                  !password.isEmpty else {
                setStatus("PC upload is not configured; recording remains saved")
                return
            }
            let bodyURL = try makeMultipartBody(fileURL: upload.fileURL, fields: fields)
            var request = URLRequest(url: uploadURL)
            request.httpMethod = "POST"
            request.timeoutInterval = 180
            let boundary = bodyURL.deletingPathExtension().lastPathComponent
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.setValue("Basic \(basicAuth(username: username, password: password))", forHTTPHeaderField: "Authorization")
            request.setValue("Scribe Pilot", forHTTPHeaderField: "User-Agent")
            guard let uploadSession else {
                try? FileManager.default.removeItem(at: bodyURL)
                setStatus("Upload service unavailable")
                return
            }
            let task = uploadSession.uploadTask(with: request, fromFile: bodyURL)
            task.taskDescription = taskDescription(
                bodyURL: bodyURL,
                sourceURL: upload.fileURL,
                chunk: upload.chunk,
                attempt: upload.attempt,
                recipient: upload.recipient
            )
            bodyURLs[task.taskIdentifier] = bodyURL
            sourceURLs[task.taskIdentifier] = upload.fileURL
            if let context = upload.chunk {
                chunkContexts[task.taskIdentifier] = context
            }
            activeTaskIDsByKey[key] = task.taskIdentifier
            task.resume()
            if upload.chunk == nil {
                setStatus("Uploading to PC")
            }
        } catch {
            setStatus("Could not prepare upload; recording remains saved: \(error.localizedDescription)")
        }
    }

    private func restoreBackgroundTasks(_ tasks: [URLSessionTask]) {
        for task in tasks {
            guard let persisted = persistedTaskContext(from: task.taskDescription),
                  let sourceURL = persisted.sourceURL else {
                task.cancel()
                continue
            }
            let key = uploadKey(fileURL: sourceURL, chunk: persisted.chunk)
            if activeTaskIDsByKey[key] != nil {
                task.cancel()
                continue
            }
            pendingUploadsByKey.removeValue(forKey: key)
            scheduledRetryAttempts.removeValue(forKey: key)
            activeTaskIDsByKey[key] = task.taskIdentifier
            bodyURLs[task.taskIdentifier] = persisted.bodyURL
            sourceURLs[task.taskIdentifier] = sourceURL
            if let chunk = persisted.chunk {
                chunkContexts[task.taskIdentifier] = chunk
            }
        }
        isRestoringBackgroundTasks = false
        recoverSavedUploads(manual: false)
        resumeCompletionPolling()
        clearLegacyStaleCompletionStatus()
        pumpUploads()
    }

    private func recoverSavedUploads(manual: Bool) {
        if let directory = try? recordingsDirectory() {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            for fileURL in files where ["m4a", "mp3", "wav", "caf"].contains(fileURL.pathExtension.lowercased()) {
                enqueueUpload(
                    fileURL: fileURL,
                    chunk: nil,
                    recipient: PhoneRecipientSettings.recipient,
                    manual: manual
                )
            }
        }
        if let directory = try? streamChunksDirectory() {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            for fileURL in files {
                guard let context = chunkContext(from: fileURL) else { continue }
                enqueueUpload(
                    fileURL: fileURL,
                    chunk: context,
                    recipient: PhoneRecipientSettings.recipient,
                    manual: manual
                )
            }
        }
    }

    private func scheduleRetry(_ upload: PendingUpload, key: String) {
        guard upload.attempt <= retryDelays.count,
              FileManager.default.fileExists(atPath: upload.fileURL.path) else {
            setStatus("PC upload paused after repeated failures; tap retry when connected")
            return
        }
        let delay = retryDelays[upload.attempt - 1]
        scheduledRetryAttempts[key] = upload.attempt
        setStatus("PC unavailable; retrying in \(Int(delay)) seconds")
        stateQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.scheduledRetryAttempts[key] == upload.attempt else { return }
            self.scheduledRetryAttempts.removeValue(forKey: key)
            self.enqueueUpload(
                fileURL: upload.fileURL,
                chunk: upload.chunk,
                recipient: upload.recipient,
                attempt: upload.attempt
            )
        }
    }

    private func isRetryable(statusCode: Int?) -> Bool {
        guard let statusCode else { return true }
        return statusCode == 408 || statusCode == 425 || statusCode == 429 || (500...599).contains(statusCode)
    }

    private func isRetryable(error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else { return false }
        switch URLError.Code(rawValue: error.code) {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
             .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    private func uploadKey(fileURL: URL, chunk: ChunkContext?) -> String {
        if let chunk {
            return "chunk:\(chunkKey(chunk))"
        }
        return "file:\(fileURL.standardizedFileURL.path.lowercased())"
    }

    func session(
        _ session: WCSession,
        didReceiveMessageData messageData: Data,
        replyHandler: @escaping (Data) -> Void
    ) {
        do {
            let envelope = try PropertyListDecoder().decode(
                ImmediateWatchChunkEnvelope.self,
                from: messageData
            )
            guard envelope.version == 1, !envelope.audioData.isEmpty else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let context = ChunkContext(
                recordingID: envelope.recordingID,
                chunkIndex: envelope.chunkIndex,
                isFinal: envelope.isFinal
            )
            let destination = try streamChunksDirectory().appendingPathComponent(
                String(
                    format: "stream_%@_%06d_%d.m4a",
                    context.recordingID,
                    context.chunkIndex,
                    context.isFinal ? 1 : 0
                )
            )
            try envelope.audioData.write(to: destination, options: [.atomic])
            immediateChunkKeys.insert(chunkKey(context))
            markChunkReceived(context)
            stateQueue.async {
                self.queueChunkUpload(fileURL: destination, context: context)
            }
            replyHandler(Data("accepted".utf8))
        } catch {
            setStatus("Immediate watch chunk failed; waiting for fallback: \(error.localizedDescription)")
            replyHandler(Data("rejected".utf8))
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard userInfo["command"] as? String == "retry-recording",
              let recordingID = userInfo["recording_id"] as? String else { return }
        retryRecording(recordingID: recordingID)
    }

    private func retryRecording(recordingID: String) {
        setStatus("Checking saved recording chunks")
        stateQueue.async {
            let directory = try? self.streamChunksDirectory()
            let files = directory.flatMap {
                try? FileManager.default.contentsOfDirectory(
                    at: $0,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
            } ?? []
            let matching = files.compactMap { fileURL -> (URL, ChunkContext)? in
                guard let context = self.chunkContext(from: fileURL),
                      context.recordingID == recordingID else { return nil }
                return (fileURL, context)
            }
            if !matching.isEmpty {
                for (fileURL, context) in matching {
                    self.enqueueUpload(
                        fileURL: fileURL,
                        chunk: context,
                        recipient: PhoneRecipientSettings.recipient,
                        manual: true
                    )
                }
                self.setStatus("Retrying \(matching.count) saved chunks")
            }
            self.checkPCRecording(recordingID)
        }
    }

    private func checkPCRecording(_ recordingID: String) {
        Task { [weak self] in
            do {
                let progress = try await PhoneMemoAPIClient.shared.getRecordingProgress(id: recordingID)
                if progress.status == "done" {
                    self?.finishCompletionPolling(recordingID: recordingID)
                    return
                }
                let hasCompleteSequence = progress.finalChunkIndex.map {
                    progress.receivedChunks >= $0 + 1 &&
                    (progress.missingChunkIndexes ?? []).isEmpty
                } ?? false
                if progress.status == "failed" {
                    try await PhoneMemoAPIClient.shared.retryRecording(id: recordingID)
                    self?.setStatus("PC processing retry queued")
                } else if hasCompleteSequence {
                    self?.setStatus("PC has every chunk and is processing")
                } else {
                    let missing = progress.missingChunkIndexes ?? []
                    self?.requestWatchResend(
                        recordingID,
                        chunkIndexes: missing.isEmpty ? nil : missing
                    )
                }
            } catch PhoneMemoAPIError.httpStatus(404) {
                self?.requestWatchResend(recordingID)
            } catch {
                self?.setStatus("Could not check PC; retry after the connection returns")
            }
        }
    }

    private func beginCompletionPolling(recordingID: String) {
        stateQueue.async {
            self.rememberPendingCompletion(recordingID)
            self.startCompletionPolling(recordingID: recordingID)
        }
    }

    private func resumeCompletionPolling() {
        for recordingID in pendingCompletionRecordingIDs() {
            startCompletionPolling(recordingID: recordingID)
        }
    }

    private func clearLegacyStaleCompletionStatus() {
        guard pendingCompletionRecordingIDs().isEmpty,
              let status = UserDefaults.standard.string(forKey: Self.statusDefaultsKey),
              status.hasPrefix("Uploaded ") ||
              status.hasPrefix("Final chunk uploaded") else { return }
        setStatus("Ready for watch recordings")
    }

    private func startCompletionPolling(recordingID: String) {
        guard completionPollingRecordingIDs.insert(recordingID).inserted else { return }
        Task { [weak self] in
            var requestedMissingIndexes: Set<Int>?
            defer {
                self?.stateQueue.async {
                    self?.completionPollingRecordingIDs.remove(recordingID)
                }
            }

            for _ in 0..<360 {
                guard let self else { return }
                do {
                    let progress = try await PhoneMemoAPIClient.shared.getRecordingProgress(id: recordingID)
                    if progress.status == "done" {
                        self.finishCompletionPolling(recordingID: recordingID)
                        return
                    }
                    if progress.status == "failed" {
                        self.setStatus(
                            "PC processing failed; recording remains saved for retry",
                            forRecordingID: recordingID
                        )
                        return
                    }
                    let missingIndexes = Set(progress.missingChunkIndexes ?? [])
                    if !missingIndexes.isEmpty {
                        if requestedMissingIndexes != missingIndexes {
                            self.requestWatchResend(
                                recordingID,
                                chunkIndexes: missingIndexes.sorted()
                            )
                            requestedMissingIndexes = missingIndexes
                        }
                        self.setStatus(
                            "Recovering \(missingIndexes.count) missing watch chunk\(missingIndexes.count == 1 ? "" : "s")",
                            forRecordingID: recordingID
                        )
                        try? await Task.sleep(for: .seconds(5))
                        continue
                    }
                    if let finalIndex = progress.finalChunkIndex,
                       progress.receivedChunks < finalIndex + 1 {
                        if requestedMissingIndexes != Set<Int>() {
                            self.requestWatchResend(recordingID)
                            requestedMissingIndexes = Set<Int>()
                        }
                        self.setStatus(
                            "Recovering missing watch chunks",
                            forRecordingID: recordingID
                        )
                        try? await Task.sleep(for: .seconds(5))
                        continue
                    }
                    self.setStatus(
                        "PC transcribed \(progress.transcribedChunks) of \(progress.receivedChunks) chunks",
                        forRecordingID: recordingID
                    )
                } catch PhoneMemoAPIError.httpStatus(404) {
                    self.setStatus("Waiting for the final chunk to reach the PC", forRecordingID: recordingID)
                } catch {
                    self.setStatus("Waiting for the PC connection", forRecordingID: recordingID)
                }
                try? await Task.sleep(for: .seconds(5))
            }

            self?.setStatus(
                "PC processing is taking longer than expected",
                forRecordingID: recordingID
            )
        }
    }

    private func finishCompletionPolling(recordingID: String) {
        stateQueue.async {
            self.forgetPendingCompletion(recordingID)
            self.completionPollingRecordingIDs.remove(recordingID)
        }
        DispatchQueue.main.async {
            guard self.activeRecordingID == nil || self.activeRecordingID == recordingID else { return }
            if self.activeRecordingID == recordingID {
                self.activeRecordingID = nil
                self.receivedChunkCount = 0
                self.uploadedChunkCount = 0
                self.finalChunkReceived = false
                self.receivedChunkKeys.removeAll()
                self.uploadedChunkKeys.removeAll()
            }
            self.finalUploadSequence += 1
            self.statusMessage = "Transcript delivered"
            UserDefaults.standard.set(self.statusMessage, forKey: Self.statusDefaultsKey)
        }
    }

    private func setStatus(_ message: String, forRecordingID recordingID: String) {
        DispatchQueue.main.async {
            guard self.activeRecordingID == recordingID else { return }
            self.statusMessage = message
            UserDefaults.standard.set(message, forKey: Self.statusDefaultsKey)
        }
    }

    private func pendingCompletionRecordingIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.pendingCompletionDefaultsKey) ?? [])
    }

    private func rememberPendingCompletion(_ recordingID: String) {
        var recordingIDs = pendingCompletionRecordingIDs()
        recordingIDs.insert(recordingID)
        UserDefaults.standard.set(recordingIDs.sorted(), forKey: Self.pendingCompletionDefaultsKey)
    }

    private func forgetPendingCompletion(_ recordingID: String) {
        var recordingIDs = pendingCompletionRecordingIDs()
        recordingIDs.remove(recordingID)
        UserDefaults.standard.set(recordingIDs.sorted(), forKey: Self.pendingCompletionDefaultsKey)
    }

    private func requestWatchResend(
        _ recordingID: String,
        chunkIndexes: [Int]? = nil
    ) {
        DispatchQueue.main.async {
            guard WCSession.isSupported() else {
                self.setStatus("Watch connection unavailable")
                return
            }
            var request: [String: Any] = [
                "command": "resend-recording",
                "recording_id": recordingID,
            ]
            if let chunkIndexes, !chunkIndexes.isEmpty {
                request["chunk_indexes"] = chunkIndexes
            }
            let session = WCSession.default
            if session.isReachable {
                session.sendMessage(request, replyHandler: nil) { _ in
                    session.transferUserInfo(request)
                }
            } else {
                session.transferUserInfo(request)
            }
            self.setStatus(
                chunkIndexes?.count == 1
                    ? "Asked Watch for the missing chunk"
                    : "Asked Watch to resend missing chunks"
            )
        }
    }

    private func recordingsDirectory() throws -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func streamChunksDirectory() throws -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StreamChunks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeMultipartBody(fileURL: URL, fields: [String: String] = [:]) throws -> URL {
        let boundary = "CodexWatch-\(UUID().uuidString)"
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Uploads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bodyURL = directory.appendingPathComponent("\(boundary).body")

        guard FileManager.default.createFile(atPath: bodyURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let fileName = fileURL.lastPathComponent.replacingOccurrences(of: "\"", with: "")
        let fieldData = fields.sorted(by: { $0.key < $1.key }).map { key, value in
            "--\(boundary)\r\n" +
                "Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n" +
                "\(value)\r\n"
        }.joined()
        let header = fieldData + "--\(boundary)\r\n" +
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n" +
            "Content-Type: audio/mp4\r\n\r\n"
        let footer = "\r\n--\(boundary)--\r\n"

        let output = try FileHandle(forWritingTo: bodyURL)
        defer { try? output.close() }
        try output.write(contentsOf: Data(header.utf8))

        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
        try output.write(contentsOf: Data(footer.utf8))
        return bodyURL
    }

    private func basicAuth(username: String, password: String) -> String {
        Data("\(username):\(password)".utf8).base64EncodedString()
    }

    private func chunkContext(from metadata: [String: Any]) -> ChunkContext? {
        guard let recordingID = metadata["recording_id"] as? String,
              let chunkIndex = metadata["chunk_index"] as? Int else { return nil }
        let isFinal = metadata["is_final"] as? Bool ?? false
        return ChunkContext(recordingID: recordingID, chunkIndex: chunkIndex, isFinal: isFinal)
    }

    private func chunkContext(from fileURL: URL) -> ChunkContext? {
        let parts = fileURL.deletingPathExtension().lastPathComponent.split(separator: "_")
        guard parts.count == 4,
              parts[0] == "stream",
              let chunkIndex = Int(parts[2]),
              let finalFlag = Int(parts[3]) else { return nil }
        return ChunkContext(
            recordingID: String(parts[1]),
            chunkIndex: chunkIndex,
            isFinal: finalFlag == 1
        )
    }

    private func markChunkReceived(_ context: ChunkContext) {
        DispatchQueue.main.async {
            if self.activeRecordingID != context.recordingID {
                self.activeRecordingID = context.recordingID
                self.receivedChunkCount = 0
                self.uploadedChunkCount = 0
                self.finalChunkReceived = false
                self.receivedChunkKeys.removeAll()
                self.uploadedChunkKeys.removeAll()
            }
            guard self.receivedChunkKeys.insert(self.chunkKey(context)).inserted else { return }
            self.receivedChunkCount += 1
            self.finalChunkReceived = self.finalChunkReceived || context.isFinal
            if context.isFinal {
                self.stateQueue.async {
                    self.rememberPendingCompletion(context.recordingID)
                }
            }
            self.statusMessage = context.isFinal
                ? "Final watch chunk received"
                : "Received watch chunk \(context.chunkIndex + 1)"
            UserDefaults.standard.set(self.statusMessage, forKey: Self.statusDefaultsKey)
        }
    }

    private func chunkKey(_ context: ChunkContext) -> String {
        "\(context.recordingID):\(context.chunkIndex)"
    }

    private func taskDescription(
        bodyURL: URL,
        sourceURL: URL?,
        chunk: ChunkContext?,
        attempt: Int,
        recipient: String
    ) -> String {
        [
            "v3",
            chunk == nil ? "file" : "chunk",
            bodyURL.path,
            sourceURL?.path ?? "",
            chunk?.recordingID ?? "",
            chunk.map { String($0.chunkIndex) } ?? "",
            chunk?.isFinal == true ? "1" : "0",
            String(attempt),
            recipient,
        ].joined(separator: "\t")
    }

    private func persistedTaskContext(from description: String?) -> PersistedTaskContext? {
        guard let description else { return nil }
        let fields = description
            .split(separator: "\t", omittingEmptySubsequences: false)
            .map(String.init)
        let offset: Int
        let attempt: Int
        let recipient: String
        if fields.count == 9, fields[0] == "v3" {
            offset = 1
            attempt = Int(fields[7]) ?? 0
            recipient = fields[8]
        } else if fields.count == 8, fields[0] == "v2" {
            offset = 1
            attempt = Int(fields[7]) ?? 0
            recipient = PhoneRecipientSettings.recipient
        } else if fields.count == 6 {
            offset = 0
            attempt = 0
            recipient = PhoneRecipientSettings.recipient
        } else {
            return nil
        }
        let chunk: ChunkContext?
        if fields[offset] == "chunk", let index = Int(fields[offset + 4]) {
            chunk = ChunkContext(
                recordingID: fields[offset + 3],
                chunkIndex: index,
                isFinal: fields[offset + 5] == "1"
            )
        } else {
            chunk = nil
        }
        return PersistedTaskContext(
            bodyURL: URL(fileURLWithPath: fields[offset + 1]),
            sourceURL: fields[offset + 2].isEmpty ? nil : URL(fileURLWithPath: fields[offset + 2]),
            chunk: chunk,
            attempt: attempt,
            recipient: recipient
        )
    }
}

enum CodexWatchPhoneConfiguration {
    static let isConfigured: Bool = {
        audioUploadURL != nil &&
        !(audioUploadUsername ?? "").isEmpty &&
        !(audioUploadPassword ?? "").isEmpty
    }()

    static let audioUploadURL: URL? = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "CODEX_WATCH_AUDIO_UPLOAD_URL") as? String,
              !value.isEmpty,
              !value.contains("REPLACE_WITH") else {
            return nil
        }
        return URL(string: value)
    }()

    static let chunkUploadURL: URL? = {
        guard let audioUploadURL else { return nil }
        var components = URLComponents(url: audioUploadURL, resolvingAgainstBaseURL: false)
        components?.path = "/upload/chunk"
        return components?.url
    }()

    static let audioUploadUsername = Bundle.main.object(forInfoDictionaryKey: "CODEX_WATCH_AUDIO_UPLOAD_USERNAME") as? String
    static let audioUploadPassword = Bundle.main.object(forInfoDictionaryKey: "CODEX_WATCH_AUDIO_UPLOAD_PASSWORD") as? String
}
