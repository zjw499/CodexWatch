import SwiftUI
import UIKit

@main
struct CodexWatchApp: App {
    @UIApplicationDelegateAdaptor(CodexWatchAppDelegate.self) private var appDelegate
    @StateObject private var recorder = PhoneRecorderService.shared

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                PhoneRecorderView()
            }
            .environmentObject(recorder)
            .preferredColorScheme(.dark)
        }
    }
}
