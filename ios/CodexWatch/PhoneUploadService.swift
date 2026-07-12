import Combine
import Foundation
import Security
import WatchConnectivity

final class PhoneUploadService: NSObject, ObservableObject, WCSessionDelegate, URLSessionDelegate, URLSessionTaskDelegate {
    static let shared = PhoneUploadService()
    static let backgroundIdentifier = "com.zachwyatt.codexwatch.audio-upload"
    private static let statusDefaultsKey = "CodexWatch.PhoneUploadStatus"

    @Published private(set) var statusMessage: String

    private let stateQueue = DispatchQueue(label: "com.zachwyatt.codexwatch.upload-state")
    private var uploadSession: URLSession?
    private var bodyURLs: [Int: URL] = [:]
    private var sourceURLs: [Int: URL] = [:]
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
        }
    }

    func enqueueTranscript(text: String, filename: String, sourceURL: URL?) {
        start()
        stateQueue.async {
            self.queueTranscript(text: text, filename: filename, sourceURL: sourceURL)
        }
    }

    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void, for identifier: String) {
        stateQueue.async {
            self.completionHandlers[identifier] = handler
        }
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        do {
            let directory = try recordingsDirectory()
            let destination = directory.appendingPathComponent(file.fileURL.lastPathComponent)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: file.fileURL, to: destination)
            setStatus("Watch recording received; uploading to PC")
            enqueue(fileURL: destination)
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
            let bodyURL = self.bodyURLs.removeValue(forKey: task.taskIdentifier)
            let sourceURL = self.sourceURLs.removeValue(forKey: task.taskIdentifier)
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
            self.setStatus("Uploaded to PC")
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
            bodyURLs[task.taskIdentifier] = bodyURL
            sourceURLs[task.taskIdentifier] = fileURL
            task.resume()
            setStatus("Uploading to PC")
        } catch {
            setStatus("Upload queued for retry: \(error.localizedDescription)")
        }
    }

    private func queueTranscript(text: String, filename: String, sourceURL: URL?) {
        do {
            let bodyURL = try makeTranscriptBody(text: text, filename: filename)
            guard let uploadURL = CodexWatchPhoneConfiguration.transcriptURL,
                  let username = CodexWatchPhoneConfiguration.audioUploadUsername,
                  let password = CodexWatchPhoneConfiguration.audioUploadPassword,
                  !username.isEmpty,
                  !password.isEmpty else {
                try? FileManager.default.removeItem(at: bodyURL)
                setStatus("PC transcript upload is not configured")
                return
            }

            var request = URLRequest(url: uploadURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Basic \(basicAuth(username: username, password: password))", forHTTPHeaderField: "Authorization")
            request.setValue("Codex Watch", forHTTPHeaderField: "User-Agent")

            guard let uploadSession else {
                try? FileManager.default.removeItem(at: bodyURL)
                setStatus("Upload service unavailable")
                return
            }
            let task = uploadSession.uploadTask(with: request, fromFile: bodyURL)
            bodyURLs[task.taskIdentifier] = bodyURL
            if let sourceURL {
                sourceURLs[task.taskIdentifier] = sourceURL
            }
            task.resume()
            setStatus("Transcript queued for email")
        } catch {
            setStatus("Transcript upload queued for retry: \(error.localizedDescription)")
        }
    }

    private func recordingsDirectory() throws -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeMultipartBody(fileURL: URL) throws -> URL {
        let boundary = "CodexWatch-\(UUID().uuidString)"
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Uploads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bodyURL = directory.appendingPathComponent("\(boundary).body")

        guard FileManager.default.createFile(atPath: bodyURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let fileName = fileURL.lastPathComponent.replacingOccurrences(of: "\"", with: "")
        let header = "--\(boundary)\r\n" +
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

    private func makeTranscriptBody(text: String, filename: String) throws -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Uploads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bodyURL = directory.appendingPathComponent("CodexWatch-Transcript-\(UUID().uuidString).json")
        let payload: [String: String] = [
            "filename": filename,
            "source": "iphone-on-device",
            "transcript": text,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: bodyURL, options: [.atomic])
        return bodyURL
    }

    private func basicAuth(username: String, password: String) -> String {
        Data("\(username):\(password)".utf8).base64EncodedString()
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

    static let transcriptURL: URL? = {
        guard let audioUploadURL else { return nil }
        var components = URLComponents(url: audioUploadURL, resolvingAgainstBaseURL: false)
        components?.path = "/transcript"
        return components?.url
    }()

    static let audioUploadUsername = Bundle.main.object(forInfoDictionaryKey: "CODEX_WATCH_AUDIO_UPLOAD_USERNAME") as? String
    static let audioUploadPassword = Bundle.main.object(forInfoDictionaryKey: "CODEX_WATCH_AUDIO_UPLOAD_PASSWORD") as? String
}
