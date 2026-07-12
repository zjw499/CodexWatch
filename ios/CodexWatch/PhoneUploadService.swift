import Combine
import Foundation
import Security
import WatchConnectivity

final class PhoneUploadService: NSObject, ObservableObject, WCSessionDelegate, URLSessionDelegate, URLSessionTaskDelegate {
    static let shared = PhoneUploadService()
    static let backgroundIdentifier = "com.zachwyatt.codexwatch.audio-upload"

    @Published private(set) var statusMessage = "Ready"

    private let stateQueue = DispatchQueue(label: "com.zachwyatt.codexwatch.upload-state")
    private var uploadSession: URLSession?
    private var bodyURLs: [Int: URL] = [:]
    private var completionHandlers: [String: () -> Void] = [:]
    private var started = false

    func start() {
        stateQueue.async {
            guard !self.started else { return }
            self.started = true

            let configuration = URLSessionConfiguration.background(withIdentifier: Self.backgroundIdentifier)
            configuration.sessionSendsLaunchEvents = true
            configuration.isDiscretionary = false
            configuration.waitsForConnectivity = true
            self.uploadSession = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)

            guard WCSession.isSupported() else {
                self.setStatus("Watch transfer unavailable")
                return
            }
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func enqueue(fileURL: URL) {
        start()
        stateQueue.async {
            do {
                let bodyURL = try self.makeMultipartBody(fileURL: fileURL)
                guard let uploadURL = CodexWatchPhoneConfiguration.audioUploadURL,
                      let username = CodexWatchPhoneConfiguration.audioUploadUsername,
                      let password = CodexWatchPhoneConfiguration.audioUploadPassword,
                      !username.isEmpty,
                      !password.isEmpty else {
                    try? FileManager.default.removeItem(at: bodyURL)
                    self.setStatus("PC upload is not configured")
                    return
                }

                var request = URLRequest(url: uploadURL)
                request.httpMethod = "POST"
                let boundary = bodyURL.deletingPathExtension().lastPathComponent
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                request.setValue("Basic \(self.basicAuth(username: username, password: password))", forHTTPHeaderField: "Authorization")
                request.setValue("Codex Watch", forHTTPHeaderField: "User-Agent")

                guard let uploadSession = self.uploadSession else {
                    try? FileManager.default.removeItem(at: bodyURL)
                    self.setStatus("Upload service unavailable")
                    return
                }
                let task = uploadSession.uploadTask(with: request, fromFile: bodyURL)
                self.bodyURLs[task.taskIdentifier] = bodyURL
                task.resume()
                self.setStatus("Uploading to PC")
            } catch {
                self.setStatus("Upload queued for retry: \(error.localizedDescription)")
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
            let directory = try recordingsDirectory()
            let destination = directory.appendingPathComponent(file.fileURL.lastPathComponent)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: file.fileURL, to: destination)
            enqueue(fileURL: destination)
            setStatus("Watch recording received")
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
            let statusCode = (task.response as? HTTPURLResponse)?.statusCode

            if let error {
                self.setStatus("PC upload failed: \(error.localizedDescription)")
                return
            }

            guard let statusCode, (200..<300).contains(statusCode) else {
                self.setStatus("PC upload rejected the recording (HTTP \(statusCode ?? 0))")
                return
            }

            if let bodyURL {
                try? FileManager.default.removeItem(at: bodyURL)
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
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let rootCertificateData = Bundle.main.url(forResource: "watch-audio-ca", withExtension: "crt")
                .flatMap({ try? Data(contentsOf: $0) }),
              let rootCertificate = SecCertificateCreateWithData(nil, rootCertificateData as CFData) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let host = challenge.protectionSpace.host as CFString
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host))
        SecTrustSetAnchorCertificates(trust, [rootCertificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)

        var result = SecTrustResultType.invalid
        let status = SecTrustEvaluate(trust, &result)
        if status == errSecSuccess && (result == .unspecified || result == .proceed) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    private func setStatus(_ message: String) {
        DispatchQueue.main.async {
            self.statusMessage = message
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

    private func basicAuth(username: String, password: String) -> String {
        Data("\(username):\(password)".utf8).base64EncodedString()
    }
}

private enum CodexWatchPhoneConfiguration {
    static let audioUploadURL: URL? = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "CODEX_WATCH_AUDIO_UPLOAD_URL") as? String,
              !value.isEmpty,
              !value.contains("REPLACE_WITH") else {
            return nil
        }
        return URL(string: value)
    }()

    static let audioUploadUsername = Bundle.main.object(forInfoDictionaryKey: "CODEX_WATCH_AUDIO_UPLOAD_USERNAME") as? String
    static let audioUploadPassword = Bundle.main.object(forInfoDictionaryKey: "CODEX_WATCH_AUDIO_UPLOAD_PASSWORD") as? String
}
