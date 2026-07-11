import Foundation
import Security

actor AudioUploadClient {
    enum UploadError: LocalizedError {
        case notConfigured
        case invalidResponse
        case rejected(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Audio upload is not configured in this build."
            case .invalidResponse:
                return "The audio receiver returned an unexpected response."
            case .rejected(let message):
                return message
            }
        }
    }

    private let uploadURL: URL?
    private let username: String?
    private let password: String?
    private let session: URLSession

    init(
        uploadURL: URL? = CodexWatchConfiguration.audioUploadURL,
        username: String? = CodexWatchConfiguration.audioUploadUsername,
        password: String? = CodexWatchConfiguration.audioUploadPassword
    ) {
        self.uploadURL = uploadURL
        self.username = username
        self.password = password

        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        self.session = URLSession(
            configuration: configuration,
            delegate: AudioUploadSessionDelegate(),
            delegateQueue: nil
        )
    }

    func upload(fileURL: URL) async throws {
        guard let uploadURL, let username, let password, !username.isEmpty, !password.isEmpty else {
            throw UploadError.notConfigured
        }

        let boundary = "CodexWatch-\(UUID().uuidString)"
        let bodyURL = try makeMultipartBody(fileURL: fileURL, boundary: boundary)
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Basic \(basicAuth(username: username, password: password))", forHTTPHeaderField: "Authorization")
        request.setValue("Codex Watch", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.upload(for: request, fromFile: bodyURL)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UploadError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            throw UploadError.rejected(detail ?? "The audio receiver rejected the upload.")
        }
    }

    private func basicAuth(username: String, password: String) -> String {
        Data("\(username):\(password)".utf8).base64EncodedString()
    }

    private func makeMultipartBody(fileURL: URL, boundary: String) throws -> URL {
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-watch-upload-\(UUID().uuidString).body")
        guard FileManager.default.createFile(atPath: bodyURL.path, contents: nil) else {
            throw UploadError.invalidResponse
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
}

private final class AudioUploadSessionDelegate: NSObject, URLSessionDelegate {
    private let rootCertificateData: Data?

    override init() {
        rootCertificateData = Bundle.main.url(forResource: "watch-audio-ca", withExtension: "crt")
            .flatMap { try? Data(contentsOf: $0) }
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let rootCertificateData,
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
}
