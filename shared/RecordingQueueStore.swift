import Combine
import Foundation

enum RecordingState: String, Codable {
    case recording, receiving, queued, processing, failed, ready

    var label: String {
        switch self {
        case .recording: return "Recording"
        case .receiving: return "Receiving audio"
        case .queued: return "Ready to process"
        case .processing: return "Transcribing"
        case .failed: return "Needs attention"
        case .ready: return "Transcript ready"
        }
    }

    var icon: String {
        switch self {
        case .recording: return "record.circle"
        case .receiving: return "iphone.and.arrow.forward"
        case .queued: return "tray"
        case .processing: return "waveform"
        case .failed: return "exclamationmark.circle"
        case .ready: return "checkmark.circle"
        }
    }
}

struct RecordingPart: Codable, Equatable {
    let index: Int
    let filename: String
    let isFinal: Bool
}

struct QueuedRecording: Identifiable, Codable {
    let id: String
    var title: String
    let source: String
    let createdAt: Date
    var state: RecordingState
    var parts: [RecordingPart] = []
    var finalIndex: Int?
    var duration: TimeInterval?
    var transcripts: [String: String] = [:]
    var transcript = ""
    var summary: String?
    var error: String?
    var progress = 0.0
    var protectedWorkflow = true

    var isComplete: Bool {
        guard let finalIndex, finalIndex >= 0 else { return false }
        let indexes = Set(parts.map(\.index))
        return indexes.count == finalIndex + 1 && (0...finalIndex).allSatisfy { indexes.contains($0) }
    }
    var isWatch: Bool { source == "Apple Watch" }
    var canProcess: Bool { isComplete && [.queued, .failed].contains(state) }
}

enum RecordingQueueError: LocalizedError {
    case invalidRecording, persistence, stillRecording
    var errorDescription: String? {
        switch self {
        case .invalidRecording: return "The recording data could not be read safely."
        case .persistence: return "Changes could not be saved. Your audio has been kept."
        case .stillRecording: return "Finish this recording before removing it."
        }
    }
}

/// Metadata, transcripts, and deletion markers live in a protected, backup-excluded file.
/// A deletion marker is saved before audio is removed so late Watch transfers cannot restore it.
@MainActor
final class RecordingQueueStore: ObservableObject {
    static let shared = RecordingQueueStore()
    @Published private(set) var recordings: [QueuedRecording] = []
    @Published var errorMessage: String?
    private(set) var removedIDs: Set<String> = []
    private let root: URL
    private var storageUnavailable = false

    private struct Snapshot: Codable {
        var recordings: [QueuedRecording]
        var removedIDs: Set<String>
    }

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScribePilot", isDirectory: true)
        do {
            try Self.protectDirectory(self.root)
            let snapshotURL = self.root.appendingPathComponent("queue.json")
            if FileManager.default.fileExists(atPath: snapshotURL.path) {
                let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: snapshotURL))
                recordings = snapshot.recordings
                removedIDs = snapshot.removedIDs
                for index in recordings.indices where recordings[index].state == .processing {
                    recordings[index].state = .queued
                    recordings[index].error = "Processing was interrupted. Tap Process to continue."
                }
                for index in recordings.indices where recordings[index].state == .recording {
                    recordings[index].state = .receiving
                    recordings[index].error = "Recording was interrupted. Retry the transfer or remove the saved audio."
                }
                // A saved deletion marker remains authoritative if cleanup was interrupted.
                for id in removedIDs {
                    do { try purgeAudio(id) }
                    catch { errorMessage = "Removed recordings remain hidden. Audio cleanup will retry when the app reopens." }
                }
            }
        } catch {
            // Fail closed: do not overwrite an unreadable queue with an empty snapshot.
            errorMessage = "Saved recordings are unavailable. Unlock your device and reopen Scribe Pilot."
            storageUnavailable = true
        }
    }

    var pending: [QueuedRecording] { recordings.filter { $0.state != .ready }.sorted { $0.createdAt > $1.createdAt } }
    var completed: [QueuedRecording] { recordings.filter { $0.state == .ready }.sorted { $0.createdAt > $1.createdAt } }
    func recording(_ id: String) -> QueuedRecording? { recordings.first { $0.id == id } }
    func isRemoved(_ id: String) -> Bool { removedIDs.contains(id) }

    nonisolated static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 140 && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }
    }

    func begin(id: String, source: String) throws {
        guard Self.validID(id), !storageUnavailable else { throw RecordingQueueError.persistence }
        guard !isRemoved(id), recording(id) == nil else { return }
        var item = newRecording(id: id, source: source)
        item.state = .recording
        try commit(recordings + [item], removed: removedIDs)
    }

    @discardableResult
    func accept(fileURL: URL, id: String, index: Int, isFinal: Bool, source: String, duration: TimeInterval? = nil) throws -> Bool {
        guard Self.validID(id), index >= 0, index < 100_000 else { throw RecordingQueueError.invalidRecording }
        guard !storageUnavailable else { throw RecordingQueueError.persistence }
        guard !isRemoved(id) else { return false }
        var items = recordings
        let position: Int
        if let existing = items.firstIndex(where: { $0.id == id }) { position = existing }
        else { items.append(newRecording(id: id, source: source)); position = items.count - 1 }
        // Duplicate file and immediate deliveries are acknowledgements, never reprocessing.
        if items[position].parts.contains(where: { $0.index == index }) {
            if isFinal && items[position].finalIndex == nil {
                items[position].finalIndex = index
                if items[position].isComplete && items[position].state != .ready && items[position].state != .processing {
                    items[position].state = .queued
                }
                try commit(items, removed: removedIDs)
            }
            return false
        }
        if let final = items[position].finalIndex, index > final { throw RecordingQueueError.invalidRecording }
        if isFinal && items[position].parts.contains(where: { $0.index > index }) { throw RecordingQueueError.invalidRecording }
        let directory = audioDirectory(id)
        try Self.protectDirectory(directory)
        let suffix = ["m4a", "mp3", "wav", "mp4", "caf"].contains(fileURL.pathExtension.lowercased())
            ? fileURL.pathExtension.lowercased() : "m4a"
        let filename = String(format: "part_%06d.%@", index, suffix)
        let destination = directory.appendingPathComponent(filename)
        if destination != fileURL {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: fileURL, to: destination)
        }
        try Self.protectFile(destination)
        items[position].parts.append(RecordingPart(index: index, filename: filename, isFinal: isFinal))
        if isFinal { items[position].finalIndex = index }
        if let duration { items[position].duration = duration }
        items[position].state = items[position].isComplete ? .queued
            : (items[position].state == .recording && !isFinal ? .recording : .receiving)
        try commit(items, removed: removedIDs)
        return true
    }

    func rename(_ id: String, title: String) throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 160 else { throw RecordingQueueError.invalidRecording }
        try update(id) { $0.title = title }
    }

    func update(_ id: String, mutation: (inout QueuedRecording) -> Void) throws {
        guard let position = recordings.firstIndex(where: { $0.id == id }), !isRemoved(id) else { return }
        var items = recordings
        mutation(&items[position])
        try commit(items, removed: removedIDs)
    }

    func remove(_ ids: Set<String>) throws {
        guard !recordings.contains(where: { ids.contains($0.id) && $0.state == .recording }) else {
            throw RecordingQueueError.stillRecording
        }
        guard ids.allSatisfy(Self.validID) else { throw RecordingQueueError.invalidRecording }
        try commit(recordings.filter { !ids.contains($0.id) }, removed: removedIDs.union(ids))
        for id in ids { try purgeAudio(id) }
    }

    func purgeAudio(_ id: String) throws {
        guard Self.validID(id) else { throw RecordingQueueError.invalidRecording }
        let directory = audioDirectory(id)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    func audioURL(_ id: String, part: RecordingPart) -> URL {
        audioDirectory(id).appendingPathComponent(part.filename)
    }

    private func audioDirectory(_ id: String) -> URL {
        root.appendingPathComponent("Audio", isDirectory: true).appendingPathComponent(id, isDirectory: true)
    }

    private func newRecording(id: String, source: String) -> QueuedRecording {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return QueuedRecording(id: id, title: "\(source) · \(formatter.string(from: Date()))", source: source,
                               createdAt: Date(), state: .receiving)
    }

    private func commit(_ items: [QueuedRecording], removed: Set<String>) throws {
        guard !storageUnavailable else { throw RecordingQueueError.persistence }
        do {
            let data = try JSONEncoder().encode(Snapshot(recordings: items, removedIDs: removed))
            let url = root.appendingPathComponent("queue.json")
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try Self.protectFile(url)
            recordings = items
            removedIDs = removed
        } catch { throw RecordingQueueError.persistence }
    }

    nonisolated static func protectDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try protectFile(directory)
    }

    nonisolated static func protectFile(_ file: URL) throws {
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
        var url = file
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}
