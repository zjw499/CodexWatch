import AVFoundation
import Foundation

struct VoiceReplyPlaybackDiagnostic: Codable, Sendable {
    var scheduledFrames: Int64 = 0
    var completedFrames: Int64 = 0
    var completedItems = 0
    var starts = 0
    var underruns = 0
}

// Use the same player in production and native rendering tests. Keep its clock
// running between network packets; sampled times can already be in the past by
// the time a buffer reaches the audio render thread.
@MainActor
final class VoiceReplyPlayer {
    let player: AVAudioPlayerNode
    private var ledger = VoicePlaybackLedger()
    private var generation = UUID()
    private var preroll: Task<Void, Never>?
    private var finished = Set<String>()
    private var notified = Set<String>()
    private var heard = [String: Int64]()
    private let outputLatency: () -> Double
    private let completionType: AVAudioPlayerNodeCompletionCallbackType
    private(set) var outputItem: String?
    private(set) var peakFrames: Int64 = 0
    private(set) var diagnostic = VoiceReplyPlaybackDiagnostic()
    var onItemFinished: ((String, Int) -> Void)?
    var onDrained: (() -> Void)?
    var hasPending: Bool { !ledger.pending.isEmpty }
    var pendingFrames: Int64 { ledger.remainingFrames(audibleFrame: audibleFrame) }
    var pendingItems: [String] { Array(Set(ledger.pending.map { $0.item })) }

    init(player: AVAudioPlayerNode, outputLatency: @escaping () -> Double = { 0 },
         completionType: AVAudioPlayerNodeCompletionCallbackType = .dataPlayedBack) {
        self.player = player; self.outputLatency = outputLatency; self.completionType = completionType
    }

    func append(_ data: Data, item: String) throws {
        guard !data.isEmpty, data.count % 2 == 0, data.count <= 192000,
              let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(data.count / 2)),
              let samples = buffer.floatChannelData?[0] else { throw VoiceError.audioRoute }
        buffer.frameLength = buffer.frameCapacity
        guard let segment = ledger.schedule(item: item, frames: Int64(buffer.frameLength),
            renderFrame: renderFrame, audibleFrame: audibleFrame) else { throw VoiceError.playbackBacklog }
        data.withUnsafeBytes { raw in
            for index in 0..<Int(buffer.frameLength) {
                samples[index] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32768
            }
        }
        outputItem = item; peakFrames = max(peakFrames, pendingFrames)
        diagnostic.scheduledFrames += segment.frames
        let run = generation
        player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: completionType) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == run else { return }
                self.ledger.complete(segment.id)
                self.diagnostic.completedFrames += segment.frames
                self.notifyFinishedItems()
                if !self.hasPending {
                    if !self.finished.contains(item) { self.diagnostic.underruns += 1 }
                    self.onDrained?()
                }
            }
        }
        // Start with roughly half a second queued, or at the deadline for a
        // short/slow reply. Never pause on an empty packet queue.
        if !player.isPlaying {
            if pendingFrames >= 12000 { start() }
            else if preroll == nil {
                preroll = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                    guard let self, self.generation == run else { return }
                    self.start()
                }
            }
        }
    }

    func finish(item: String) {
        finished.insert(item)
        if hasPending, !player.isPlaying { start() }
        notifyFinishedItems()
    }

    private func start() {
        preroll?.cancel(); preroll = nil
        guard hasPending, !player.isPlaying else { return }
        diagnostic.starts += 1; player.play()
    }

    private var renderFrame: Int64 {
        guard player.isPlaying, let render = player.lastRenderTime,
              render.isSampleTimeValid || render.isHostTimeValid,
              let time = player.playerTime(forNodeTime: render), time.isSampleTimeValid else { return 0 }
        return max(0, time.sampleTime)
    }
    private var audibleFrame: Int64 { max(0, renderFrame - Int64(ceil(outputLatency() * 24000))) }

    func playedMilliseconds(item: String) -> Int {
        Int(max(heard[item, default: 0], ledger.playedFrames(item: item, audibleFrame: audibleFrame)) / 24)
    }

    private func notifyFinishedItems() {
        for item in finished where !notified.contains(item) && !ledger.pending.contains(where: { $0.item == item }) {
            let frames = max(heard[item, default: 0], ledger.playedFrames(item: item, audibleFrame: audibleFrame))
            guard frames > 0 else { continue }
            heard[item] = frames; notified.insert(item); diagnostic.completedItems += 1
            onItemFinished?(item, Int(frames / 24))
        }
    }

    @discardableResult func interrupt(item: String) -> Int {
        let milliseconds = playedMilliseconds(item: item)
        // A delayed interrupt for an older reply must not stop newer speech.
        guard ledger.pending.contains(where: { $0.item == item }) || outputItem == item else { return milliseconds }
        for key in Set(ledger.pending.map { $0.item }).union([item]) {
            heard[key] = max(heard[key, default: 0], ledger.playedFrames(item: key, audibleFrame: audibleFrame))
        }
        generation = UUID(); preroll?.cancel(); preroll = nil
        player.stop(); ledger.reset(); outputItem = nil
        return milliseconds
    }

    func stop() {
        generation = UUID(); preroll?.cancel(); preroll = nil
        player.stop(); ledger.reset(); outputItem = nil
    }
}
