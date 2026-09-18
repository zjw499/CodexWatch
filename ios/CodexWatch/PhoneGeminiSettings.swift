import Foundation

enum PhoneGeminiSettings {
    private static let urlKey = "ScribePilot.GeminiDestinationURL"
    static let defaultURLString = "https://gemini.google.com/app"

    static var savedURLString: String? {
        let value = UserDefaults.standard.string(forKey: urlKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    static func resolvedURL(serverURL: String?) -> URL {
        for candidate in [savedURLString, serverURL, defaultURLString] {
            if let candidate, let url = validatedURL(candidate) {
                return url
            }
        }
        return URL(string: defaultURLString)!
    }

    static func save(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: urlKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: urlKey)
        }
    }

    static func validatedURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https", url.host != nil else {
            return nil
        }
        return url
    }
}
