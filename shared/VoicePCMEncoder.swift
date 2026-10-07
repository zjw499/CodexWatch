import AVFoundation
import Foundation

// Converts live input to mono PCM16/24 kHz in 200 ms batches. Nothing is written to disk.
final class VoicePCMEncoder: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private let lock = NSLock()
    private var pending = Data()
    private var counters = VoiceCaptureStatistics()
    private let deliver: @Sendable (Data?) -> Void

    init(input: AVAudioFormat, deliver: @escaping @Sendable (Data?) -> Void) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1),
              let converter = AVAudioConverter(from: input, to: format) else { throw VoiceError.audioConversion }
        self.format = format
        self.converter = converter
        self.deliver = deliver
        // Live buffers have no preceding frames available for converter priming.
        converter.primeMethod = .none
    }

    var statistics: VoiceCaptureStatistics {
        lock.lock(); defer { lock.unlock() }
        return counters
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        counters.inputFrames += Int64(buffer.frameLength)
        counters.drainedFrames += Int64(buffer.frameLength)
        guard buffer.frameLength > 0 else { return }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 24000 / buffer.format.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            counters.conversionErrors += 1; deliver(nil); return
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true; inputStatus.pointee = .haveData; return buffer
        }
        counters.converterStatus = Int(status.rawValue)
        counters.converterCode = error.map { $0.code }
        guard status != .error, error == nil, let channel = output.floatChannelData?[0] else {
            counters.conversionErrors += 1; deliver(nil); return
        }
        counters.outputFrames += Int64(output.frameLength)
        var samples = [Int16](repeating: 0, count: Int(output.frameLength))
        for i in samples.indices {
            let value = channel[i].isFinite ? max(-1, min(1, channel[i])) : 0
            samples[i] = Int16((value * 32767).rounded()).littleEndian
        }
        samples.withUnsafeBytes { pending.append(contentsOf: $0) }
        while pending.count >= 9600 {
            counters.batches += 1
            deliver(Data(pending.prefix(9600)))
            pending.removeFirst(9600)
        }
        counters.pendingFrames = pending.count / 2
    }
}
