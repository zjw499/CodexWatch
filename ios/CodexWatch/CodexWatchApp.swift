import AppIntents
import SwiftUI
import UIKit

@main
struct CodexWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(CodexWatchAppDelegate.self) private var appDelegate
    @StateObject private var recorder = PhoneRecorderService.shared
    @StateObject private var uploader = PhoneUploadService.shared
    @StateObject private var memoService = PhoneMemoService.shared
    @StateObject private var queue = RecordingQueueStore.shared
    @StateObject private var openAI = PhoneOpenAISettings.shared
    @StateObject private var privacy = PhonePrivacyGuard()

    init() {
        CodexWatchShortcuts.updateAppShortcutParameters()
        ScribePreviewFixtures.loadIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                PhoneMemosView()
            }
            .environmentObject(recorder)
            .environmentObject(uploader)
            .environmentObject(memoService)
            .environmentObject(queue)
            .environmentObject(openAI)
            .tint(ScribeTheme.red)
            .preferredColorScheme(.dark)
            .overlay {
                if scenePhase != .active {
                    ScribeTheme.background.ignoresSafeArea().overlay {
                        Text("SCRIBE PILOT").font(.headline).foregroundStyle(ScribeTheme.red)
                    }
                } else if privacy.requiresUnlock && !privacy.unlocked { PhonePrivacyCurtain(privacy: privacy) }
            }
            .task { await privacy.unlock() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { privacy.lock() }
                if phase == .active { Task { await privacy.unlock() } }
            }
        }
    }
}
