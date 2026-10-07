import AppIntents
import SwiftUI

@main
struct CodexWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = CodexWatchStore(
        api: CodexWatchAPIClient(
            baseURL: CodexWatchConfiguration.relayBaseURL,
            relayToken: CodexWatchConfiguration.relayToken
        )
    )
    @StateObject private var recorder = AudioRecorderService.shared
    @StateObject private var queue = RecordingQueueStore.shared
    @StateObject private var voice = WatchVoiceService.shared

    init() {
        CodexWatchWatchShortcuts.updateAppShortcutParameters()
        ScribePreviewFixtures.loadIfRequested()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-scribe-watch-voice") { WatchVoiceService.shared.loadPreview() }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                RecorderView()
                .task {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-scribe-ui-preview") { return }
                    #endif
                    WatchVoiceDiagnosticReporter.shared.retry()
                    await recorder.prepare()
                    await WatchShortcutCommandRouter.consumePendingCommand(using: recorder)
                }
            }
            .id(queue.accountID ?? "signed-out")
            .environmentObject(store)
            .environmentObject(recorder)
            .environmentObject(queue)
            .sheet(isPresented: $voice.isPresented) {
                NavigationStack { WatchVoiceView() }
            }
            .tint(ScribeTheme.red)
            .background(ScribeTheme.background)
            .preferredColorScheme(.dark)
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { voice.end(message: "Conversation ended when Scribe Pilot left the foreground.") }
                guard phase == .active else { return }
                WatchVoiceDiagnosticReporter.shared.retry()
                Task {
                    await WatchShortcutCommandRouter.consumePendingCommand(using: recorder)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .watchShortcutCommandQueued)) { _ in
                Task {
                    await WatchShortcutCommandRouter.consumePendingCommand(using: recorder)
                }
            }
            .onContinueUserActivity(ScribePilotComplication.recordActivityType) { activity in
                Task {
                    await WatchShortcutCommandRouter.handleComplicationActivity(
                        activity,
                        using: recorder
                    )
                }
            }
            .onContinueUserActivity(ScribePilotComplication.voiceActivityType) { activity in
                Task { await WatchShortcutCommandRouter.handleComplicationActivity(activity, using: recorder) }
            }
            .onOpenURL { url in
                Task {
                    await store.handleDeepLink(url)
                }
            }
        }
    }
}
