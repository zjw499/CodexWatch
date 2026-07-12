import AppIntents

struct StartRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Recording"
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        await PhoneRecorderService.shared.startRecording()
        return .result()
    }
}

struct StopRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Recording"
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        await PhoneRecorderService.shared.stopRecording()
        return .result()
    }
}

struct CodexWatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        [
            AppShortcut(
                intent: StartRecordingIntent(),
                phrases: ["Start a recording with \(.applicationName)"],
                shortTitle: "Start Recording",
                systemImageName: "record.circle"
            ),
            AppShortcut(
                intent: StopRecordingIntent(),
                phrases: ["Stop recording with \(.applicationName)"],
                shortTitle: "Stop Recording",
                systemImageName: "stop.circle"
            ),
        ]
    }
}
