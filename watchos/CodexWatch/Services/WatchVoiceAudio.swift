import AVFoundation
import Foundation

// Runs on the audio callback thread. Only 200 ms PCM batches leave this object.
private final class VoicePCMEncoder: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private let lock = NSLock()
    private var pending = Data()
    private let deliver: @Sendable (Data?) -> Void
    init(input: AVAudioFormat, deliver: @escaping @Sendable (Data?) -> Void) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1),
              let converter = AVAudioConverter(from: input, to: format) else { throw VoiceError.audioRoute }
        self.format = format; self.converter = converter; self.deliver = deliver
    }
    func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 24000 / buffer.format.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { deliver(nil); return }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return buffer
        }
        guard error == nil, let channel = output.floatChannelData?[0] else { deliver(nil); return }
        var samples = [Int16](repeating: 0, count: Int(output.frameLength))
        for i in samples.indices {
            let value = channel[i].isFinite ? max(-1, min(1, channel[i])) : 0
            samples[i] = Int16((value * 32767).rounded()).littleEndian
        }
        samples.withUnsafeBytes { pending.append(contentsOf: $0) }
        while pending.count >= 9600 {
            deliver(Data(pending.prefix(9600)))
            pending.removeFirst(9600)
        }
    }
}

@MainActor
final class WatchVoiceAudio {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var encoder: VoicePCMEncoder?
    private var hasInputTap = false
    private var playback = VoicePlaybackLedger()
    private var playbackGeneration = UUID()
    private var activation: UUID?
    var outputItem: String?
    var onPlaybackFinished: (() -> Void)?
    var hasPendingPlayback: Bool { !playback.pending.isEmpty }

    func start(deliver: @escaping @Sendable (Data?) -> Void) async throws {
        try Task.checkCancellation()
        let session = AVAudioSession.sharedInstance()
        let ticket = UUID()
        activation = ticket
        defer { if activation == ticket { activation = nil } }
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [])
        let activated = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            session.activate(options: []) { active, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: active) }
            }
        }
        guard activation == ticket, !Task.isCancelled else {
            // A late activation must not revive audio after exit, or stop a newer startup.
            if activation == nil, engine == nil { try? session.setActive(false) }
            throw CancellationError()
        }
        guard activated else { throw VoiceError.audioRoute }
        let engine = AVAudioEngine()
        self.engine = engine
        // Voice I/O provides acoustic echo cancellation for speaker conversations.
        try engine.inputNode.setVoiceProcessingEnabled(true)
        let input = engine.inputNode.outputFormat(forBus: 0)
        guard input.sampleRate > 0, input.channelCount > 0 else { throw VoiceError.audioRoute }
        let encoder = try VoicePCMEncoder(input: input, deliver: deliver)
        self.encoder = encoder
        let player = AVAudioPlayerNode()
        engine.attach(player)
        guard let output = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1) else { throw VoiceError.audioRoute }
        engine.connect(player, to: engine.mainMixerNode, format: output)
        self.player = player
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: input) { buffer, _ in encoder.consume(buffer) }
        hasInputTap = true
        engine.prepare(); try engine.start()
    }

    func play(_ data: Data, item: String) throws {
        guard !data.isEmpty, data.count % 2 == 0, data.count <= 192000,
              let player, let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(data.count / 2)),
              let samples = buffer.floatChannelData?[0] else { throw VoiceError.audioRoute }
        buffer.frameLength = buffer.frameCapacity
        guard let segment = playback.schedule(item: item, frames: Int64(buffer.frameLength),
                                             renderFrame: renderFrames(), audibleFrame: audibleFrames()) else { throw VoiceError.slow }
        data.withUnsafeBytes { raw in
            for index in 0..<Int(buffer.frameLength) {
                let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
                samples[index] = Float(sample) / 32768
            }
        }
        outputItem = item
        let generation = playbackGeneration
        player.scheduleBuffer(buffer, at: AVAudioTime(sampleTime: segment.start, atRate: 24000), options: [],
                              completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.playbackGeneration == generation else { return }
                self.playback.complete(segment.id)
                if self.playback.pending.isEmpty { self.player?.pause(); self.onPlaybackFinished?() }
            }
        }
        if !player.isPlaying { player.play() }
    }

    private func renderFrames() -> Int64 {
        guard let player, let render = player.lastRenderTime, let time = player.playerTime(forNodeTime: render) else { return 0 }
        return time.sampleTime
    }
    private func audibleFrames() -> Int64 {
        max(0, renderFrames() - Int64(ceil(AVAudioSession.sharedInstance().outputLatency * 24000)))
    }
    func playedMilliseconds(item: String) -> Int {
        let frames = playback.playedFrames(item: item, audibleFrame: audibleFrames())
        return Int(frames * 1000 / 24000)
    }
    func interrupt(item: String) -> Int {
        let milliseconds = playedMilliseconds(item: item)
        playbackGeneration = UUID(); player?.stop()
        playback.reset(); outputItem = nil
        return milliseconds
    }
    func stop() {
        activation = nil
        playbackGeneration = UUID()
        if let engine { if hasInputTap { engine.inputNode.removeTap(onBus: 0) }; engine.stop() }
        hasInputTap = false
        player?.stop(); encoder = nil; player = nil; engine = nil
        playback.reset(); outputItem = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }
}
