import Foundation

enum VoiceAudioStartupStage: String, CaseIterable, Sendable {
    case configuration = "SESSION-01"
    case activation = "SESSION-02"
    case voiceProcessing = "ECHO-01"
    case microphone = "INPUT-01"
    case speaker = "OUTPUT-01"
    case conversion = "PCM-01"
    case engine = "START-01"

    var action: String {
        switch self {
        case .configuration: return "configuring two-way audio"
        case .activation: return "activating Watch audio"
        case .voiceProcessing: return "preparing echo cancellation"
        case .microphone: return "opening the microphone"
        case .speaker: return "opening the speaker"
        case .conversion: return "preparing microphone audio"
        case .engine: return "starting the microphone and speaker"
        }
    }
}

// Only a local stage and numeric Apple code reach the UI. Never include NSError
// descriptions, userInfo, audio, provider payloads, credentials or route/device names.
struct VoiceAudioStartupError: LocalizedError {
    let stage: VoiceAudioStartupStage
    let nativeCode: Int?

    init(stage: VoiceAudioStartupStage, underlying: Error? = nil) {
        self.stage = stage
        nativeCode = underlying.map { ($0 as NSError).code }
    }

    var errorDescription: String? {
        let reason = nativeCode == -308 ? "Watch audio service stopped" : "Watch audio failed"
        let code = nativeCode.map { ", Apple \($0)" } ?? ""
        return "\(reason) while \(stage.action) (\(stage.rawValue)\(code)). Start a new conversation."
    }
}
