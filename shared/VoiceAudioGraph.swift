import AVFoundation

// Assistant playback is independent of microphone capture. The input connects
// directly to an AVAudioSinkNode and never enters the audible output graph.
final class VoiceAudioGraph {
    let player = AVAudioPlayerNode()

    init(engine: AVAudioEngine) throws {
        guard let replyFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1) else { throw VoiceError.audioRoute }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: replyFormat)
        // Keep the engine's automatic main-mixer/output connection. Microphone and
        // speaker routes can have different rates or channel counts, especially on Watch.
        // The mixer converts reply PCM without overriding hardware output.
    }
}
