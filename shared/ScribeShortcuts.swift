import AppIntents
import Foundation

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

// Preserve existing intent names. Both apps compile the same catalog; recording
// runs locally on the device executing the shortcut and always opens the app.
struct TalkWatchAssistantIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to Assistant"
    static let description = IntentDescription("Start a live conversation using your Watch microphone and speaker. Other devices prepare a handoff to your Watch.")
    static let openAppWhenRun = true
    @available(iOS 26.0, watchOS 26.0, *)
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    @Parameter(title: "Assistant") var assistant: VoiceAssistantEntity?
    static var parameterSummary: some ParameterSummary { Summary("Talk to \(\.$assistant)") }
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        #if os(watchOS)
        if RecordingQueueStore.shared.accountID == nil { _ = await WatchConnectivityTransferService.shared.ensureVoiceSetup() }
        WatchShortcutCommandRouter.enqueueVoice(assistantID: assistant?.id)
        return .result(dialog: "Opening your assistant.")
        #else
        try await PhoneWorkspace.shared.launchWatchVoice(assistantID: assistant?.id)
        return .result(dialog: "Open Scribe Pilot on your Apple Watch to start talking.")
        #endif
    }
}

struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Record Meeting"
    static let description = IntentDescription("Record a meeting on the device running this shortcut.")
    static let openAppWhenRun = true
    @available(iOS 26.0, watchOS 26.0, *)
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    @MainActor
    func perform() async throws -> some IntentResult {
        #if os(watchOS)
        WatchShortcutCommandRouter.enqueue(.startRecording)
        #else
        await PhoneRecorderService.shared.startRecording()
        guard PhoneRecorderService.shared.isRecording else {
            throw VoiceStartupError(message: PhoneRecorderService.shared.errorMessage ?? PhoneRecorderService.shared.statusMessage)
        }
        #endif
        return .result()
    }
}

struct StopRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    static let openAppWhenRun = true
    @available(iOS 26.0, watchOS 26.0, *)
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    @MainActor
    func perform() async throws -> some IntentResult {
        #if os(watchOS)
        WatchShortcutCommandRouter.enqueue(.stopRecording)
        #else
        PhoneRecorderService.shared.stopRecording()
        #endif
        return .result()
    }
}

struct ResumeWatchRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Recording"
    static let openAppWhenRun = true
    @available(iOS 26.0, watchOS 26.0, *)
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    @MainActor
    func perform() async throws -> some IntentResult {
        #if os(watchOS)
        WatchShortcutCommandRouter.enqueue(.resumeRecording)
        #else
        PhoneRecorderService.shared.resumeRecording()
        if let error = PhoneRecorderService.shared.errorMessage { throw VoiceStartupError(message: error) }
        #endif
        return .result()
    }
}

struct RetryWatchUploadIntent: AppIntent {
    static let title: LocalizedStringResource = "Retry Recording Uploads"
    static let openAppWhenRun = true
    @available(iOS 26.0, watchOS 26.0, *)
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    @MainActor
    func perform() async throws -> some IntentResult {
        #if os(watchOS)
        WatchShortcutCommandRouter.enqueue(.retryUpload)
        #else
        PhoneUploadService.shared.retryPendingRecordings()
        await PhoneWorkspace.shared.refresh()
        await PhoneOpenAIService.shared.reconcile()
        #endif
        return .result()
    }
}

struct EndWatchVoiceIntent: AppIntent {
    static let title: LocalizedStringResource = "End Voice Conversation"
    static let openAppWhenRun = true
    @available(iOS 26.0, watchOS 26.0, *)
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    @MainActor
    func perform() async throws -> some IntentResult {
        #if os(watchOS)
        WatchShortcutCommandRouter.enqueue(.endVoice)
        #else
        try await PhoneWorkspace.shared.endWatchVoice()
        #endif
        return .result()
    }
}

struct OpenScribePilotIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Scribe Pilot"
    static let openAppWhenRun = true
    @available(iOS 26.0, watchOS 26.0, *)
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    func perform() async throws -> some IntentResult { .result() }
}

struct StartWatchRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Record Meeting on Watch"
    static let isDiscoverable = false
    static let openAppWhenRun = true
    @available(iOS 26.0, watchOS 26.0, *)
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    func perform() async throws -> some IntentResult { try await StartRecordingIntent().perform() }
}

struct StopWatchRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Watch Recording"
    static let isDiscoverable = false
    static let openAppWhenRun = true
    @available(iOS 26.0, watchOS 26.0, *)
    static let supportedModes: IntentModes = [.foreground(.immediate)]
    func perform() async throws -> some IntentResult { try await StopRecordingIntent().perform() }
}

struct CodexWatchShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .red
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TalkWatchAssistantIntent(),
            phrases: ["Talk to an assistant with \(.applicationName)", "Talk to \(\.$assistant) with \(.applicationName)"],
            shortTitle: "Talk to Assistant", systemImageName: "waveform")
        AppShortcut(intent: EndWatchVoiceIntent(),
            phrases: ["End the voice conversation with \(.applicationName)"],
            shortTitle: "End Conversation", systemImageName: "phone.down")
        AppShortcut(intent: StartRecordingIntent(),
            phrases: ["Start a recording with \(.applicationName)", "Record a meeting with \(.applicationName)"],
            shortTitle: "Record Meeting", systemImageName: "record.circle")
        AppShortcut(intent: StopRecordingIntent(),
            phrases: ["Stop recording with \(.applicationName)", "Finish the recording with \(.applicationName)"],
            shortTitle: "Stop Recording", systemImageName: "stop.circle")
        AppShortcut(intent: ResumeWatchRecordingIntent(),
            phrases: ["Resume the recording with \(.applicationName)", "Continue recording with \(.applicationName)"],
            shortTitle: "Resume Recording", systemImageName: "play.circle")
        AppShortcut(intent: RetryWatchUploadIntent(),
            phrases: ["Retry the upload with \(.applicationName)"],
            shortTitle: "Retry Uploads", systemImageName: "arrow.clockwise.circle")
        AppShortcut(intent: OpenScribePilotIntent(),
            phrases: ["Open \(.applicationName)"],
            shortTitle: "Open Scribe Pilot", systemImageName: "mic.circle")
    }
}
