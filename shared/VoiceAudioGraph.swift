import AVFoundation

// Assistant playback is independent of microphone capture. The input connects
// directly to an AVAudioSinkNode and never enters the audible output graph.
final class VoiceAudioGraph {
    let player = AVAudioPlayerNode()
    private let outputClock: AVAudioPlayerNode?

    init(engine: AVAudioEngine, keepOutputActive: Bool = false) throws {
        guard let replyFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1) else { throw VoiceError.audioRoute }
        outputClock = keepOutputActive ? AVAudioPlayerNode() : nil
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: replyFormat)
        // Keep the engine's automatic main-mixer/output connection. Microphone and
        // speaker routes can have different rates or channel counts, especially on Watch.
        // The mixer converts reply PCM without overriding hardware output.
        if let outputClock {
            guard let silence = AVAudioPCMBuffer(pcmFormat: replyFormat, frameCapacity: 24000),
                  let samples = silence.floatChannelData?[0] else { throw VoiceError.audioRoute }
            silence.frameLength = silence.frameCapacity
            samples.update(repeating: 0, count: Int(silence.frameLength))
            engine.attach(outputClock)
            engine.connect(outputClock, to: engine.mainMixerNode, format: replyFormat)
            // Render zero samples rather than muting the node. The physical A probe
            // restored capture with active output before any assistant reply.
            outputClock.scheduleBuffer(silence, at: nil, options: .loops, completionHandler: nil)
        }
    }

    func startOutputClock() { outputClock?.play() }
    func stopOutputClock() { outputClock?.stop() }

    var outputClockFrames: Int64 {
        guard let outputClock, let render = outputClock.lastRenderTime,
              let time = outputClock.playerTime(forNodeTime: render) else { return 0 }
        return max(0, time.sampleTime)
    }
}
