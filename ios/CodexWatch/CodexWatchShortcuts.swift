import AppIntents

struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Record Meeting on iPhone"
    static let openAppWhenRun = true
    @available(iOS 26.0, *)
    static let supportedModes: IntentModes = [.background, .foreground(.immediate)]

    func perform() async throws -> some IntentResult {
        await PhoneRecorderService.shared.startRecording()
        return .result()
    }
}

struct StopRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    static let openAppWhenRun = true
    @available(iOS 26.0, *)
    static let supportedModes: IntentModes = [.background, .foreground(.immediate)]

    func perform() async throws -> some IntentResult {
        await PhoneRecorderService.shared.stopRecording()
        return .result()
    }
}

struct CodexWatchShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .red
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: ["Start a recording with \(.applicationName)", "Record a meeting with \(.applicationName)"],
            shortTitle: "Record Meeting",
            systemImageName: "record.circle"
        )
        AppShortcut(
            intent: StopRecordingIntent(),
            phrases: ["Stop recording with \(.applicationName)"],
            shortTitle: "Stop Recording",
            systemImageName: "stop.circle"
        )
    }
}
