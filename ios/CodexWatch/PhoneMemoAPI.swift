import Combine
import Foundation
import Security

struct MemoSummary: Identifiable, Decodable {
    let id: String
    let title: String
    let summary: String?
    let originalFilename: String
    let source: String
    let durationSeconds: Double?
    let language: String?
    let speakerCount: Int?
    let status: String
    let createdAt: String
    let emailSentAt: String?

    enum CodingKeys: String, CodingKey {
        case id, title, summary, originalFilename = "original_filename", source
        case durationSeconds = "duration_seconds", language, speakerCount = "speaker_count"
        case status, createdAt = "created_at", emailSentAt = "email_sent_at"
    }
}

struct MemoDetail: Identifiable, Decodable {
    let id: String
    let title: String
    let summary: String?
    let transcript: String
    let originalFilename: String
    let source: String
    let durationSeconds: Double?
    let language: String?
    let speakerCount: Int?
    let status: String
    let createdAt: String
    let errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case id, title, summary, transcript, originalFilename = "original_filename", source
        case durationSeconds = "duration_seconds", language, speakerCount = "speaker_count"
        case status, createdAt = "created_at", errorMessage = "error_message"
    }
}

struct MemoListResponse: Decodable {
    let memos: [MemoSummary]
}

struct RecordingProgress: Decodable {
    let recordingID: String
    let status: String
    let receivedChunks: Int
    let transcribedChunks: Int
    let finalChunkIndex: Int?

    enum CodingKeys: String, CodingKey {
        case recordingID = "recording_id"
        case status
        case receivedChunks = "received_chunks"
        case transcribedChunks = "transcribed_chunks"
        case finalChunkIndex = "final_chunk_index"
    }
}

struct PhonePreferences: Codable, Equatable {
    var language = "English"
    var speakerLabelsEnabled = true
    var autoParagraphs = true
    var preferNumbers = false
    var generateTitle = true
    var sendEmail = true
    var recipient = ""
    var addEmoji = false
    var emailPrefix = ""
    var removeFooter = false
    var emptySubject = false
    var privateMode = false
    var summaryEnabled = true
    var autoEmailSummary = false
    var summaryTemplate = "default"

    enum CodingKeys: String, CodingKey {
        case language
        case speakerLabelsEnabled = "speaker_labels_enabled"
        case autoParagraphs = "auto_paragraphs"
        case preferNumbers = "prefer_numbers"
        case generateTitle = "generate_title"
        case sendEmail = "send_email"
        case recipient
        case addEmoji = "add_emoji"
        case emailPrefix = "email_prefix"
        case removeFooter = "remove_footer"
        case emptySubject = "empty_subject"
        case privateMode = "private_mode"
        case summaryEnabled = "summary_enabled"
        case autoEmailSummary = "auto_email_summary"
        case summaryTemplate = "summary_template"
    }

    init() {
        recipient = PhoneRecipientSettings.recipient
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        language = try values.decodeIfPresent(String.self, forKey: .language) ?? language
        speakerLabelsEnabled = try values.decodeIfPresent(Bool.self, forKey: .speakerLabelsEnabled) ?? speakerLabelsEnabled
        autoParagraphs = try values.decodeIfPresent(Bool.self, forKey: .autoParagraphs) ?? autoParagraphs
        preferNumbers = try values.decodeIfPresent(Bool.self, forKey: .preferNumbers) ?? preferNumbers
        generateTitle = try values.decodeIfPresent(Bool.self, forKey: .generateTitle) ?? generateTitle
        sendEmail = try values.decodeIfPresent(Bool.self, forKey: .sendEmail) ?? sendEmail
        recipient = try values.decodeIfPresent(String.self, forKey: .recipient)
            ?? PhoneRecipientSettings.recipient
        addEmoji = try values.decodeIfPresent(Bool.self, forKey: .addEmoji) ?? addEmoji
        emailPrefix = try values.decodeIfPresent(String.self, forKey: .emailPrefix) ?? emailPrefix
        removeFooter = try values.decodeIfPresent(Bool.self, forKey: .removeFooter) ?? removeFooter
        emptySubject = try values.decodeIfPresent(Bool.self, forKey: .emptySubject) ?? emptySubject
        privateMode = try values.decodeIfPresent(Bool.self, forKey: .privateMode) ?? privateMode
        summaryEnabled = try values.decodeIfPresent(Bool.self, forKey: .summaryEnabled) ?? summaryEnabled
        autoEmailSummary = try values.decodeIfPresent(Bool.self, forKey: .autoEmailSummary) ?? autoEmailSummary
        summaryTemplate = try values.decodeIfPresent(String.self, forKey: .summaryTemplate) ?? summaryTemplate
    }
}

private struct EmptyResponse: Decodable {}

final class PhoneMemoAPIClient: NSObject, URLSessionDelegate {
    static let shared = PhoneMemoAPIClient()

    private lazy var session: URLSession = {
        URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    }()

    func listMemos(query: String = "") async throws -> [MemoSummary] {
        var path = "/memos"
        if !query.isEmpty {
            path += "?q=" + query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        }
        return try await request(path, responseType: MemoListResponse.self).memos
    }

    func getMemo(id: String) async throws -> MemoDetail {
        try await request("/memos/\(id)", responseType: MemoDetail.self)
    }

    func getPreferences() async throws -> PhonePreferences {
        try await request("/preferences", responseType: PhonePreferences.self)
    }

    func updatePreferences(_ preferences: PhonePreferences) async throws -> PhonePreferences {
        try await request(
            "/preferences",
            method: "PUT",
            body: try JSONEncoder().encode(preferences),
            responseType: PhonePreferences.self
        )
    }

    func retryMemo(id: String) async throws {
        _ = try await request("/memos/\(id)/retry", method: "POST", responseType: EmptyResponse.self)
    }

    func retryRecording(id: String) async throws {
        _ = try await request(
            "/recordings/\(id)/retry",
            method: "POST",
            responseType: EmptyResponse.self
        )
    }

    func getRecordingProgress(id: String) async throws -> RecordingProgress {
        try await request("/recordings/\(id)", responseType: RecordingProgress.self)
    }

    func deleteMemo(id: String) async throws {
        _ = try await request("/memos/\(id)", method: "DELETE", responseType: EmptyResponse.self)
    }

    private func request<Response: Decodable>(
        _ path: String,
        method: String = "GET",
        body: Data? = nil,
        responseType: Response.Type
    ) async throws -> Response {
        guard let url = endpoint(path),
              let username = CodexWatchPhoneConfiguration.audioUploadUsername,
              let password = CodexWatchPhoneConfiguration.audioUploadPassword,
              !username.isEmpty,
              !password.isEmpty else {
            throw PhoneMemoAPIError.notConfigured
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Basic \(basicAuth(username: username, password: password))", forHTTPHeaderField: "Authorization")
        request.setValue(PhoneRecipientSettings.clientID, forHTTPHeaderField: "X-Codex-Client-ID")
        request.setValue("Codex Watch", forHTTPHeaderField: "User-Agent")
        if body != nil {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PhoneMemoAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw PhoneMemoAPIError.httpStatus(httpResponse.statusCode)
        }
        if data.isEmpty {
            return try JSONDecoder().decode(responseType, from: Data("{}".utf8))
        }
        return try JSONDecoder().decode(responseType, from: data)
    }

    private func endpoint(_ path: String) -> URL? {
        guard let uploadURL = CodexWatchPhoneConfiguration.audioUploadURL else { return nil }
        var components = URLComponents(url: uploadURL, resolvingAgainstBaseURL: false)
        components?.path = path.split(separator: "?").first.map(String.init) ?? path
        if let query = path.split(separator: "?", maxSplits: 1).dropFirst().first {
            components?.percentEncodedQuery = String(query)
        }
        return components?.url
    }

    private func basicAuth(username: String, password: String) -> String {
        Data("\(username):\(password)".utf8).base64EncodedString()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificate = bundledRootCertificate() else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let host = challenge.protectionSpace.host as CFString
        guard SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host)) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    private func bundledRootCertificate() -> SecCertificate? {
        guard let url = Bundle.main.url(forResource: "watch-audio-ca", withExtension: "crt"),
              let data = try? Data(contentsOf: url) else { return nil }
        if let certificate = SecCertificateCreateWithData(nil, data as CFData) {
            return certificate
        }
        let base64 = String(data: data, encoding: .utf8)?
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let decoded = base64.flatMap({ Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }) else {
            return nil
        }
        return SecCertificateCreateWithData(nil, decoded as CFData)
    }
}

enum PhoneMemoAPIError: LocalizedError {
    case notConfigured
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "PC memo API is not configured."
        case .invalidResponse: return "The PC returned an invalid response."
        case .httpStatus(let status): return "The PC memo API returned HTTP \(status)."
        }
    }
}

@MainActor
final class PhoneMemoService: ObservableObject {
    static let shared = PhoneMemoService()

    @Published private(set) var memos: [MemoSummary] = []
    @Published private(set) var preferences = PhonePreferences()
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            memos = try await PhoneMemoAPIClient.shared.listMemos()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadPreferences() async {
        do {
            var loaded = try await PhoneMemoAPIClient.shared.getPreferences()
            loaded.recipient = PhoneRecipientSettings.recipient
            preferences = loaded
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func savePreferences(_ newPreferences: PhonePreferences) async {
        PhoneRecipientSettings.save(recipient: newPreferences.recipient)
        var remotePreferences = newPreferences
        // The email address belongs to this phone and is attached to each upload.
        // Do not overwrite a server-wide legacy preference with this user's address.
        remotePreferences.recipient = ""
        do {
            var saved = try await PhoneMemoAPIClient.shared.updatePreferences(remotePreferences)
            saved.recipient = PhoneRecipientSettings.recipient
            preferences = saved
            errorMessage = nil
        } catch {
            preferences = newPreferences
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ memo: MemoSummary) async {
        do {
            try await PhoneMemoAPIClient.shared.deleteMemo(id: memo.id)
            memos.removeAll { $0.id == memo.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func retry(_ memo: MemoSummary) async {
        do {
            try await PhoneMemoAPIClient.shared.retryMemo(id: memo.id)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
