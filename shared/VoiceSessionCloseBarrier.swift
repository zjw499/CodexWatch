import Foundation

// Final playback acknowledgements and End must finish before a fresh session
// can consume the account's single active-conversation slot.
@MainActor
final class VoiceSessionCloseBarrier {
    private var task: Task<Void, Never>?
    private var revision = 0
    func close(_ action: @escaping @MainActor () async -> Void) {
        let previous = task
        revision += 1
        task = Task {
            await previous?.value
            await action()
        }
    }
    func wait() async {
        while let current = task {
            let expected = revision
            await current.value
            if revision == expected { return }
        }
    }
}
