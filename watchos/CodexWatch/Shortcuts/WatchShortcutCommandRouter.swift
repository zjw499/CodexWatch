import Foundation

enum WatchShortcutCommand: String, Codable {
    case startRecording
    case stopRecording
    case resumeRecording
    case retryUpload
    case talkToAssistant
    case endVoice
}

extension Notification.Name {
    static let watchShortcutCommandQueued = Notification.Name(
        "ScribePilot.WatchShortcutCommandQueued"
    )
}

@MainActor
enum WatchShortcutCommandRouter {
    private static let pendingCommandKey = "ScribePilot.PendingWatchShortcutCommand"
    private struct Pending: Codable {
        let command: WatchShortcutCommand
        let launch: VoiceLaunchRequest?
    }

    static func enqueue(_ command: WatchShortcutCommand) {
        UserDefaults.standard.set(command.rawValue, forKey: pendingCommandKey)
        NotificationCenter.default.post(name: .watchShortcutCommandQueued, object: nil)
    }

    static func enqueueVoice(assistantID: String? = nil, ownerID: String? = nil) {
        let launch = VoiceLaunchRequest(ownerID: ownerID ?? RecordingQueueStore.shared.accountID ?? "", assistantID: assistantID)
        if let data = try? JSONEncoder().encode(Pending(command: .talkToAssistant, launch: launch)) {
            UserDefaults.standard.set(data, forKey: pendingCommandKey)
            NotificationCenter.default.post(name: .watchShortcutCommandQueued, object: nil)
        }
    }
    static func clearPendingVoiceCommand() {
        if let data = UserDefaults.standard.data(forKey: pendingCommandKey),
           let pending = try? JSONDecoder().decode(Pending.self, from: data), pending.command == .talkToAssistant {
            UserDefaults.standard.removeObject(forKey: pendingCommandKey)
        }
    }

    static func consumePendingCommand(using recorder: AudioRecorderService) async {
        let pending: Pending
        if let data = UserDefaults.standard.data(forKey: pendingCommandKey),
           let decoded = try? JSONDecoder().decode(Pending.self, from: data) { pending = decoded }
        else if let rawValue = UserDefaults.standard.string(forKey: pendingCommandKey),
                let command = WatchShortcutCommand(rawValue: rawValue) { pending = Pending(command: command, launch: nil) }
        else { return }

        UserDefaults.standard.removeObject(forKey: pendingCommandKey)

        switch pending.command {
        case .talkToAssistant:
            guard let launch = pending.launch, launch.valid(owner: RecordingQueueStore.shared.accountID) else { return }
            await WatchVoiceService.shared.open(assistantID: launch.assistantID, requestID: launch.requestID)
        case .endVoice:
            WatchVoiceService.shared.end()
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
        if activity.activityType == ScribePilotComplication.recordActivityType { enqueue(.startRecording) }
        else if activity.activityType == ScribePilotComplication.voiceActivityType {
            enqueueVoice(assistantID: activity.userInfo?["assistant_id"] as? String,
                         ownerID: activity.userInfo?["owner_id"] as? String)
        } else { return }
        await consumePendingCommand(using: recorder)
    }
}
