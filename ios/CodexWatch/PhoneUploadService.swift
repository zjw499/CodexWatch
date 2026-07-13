import Combine
import Foundation
import Security
import WatchConnectivity

final class PhoneUploadService: NSObject, ObservableObject, WCSessionDelegate, URLSessionDelegate, URLSessionTaskDelegate {
    static let shared = PhoneUploadService()
    static let backgroundIdentifier = "com.zachwyatt.codexwatch.audio-upload"
    private static let statusDefaultsKey = "CodexWatch.PhoneUploadStatus"

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
    }

    private let stateQueue = DispatchQueue(label: "com.zachwyatt.codexwatch.upload-state")
    private var uploadSession: URLSession?
    private var bodyURLs: [Int: URL] = [:]
    private var sourceURLs: [Int: URL] = [:]
    private var chunkContexts: [Int: ChunkContext] = [:]
    private var completionHandlers: [String: () -> Void] = [:]
    private var started = false

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
            self.uploadSession = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            shouldStart = true
        }

        guard shouldStart else { return }
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
            self.queueUpload(fileURL: fileURL)
        }
    }

    func retryPendingRecordings() {
        start()
        stateQueue.async {
            guard let directory = try? self.recordingsDirectory() else { return }
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            for fileURL in files where ["m4a", "mp3", "wav", "caf"].contains(fileURL.pathExtension.lowercased()) {
                self.queueUpload(fileURL: fileURL)
            }
            guard let chunkDirectory = try? self.streamChunksDirectory() else { return }
            let chunks = (try? FileManager.default.contentsOfDirectory(
                at: chunkDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            for fileURL in chunks {
                guard let context = self.chunkContext(from: fileURL) else { continue }
                self.queueChunkUpload(fileURL: fileURL, context: context)
            }
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
            let statusCode = (task.response as? HTTPURLResponse)?.statusCode

            if let bodyURL {
                try? FileManager.default.removeItem(at: bodyURL)
            }

            if let error {
                let nsError = error as NSError
                self.setStatus("PC upload failed (\(nsError.code)): \(error.localizedDescription)")
                return
            }

            guard let statusCode, (200..<300).contains(statusCode) else {
                self.setStatus("PC upload rejected the recording (HTTP \(statusCode ?? 0))")
                return
            }

            if let sourceURL {
                try? FileManager.default.removeItem(at: sourceURL)
            }
            if let chunkContext {
                DispatchQueue.main.async {
                    self.uploadedChunkCount += 1
                    if chunkContext.isFinal {
                        self.finalUploadSequence += 1
                        self.statusMessage = "Final chunk uploaded; PC is finishing the transcript"
                        UserDefaults.standard.set(self.statusMessage, forKey: Self.statusDefaultsKey)
                    } else {
                        self.statusMessage = "Uploaded \(self.uploadedChunkCount) of \(self.receivedChunkCount) chunks"
                        UserDefaults.standard.set(self.statusMessage, forKey: Self.statusDefaultsKey)
                    }
                }
            } else {
                self.setStatus("Uploaded to PC")
            }
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

        guard let trust = challenge.protectionSpace.serverTrust,
              let rootCertificate = bundledRootCertificate() else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let host = challenge.protectionSpace.host as CFString
        guard SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host)) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [rootCertificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        if SecTrustEvaluateWithError(trust, nil) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
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

    private func queueUpload(fileURL: URL) {
        do {
            let bodyURL = try makeMultipartBody(fileURL: fileURL)
            guard let uploadURL = CodexWatchPhoneConfiguration.audioUploadURL,
                  let username = CodexWatchPhoneConfiguration.audioUploadUsername,
                  let password = CodexWatchPhoneConfiguration.audioUploadPassword,
                  !username.isEmpty,
                  !password.isEmpty else {
                try? FileManager.default.removeItem(at: bodyURL)
                setStatus("PC upload is not configured")
                return
            }

            var request = URLRequest(url: uploadURL)
            request.httpMethod = "POST"
            let boundary = bodyURL.deletingPathExtension().lastPathComponent
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.setValue("Basic \(basicAuth(username: username, password: password))", forHTTPHeaderField: "Authorization")
            request.setValue("Codex Watch", forHTTPHeaderField: "User-Agent")

            guard let uploadSession else {
                try? FileManager.default.removeItem(at: bodyURL)
                setStatus("Upload service unavailable")
                return
            }
            let task = uploadSession.uploadTask(with: request, fromFile: bodyURL)
            task.taskDescription = taskDescription(bodyURL: bodyURL, sourceURL: fileURL, chunk: nil)
            bodyURLs[task.taskIdentifier] = bodyURL
            sourceURLs[task.taskIdentifier] = fileURL
            task.resume()
            setStatus("Uploading to PC")
        } catch {
            setStatus("Upload queued for retry: \(error.localizedDescription)")
        }
    }

    private func queueChunkUpload(fileURL: URL, context: ChunkContext) {
        do {
            let fields = [
                "recording_id": context.recordingID,
                "chunk_index": String(context.chunkIndex),
                "is_final": context.isFinal ? "true" : "false",
                "source": "apple-watch-stream",
            ]
            let bodyURL = try makeMultipartBody(fileURL: fileURL, fields: fields)
            guard let uploadURL = CodexWatchPhoneConfiguration.chunkUploadURL,
                  let username = CodexWatchPhoneConfiguration.audioUploadUsername,
                  let password = CodexWatchPhoneConfiguration.audioUploadPassword,
                  !username.isEmpty,
                  !password.isEmpty else {
                try? FileManager.default.removeItem(at: bodyURL)
                setStatus("PC chunk upload is not configured")
                return
            }
            var request = URLRequest(url: uploadURL)
            request.httpMethod = "POST"
            let boundary = bodyURL.deletingPathExtension().lastPathComponent
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.setValue("Basic \(basicAuth(username: username, password: password))", forHTTPHeaderField: "Authorization")
            request.setValue("Codex Watch", forHTTPHeaderField: "User-Agent")
            guard let uploadSession else {
                try? FileManager.default.removeItem(at: bodyURL)
                setStatus("Upload service unavailable")
                return
            }
            let task = uploadSession.uploadTask(with: request, fromFile: bodyURL)
            task.taskDescription = taskDescription(bodyURL: bodyURL, sourceURL: fileURL, chunk: context)
            bodyURLs[task.taskIdentifier] = bodyURL
            sourceURLs[task.taskIdentifier] = fileURL
            chunkContexts[task.taskIdentifier] = context
            task.resume()
            setStatus(
                context.isFinal
                    ? "Uploading final chunk to PC"
                    : "Uploading chunk \(context.chunkIndex + 1) to PC"
            )
        } catch {
            setStatus("Chunk upload queued for retry: \(error.localizedDescription)")
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard userInfo["command"] as? String == "retry-recording",
              let recordingID = userInfo["recording_id"] as? String else { return }
        retryRecording(recordingID: recordingID)
    }

    private func retryRecording(recordingID: String) {
        setStatus("Retrying watch recording")
        stateQueue.async {
            let directory = try? self.streamChunksDirectory()
            let files = directory.flatMap {
                try? FileManager.default.contentsOfDirectory(
                    at: $0,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
            } ?? []
            for fileURL in files {
                guard let context = self.chunkContext(from: fileURL),
                      context.recordingID == recordingID else { continue }
                self.queueChunkUpload(fileURL: fileURL, context: context)
            }
        }
        Task { [weak self] in
            do {
                try await PhoneMemoAPIClient.shared.retryRecording(id: recordingID)
                self?.setStatus("PC processing retry queued")
            } catch PhoneMemoAPIError.httpStatus(409) {
                self?.setStatus("Re-uploading saved chunks to PC")
            } catch {
                self?.setStatus("Retry request saved on iPhone: \(error.localizedDescription)")
            }
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
            }
            self.receivedChunkCount += 1
            self.finalChunkReceived = self.finalChunkReceived || context.isFinal
            self.statusMessage = context.isFinal
                ? "Final watch chunk received"
                : "Received watch chunk \(context.chunkIndex + 1)"
            UserDefaults.standard.set(self.statusMessage, forKey: Self.statusDefaultsKey)
        }
    }

    private func taskDescription(bodyURL: URL, sourceURL: URL?, chunk: ChunkContext?) -> String {
        [
            chunk == nil ? "file" : "chunk",
            bodyURL.path,
            sourceURL?.path ?? "",
            chunk?.recordingID ?? "",
            chunk.map { String($0.chunkIndex) } ?? "",
            chunk?.isFinal == true ? "1" : "0",
        ].joined(separator: "\t")
    }

    private func persistedTaskContext(from description: String?) -> PersistedTaskContext? {
        guard let description else { return nil }
        let fields = description
            .split(separator: "\t", omittingEmptySubsequences: false)
            .map(String.init)
        guard fields.count == 6 else { return nil }
        let chunk: ChunkContext?
        if fields[0] == "chunk", let index = Int(fields[4]) {
            chunk = ChunkContext(
                recordingID: fields[3],
                chunkIndex: index,
                isFinal: fields[5] == "1"
            )
        } else {
            chunk = nil
        }
        return PersistedTaskContext(
            bodyURL: URL(fileURLWithPath: fields[1]),
            sourceURL: fields[2].isEmpty ? nil : URL(fileURLWithPath: fields[2]),
            chunk: chunk
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
