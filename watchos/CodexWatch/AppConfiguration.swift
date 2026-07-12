import Foundation

enum CodexWatchConfiguration {
    static let relayBaseURL: URL = {
        let configured = Bundle.main.object(forInfoDictionaryKey: "CODEX_WATCH_RELAY_BASE_URL") as? String
        return URL(string: configured ?? "http://127.0.0.1:8790")!
    }()

    static let relayToken: String? = Bundle.main.object(forInfoDictionaryKey: "CODEX_WATCH_RELAY_TOKEN") as? String

}
