import AppIntents
import SwiftUI
import UIKit

@main
struct CodexWatchApp: App {
    @UIApplicationDelegateAdaptor(CodexWatchAppDelegate.self) private var appDelegate
    @StateObject private var recorder = PhoneRecorderService.shared
    @StateObject private var uploader = PhoneUploadService.shared
    @StateObject private var memoService = PhoneMemoService.shared

    init() {
        CodexWatchShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                PhoneMemosView()
            }
            .environmentObject(recorder)
            .environmentObject(uploader)
            .environmentObject(memoService)
            .preferredColorScheme(.dark)
        }
    }
}
