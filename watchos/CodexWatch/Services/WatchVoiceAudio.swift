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
    var diagnosticSnapshot: VoiceAudioDiagnosticSnapshot { Self.snapshot(engine: engine) }
    var outputClockFrames: Int64 { graph?.outputClockFrames ?? 0 }

    func start(deliver: @escaping @Sendable (Data?) -> Void) async throws {
        try Task.checkCancellation()
        let session = AVAudioSession.sharedInstance()
        var stage = VoiceAudioStartupStage.configuration
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [])
            stage = .activation
            // Use synchronous activation, but do not rely on idle output: build 148
            // still received no frames in a normal conversation on the physical Watch.
            // Keep startup on the main actor with no suspension or late activation callback.
            try session.setActive(true)
            try Task.checkCancellation()
            let engine = AVAudioEngine()
            self.engine = engine
            // Voice I/O provides acoustic echo cancellation for speaker conversations.
            stage = .voiceProcessing
            try engine.inputNode.setVoiceProcessingEnabled(true)
            engine.inputNode.isVoiceProcessingInputMuted = false
            stage = .speaker
            let hardwareOutput = engine.outputNode.outputFormat(forBus: 0)
            guard hardwareOutput.sampleRate > 0, hardwareOutput.channelCount > 0 else { throw VoiceAudioStartupError(stage: stage) }
            let graph = try VoiceAudioGraph(engine: engine, keepOutputActive: true)
            self.graph = graph
            self.player = graph.player
            stage = .microphone
            let hardwareInput = engine.inputNode.inputFormat(forBus: 0)
            let input = engine.inputNode.outputFormat(forBus: 0)
            guard hardwareInput.sampleRate > 0, hardwareInput.channelCount > 0,
                  input.sampleRate > 0, input.channelCount > 0 else { throw VoiceAudioStartupError(stage: stage) }
            stage = .conversion
            let receiver = try VoiceInputReceiver(input: input, deliver: deliver)
            self.inputReceiver = receiver
            self.inputSink = receiver.attach(to: engine)
            receiver.start()
            stage = .engine
            // start() prepares the engine and reports preparation/start failures through throws.
            try engine.start()
            // Build 147's A comparison restored capture while output was rendering.
            // A separate silent player keeps capture clocked across reply pauses and
            // interruptions without adding silence to the provider playback ledger.
            graph.startOutputClock()
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
        graph?.stopOutputClock()
        engine?.stop()
        inputReceiver?.clearStoppedInput()
        player?.stop(); inputSink = nil; inputReceiver = nil; graph = nil; player = nil; engine = nil
        playback.reset(); outputItem = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    // Safe local diagnostics shared by the real startup path and comparison probes.
    // Never include port names, hardware identifiers or arbitrary error descriptions.
    static func snapshot(engine: AVAudioEngine?, speakerOnly: Bool = false,
                         includesOutput: Bool = true) -> VoiceAudioDiagnosticSnapshot {
        let session = AVAudioSession.sharedInstance()
        var result = VoiceAudioDiagnosticSnapshot()
        switch session.category {
        case .record: result.category = "record"
        case .playAndRecord: result.category = "playAndRecord"
        case .playback: result.category = "playback"
        default: result.category = "Other"
        }
        switch session.mode {
        case .default: result.mode = "default"
        case .voiceChat: result.mode = "voiceChat"
        default: result.mode = "Other"
        }
        func port(_ value: AVAudioSession.Port) -> String {
            switch value {
            case .builtInMic: return "built-in mic"
            case .builtInSpeaker: return "built-in speaker"
            case .bluetoothHFP: return "Bluetooth HFP"
            case .bluetoothA2DP: return "Bluetooth A2DP"
            case .bluetoothLE: return "Bluetooth LE"
            case .headphones: return "headphones"
            case .headsetMic: return "headset mic"
            default: return "Other"
            }
        }
        result.inputPorts = session.currentRoute.inputs.map { port($0.portType) }
        result.outputPorts = session.currentRoute.outputs.map { port($0.portType) }
        result.outputVolume = session.outputVolume
        guard let engine else { return result }
        result.engineRunning = engine.isRunning
        if !speakerOnly {
            let hardware = engine.inputNode.inputFormat(forBus: 0), capture = engine.inputNode.outputFormat(forBus: 0)
            result.hardwareInputRate = hardware.sampleRate; result.hardwareInputChannels = hardware.channelCount
            result.captureRate = capture.sampleRate; result.captureChannels = capture.channelCount
            result.voiceProcessing = engine.inputNode.isVoiceProcessingEnabled
            result.inputMuted = engine.inputNode.isVoiceProcessingInputMuted
        }
        if includesOutput {
            let output = engine.outputNode.outputFormat(forBus: 0)
            result.outputRate = output.sampleRate; result.outputChannels = output.channelCount
        }
        return result
    }
}
