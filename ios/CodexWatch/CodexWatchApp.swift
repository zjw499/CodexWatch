import AppIntents
import SwiftUI
import UIKit

@main
struct CodexWatchApp: App {
    @UIApplicationDelegateAdaptor(CodexWatchAppDelegate.self) private var appDelegate
    @StateObject private var recorder = PhoneRecorderService.shared
    @StateObject private var uploader = PhoneUploadService.shared
    @StateObject private var memoService = PhoneMemoService.shared
    @StateObject private var queue = RecordingQueueStore.shared
    @StateObject private var openAI = PhoneOpenAISettings.shared

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
        }
    }
}
