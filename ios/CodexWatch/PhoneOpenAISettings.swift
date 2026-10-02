import Combine
import Foundation
import Security

struct OpenAIConfiguration: Codable, Equatable {
    var model = "gpt-4o-mini-transcribe"
    var projectID = ""
    var organizationID = ""
    var protectedMode = true
    var baaConfirmed = false
    var retentionConfirmed = false
    var safeguardsConfirmed = false
    var retention = "Modified Retention"
    var automaticProcessing = false
    var createNotes = true
    var deleteAudioAfterProcessing = true
    var revision = UUID().uuidString

    var safeguardsReady: Bool {
        !protectedMode || (baaConfirmed && retentionConfirmed && safeguardsConfirmed)
    }
}

enum OpenAIKeychain {
    private static let service = "com.zachwyatt.scribepilot.openai"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "api-key"]
    }
    static func read() -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ value: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw OpenAIError.keychain }
        } else if status != errSecSuccess { throw OpenAIError.keychain }
    }
    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw OpenAIError.keychain }
    }
}

@MainActor
final class PhoneOpenAISettings: ObservableObject {
    static let shared = PhoneOpenAISettings()
    @Published private(set) var configuration: OpenAIConfiguration
    @Published private(set) var hasKey: Bool
    private let defaults = UserDefaults.standard
    private let defaultsKey = "ScribePilot.OpenAIConfiguration"

    private init() {
        configuration = defaults.data(forKey: defaultsKey)
            .flatMap { try? JSONDecoder().decode(OpenAIConfiguration.self, from: $0) } ?? OpenAIConfiguration()
        hasKey = !(OpenAIKeychain.read() ?? "").isEmpty
    }

    var ready: Bool { PhoneWorkspace.shared.ready }
    var readinessLabel: String {
        if !PhoneWorkspace.shared.signedIn { return "Sign in to your workspace" }
        if !PhoneWorkspace.shared.processingEnabled { return "Organization approval pending" }
        return "Shared OpenAI connection"
    }

    func refreshKeyAvailability() {
        hasKey = !(OpenAIKeychain.read() ?? "").isEmpty
        PhoneOpenAIService.shared.syncConfiguration()
    }

    func save(_ draft: OpenAIConfiguration, newKey: String) throws {
        guard PhoneOpenAIClient.models.contains(draft.model),
              [draft.projectID, draft.organizationID].allSatisfy({ !$0.contains("\n") && !$0.contains("\r") }) else {
            throw OpenAIError.configuration
        }
        let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            guard key.hasPrefix("sk-"), key.count > 20,
                  key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
                throw OpenAIError.invalidKey
            }
            try OpenAIKeychain.save(key)
        }
        var saved = draft
        saved.projectID = saved.projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.organizationID = saved.organizationID.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.revision = UUID().uuidString
        defaults.set(try JSONEncoder().encode(saved), forKey: defaultsKey)
        configuration = saved
        hasKey = !(OpenAIKeychain.read() ?? "").isEmpty
        PhoneOpenAIService.shared.configurationChanged()
    }

    func removeKey() throws {
        try OpenAIKeychain.remove()
        hasKey = false
        var draft = configuration
        draft.baaConfirmed = false
        draft.retentionConfirmed = false
        draft.safeguardsConfirmed = false
        try save(draft, newKey: "")
    }
}
