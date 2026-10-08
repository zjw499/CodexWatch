import AVFoundation
import Foundation

// The sink copies into preallocated memory on the audio thread. A separate serial
// queue performs conversion and delivery, with a fixed upper bound on buffered input.
final class VoiceInputReceiver: @unchecked Sendable {
    static let maximumFrames: AVAudioFrameCount = 8192
    private let ring: OpaquePointer
    private let buffer: AVAudioPCMBuffer
    private let encoder: VoicePCMEncoder
    private let deliver: @Sendable (Data?) -> Void
    private let queue = DispatchQueue(label: "scribe.voice.input", qos: .userInitiated)
    // Only accessed on queue.
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var reportedFailure = false

    init(input: AVAudioFormat, slots: UInt32 = 16, deliver: @escaping @Sendable (Data?) -> Void) throws {
        let buffers = input.isInterleaved ? 1 : input.channelCount
        let channelsPerBuffer = input.isInterleaved ? input.channelCount : 1
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: Self.maximumFrames),
              let ring = SPVoiceCaptureRingCreate(buffers, channelsPerBuffer,
                  input.streamDescription.pointee.mBytesPerFrame, Self.maximumFrames, slots) else { throw VoiceError.audioConversion }
        self.ring = ring
        self.buffer = buffer
        self.deliver = deliver
        do { self.encoder = try VoicePCMEncoder(input: input, deliver: deliver) }
        catch { SPVoiceCaptureRingDestroy(ring); throw error }
    }

    deinit { timer?.cancel(); SPVoiceCaptureRingDestroy(ring) }

    var statistics: VoiceCaptureStatistics {
        var result = encoder.statistics
        result.inputFrames = Int64(SPVoiceCaptureRingReceivedFrames(ring))
        result.receiverFailure = SPVoiceCaptureRingFault(ring)
        return result
    }

    // Called exclusively by the audio sink's single producer. No allocation,
    // conversion, lock, dispatch or network access is allowed here.
    func receive(frames: AVAudioFrameCount, from input: UnsafePointer<AudioBufferList>) {
        SPVoiceCaptureRingWrite(ring, frames, input)
    }

    func attach(to engine: AVAudioEngine) -> AVAudioSinkNode {
        let sink = AVAudioSinkNode { [self] _, frames, list in
            receive(frames: frames, from: list)
            return 0
        }
        engine.attach(sink)
        engine.connect(engine.inputNode, to: sink, format: buffer.format)
        return sink
    }

    func start() {
        queue.sync {
            guard !stopped, timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.drainOnQueue() }
            self.timer = timer
            timer.resume()
        }
    }

    // Also used by deterministic tests to exercise the same worker path.
    func drain() { queue.sync { drainOnQueue() } }

    private func drainOnQueue() {
        guard !stopped, !reportedFailure else { return }
        if SPVoiceCaptureRingFault(ring) != 0 {
            reportedFailure = true; deliver(nil); return
        }
        while !stopped {
            // Reset destination capacity after the previous (possibly smaller) callback.
            buffer.frameLength = buffer.frameCapacity
            let frames = SPVoiceCaptureRingRead(ring, buffer.mutableAudioBufferList)
            guard frames > 0 else { break }
            buffer.frameLength = frames
            encoder.consume(buffer)
        }
        if SPVoiceCaptureRingFault(ring) != 0, !reportedFailure {
            reportedFailure = true; deliver(nil)
        }
    }

    func stop() {
        SPVoiceCaptureRingStop(ring)
        queue.sync {
            stopped = true
            timer?.cancel(); timer = nil
            buffer.frameLength = buffer.frameCapacity
            for audio in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                if let data = audio.mData { memset(data, 0, Int(audio.mDataByteSize)) }
            }
        }
    }

    // Engine.stop must precede this call, so the producer cannot still be writing.
    func clearStoppedInput() { queue.sync { SPVoiceCaptureRingClear(ring) } }
}
