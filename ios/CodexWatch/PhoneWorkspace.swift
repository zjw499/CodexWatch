import Combine
import CryptoKit
import Foundation
import Security
import WatchConnectivity

struct WorkspaceUser: Codable, Identifiable, Equatable {
    let id: String
    let username: String
    let role: String
    var isAdmin: Bool { role == "admin" }
}

struct WorkspaceCredential: Codable {
    let token: String
    let user: WorkspaceUser
    let expires: Double
    var server: String = ""
    enum CodingKeys: String, CodingKey { case token, user, expires, server }
    init(token: String, user: WorkspaceUser, expires: Double, server: String) {
        self.token = token; self.user = user; self.expires = expires; self.server = server
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        token = try values.decode(String.self, forKey: .token)
        user = try values.decode(WorkspaceUser.self, forKey: .user)
        expires = try values.decode(Double.self, forKey: .expires)
        server = try values.decodeIfPresent(String.self, forKey: .server) ?? ""
    }
}

struct WorkspaceAssistant: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var instructions: String
    var model: String
    var voice: VoiceAssistantSettings?
    var knowledge_file_count: Int? = nil
    var voiceSettings: VoiceAssistantSettings {
        get { voice ?? VoiceAssistantSettings() }
        set { voice = newValue }
    }
}

struct WorkspaceTurn: Codable, Identifiable {
    let role: String
    let content: String
    let request_id: String
    var id: String { request_id + role }
}

struct WorkspaceRecording: Codable, Identifiable {
    let id: String
    let owner: String
    let title: String
    let source: String
    let state: String
    let created: Double
    let updated: Double
    let expected_parts: Int
    let duration: Double?
    let transcript: String
    let summary: String
    let chat: [WorkspaceTurn]
    let error: String?
    let assistant_name: String?
    let result_model: String?
    let transcribed_seconds: Double?
    let transcription_complete: Bool?
    let quality_warning: String?
}

struct WorkspacePolicy: Codable {
    var baa_verified = false
    var retention_verified = false
    var safeguards_verified = false
    var approval_evidence = ""
    var organization_id = ""
    var project_id = ""
}

struct WorkspaceInvitation: Codable {
    let code: String
    let username: String
    let expires_in_days: Int
}

struct WorkspaceManagedUser: Codable, Identifiable {
    let id: String
    let username: String
    let role: String
    let active: Int
}

struct WorkspaceAuditEvent: Codable, Identifiable {
    let id: Int
    let actor: String
    let action: String
    let target: String
    let timestamp: Double
}

enum WorkspaceError: LocalizedError {
    case signIn, server, status(Int, String), ownership, missingAssistant
    static func retryable(_ error: Error) -> Bool {
        if let error = error as? URLError {
            return [.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                    .dnsLookupFailed, .notConnectedToInternet, .dataNotAllowed, .cancelled].contains(error.code)
        }
        if case let WorkspaceError.status(code, _) = error {
            return [408, 425, 429].contains(code) || (500...599).contains(code)
        }
        return false
    }
    var errorDescription: String? {
        switch self {
        case .signIn: return "Sign in to your Scribe Pilot account."
        case .server: return "Use your organization's private HTTPS workspace address."
        case let .status(_, message): return message
        case .ownership: return "This recording belongs to another account. Sign in to its original account."
        case .missingAssistant: return "Choose an assistant in Settings before processing."
        }
    }
}

enum WorkspaceKeychain {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.zachwyatt.scribepilot.workspace",
         kSecAttrAccount as String: account]
    }
    static func read<T: Decodable>(_ type: T.Type, account: String = "session") -> T? {
        var item = query(account)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    static func save<T: Encodable>(_ value: T, account: String = "session") throws {
        let data = try JSONEncoder().encode(value)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly]
        let status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account)
            attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw OpenAIError.keychain }
        } else if status != errSecSuccess { throw OpenAIError.keychain }
    }
    static func remove(account: String = "session") throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw OpenAIError.keychain }
    }
}

private final class WorkspaceNetworkDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward account credentials or protected request bodies to redirects.
        completionHandler(nil)
    }
}

@MainActor
final class PhoneWorkspace: ObservableObject {
    static let shared = PhoneWorkspace()
    static let defaultServer = "https://zwyattpc.tail488e93.ts.net/workspace"
    @Published private(set) var credential: WorkspaceCredential?
    @Published private(set) var processingEnabled = false
    @Published private(set) var assistants: [WorkspaceAssistant] = []
    @Published private(set) var transcriptionModels = ["gpt-4o-mini-transcribe", "gpt-4o-transcribe"]
    @Published private(set) var generationModels = ["gpt-4.1-mini", "gpt-4.1"]
    @Published private(set) var pendingGenerationModels: [String] = []
    @Published var selectedAssistantID = ""
    @Published var transcriptionModel = "gpt-4o-transcribe"
    @Published var transcriptionContext = ""
    @Published var connectionMessage: String?
    @Published private(set) var voiceConfiguration: VoiceConfiguration?
    @Published private(set) var voiceMessage: String?
    private let session: URLSession
    private let networkDelegate = WorkspaceNetworkDelegate()
    private struct Me: Decodable {
        let user: WorkspaceUser
        let processing_enabled: Bool
        let transcription_models: [String]
        let generation_models: [String]
        let pending_generation_models: [String]?
    }
    struct Assistants: Decodable { let assistants: [WorkspaceAssistant] }
    struct Recordings: Decodable { let recordings: [WorkspaceRecording] }
    struct Users: Decodable { let users: [WorkspaceManagedUser] }
    struct Audit: Decodable { let events: [WorkspaceAuditEvent] }
    struct OK: Decodable { let ok: Bool }

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForResource = 600
        session = URLSession(configuration: configuration, delegate: networkDelegate, delegateQueue: nil)
        credential = WorkspaceKeychain.read(WorkspaceCredential.self)
        if let saved = credential, saved.expires <= Date().timeIntervalSince1970 {
            credential = nil
            try? WorkspaceKeychain.remove()
        }
        RecordingQueueStore.shared.setAccount(credential?.user.id)
        loadPreferences()
        loadAssistantCache()
    }
    #if DEBUG
    init(session: URLSession, credential: WorkspaceCredential, assistants: [WorkspaceAssistant]) {
        self.session = session; self.credential = credential; self.assistants = assistants
        processingEnabled = true; selectedAssistantID = assistants.first?.id ?? ""
    }
    #endif
    var user: WorkspaceUser? { credential?.user }
    var signedIn: Bool { credential != nil }
    var ready: Bool { signedIn && processingEnabled && assistants.contains { $0.id == selectedAssistantID } }
    var selectedAssistant: WorkspaceAssistant? { assistants.first { $0.id == selectedAssistantID } }

    static func validServer(_ value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", let host = url.host, host.hasSuffix(".ts.net"),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path == "/workspace" || url.path == "/workspace/" else { return nil }
        return url
    }

    func signIn(server: String, username: String, password: String, invitation: Bool) async throws {
        guard let base = Self.validServer(server) else { throw WorkspaceError.server }
        let body = invitation ? ["code": username.trimmingCharacters(in: .whitespacesAndNewlines), "password": password]
            : ["username": username, "password": password]
        var result: WorkspaceCredential = try await request(invitation ? "register" : "login", method: "POST",
            body: JSONEncoder().encode(body), base: base.absoluteString, authenticated: false)
        result.server = base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // A replacement sign-in must retire the old parent session and its Watch access.
        if let old = credential, old.token != result.token {
            var pending = WorkspaceKeychain.read([WorkspaceCredential].self, account: "revocations") ?? []
            if !pending.contains(where: { $0.token == old.token }) { pending.append(old) }
            try WorkspaceKeychain.save(pending, account: "revocations")
        }
        try WorkspaceKeychain.save(result)
        PhoneOpenAIService.shared.configurationChanged()
        credential = result
        voiceConfiguration = nil; voiceMessage = nil
        try? WorkspaceKeychain.remove(account: "watch-voice")
        processingEnabled = false; assistants = []; pendingGenerationModels = []
        RecordingQueueStore.shared.setAccount(result.user.id)
        loadPreferences()
        loadAssistantCache()
        // Older device keys are no longer used by this workflow.
        try? OpenAIKeychain.remove()
        syncWatchAccount()
        await refresh()
    }

    func signOut() async throws {
        guard let old = credential else { return }
        var pending = WorkspaceKeychain.read([WorkspaceCredential].self, account: "revocations") ?? []
        if !pending.contains(where: { $0.token == old.token }) { pending.append(old) }
        try WorkspaceKeychain.save(pending, account: "revocations")
        try WorkspaceKeychain.remove()
        PhoneOpenAIService.shared.configurationChanged()
        credential = nil; processingEnabled = false; assistants = []; selectedAssistantID = ""; transcriptionContext = ""; pendingGenerationModels = []
        voiceConfiguration = nil; voiceMessage = nil
        try? WorkspaceKeychain.remove(account: "watch-voice")
        RecordingQueueStore.shared.setAccount(nil)
        syncWatchAccount()
        await revokePendingSessions()
    }

    func watchAccountContext() -> [String: Any] {
        var context: [String: Any] = ["command": "workspace-account", "owner_id": user?.id ?? "",
                                    "username": user?.username ?? "", "ready": ready, "protected": true]
        if let config = voiceConfiguration, let saved = credential,
           let data = try? JSONEncoder().encode(config) {
            context["voice_config"] = data
            let hash = SHA256.hash(data: Data(saved.token.utf8)).map { String(format: "%02x", $0) }.joined()
            if config.enabled, let binding = WorkspaceKeychain.read(WatchVoiceBinding.self, account: "watch-voice"),
               binding.parentHash == hash, binding.credential.valid, binding.credential.owner_id == saved.user.id {
                context["voice_credential"] = try? JSONEncoder().encode(binding.credential)
                if let requestID = binding.setupRequestID { context["voice_setup_request"] = requestID }
            }
        }
        return context
    }

    func syncWatchAccount() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let watch = WCSession.default, context = watchAccountContext()
        do { try watch.updateApplicationContext(context) }
        catch { if context["voice_setup_request"] != nil { voiceMessage = "Watch setup is waiting. Open Scribe Pilot on both devices, then connect Watch voice again." } }
        if context["voice_setup_request"] != nil, watch.isReachable {
            watch.sendMessage(context, replyHandler: { reply in
                Task { @MainActor in self.receiveWatchVoiceReceipt(reply) }
            }, errorHandler: { _ in
                // The durable application context still delivers when the Watch reconnects.
            })
        }
        PhoneOpenAIService.shared.syncConfiguration()
    }

    func receiveWatchVoiceReceipt(_ reply: [String: Any]) {
        guard let data = reply["voice_setup_receipt"] as? Data,
              let receipt = try? JSONDecoder().decode(VoiceSetupReceipt.self, from: data),
              let saved = credential,
              var binding = WorkspaceKeychain.read(WatchVoiceBinding.self, account: "watch-voice"),
              binding.accepts(receipt, owner: saved.user.id) else { return }
        let hash = SHA256.hash(data: Data(saved.token.utf8)).map { String(format: "%02x", $0) }.joined()
        guard binding.parentHash == hash else { return }
        // A delayed failure cannot overwrite a later successful receipt for the same setup.
        if binding.receipt?.state == .ready, receipt.state != .ready { return }
        binding.receipt = receipt
        try? WorkspaceKeychain.save(binding, account: "watch-voice")
        voiceMessage = receipt.state == .ready ? "Your Watch confirmed voice setup. No code is needed. Open Talk to Assistant on your Watch." : receipt.state.message
    }

    func savePreferences() {
        guard let id = user?.id else { return }
        UserDefaults.standard.set(selectedAssistantID, forKey: "ScribePilot.Assistant.\(id)")
        UserDefaults.standard.set(transcriptionModel, forKey: "ScribePilot.Transcription.\(id)")
        saveAssistantCache()
        syncWatchAccount()
    }
    private func loadPreferences() {
        guard let id = user?.id else { selectedAssistantID = ""; return }
        selectedAssistantID = UserDefaults.standard.string(forKey: "ScribePilot.Assistant.\(id)") ?? ""
        transcriptionModel = UserDefaults.standard.string(forKey: "ScribePilot.Transcription.\(id)") ?? "gpt-4o-transcribe"
        transcriptionContext = ""
    }
    private struct AssistantCache: Codable {
        let assistants: [WorkspaceAssistant]
        let transcriptionModels: [String]
        let generationModels: [String]
        let processingEnabled: Bool
        let server: String
        var transcriptionContext: String?
        var pendingGenerationModels: [String]? = nil
    }
    private func cacheURL() -> URL? {
        guard let owner = user?.id, RecordingQueueStore.validID(owner) else { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScribePilot", isDirectory: true).appendingPathComponent("assistants-\(owner).json")
    }
    private func loadAssistantCache() {
        guard let url = cacheURL(), let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(AssistantCache.self, from: data), cache.server == credential?.server else { return }
        assistants = cache.assistants; transcriptionModels = cache.transcriptionModels
        generationModels = cache.generationModels; processingEnabled = cache.processingEnabled
        pendingGenerationModels = cache.pendingGenerationModels ?? []
        transcriptionContext = cache.transcriptionContext ?? ""
    }
    private func saveAssistantCache() {
        guard let url = cacheURL(), let server = credential?.server else { return }
        do {
            try RecordingQueueStore.protectDirectory(url.deletingLastPathComponent())
            let cache = AssistantCache(assistants: assistants, transcriptionModels: transcriptionModels,
                                       generationModels: generationModels, processingEnabled: processingEnabled, server: server,
                                       transcriptionContext: transcriptionContext, pendingGenerationModels: pendingGenerationModels)
            try JSONEncoder().encode(cache).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try RecordingQueueStore.protectFile(url)
        } catch { /* Server definitions remain authoritative if cache persistence fails. */ }
    }

    func refresh() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-scribe-ui-preview") { return }
        #endif
        await revokePendingSessions()
        guard let saved = credential else { return }
        do {
            let me: Me = try await request("me")
            guard credential?.token == saved.token else { return }
            processingEnabled = me.processing_enabled
            transcriptionModels = me.transcription_models; generationModels = me.generation_models
            pendingGenerationModels = me.pending_generation_models ?? []
            let result: Assistants = try await request("assistants")
            guard credential?.token == saved.token else { return }
            assistants = result.assistants
            if !assistants.contains(where: { $0.id == selectedAssistantID }) { selectedAssistantID = assistants.first?.id ?? "" }
            if !transcriptionModels.contains(transcriptionModel) { transcriptionModel = transcriptionModels.first ?? "" }
            savePreferences(); saveAssistantCache(); connectionMessage = nil
            await refreshVoice()
            await PhoneOpenAIService.shared.reconcile()
        } catch {
            guard credential?.token == saved.token else { return }
            connectionMessage = "Connect to your private network to sync with the PC."
            if case WorkspaceError.status(401, _) = error {
                try? await signOut()
                connectionMessage = "Your session ended. Sign in again."
            }
        }
    }

    func refreshVoice() async {
        guard let captured = credential else { return }
        do {
            let config: VoiceConfiguration = try await request("voice/config")
            guard credential?.token == captured.token else { return }
            guard config.version == 1, let url = VoiceWire.gatewayURL(config.gateway_url),
                  url.host == URL(string: captured.server)?.host else { throw VoiceError.version }
            voiceConfiguration = config
            if !config.enabled { voiceMessage = "Watch voice is awaiting organization approval and device testing." }
            else if let binding = WorkspaceKeychain.read(WatchVoiceBinding.self, account: "watch-voice"),
                    binding.credential.valid, binding.credential.owner_id == captured.user.id {
                voiceMessage = binding.receipt?.state == .ready ? "Your Watch confirmed voice setup. No code is needed." :
                    (binding.receipt?.state.message ?? "Waiting for Watch confirmation. Open Scribe Pilot on your unlocked Watch; no code is needed.")
            } else { voiceMessage = VoiceSetupState.needsSetup.message }
            syncWatchAccount()
        } catch {
            guard credential?.token == captured.token else { return }
            voiceMessage = "Connect to the private workspace to refresh Watch voice settings."
        }
    }

    func setDefaultVoiceAssistant(_ id: String) async throws {
        let config: VoiceConfiguration = try await request("voice/preferences", method: "PUT",
            body: JSONEncoder().encode(["default_assistant_id": id]))
        voiceConfiguration = config
        syncWatchAccount()
    }

    func provisionWatchVoice() async throws {
        guard let captured = credential else { throw VoiceError.setup }
        await refreshVoice()
        guard let config = voiceConfiguration, config.enabled, !config.assistants.isEmpty else { throw VoiceError.status(409) }
        let deviceID = UserDefaults.standard.string(forKey: "ScribePilot.WatchVoiceDeviceID") ?? UUID().uuidString
        UserDefaults.standard.set(deviceID, forKey: "ScribePilot.WatchVoiceDeviceID")
        let device: VoiceDeviceCredential = try await request("voice/devices", method: "POST",
            body: JSONEncoder().encode(["device_id": deviceID]))
        guard credential?.token == captured.token else { throw CancellationError() }
        guard device.valid, device.owner_id == captured.user.id, device.gateway_url == config.gateway_url else { throw VoiceError.setup }
        let hash = SHA256.hash(data: Data(captured.token.utf8)).map { String(format: "%02x", $0) }.joined()
        try WorkspaceKeychain.save(WatchVoiceBinding(parentHash: hash, credential: device, setupRequestID: UUID().uuidString), account: "watch-voice")
        voiceMessage = "Waiting for Watch confirmation. Open Scribe Pilot on your unlocked Watch; no code is needed."
        syncWatchAccount()
    }

    private func revokePendingSessions() async {
        let pending = WorkspaceKeychain.read([WorkspaceCredential].self, account: "revocations") ?? []
        var remaining: [WorkspaceCredential] = []
        for entry in pending where entry.expires > Date().timeIntervalSince1970 {
            do {
                let _: OK = try await request("session", method: "DELETE", base: entry.server, token: entry.token)
            } catch {
                if case WorkspaceError.status(401, _) = error { continue }
                remaining.append(entry)
            }
        }
        if !pending.isEmpty { try? WorkspaceKeychain.save(remaining, account: "revocations") }
    }

    func request<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil,
                               base: String? = nil, token: String? = nil, authenticated: Bool = true) async throws -> T {
        let data = try await rawRequest(path, method: method, body: body, base: base, token: token, authenticated: authenticated)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func rawRequest(_ path: String, method: String = "GET", body: Data? = nil, contentType: String = "application/json",
                    base: String? = nil, token: String? = nil, authenticated: Bool = true) async throws -> Data {
        let captured = credential
        guard let server = base ?? captured?.server, let url = URL(string: server + "/api/" + path), Self.validServer(server) != nil else {
            throw WorkspaceError.signIn
        }
        let authorization = token ?? captured?.token
        if authenticated && authorization == nil { throw WorkspaceError.signIn }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body
        request.timeoutInterval = 330
        if authenticated, let authorization { request.setValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization") }
        if body != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        if base == nil && captured?.token != credential?.token { throw CancellationError() }
        guard let http = response as? HTTPURLResponse else { throw WorkspaceError.server }
        guard (200..<300).contains(http.statusCode) else {
            if path.hasPrefix("assistants/"), path.contains("/knowledge"), (400..<600).contains(http.statusCode),
               let detail = try? JSONDecoder().decode(KnowledgeRequestFailure.self, from: data) {
                throw WorkspaceError.status(http.statusCode, String(detail.detail.prefix(300)))
            }
            let messages = [400: "This invitation is invalid or expired.", 401: "Sign in again.", 403: "Administrator access required.", 404: "This item is unavailable to your account.",
                409: "The item changed or organization processing approval is incomplete. Refresh and try again.",
                410: "This recording was removed.", 413: "This audio part is too large.",
                422: "Check the fields. Passwords need at least 12 characters; choose an approved model.",
                429: "Too many sign-in attempts. Try again in 15 minutes."]
            throw WorkspaceError.status(http.statusCode, messages[http.statusCode] ?? "The PC could not complete this request. Try again.")
        }
        return data
    }

    func upload(_ url: URL, recordingID: String, index: Int) async throws {
        let body = try Data(contentsOf: url)
        _ = try await rawRequest("recordings/\(recordingID)/parts/\(index)", method: "PUT", body: body,
                                contentType: "audio/mp4")
    }

    func saveAssistant(_ assistant: WorkspaceAssistant) async throws {
        let _: WorkspaceAssistant = try await request("assistants/\(assistant.id)", method: "PUT", body: JSONEncoder().encode(assistant))
        await refresh()
    }
    func deleteAssistant(_ id: String) async throws {
        let _: OK = try await request("assistants/\(id)", method: "DELETE")
        await refresh()
    }
    func remoteRecordings(review: Bool = false) async throws -> [WorkspaceRecording] {
        var result: [WorkspaceRecording] = []
        var offset = 0
        while true {
            let page: Recordings = try await request("\(review ? "admin/recordings" : "recordings")?offset=\(offset)")
            result.append(contentsOf: page.recordings)
            if page.recordings.count < 100 { return result }
            offset += 100
        }
    }
    #if DEBUG
    func loadPreview() {
        guard !ProcessInfo.processInfo.arguments.contains("-scribe-login-preview") else { return }
        credential = WorkspaceCredential(token: "synthetic-preview", user: WorkspaceUser(id: "preview-user", username: "Alex", role: "admin"),
                                         expires: Date().timeIntervalSince1970 + 3600, server: Self.defaultServer)
        assistants = [WorkspaceAssistant(id: "preview-assistant", name: "Meeting notes", instructions: "Create concise notes and explicit follow-up actions.", model: "gpt-4.1-mini")]
        selectedAssistantID = "preview-assistant"
        processingEnabled = true
        RecordingQueueStore.shared.setAccount("preview-user")
    }
    #endif
}
