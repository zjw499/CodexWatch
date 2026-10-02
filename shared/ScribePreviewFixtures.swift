import Foundation

enum ScribePreviewFixtures {
    @MainActor static func loadIfRequested() {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-scribe-ui-preview") else { return }
        #if os(iOS)
        PhoneWorkspace.shared.loadPreview()
        #endif
        let queue = RecordingQueueStore.shared
        do {
            try queue.remove(Set(queue.recordings.filter { $0.state != .recording }.map(\.id)))
            let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
            try Data(repeating: 0, count: 2048).write(to: audio)
            defer { try? FileManager.default.removeItem(at: audio) }
            let queued = UUID().uuidString
            try queue.accept(fileURL: audio, id: queued, index: 0, isFinal: true, source: "Apple Watch")
            try queue.rename(queued, title: "Team check-in")
            let completed = UUID().uuidString
            let fullPreview = ProcessInfo.processInfo.arguments.contains("-scribe-full-recording-preview")
            try queue.accept(fileURL: audio, id: completed, index: 0, isFinal: !fullPreview, source: fullPreview ? "Apple Watch" : "iPhone", ownerID: fullPreview ? "preview-user" : nil)
            if fullPreview {
                try queue.accept(fileURL: audio, id: completed, index: 1, isFinal: false, source: "Apple Watch", ownerID: "preview-user")
                try queue.accept(fileURL: audio, id: completed, index: 2, isFinal: true, source: "Apple Watch", duration: 90, ownerID: "preview-user")
            }
            try queue.update(completed) {
                $0.title = "Project kickoff"
                $0.state = .ready
                $0.protectedWorkflow = false
                $0.transcript = "We reviewed the project timeline. Alex will prepare the agenda for Friday. The next check-in is Monday."
                $0.summary = "Overview\nThe team reviewed the project timeline.\n\nFollow-up\nPrepare the agenda for Friday.\n\nNext meeting\nMonday."
            }
        } catch { queue.errorMessage = error.localizedDescription }
        #endif
    }
}
