import SwiftUI

@main
struct CodexWatchApp: App {
    @StateObject private var store = CodexWatchStore(
        api: CodexWatchAPIClient(
            baseURL: CodexWatchConfiguration.relayBaseURL,
            relayToken: CodexWatchConfiguration.relayToken
        )
    )
    @StateObject private var recorder = AudioRecorderService.shared

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                RecorderView()
                .task {
                    if store.desktops.isEmpty {
                        await store.loadBootstrap()
                    }
                }
            }
            .environmentObject(store)
            .environmentObject(recorder)
            .background(Color.black)
            .preferredColorScheme(.dark)
            .onOpenURL { url in
                Task {
                    await store.handleDeepLink(url)
                }
            }
        }
    }
}
