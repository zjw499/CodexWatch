import Foundation

enum PhoneRecipientSettings {
    private static let recipientKey = "CodexWatch.TranscriptRecipient"
    private static let clientIDKey = "CodexWatch.ClientID"

    static var clientID: String {
        if let existing = UserDefaults.standard.string(forKey: clientIDKey), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: clientIDKey)
        return generated
    }

    static var recipient: String {
        (UserDefaults.standard.string(forKey: recipientKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func save(recipient: String) {
        UserDefaults.standard.set(
            recipient.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: recipientKey
        )
    }
}
