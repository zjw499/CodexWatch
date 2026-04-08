import Foundation
import WatchKit

enum DictationService {
    static func requestTextInput(suggestions: [String] = []) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            guard let controller = WKExtension.shared().visibleInterfaceController else {
                continuation.resume(returning: "")
                return
            }

            controller.presentTextInputController(withSuggestions: suggestions, allowedInputMode: .plain) { results in
                guard let first = results?.first as? String else {
                    continuation.resume(returning: "")
                    return
                }
                continuation.resume(returning: first)
            }
        }
    }
}
