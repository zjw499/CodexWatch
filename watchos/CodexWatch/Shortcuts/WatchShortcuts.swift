import AppIntents

struct VoiceAssistantEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Voice Assistant")
    static let defaultQuery = VoiceAssistantQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct VoiceAssistantQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [VoiceAssistantEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [VoiceAssistantEntity] {
        await MainActor.run {
            guard let cache = VoiceDescriptorCache.read(), cache.owner == RecordingQueueStore.shared.accountID,
                  cache.configuration.enabled else { return [] }
            return cache.configuration.assistants.map { VoiceAssistantEntity(id: $0.id, name: $0.name) }
        }
    }
}

struct TalkWatchAssistantIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to Assistant"
    static let description = IntentDescription("Talk through your Watch microphone and speaker using your Scribe Pilot assistant.")
    static let openAppWhenRun = true
    @available(watchOS 26.0, *)
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    @Parameter(title: "Assistant") var assistant: VoiceAssistantEntity?
    static var parameterSummary: some ParameterSummary { Summary("Talk to \(\.$assistant)") }
    func perform() async throws -> some IntentResult {
        await WatchShortcutCommandRouter.enqueueVoice(assistantID: assistant?.id)
        return .result()
    }
}

struct EndWatchVoiceIntent: AppIntent {
    static let title: LocalizedStringResource = "End Voice Conversation"
    static let openAppWhenRun = true
    func perform() async throws -> some IntentResult {
        await WatchShortcutCommandRouter.enqueue(.endVoice)
        return .result()
    }
}

struct StartWatchRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Record Meeting on Watch"
    static let description = IntentDescription(
        "Opens Scribe Pilot on Apple Watch and records a meeting for your configured destination."
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
    static let shortcutTileColor: ShortcutTileColor = .red

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TalkWatchAssistantIntent(),
            phrases: ["Talk to an assistant with \(.applicationName)", "Talk to \(\.$assistant) with \(.applicationName)"],
            shortTitle: "Talk to Assistant",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: EndWatchVoiceIntent(),
            phrases: ["End the voice conversation with \(.applicationName)"],
            shortTitle: "End Conversation",
            systemImageName: "phone.down"
        )
        AppShortcut(
            intent: StartWatchRecordingIntent(),
            phrases: [
                "Start a recording with \(.applicationName)",
                "Start recording on my watch with \(.applicationName)",
                "Record a meeting with \(.applicationName)",
                "Begin a memo with \(.applicationName)"
            ],
            shortTitle: "Record Meeting",
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
