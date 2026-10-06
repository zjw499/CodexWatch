import AVFoundation
import Foundation

@MainActor
final class WatchVoiceAudio {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var inputReceiver: VoiceInputReceiver?
    private var inputSink: AVAudioSinkNode?
    private var graph: VoiceAudioGraph?
    private var playback = VoicePlaybackLedger()
    private var playbackGeneration = UUID()
    var outputItem: String?
    var onPlaybackFinished: (() -> Void)?
    var hasPendingPlayback: Bool { !playback.pending.isEmpty }
    var captureStatistics: VoiceCaptureStatistics { inputReceiver?.statistics ?? VoiceCaptureStatistics() }

    func start(deliver: @escaping @Sendable (Data?) -> Void) async throws {
        try Task.checkCancellation()
        let session = AVAudioSession.sharedInstance()
        var stage = VoiceAudioStartupStage.configuration
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [])
            stage = .activation
            // Build 147's physical S test captured with voice processing and idle output;
            // the same graph with asynchronous activation received no microphone frames.
            // Keep startup on the main actor with no suspension or late activation callback.
            try session.setActive(true)
            try Task.checkCancellation()
            let engine = AVAudioEngine()
            self.engine = engine
            // Voice I/O provides acoustic echo cancellation for speaker conversations.
            stage = .voiceProcessing
            try engine.inputNode.setVoiceProcessingEnabled(true)
            engine.inputNode.isVoiceProcessingInputMuted = false
            stage = .microphone
            let hardwareInput = engine.inputNode.inputFormat(forBus: 0)
            let input = engine.inputNode.outputFormat(forBus: 0)
            guard hardwareInput.sampleRate > 0, hardwareInput.channelCount > 0,
                  input.sampleRate > 0, input.channelCount > 0 else { throw VoiceAudioStartupError(stage: stage) }
            stage = .speaker
            let hardwareOutput = engine.outputNode.outputFormat(forBus: 0)
            guard hardwareOutput.sampleRate > 0, hardwareOutput.channelCount > 0 else { throw VoiceAudioStartupError(stage: stage) }
            let graph = try VoiceAudioGraph(engine: engine)
            self.graph = graph
            self.player = graph.player
            stage = .conversion
            let receiver = try VoiceInputReceiver(input: input, deliver: deliver)
            self.inputReceiver = receiver
            self.inputSink = receiver.attach(to: engine)
            receiver.start()
            stage = .engine
            // start() prepares the engine and reports preparation/start failures through throws.
            try engine.start()
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as VoiceAudioStartupError {
            throw failure
        } catch {
            throw VoiceAudioStartupError(stage: stage, underlying: error)
        }
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
        playbackGeneration = UUID()
        inputReceiver?.stop()
        engine?.stop()
        inputReceiver?.clearStoppedInput()
        player?.stop(); inputSink = nil; inputReceiver = nil; graph = nil; player = nil; engine = nil
        playback.reset(); outputItem = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }
}
