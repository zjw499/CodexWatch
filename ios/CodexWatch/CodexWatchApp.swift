import SwiftUI
import UIKit

@main
struct CodexWatchApp: App {
    @UIApplicationDelegateAdaptor(CodexWatchAppDelegate.self) private var appDelegate
    @StateObject private var recorder = PhoneRecorderService.shared
    @StateObject private var uploader = PhoneUploadService.shared
    @StateObject private var transcriber = PhoneTranscriptionService.shared
    @StateObject private var memoService = PhoneMemoService.shared

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                PhoneMemosView()
            }
            .environmentObject(recorder)
            .environmentObject(uploader)
            .environmentObject(transcriber)
            .environmentObject(memoService)
            .preferredColorScheme(.dark)
        }
    }
}
