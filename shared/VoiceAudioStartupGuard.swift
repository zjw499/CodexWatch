import Foundation

// Rebuild only during initial route negotiation, before any audio is sent.
// An established conversation never reconnects or restarts capture automatically.
enum VoiceAudioStartupDecision: Equatable { case wait, ready, rebuild, failed }

enum VoiceAudioStartupGuard {
    static func decide(elapsedMs: Int, attemptElapsedMs: Int? = nil, attempt: Int, engineRunning: Bool,
                       configurationChanged: Bool, statistics: VoiceCaptureStatistics) -> VoiceAudioStartupDecision {
        if statistics.receiverFailure != 0 || statistics.conversionErrors > 0 { return .failed }
        if engineRunning && statistics.batches > 0 { return .ready }
        if elapsedMs >= 5000 { return .failed }
        if (attemptElapsedMs ?? elapsedMs) >= 300 && (configurationChanged || !engineRunning) {
            return attempt < 3 ? .rebuild : .failed
        }
        return .wait
    }
}

// Conversion runs off the main actor. Hold its first bounded batches until the
// engine is ready, then deliver in order. Discard abandoned attempts completely.
final class VoiceAudioStartupDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var packets = [Data]()
    private var committed = false
    private var stopped = false
    private let deliver: @Sendable (Data?) -> Void
    init(deliver: @escaping @Sendable (Data?) -> Void) { self.deliver = deliver }
    func receive(_ data: Data?) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        if committed { deliver(data); return }
        guard let data else { return }
        guard packets.count < 10 else { stopped = true; packets.removeAll(); return }
        packets.append(data)
    }
    func commit() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, !committed else { return }
        committed = true
        for packet in packets { deliver(packet) }
        packets.removeAll()
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopped = true; packets.removeAll()
    }
}
