import Foundation

struct VoiceDiagnosticReport: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case audioTest = "audio-test", voiceStartup = "voice-startup", voiceSession = "voice-session" }
    let version = 1
    let request_id: String
    var revision = 1
    let kind: Kind
    let build: String
    let watch_os: String
    let completed: Bool
    var speaker_heard: Bool?
    let route_changes: Int
    let interruptions: Int
    let media_resets: Int
    let results: [VoiceAudioDiagnosticResult]
    var transport: VoiceTransportDiagnostic?
}

struct VoiceTransportDiagnostic: Codable, Sendable {
    enum EndReason: String, Codable, Sendable {
        case closed, network, serverEnded = "server-ended", uploadBacklog = "upload-backlog", playbackBacklog = "playback-backlog"
    }
    var endReason = EndReason.closed
    var uploadedBytes = 0
    var uploadRequests = 0
    var pendingUploadBytes = 0
    var peakUploadBytes = 0
    var lastUploadMs = 0
    var maxUploadMs = 0
    var receivedAudioBytes = 0
    var playbackFrames: Int64 = 0
    var peakPlaybackFrames: Int64 = 0
    var sessionID: String?
    var replyPlayback: VoiceReplyPlaybackDiagnostic?
    var controlFailures: Int?
    var audioRetries: Int?
    var maxAudioGapMs: Int?
}

struct VoiceDiagnosticReceipt: Codable {
    let version: Int
    let id: String
    let revision: Int
    func accepts(_ report: VoiceDiagnosticReport) -> Bool {
        version == report.version && id == report.request_id && revision >= report.revision
    }
}

// No credentials are persisted here. Account binding prevents a later account
// from uploading an earlier account's diagnostics; only ten pending reports fit.
struct VoiceDiagnosticOutbox: Codable {
    struct Entry: Codable {
        let owner: String
        var report: VoiceDiagnosticReport
    }
    private(set) var entries = [Entry]()
    mutating func enqueue(_ report: VoiceDiagnosticReport, owner: String) {
        entries.removeAll { $0.owner != owner }
        if let latest = entries.filter({ $0.report.request_id == report.request_id }).map({ $0.report.revision }).max(),
           report.revision <= latest { return }
        entries.append(Entry(owner: owner, report: report))
        var ids = [String]()
        for entry in entries where !ids.contains(entry.report.request_id) { ids.append(entry.report.request_id) }
        if ids.count > 10 {
            let old = Set(ids.prefix(ids.count - 10))
            entries.removeAll { old.contains($0.report.request_id) }
        }
    }
    mutating func accountChanged(_ owner: String?) { entries.removeAll { $0.owner != owner } }
    mutating func acknowledge(_ receipt: VoiceDiagnosticReceipt, owner: String) {
        entries.removeAll { $0.owner == owner && receipt.accepts($0.report) }
    }
}
