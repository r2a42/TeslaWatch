import Foundation

/// Messages over BLE are preceded by their length as a 2-byte big-endian integer and may be
/// split across several notifications/writes.
struct BLEFrameBuffer {
    /// A partial message is discarded if the next chunk arrives later than this.
    static let rxTimeout: TimeInterval = 1

    private var buffer = [UInt8]()
    private var lastRx: Date?

    /// Appends a received chunk and returns every message completed by it.
    mutating func append(_ chunk: Data, now: Date = Date()) -> [Data] {
        if let lastRx, now.timeIntervalSince(lastRx) > Self.rxTimeout { buffer.removeAll() }
        lastRx = now
        buffer.append(contentsOf: chunk)

        var messages = [Data]()
        while buffer.count >= 2 {
            let length = Int(buffer[0]) << 8 | Int(buffer[1])
            guard buffer.count >= 2 + length else { break }
            messages.append(Data(buffer[2..<2 + length]))
            buffer.removeFirst(2 + length)
        }
        return messages
    }

    static func frame(_ message: Data) -> Data {
        precondition(message.count <= 0xFFFF)
        return Data([UInt8(message.count >> 8), UInt8(message.count & 0xFF)]) + message
    }

    static func chunks(of data: Data, size: Int) -> [Data] {
        precondition(size > 0)
        var out = [Data]()
        var offset = 0
        while offset < data.count {
            let end = min(offset + size, data.count)
            out.append(Data(data[data.startIndex + offset..<data.startIndex + end]))
            offset = end
        }
        return out
    }
}
