import SwiftUI

@main
struct CodexWatchApp: App {
    @StateObject private var store = CodexWatchStore(
        api: CodexWatchAPIClient(
            baseURL: CodexWatchConfiguration.relayBaseURL,
            relayToken: CodexWatchConfiguration.relayToken
        )
    )

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                Group {
                    if store.selectedDesktop == nil {
                        DesktopPickerView()
                    } else {
                        HomeView()
                    }
                }
                .task {
                    if store.desktops.isEmpty {
                        await store.loadBootstrap()
                    }
                }
            }
            .environmentObject(store)
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
