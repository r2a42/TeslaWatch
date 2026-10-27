import Foundation

// Minimal protobuf wire-format codec. The protocol only needs a handful of messages, so this
// avoids a SwiftProtobuf dependency and generated code. Field numbers come from Tesla's .proto
// files (vehicle-command/pkg/protocol/protobuf); tools/reference_vectors.py cross-checks the
// encoder against the official bindings.

enum WireError: Error {
    case truncated
    case malformed
    case unsupportedWireType(UInt64)
}

struct ProtoWriter {
    private var buffer = [UInt8]()

    var data: Data { Data(buffer) }

    private mutating func writeVarint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            buffer.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        buffer.append(UInt8(v))
    }

    mutating func varint(_ field: Int, _ value: UInt64) {
        writeVarint(UInt64(field) << 3)
        writeVarint(value)
    }

    mutating func fixed32(_ field: Int, _ value: UInt32) {
        writeVarint(UInt64(field) << 3 | 5)
        for shift in stride(from: 0, to: 32, by: 8) {
            buffer.append(UInt8((value >> UInt32(shift)) & 0xFF))
        }
    }

    mutating func bytes(_ field: Int, _ value: Data) {
        writeVarint(UInt64(field) << 3 | 2)
        writeVarint(UInt64(value.count))
        buffer.append(contentsOf: value)
    }

    mutating func message(_ field: Int, _ body: ProtoWriter) {
        bytes(field, body.data)
    }
}

struct ProtoReader {
    enum Value {
        case varint(UInt64)
        case fixed32(UInt32)
        case fixed64(UInt64)
        case bytes(Data)

        var uint64: UInt64? {
            switch self {
            case .varint(let v), .fixed64(let v): return v
            case .fixed32(let v): return UInt64(v)
            case .bytes: return nil
            }
        }

        var uint32: UInt32? { uint64.flatMap { UInt32(truncatingIfNeeded: $0) } }
        var data: Data? { if case .bytes(let d) = self { return d } else { return nil } }
    }

    private let buffer: [UInt8]
    private var pos = 0

    init(_ data: Data) { buffer = [UInt8](data) }

    private mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard pos < buffer.count else { throw WireError.truncated }
            guard shift < 64 else { throw WireError.malformed }
            let byte = buffer[pos]
            pos += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    private mutating func readFixed(_ count: Int) throws -> UInt64 {
        guard pos + count <= buffer.count else { throw WireError.truncated }
        var result: UInt64 = 0
        for i in 0..<count {
            result |= UInt64(buffer[pos + i]) << UInt64(8 * i)
        }
        pos += count
        return result
    }

    /// Returns the next (field number, value) pair, or nil at the end of the message.
    mutating func next() throws -> (field: Int, value: Value)? {
        guard pos < buffer.count else { return nil }
        let key = try readVarint()
        let field = Int(truncatingIfNeeded: key >> 3)
        switch key & 7 {
        case 0:
            return (field, .varint(try readVarint()))
        case 1:
            return (field, .fixed64(try readFixed(8)))
        case 2:
            guard let length = Int(exactly: try readVarint()), length <= buffer.count - pos else {
                throw WireError.truncated
            }
            let slice = Data(buffer[pos..<pos + length])
            pos += length
            return (field, .bytes(slice))
        case 5:
            return (field, .fixed32(UInt32(try readFixed(4))))
        default:
            throw WireError.unsupportedWireType(key & 7)
        }
    }
}

extension ProtoReader {
    /// The first value with the given field number in an encoded message, if any.
    static func firstValue(of field: Int, in data: Data) throws -> Value? {
        var reader = ProtoReader(data)
        while let (f, v) = try reader.next() {
            if f == field { return v }
        }
        return nil
    }
}
