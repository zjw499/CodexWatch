import AppIntents

struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Recording"
    static let supportedModes: IntentModes = [.background, .foreground(.immediate)]

    func perform() async throws -> some IntentResult {
        await PhoneRecorderService.shared.startRecording()
        return .result()
    }
}

struct StopRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    static let supportedModes: IntentModes = [.background, .foreground(.immediate)]

    func perform() async throws -> some IntentResult {
        await PhoneRecorderService.shared.stopRecording()
        return .result()
    }
}

struct CodexWatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: ["Start a recording with \(.applicationName)"],
            shortTitle: "Start Recording",
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
