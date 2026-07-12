import AppIntents

struct StartWatchRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Watch Recording"
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        await AudioRecorderService.shared.startRecording()
        return .result()
    }
}

struct StopWatchRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Watch Recording"
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        await AudioRecorderService.shared.stopRecording()
        return .result()
    }
}

struct CodexWatchWatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        [
            AppShortcut(
                intent: StartWatchRecordingIntent(),
                phrases: ["Start a watch recording with \(.applicationName)"],
                shortTitle: "Start Watch Recording",
                systemImageName: "record.circle"
            ),
            AppShortcut(
                intent: StopWatchRecordingIntent(),
                phrases: ["Stop the watch recording with \(.applicationName)"],
                shortTitle: "Stop Watch Recording",
                systemImageName: "stop.circle"
            ),
        ]
    }
}
