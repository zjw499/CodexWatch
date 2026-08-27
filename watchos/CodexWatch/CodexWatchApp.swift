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

    init() {
        CodexWatchWatchShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                RecorderView()
                .task {
                    if store.desktops.isEmpty {
                        await store.loadBootstrap()
                    }
                    await recorder.prepare()
                    await WatchShortcutCommandRouter.consumePendingCommand(using: recorder)
                }
            }
            .environmentObject(store)
            .environmentObject(recorder)
            .background(Color.black)
            .preferredColorScheme(.dark)
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
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
            .onOpenURL { url in
                Task {
                    await store.handleDeepLink(url)
                }
            }
        }
    }
}
