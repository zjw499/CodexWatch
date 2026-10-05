import Foundation
import Security

struct VoiceAssistantSettings: Codable, Equatable {
    var enabled = false
    var model = "gpt-realtime-2.1"
    var voice = "marin"
}

struct VoiceAssistantDescriptor: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let model: String
    let voice: String
}

struct VoiceConfiguration: Codable, Equatable {
    let version: Int
    let enabled: Bool
    let gateway_url: String
    let default_assistant_id: String
    let assistants: [VoiceAssistantDescriptor]
    let models: [String]
    let voices: [String]
    let session_seconds: Int
    let idle_seconds: Int
}

struct VoiceDeviceCredential: Codable {
    let version: Int
    let token: String
    let owner_id: String
    let expires: Double
    let gateway_url: String
    let device_id: String
    var valid: Bool {
        version == 1 && expires > Date().timeIntervalSince1970 && VoiceWire.validID(owner_id)
            && VoiceWire.gatewayURL(gateway_url) != nil && !token.isEmpty
    }
}

struct VoiceTurn: Codable, Identifiable, Equatable {
    let id: String
    let role: String
    let text: String
    let final: Bool
    let interrupted: Bool
}

struct VoiceConversation: Codable, Identifiable {
    let id: String
    let owner: String
    let assistant_id: String
    let assistant_name: String
    let title: String
    let state: String
    let created: Double
    let updated: Double
    let turns: [VoiceTurn]?
}

struct VoiceHistory: Decodable { let conversations: [VoiceConversation] }

struct VoiceSessionInfo: Decodable {
    let version: Int
    let id: String
    let conversation_id: String
    let assistant_id: String
    let assistant_name: String
    let state: String
}

struct VoiceSessionRequest: Encodable {
    let request_id: String
    var assistant_id: String?
    var conversation_id: String?
}

struct VoiceControl: Encodable {
    let action: String
    var muted: Bool?
    var item_id: String?
    var audio_end_ms: Int?
}

struct VoiceEvent: Decodable {
    let version: Int
    let id: Int
    let type: String
    let state: String?
    let message: String?
    let audio: String?
    let item_id: String?
    let turn: VoiceTurn?
}

struct VoicePolicy: Codable {
    var enabled = false
    var pilot_enabled = false
    var realtime_retention_verified = false
    var device_acceptance_verified = false
    var approval_evidence = ""
    var session_seconds = 600
    var idle_seconds = 120
    var max_active_sessions: Int? = 1
    var organization_id = ""
    var project_id = ""
}

struct VoiceLaunchRequest: Codable {
    let version: Int
    let requestID: String
    let ownerID: String
    let assistantID: String?
    let expires: Double
    init(ownerID: String, assistantID: String?) {
        version = 1; requestID = UUID().uuidString; self.ownerID = ownerID; self.assistantID = assistantID
        expires = Date().timeIntervalSince1970 + 60
    }
    func valid(owner: String?, now: Double = Date().timeIntervalSince1970) -> Bool {
        version == 1 && owner == ownerID && !ownerID.isEmpty && expires > now && VoiceWire.validID(requestID)
            && (assistantID == nil || VoiceWire.validID(assistantID!))
    }
}

enum VoiceWire {
    static func validID(_ id: String) -> Bool {
        id.range(of: "^[A-Za-z0-9_-]{1,140}$", options: .regularExpression) != nil
    }
    static func gatewayURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https", let host = url.host,
              host.hasSuffix(".ts.net"), url.port == 8443, url.path == "/voice/v1",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        return url
    }
    static func event(line: String) throws -> VoiceEvent? {
        guard line.hasPrefix("data: ") else { return nil }
        guard line.utf8.count <= 350000 else { throw VoiceError.connection }
        let event = try JSONDecoder().decode(VoiceEvent.self, from: Data(line.dropFirst(6).utf8))
        guard event.version == 1 else { throw VoiceError.version }
        return event
    }
}

enum VoiceError: LocalizedError {
    case setup, connection, version, status(Int), microphone, audioBusy, audioRoute, slow
    var errorDescription: String? {
        switch self {
        case .setup: return "Open Scribe Pilot on your iPhone and set up Watch voice in Settings."
        case .connection: return "The voice connection ended. Check Watch internet and that your PC is online."
        case .version: return "Update Scribe Pilot to use this voice service."
        case .microphone: return "Allow microphone access in Watch Settings."
        case .audioBusy: return "End your meeting recording before starting a voice conversation."
        case .audioRoute: return "The Watch could not start two-way audio. Check its speaker or headphone connection."
        case .slow: return "The audio connection is too slow. Start a new conversation."
        case let .status(code):
            switch code {
            case 401: return "Voice access expired. Open Scribe Pilot on your iPhone to set it up again."
            case 404: return "This assistant or conversation is unavailable. Choose an assistant in Settings."
            case 409: return "Voice is unavailable or a conversation is already active. Check Settings or end the current conversation."
            case 410: return "That connection ended. Start a new conversation."
            case 429: return "Voice is temporarily busy. Try again shortly."
            default: return "The PC could not complete the voice request. Try again."
            }
        }
    }
}

enum VoiceKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.zachwyatt.scribepilot.watch-voice",
         kSecAttrAccount as String: "device"]
    }
    static func read() -> VoiceDeviceCredential? {
        var item = query
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(VoiceDeviceCredential.self, from: data)
    }
    static func save(_ credential: VoiceDeviceCredential) throws {
        guard credential.valid else { throw VoiceError.setup }
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(credential),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw VoiceError.setup }
        } else if status != errSecSuccess { throw VoiceError.setup }
    }
    static func clear() { SecItemDelete(query as CFDictionary) }
}

// Only assistant display metadata is cached here. Credentials live in Keychain.
struct VoiceDescriptorCache: Codable {
    let owner: String
    let configuration: VoiceConfiguration
    private static let key = "ScribePilot.VoiceDescriptors"
    static func read() -> Self? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    static func save(owner: String, configuration: VoiceConfiguration) {
        guard let data = try? JSONEncoder().encode(Self(owner: owner, configuration: configuration)) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}
