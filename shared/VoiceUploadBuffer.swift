import Foundation

// Keep capture bounded while combining backlog into at most one second per
// request. Serial HTTP acknowledgements need not arrive every 200 ms.
struct VoiceUploadBuffer {
    private var packets = [Data]()
    private(set) var bytes = 0
    private(set) var peakBytes = 0
    var isEmpty: Bool { packets.isEmpty }
    mutating func append(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count % 2 == 0, data.count <= 48000, bytes + data.count <= 96000 else { return false }
        packets.append(data); bytes += data.count; peakBytes = max(peakBytes, bytes)
        return true
    }
    mutating func take() -> Data? {
        guard !packets.isEmpty else { return nil }
        var result = Data()
        while let packet = packets.first, result.count + packet.count <= 48000 {
            result.append(packets.removeFirst()); bytes -= packet.count
        }
        return result
    }
    mutating func clear() { packets = []; bytes = 0 }
}
