import Combine
import LocalAuthentication
import SwiftUI

@MainActor
final class PhonePrivacyGuard: ObservableObject {
    @Published private(set) var unlocked = false
    @Published private(set) var authenticating = false
    @Published private(set) var message = "Use Face ID, Touch ID, or your device passcode to open your protected recordings."

    var requiresUnlock: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-scribe-ui-preview") { return false }
        #endif
        return PhoneOpenAISettings.shared.configuration.protectedMode
    }
    func lock() { unlocked = false }
    func unlock() async {
        guard requiresUnlock, !unlocked, !authenticating else { return }
        authenticating = true
        defer { authenticating = false }
        let context = LAContext()
        context.localizedCancelTitle = "Keep locked"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            message = "Set a device passcode in iPhone Settings to open protected recordings."
            return
        }
        do {
            unlocked = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Open your Scribe Pilot recordings and OpenAI settings.")
            if unlocked { PhoneOpenAISettings.shared.refreshKeyAvailability() }
        } catch { message = "Your recordings are locked. Tap Unlock to try again." }
    }
}

struct PhonePrivacyCurtain: View {
    @ObservedObject var privacy: PhonePrivacyGuard
    var body: some View {
        ZStack {
            ScribeTheme.background.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.shield").font(.system(size: 42)).foregroundStyle(ScribeTheme.red)
                Text("Scribe Pilot").font(.title.bold())
                Text(privacy.message).font(.subheadline).foregroundStyle(ScribeTheme.muted).multilineTextAlignment(.center)
                Button { Task { await privacy.unlock() } } label: {
                    Label("Unlock Scribe Pilot", systemImage: "lock.open").padding(8)
                }.buttonStyle(.borderedProminent).tint(ScribeTheme.red).disabled(privacy.authenticating)
            }.padding(32).frame(maxWidth: 500)
        }.foregroundStyle(.white)
    }
}
