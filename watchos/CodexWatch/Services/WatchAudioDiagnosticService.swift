import AVFoundation
import Combine
import Foundation

// Samples are discarded after counting/conversion. No file, network, analytics,
// provider connection, credential or transcript is involved in this test.
private final class DiagnosticAudioMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var peak = 0.0
    private var failed = false
    func consume(_ packet: Data?) {
        lock.lock(); defer { lock.unlock() }
        if let packet { peak = max(peak, VoiceAudioStatus.microphoneLevel(packet)) }
        else { failed = true }
    }
    var values: (peak: Double, failed: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (peak, failed)
    }
}

@MainActor
final class WatchAudioDiagnosticService: ObservableObject {
    static let shared = WatchAudioDiagnosticService()
    @Published private(set) var isRunning = false
    @Published private(set) var phase: VoiceAudioDiagnosticPhase?
    @Published private(set) var results = [VoiceAudioDiagnosticResult]()
    @Published private(set) var message: String?
    @Published private(set) var completed = false
    @Published private(set) var microphoneLevel = 0.0
    @Published private(set) var routeChanges = 0
    @Published private(set) var interruptions = 0
    @Published private(set) var mediaResets = 0
    @Published var speakerHeard: Bool?
    private var task: Task<Void, Never>?
    private var engine: AVAudioEngine?
    private var graph: VoiceAudioGraph?
    private var receiver: VoiceInputReceiver?
    private var sink: AVAudioSinkNode?
    private var encoder: VoicePCMEncoder?
    private var tapInstalled = false
    private var observers = [NSObjectProtocol]()

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.routeChanges += 1
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                    self.cancel(message: "Audio route disconnected. Completed checks are shown below.")
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let began = VoiceAudioStatus.interruptionBegan(note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
            Task { @MainActor in
                guard let self, self.isRunning, began, self.engine?.isRunning == true else { return }
                self.interruptions += 1
                self.cancel(message: "Audio was interrupted. Completed checks are shown below.")
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.mediaResets += 1
                self.cancel(message: "Watch audio service reset. Completed checks are shown below.")
            }
        })
    }

    func run() {
        guard !isRunning else { return }
        guard !AudioRecorderService.shared.isRecording, !WatchVoiceService.shared.isActive else {
            message = "End the meeting recording or voice conversation before testing audio."
            return
        }
        guard let reservation = VoiceAudioDiagnosticReservation.shared.acquire() else { return }
        isRunning = true; completed = false; results = []; phase = nil
        message = nil; speakerHeard = nil; microphoneLevel = 0
        routeChanges = 0; interruptions = 0; mediaResets = 0
        task = Task { [weak self] in
            guard let self else { VoiceAudioDiagnosticReservation.shared.release(reservation); return }
            defer {
                self.stopEngine()
                try? AVAudioSession.sharedInstance().setActive(false)
                VoiceAudioDiagnosticReservation.shared.release(reservation)
                self.isRunning = false; self.phase = nil; self.microphoneLevel = 0; self.task = nil
            }
            let granted = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
            }
            guard !Task.isCancelled else { return }
            guard granted else { self.message = "Microphone access is required for the audio test."; return }
            do {
                for phase in VoiceAudioDiagnosticPhase.allCases {
                    try Task.checkCancellation()
                    guard !AudioRecorderService.shared.isRecording, !WatchVoiceService.shared.isActive else { throw CancellationError() }
                    self.phase = phase
                    let result = try await self.check(phase)
                    self.results.append(result)
                    self.stopEngine()
                    try? AVAudioSession.sharedInstance().setActive(false)
                    // Allow the physical route to settle between independent engines.
                    try await Task.sleep(for: .milliseconds(300))
                }
                self.completed = true
            } catch is CancellationError {
                if self.message == nil { self.message = "Test stopped. Keep the screen awake while testing." }
            } catch {
                // No arbitrary error descriptions enter a diagnostic report.
                self.message = "Audio test stopped. Completed checks are shown below."
            }
        }
    }

    func cancel(message: String = "Test stopped. Completed checks are shown below.") {
        guard isRunning else { return }
        self.message = message
        task?.cancel()
        stopEngine()
        // The task retains its reservation through any pending activation callback.
        // Its defer deactivates the session before releasing the reservation.
    }

    private func check(_ phase: VoiceAudioDiagnosticPhase) async throws -> VoiceAudioDiagnosticResult {
        let session = AVAudioSession.sharedInstance()
        var result = VoiceAudioDiagnosticResult(phase: phase)
        var stage = VoiceAudioStartupStage.configuration
        let meter = DiagnosticAudioMeter()
        do {
            let speakerOnly = phase == .speaker
            let voiceChat = [.voiceMode, .echoTap, .currentVoice, .activeOutput, .standardActivation].contains(phase)
            let echo = [.echoTap, .currentVoice, .activeOutput, .standardActivation].contains(phase)
            let useSink = [.currentVoice, .activeOutput, .standardActivation].contains(phase)
            try session.setCategory(phase == .meeting ? .record : (speakerOnly ? .playback : .playAndRecord),
                                    mode: voiceChat ? .voiceChat : .default, options: [])
            result.before = sessionSnapshot()
            stage = .activation
            if phase == .meeting || phase == .standardActivation || speakerOnly {
                try session.setActive(true)
            } else {
                let active = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                    session.activate(options: []) { active, error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume(returning: active) }
                    }
                }
                guard active else { throw VoiceAudioStartupError(stage: stage) }
            }
            try Task.checkCancellation()
            let engine = AVAudioEngine(); self.engine = engine
            if echo {
                stage = .voiceProcessing
                try engine.inputNode.setVoiceProcessingEnabled(true)
                engine.inputNode.isVoiceProcessingInputMuted = false
            }
            if phase != .meeting {
                stage = .speaker
                let output = engine.outputNode.outputFormat(forBus: 0)
                guard output.sampleRate > 0, output.channelCount > 0 else { throw VoiceAudioStartupError(stage: stage) }
                self.graph = try VoiceAudioGraph(engine: engine)
            }
            if !speakerOnly {
                stage = .microphone
                let hardware = engine.inputNode.inputFormat(forBus: 0)
                let input = engine.inputNode.outputFormat(forBus: 0)
                guard hardware.sampleRate > 0, hardware.channelCount > 0,
                      input.sampleRate > 0, input.channelCount > 0 else { throw VoiceAudioStartupError(stage: stage) }
                stage = .conversion
                if useSink {
                    let receiver = try VoiceInputReceiver(input: input) { meter.consume($0) }
                    self.receiver = receiver; self.sink = receiver.attach(to: engine); receiver.start()
                } else {
                    let encoder = try VoicePCMEncoder(input: input) { meter.consume($0) }
                    self.encoder = encoder
                    engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: input) { buffer, _ in encoder.consume(buffer) }
                    self.tapInstalled = true
                }
                result.before.hardwareInputRate = hardware.sampleRate
                result.before.hardwareInputChannels = hardware.channelCount
                result.before.captureRate = input.sampleRate
                result.before.captureChannels = input.channelCount
                result.before.voiceProcessing = engine.inputNode.isVoiceProcessingEnabled
                result.before.inputMuted = engine.inputNode.isVoiceProcessingInputMuted
            }
            if let graph, phase == .activeOutput || speakerOnly {
                stage = .speaker
                // Select the non-suspending overload: awaiting a looping buffer's
                // completion would never reach engine.start or the microphone checks.
                graph.player.scheduleBuffer(try outputBuffer(tone: speakerOnly), at: nil, options: .loops, completionHandler: nil)
            }
            stage = .engine
            // The meeting probe matches the working recorder's explicit preparation.
            if phase == .meeting { engine.prepare() }
            try engine.start()
            if phase == .activeOutput || speakerOnly { graph?.player.play() }
            result.before = snapshot(engine: engine, speakerOnly: speakerOnly)
            // Poll the local meter without ever retaining packets or queueing audio to UI.
            for _ in 0..<12 {
                try await Task.sleep(for: .milliseconds(250))
                microphoneLevel = meter.values.peak
                guard !AudioRecorderService.shared.isRecording, !WatchVoiceService.shared.isActive else { throw CancellationError() }
            }
            result.after = snapshot(engine: engine, speakerOnly: speakerOnly)
            let statistics = receiver?.statistics ?? encoder?.statistics ?? VoiceCaptureStatistics()
            result.inputFrames = statistics.inputFrames
            result.convertedFrames = statistics.outputFrames
            result.batches = statistics.batches
            result.receiverFailure = statistics.receiverFailure
            result.peakLevel = meter.values.peak
            result.conversionFailed = meter.values.failed
            if let player = graph?.player, let render = player.lastRenderTime,
               let time = player.playerTime(forNodeTime: render) { result.renderedFrames = max(0, time.sampleTime) }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let failure = (error as? VoiceAudioStartupError) ?? VoiceAudioStartupError(stage: stage, underlying: error)
            result.failedStage = failure.stage; result.nativeCode = failure.nativeCode
            result.after = sessionSnapshot(); result.after.engineRunning = engine?.isRunning == true
        }
        return result
    }

    private func outputBuffer(tone: Bool) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24000),
              let channel = buffer.floatChannelData?[0] else { throw VoiceError.audioRoute }
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<24000 {
            // A short, softly faded tone each second. The clock probe is pure silence.
            let fade = min(1, min(Double(index) / 240, Double(6000 - index) / 240))
            channel[index] = tone && index < 6000 ? Float(sin(Double(index) * 2 * .pi * 440 / 24000) * 0.12 * max(0, fade)) : 0
        }
        return buffer
    }

    private func sessionSnapshot() -> VoiceAudioDiagnosticSnapshot {
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
            // Deliberately exclude portName, UID, data source and arbitrary strings.
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
        return result
    }

    private func snapshot(engine: AVAudioEngine, speakerOnly: Bool) -> VoiceAudioDiagnosticSnapshot {
        var result = sessionSnapshot()
        result.engineRunning = engine.isRunning
        if !speakerOnly {
            let hardware = engine.inputNode.inputFormat(forBus: 0), capture = engine.inputNode.outputFormat(forBus: 0)
            result.hardwareInputRate = hardware.sampleRate; result.hardwareInputChannels = hardware.channelCount
            result.captureRate = capture.sampleRate; result.captureChannels = capture.channelCount
            result.voiceProcessing = engine.inputNode.isVoiceProcessingEnabled
            result.inputMuted = engine.inputNode.isVoiceProcessingInputMuted
        }
        if phase != .meeting {
            let output = engine.outputNode.outputFormat(forBus: 0)
            result.outputRate = output.sampleRate; result.outputChannels = output.channelCount
        }
        return result
    }

    private func stopEngine() {
        receiver?.stop(); engine?.stop()
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0); tapInstalled = false }
        receiver?.clearStoppedInput(); graph?.player.stop()
        sink = nil; receiver = nil; encoder = nil; graph = nil; engine = nil
        microphoneLevel = 0
    }
}
