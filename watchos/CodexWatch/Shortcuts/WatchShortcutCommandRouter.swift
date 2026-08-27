import Foundation

enum WatchShortcutCommand: String {
    case startRecording
    case stopRecording
    case resumeRecording
    case retryUpload
}

extension Notification.Name {
    static let watchShortcutCommandQueued = Notification.Name(
        "ScribePilot.WatchShortcutCommandQueued"
    )
}

@MainActor
enum WatchShortcutCommandRouter {
    private static let pendingCommandKey = "ScribePilot.PendingWatchShortcutCommand"

    static func enqueue(_ command: WatchShortcutCommand) {
        UserDefaults.standard.set(command.rawValue, forKey: pendingCommandKey)
        NotificationCenter.default.post(name: .watchShortcutCommandQueued, object: nil)
    }

    static func consumePendingCommand(using recorder: AudioRecorderService) async {
        guard let rawValue = UserDefaults.standard.string(forKey: pendingCommandKey),
              let command = WatchShortcutCommand(rawValue: rawValue) else { return }

        UserDefaults.standard.removeObject(forKey: pendingCommandKey)

        switch command {
        case .startRecording:
            if !recorder.isRecording {
                await recorder.startRecording()
            }
        case .stopRecording:
            if recorder.isRecording {
                recorder.stopRecording()
            }
        case .resumeRecording:
            if recorder.isRecording {
                recorder.resumeRecording()
            }
        case .retryUpload:
            WatchConnectivityTransferService.shared.retryLastRecording()
        }
    }

    static func handleComplicationActivity(
        _ activity: NSUserActivity,
        using recorder: AudioRecorderService
    ) async {
        guard activity.activityType == ScribePilotComplication.recordActivityType else { return }
        enqueue(.startRecording)
        await consumePendingCommand(using: recorder)
    }
}
