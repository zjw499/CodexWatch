import Foundation

enum CodexWatchConfiguration {
    static let relayBaseURL: URL = {
        let configured = Bundle.main.object(forInfoDictionaryKey: "CODEX_WATCH_RELAY_BASE_URL") as? String
        return URL(string: configured ?? "http://127.0.0.1:8790")!
    }()

    static let relayToken: String? = Bundle.main.object(forInfoDictionaryKey: "CODEX_WATCH_RELAY_TOKEN") as? String

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
