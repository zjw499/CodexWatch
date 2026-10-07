import Foundation

// Diagnostic data contains counters and known audio route types only. It is kept
// in memory on the Watch; no microphone samples, identifiers or error payloads.
enum VoiceAudioDiagnosticPhase: String, CaseIterable, Identifiable, Hashable, Sendable {
    // Run the actual conversation audio implementation before comparison profiles
    // can warm up the route. This is local capture only, without a provider session.
    case production = "N"
    case meeting = "M"
    case duplex = "D"
    case voiceMode = "V"
    case echoTap = "E"
    case currentVoice = "R"
    case activeOutput = "A"
    case standardActivation = "S"
    case speaker = "P"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .production: return "Normal voice microphone"
        case .meeting: return "Meeting microphone"
        case .duplex: return "Two-way microphone"
        case .voiceMode: return "Voice chat mode"
        case .echoTap: return "Echo processing"
        case .currentVoice: return "Original voice input"
        case .activeOutput: return "Active output clock"
        case .standardActivation: return "Standard activation"
        case .speaker: return "Speaker tone"
        }
    }
}

struct VoiceAudioDiagnosticSnapshot: Sendable {
    var engineRunning = false
    var category = "Unknown"
    var mode = "Unknown"
    var inputPorts = [String]()
    var outputPorts = [String]()
    var hardwareInputRate = 0.0
    var hardwareInputChannels: UInt32 = 0
    var captureRate = 0.0
    var captureChannels: UInt32 = 0
    var outputRate = 0.0
    var outputChannels: UInt32 = 0
    var voiceProcessing = false
    var inputMuted = false
    var outputVolume: Float = 0
}

struct VoiceAudioDiagnosticResult: Identifiable, Sendable {
    let phase: VoiceAudioDiagnosticPhase
    var id: String { phase.id }
    var before = VoiceAudioDiagnosticSnapshot()
    var after = VoiceAudioDiagnosticSnapshot()
    var inputFrames: Int64 = 0
    var convertedFrames: Int64 = 0
    var batches = 0
    var receiverFailure: UInt32 = 0
    var conversionFailed = false
    var peakLevel = 0.0
    var renderedFrames: Int64 = 0
    var failedStage: VoiceAudioStartupStage?
    var nativeCode: Int?

    var capturedAudio: Bool {
        inputFrames > 0 && batches > 0 && receiverFailure == 0 && !conversionFailed && failedStage == nil
    }
    // A concise line allows the whole microphone comparison to fit in one photo.
    var marker: String {
        if failedStage != nil { return "error" }
        if before.engineRunning && !after.engineRunning { return "stopped" }
        if phase == .speaker { return renderedFrames > 0 ? "rendered" : "0" }
        if receiverFailure != 0 { return "CAP" }
        if inputFrames == 0 { return "0" }
        return capturedAudio ? "+" : "PCM"
    }
    var failureCode: String? {
        guard let failedStage else { return nil }
        return failedStage.rawValue + (nativeCode.map { ", Apple \($0)" } ?? "")
    }
}

enum VoiceAudioDiagnosticFinding: String, Sendable {
    case incomplete = "TEST-00"
    case currentWorks = "TEST-01"
    case conversion = "TEST-02"
    case outputClock = "TEST-03"
    case activation = "TEST-04"
    case receiver = "TEST-05"
    case echoProcessing = "TEST-06"
    case voiceMode = "TEST-07"
    case duplex = "TEST-08"
    case baseline = "TEST-09"
    case engineStopped = "TEST-10"
    case sessionChanged = "TEST-11"
    case silentInput = "TEST-12"
    case productionOnly = "TEST-13"

    var message: String {
        switch self {
        case .incomplete: return "Test stopped before all checks finished. Keep the screen awake and run again."
        case .currentWorks: return "Normal voice supplied microphone batches here. Investigate the live conversation launch and lifecycle."
        case .conversion: return "Normal voice received samples but conversion or buffering failed."
        case .outputClock: return "The output-clock comparison captured audio; normal voice did not. Inspect the N check details."
        case .activation: return "The standard-activation comparison captured audio; normal voice did not."
        case .receiver: return "The echo tap captured audio; normal voice did not."
        case .echoProcessing: return "Voice chat captured audio before echo processing was enabled."
        case .voiceMode: return "Two-way audio captured samples; voice chat mode did not."
        case .duplex: return "Meeting capture worked; two-way voice capture did not."
        case .baseline: return "The local meeting microphone check failed too. Inspect its error and route details."
        case .engineStopped: return "The normal voice engine stopped during its microphone check."
        case .sessionChanged: return "The normal voice session or audio route changed during capture."
        case .silentInput: return "Normal voice supplied only silent samples. Check the input mute and route details."
        case .productionOnly: return "A later comparison captured audio but normal voice did not. Inspect the N check; later success does not prove normal startup works."
        }
    }

    static func evaluate(_ results: [VoiceAudioDiagnosticResult]) -> Self {
        // Cancelled or partial runs cannot establish a configuration difference.
        guard Set(results.map(\.phase)) == Set(VoiceAudioDiagnosticPhase.allCases),
              results.count == VoiceAudioDiagnosticPhase.allCases.count else { return .incomplete }
        func result(_ phase: VoiceAudioDiagnosticPhase) -> VoiceAudioDiagnosticResult {
            results.first { $0.phase == phase }!
        }
        let current = result(.production)
        if current.before.engineRunning && !current.after.engineRunning { return .engineStopped }
        if current.before.engineRunning && (current.before.category != current.after.category || current.before.mode != current.after.mode ||
            current.before.inputPorts != current.after.inputPorts || current.before.outputPorts != current.after.outputPorts) { return .sessionChanged }
        if current.capturedAudio { return current.peakLevel == 0 ? .silentInput : .currentWorks }
        if current.inputFrames > 0 { return .conversion }
        if result(.currentVoice).capturedAudio { return .productionOnly }
        if result(.activeOutput).capturedAudio { return .outputClock }
        if result(.standardActivation).capturedAudio { return .activation }
        if result(.echoTap).capturedAudio { return .receiver }
        if result(.voiceMode).capturedAudio { return .echoProcessing }
        if result(.duplex).capturedAudio { return .voiceMode }
        if result(.meeting).capturedAudio { return .duplex }
        return .baseline
    }
}

// A cancelled asynchronous activation keeps this reservation until its callback
// finishes, so it cannot deactivate a newer recording or conversation.
@MainActor
final class VoiceAudioDiagnosticReservation {
    static let shared = VoiceAudioDiagnosticReservation()
    private var owner: UUID?
    var isHeld: Bool { owner != nil }
    func acquire() -> UUID? {
        guard owner == nil else { return nil }
        let token = UUID(); owner = token; return token
    }
    func release(_ token: UUID) {
        guard owner == token else { return }
        owner = nil
    }
}
