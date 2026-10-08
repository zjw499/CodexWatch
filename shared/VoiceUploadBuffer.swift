import Foundation

// Brief relay/network stalls must not kill a healthy conversation. Keep at most
// eight seconds in memory, and send 400 ms to one second per serial request.
struct VoiceUploadBuffer {
    static let limit = 8 * 48000
    static let minimumBatchBytes = 19200
    private var packets = [Data]()
    private(set) var bytes = 0
    private(set) var peakBytes = 0
    var isEmpty: Bool { packets.isEmpty }
    mutating func append(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count % 2 == 0, data.count <= 48000, bytes + data.count <= Self.limit else { return false }
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
