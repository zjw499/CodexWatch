import AVFoundation
import Foundation

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
