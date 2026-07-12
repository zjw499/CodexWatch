import UIKit

final class CodexWatchAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        PhoneUploadService.shared.start()
        Task { @MainActor in
            PhoneTranscriptionService.shared.retryPendingRecordings()
        }
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        PhoneUploadService.shared.setBackgroundCompletionHandler(
            completionHandler,
            for: identifier
        )
    }
}
