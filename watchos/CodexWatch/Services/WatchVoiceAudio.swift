import AVFoundation
import Foundation

@MainActor
final class WatchVoiceAudio {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var inputReceiver: VoiceInputReceiver?
    private var inputSink: AVAudioSinkNode?
    private var graph: VoiceAudioGraph?
    private var reply: VoiceReplyPlayer?
    var outputItem: String? { reply?.outputItem }
    var onPlaybackFinished: ((String, Int) -> Void)?
    var onPlaybackDrained: (() -> Void)?
    var hasPendingPlayback: Bool { reply?.hasPending == true }
    var pendingPlaybackFrames: Int64 { reply?.pendingFrames ?? 0 }
    var peakPlaybackFrames: Int64 { reply?.peakFrames ?? 0 }
    var playbackDiagnostic: VoiceReplyPlaybackDiagnostic { reply?.diagnostic ?? VoiceReplyPlaybackDiagnostic() }
    var pendingPlaybackItems: [String] { reply?.pendingItems ?? [] }
    private var configurationObserver: NSObjectProtocol?
    private var startupGeneration = UUID()
    private var attemptGeneration = UUID()
    private var startupDelivery: VoiceAudioStartupDelivery?
    private var started = false
    private var startedAt = Date()
    private var initialSnapshot = VoiceAudioDiagnosticSnapshot()
    private var lastSnapshot = VoiceAudioDiagnosticSnapshot()
    private var lastStatistics = VoiceCaptureStatistics()
    private var lastRenderedFrames: Int64 = 0
    private var configurationChanges = 0
    private var attempt = 1
    private var events = [VoiceAudioEngineEvent]()
    var onEngineStopped: (() -> Void)?
    var captureStatistics: VoiceCaptureStatistics { inputReceiver?.statistics ?? lastStatistics }
    var diagnosticResult: VoiceAudioDiagnosticResult {
        var result = VoiceAudioDiagnosticResult(phase: .production)
        result.before = initialSnapshot
        result.after = engine == nil ? lastSnapshot : diagnosticSnapshot
        result.apply(captureStatistics)
        result.renderedFrames = engine == nil ? lastRenderedFrames : outputClockFrames
        result.configurationChanges = configurationChanges; result.startupAttempts = attempt
        result.events = events
        return result
    }
    var diagnosticSnapshot: VoiceAudioDiagnosticSnapshot { Self.snapshot(engine: engine) }
    var outputClockFrames: Int64 { graph?.outputClockFrames ?? 0 }

    func start(deliver: @escaping @Sendable (Data?) -> Void) async throws {
        try Task.checkCancellation()
        startupGeneration = UUID()
        let run = startupGeneration
        started = false; startedAt = Date(); attempt = 1; configurationChanges = 0; events = []
        initialSnapshot = VoiceAudioDiagnosticSnapshot(); lastSnapshot = initialSnapshot
        lastStatistics = VoiceCaptureStatistics(); lastRenderedFrames = 0
        let session = AVAudioSession.sharedInstance()
        var stage = VoiceAudioStartupStage.configuration
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [])
            stage = .activation
            try session.setActive(true)
            while true {
                try Task.checkCancellation()
                guard startupGeneration == run else { throw CancellationError() }
                attemptGeneration = UUID()
                let currentAttempt = attemptGeneration
                let engine = AVAudioEngine(); self.engine = engine
                stage = .voiceProcessing
                try engine.inputNode.setVoiceProcessingEnabled(true)
                engine.inputNode.isVoiceProcessingInputMuted = false
                stage = .speaker
                let output = engine.outputNode.outputFormat(forBus: 0)
                guard output.sampleRate > 0, output.channelCount > 0 else { throw VoiceAudioStartupError(stage: stage) }
                let graph = try VoiceAudioGraph(engine: engine, keepOutputActive: true)
                self.graph = graph; self.player = graph.player
                let reply = VoiceReplyPlayer(player: graph.player, outputLatency: { AVAudioSession.sharedInstance().outputLatency })
                reply.onItemFinished = { [weak self] item, ms in self?.onPlaybackFinished?(item, ms) }
                reply.onDrained = { [weak self] in self?.onPlaybackDrained?() }
                self.reply = reply
                stage = .microphone
                let hardware = engine.inputNode.inputFormat(forBus: 0)
                let input = engine.inputNode.outputFormat(forBus: 0)
                guard hardware.sampleRate > 0, hardware.channelCount > 0,
                      input.sampleRate > 0, input.channelCount > 0 else { throw VoiceAudioStartupError(stage: stage) }
                stage = .conversion
                let delivery = VoiceAudioStartupDelivery(deliver: deliver)
                startupDelivery = delivery
                let receiver = try VoiceInputReceiver(input: input) { delivery.receive($0) }
                inputReceiver = receiver; inputSink = receiver.attach(to: engine); receiver.start()
                // The notification arrives on an internal audio queue. Rebuild on the
                // main actor after it returns; never release an engine in its handler.
                configurationObserver = NotificationCenter.default.addObserver(
                    forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
                        Task { @MainActor in
                            guard let self, self.startupGeneration == run,
                                  self.attemptGeneration == currentAttempt else { return }
                            self.configurationChanges += 1
                            self.record(.configuration)
                            if self.started, self.engine?.isRunning != true { self.onEngineStopped?() }
                        }
                    }
                let previousChanges = configurationChanges
                stage = .engine
                try engine.start(); graph.startOutputClock()
                if attempt == 1 { initialSnapshot = diagnosticSnapshot }
                record(.start)
                let attemptStart = Date()
                var rebuild = false
                while !rebuild {
                    try await Task.sleep(for: .milliseconds(50))
                    try Task.checkCancellation()
                    guard startupGeneration == run else { throw CancellationError() }
                    let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
                    let decision = VoiceAudioStartupGuard.decide(elapsedMs: elapsed,
                        attemptElapsedMs: Int(Date().timeIntervalSince(attemptStart) * 1000), attempt: attempt,
                        engineRunning: engine.isRunning, configurationChanged: configurationChanges != previousChanges,
                        statistics: receiver.statistics)
                    switch decision {
                    case .ready:
                        started = true; record(.ready); delivery.commit(); return
                    case .wait: break
                    case .rebuild:
                        record(engine.isRunning ? .rebuild : .stopped)
                        stopEngine(); attempt += 1
                        // Keep the activated session while negotiated hardware settles.
                        try await Task.sleep(for: .milliseconds(300))
                        rebuild = true
                    case .failed:
                        record(.timeout)
                        if receiver.statistics.conversionErrors > 0 { stage = .conversion }
                        throw VoiceAudioStartupError(stage: stage)
                    }
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as VoiceAudioStartupError {
            throw failure
        } catch {
            throw VoiceAudioStartupError(stage: stage, underlying: error)
        }
    }

    private func record(_ kind: VoiceAudioEngineEvent.Kind) {
        guard events.count < 12 else { return }
        let statistics = captureStatistics
        events.append(VoiceAudioEngineEvent(kind: kind,
            elapsedMs: max(0, Int(Date().timeIntervalSince(startedAt) * 1000)), attempt: attempt,
            snapshot: diagnosticSnapshot, inputFrames: statistics.inputFrames,
            convertedFrames: statistics.outputFrames, batches: statistics.batches))
    }

    func play(_ data: Data, item: String) throws {
        guard let reply else { throw VoiceError.audioRoute }
        try reply.append(data, item: item)
    }
    func finishPlayback(item: String) { reply?.finish(item: item) }
    func playedMilliseconds(item: String) -> Int {
        reply?.playedMilliseconds(item: item) ?? 0
    }
    func interrupt(item: String) -> Int {
        reply?.interrupt(item: item) ?? 0
    }
    private func stopEngine() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil; attemptGeneration = UUID()
        startupDelivery?.stop(); startupDelivery = nil
        inputReceiver?.stop()
        lastSnapshot = diagnosticSnapshot; lastStatistics = captureStatistics
        lastRenderedFrames = outputClockFrames
        graph?.stopOutputClock(); engine?.stop(); inputReceiver?.clearStoppedInput()
        reply?.stop(); reply = nil
        player?.stop(); inputSink = nil; inputReceiver = nil; graph = nil; player = nil; engine = nil
    }

    func stop() {
        startupGeneration = UUID(); started = false
        stopEngine()
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
            switch capture.commonFormat {
            case .pcmFormatFloat32: result.captureFormat = "Float32"
            case .pcmFormatFloat64: result.captureFormat = "Float64"
            case .pcmFormatInt16: result.captureFormat = "Int16"
            case .pcmFormatInt32: result.captureFormat = "Int32"
            default: result.captureFormat = "Other"
            }
            result.captureInterleaved = capture.isInterleaved
            result.captureBytesPerFrame = capture.streamDescription.pointee.mBytesPerFrame
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
