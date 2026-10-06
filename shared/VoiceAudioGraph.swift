import AVFoundation

// Keep input in the render graph even before the assistant has scheduled speech.
// Only the reply player is audible; the microphone branch cannot monitor into the speaker.
final class VoiceAudioGraph {
    let player = AVAudioPlayerNode()
    private let microphoneMixer = AVAudioMixerNode()

    init(engine: AVAudioEngine, microphone: AVAudioNode, inputFormat: AVAudioFormat) throws {
        guard let replyFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1) else { throw VoiceError.audioRoute }
        engine.attach(microphoneMixer)
        engine.attach(player)
        microphoneMixer.outputVolume = 0
        engine.connect(microphone, to: microphoneMixer, format: inputFormat)
        engine.connect(microphoneMixer, to: engine.mainMixerNode, fromBus: 0, toBus: 0, format: inputFormat)
        engine.connect(player, to: engine.mainMixerNode, fromBus: 0, toBus: 1, format: replyFormat)
        // Voice processing uses matching input/output I/O formats, independently of reply PCM.
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: inputFormat)
    }
}
