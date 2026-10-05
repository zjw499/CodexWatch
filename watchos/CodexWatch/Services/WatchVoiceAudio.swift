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
    private var scheduledFrames: Int64 = 0
    private var queuedBuffers = 0
    private var itemStarts: [String: Int64] = [:]
    private var itemFrames: [String: Int64] = [:]
    private var playbackGeneration = UUID()
    var outputItem: String?
    var onPlaybackFinished: (() -> Void)?
    var hasPendingPlayback: Bool { queuedBuffers > 0 }

    func start(deliver: @escaping @Sendable (Data?) -> Void) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [])
        try session.setActive(true)
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
        engine.prepare(); try engine.start(); player.play()
    }

    func play(_ data: Data, item: String) throws {
        guard !data.isEmpty, data.count % 2 == 0, data.count <= 192000,
              let player, let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(data.count / 2)),
              let samples = buffer.floatChannelData?[0] else { throw VoiceError.audioRoute }
        if scheduledFrames - playedFrames() > 96000 { throw VoiceError.slow }
        buffer.frameLength = buffer.frameCapacity
        data.withUnsafeBytes { raw in
            for index in 0..<Int(buffer.frameLength) {
                let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
                samples[index] = Float(sample) / 32768
            }
        }
        if itemStarts[item] == nil { itemStarts[item] = scheduledFrames }
        itemFrames[item, default: 0] += Int64(buffer.frameLength)
        scheduledFrames += Int64(buffer.frameLength)
        outputItem = item
        queuedBuffers += 1
        let generation = playbackGeneration
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.playbackGeneration == generation else { return }
                self.queuedBuffers = max(0, self.queuedBuffers - 1)
                if self.queuedBuffers == 0 { self.onPlaybackFinished?() }
            }
        }
    }

    private func playedFrames() -> Int64 {
        guard let player, let render = player.lastRenderTime, let time = player.playerTime(forNodeTime: render) else { return 0 }
        return time.sampleTime
    }
    func playedMilliseconds(item: String) -> Int {
        let frames = min(itemFrames[item] ?? 0, max(0, playedFrames() - (itemStarts[item] ?? 0)))
        return Int(frames * 1000 / 24000)
    }
    func interrupt(item: String) -> Int {
        let milliseconds = playedMilliseconds(item: item)
        playbackGeneration = UUID(); player?.stop()
        queuedBuffers = 0; scheduledFrames = 0; itemStarts = [:]; itemFrames = [:]; outputItem = nil
        player?.play()
        return milliseconds
    }
    func stop() {
        playbackGeneration = UUID()
        if let engine { if hasInputTap { engine.inputNode.removeTap(onBus: 0) }; engine.stop() }
        hasInputTap = false
        player?.stop(); encoder = nil; player = nil; engine = nil
        queuedBuffers = 0; scheduledFrames = 0; itemStarts = [:]; itemFrames = [:]; outputItem = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }
}
