import Foundation

// Playback offsets count PCM frames, excluding silence while waiting for network data.
struct VoicePlaybackLedger {
    struct Segment {
        let id = UUID()
        let item: String
        let start: Int64
        let frames: Int64
        var end: Int64 { start + frames }
    }
    private(set) var pending: [Segment] = []
    private var completed: [String: Int64] = [:]

    func remainingFrames(audibleFrame: Int64) -> Int64 {
        pending.reduce(Int64(0)) { $0 + max(0, $1.end - max($1.start, audibleFrame)) }
    }

    mutating func schedule(item: String, frames: Int64, renderFrame: Int64, audibleFrame: Int64) -> Segment? {
        let remaining = remainingFrames(audibleFrame: audibleFrame)
        guard frames > 0, remaining + frames <= 96000 else { return nil }
        let segment = Segment(item: item, start: max(pending.last?.end ?? 0, renderFrame), frames: frames)
        pending.append(segment)
        return segment
    }
    mutating func complete(_ id: UUID) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let segment = pending.remove(at: index)
        completed[segment.item, default: 0] += segment.frames
    }
    func playedFrames(item: String, audibleFrame: Int64) -> Int64 {
        pending.filter { $0.item == item }.reduce(completed[item, default: 0]) {
            $0 + min($1.frames, max(0, audibleFrame - $1.start))
        }
    }
    mutating func reset() { pending = []; completed = [:] }
}
