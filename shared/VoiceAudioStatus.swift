import AVFoundation
import Foundation

// Local counters distinguish an absent hardware callback from conversion or delivery failures.
struct VoiceCaptureStatistics: Sendable {
    var inputFrames: Int64 = 0
    var outputFrames: Int64 = 0
    var batches = 0
    var receiverFailure: UInt32 = 0
    var drainedFrames: Int64 = 0
    var pendingFrames = 0
    var conversionErrors = 0
    var converterStatus = 0
    var converterCode: Int?

    var startupFailure: String? {
        if receiverFailure == 1 {
            return "Watch audio capture could not keep up (CAP-01). Start a new conversation."
        }
        if receiverFailure != 0 {
            return "Watch microphone format changed during capture (CAP-02). Start a new conversation."
        }
        guard batches == 0 else { return nil }
        if inputFrames == 0 {
            return "Watch audio capture did not start (MIC-01). Microphone permission is allowed. Start a new conversation."
        }
        if conversionErrors > 0 {
            return "Watch microphone audio conversion failed (PCM-01). Start a new conversation."
        }
        if outputFrames > 0 && outputFrames < 4800 {
            return "Watch capture stopped before a full audio batch arrived (MIC-02). Start a new conversation."
        }
        if drainedFrames == 0 {
            return "Watch microphone samples did not reach the audio worker (CAP-03). Start a new conversation."
        }
        return "Watch microphone conversion produced no audio (PCM-02). Start a new conversation."
    }
}

enum VoiceAudioStatus {
    static func interruptionBegan(_ rawType: UInt?) -> Bool {
        rawType == AVAudioSession.InterruptionType.began.rawValue
    }

    // Local display only; no audio or levels are persisted or logged.
    static func microphoneLevel(_ pcm: Data) -> Double {
        guard !pcm.isEmpty, pcm.count % 2 == 0 else { return 0 }
        let energy = pcm.withUnsafeBytes { raw -> Double in
            var total = 0.0
            for index in stride(from: 0, to: raw.count, by: 2) {
                let value = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index, as: Int16.self))) / 32768
                total += value * value
            }
            return total / Double(raw.count / 2)
        }
        return min(1, sqrt(energy) * 6)
    }
}
