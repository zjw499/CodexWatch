import AppIntents

struct StartWatchRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Watch Recording"
    static let description = IntentDescription(
        "Opens Scribe Pilot on Apple Watch and starts a recording."
    )
    static let openAppWhenRun = true
    @available(watchOS 26.0, *)
    static let supportedModes: IntentModes = [.foreground(.immediate)]

    func perform() async throws -> some IntentResult {
        await WatchShortcutCommandRouter.enqueue(.startRecording)
        return .result()
    }
}

struct StopWatchRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Watch Recording"
    static let openAppWhenRun = true
    @available(watchOS 26.0, *)
    static let supportedModes: IntentModes = [.foreground(.immediate)]

    func perform() async throws -> some IntentResult {
        await WatchShortcutCommandRouter.enqueue(.stopRecording)
        return .result()
    }
}

struct ResumeWatchRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Watch Recording"
    static let openAppWhenRun = true
    @available(watchOS 26.0, *)
    static let supportedModes: IntentModes = [.foreground(.immediate)]

    func perform() async throws -> some IntentResult {
        await WatchShortcutCommandRouter.enqueue(.resumeRecording)
        return .result()
    }
}

struct RetryWatchUploadIntent: AppIntent {
    static let title: LocalizedStringResource = "Retry Watch Upload"
    static let openAppWhenRun = true
    @available(watchOS 26.0, *)
    static let supportedModes: IntentModes = [.foreground(.immediate)]

    func perform() async throws -> some IntentResult {
        await WatchShortcutCommandRouter.enqueue(.retryUpload)
        return .result()
    }
}

struct OpenScribePilotIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Scribe Pilot"
    static let description = IntentDescription("Opens Scribe Pilot on Apple Watch.")
    static let openAppWhenRun = true
    @available(watchOS 26.0, *)
    static let supportedModes: IntentModes = [.foreground(.immediate)]

    func perform() async throws -> some IntentResult {
        return .result()
    }
}

struct CodexWatchWatchShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .teal

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartWatchRecordingIntent(),
            phrases: [
                "Start a recording with \(.applicationName)",
                "Start recording on my watch with \(.applicationName)",
                "Begin a memo with \(.applicationName)"
            ],
            shortTitle: "Record on Watch",
            systemImageName: "record.circle"
        )
        AppShortcut(
            intent: OpenScribePilotIntent(),
            phrases: [
                "Open \(.applicationName)",
                "Show \(.applicationName) on my watch"
            ],
            shortTitle: "Open Scribe Pilot",
            systemImageName: "mic.circle"
        )
        AppShortcut(
            intent: StopWatchRecordingIntent(),
            phrases: [
                "Stop the recording with \(.applicationName)",
                "Finish the recording with \(.applicationName)"
            ],
            shortTitle: "Stop Recording",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: ResumeWatchRecordingIntent(),
            phrases: [
                "Resume the recording with \(.applicationName)",
                "Continue recording with \(.applicationName)"
            ],
            shortTitle: "Resume Recording",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: RetryWatchUploadIntent(),
            phrases: [
                "Retry the upload with \(.applicationName)",
                "Send the recording again with \(.applicationName)"
            ],
            shortTitle: "Retry Upload",
            systemImageName: "arrow.clockwise.circle"
        )
    }
}
