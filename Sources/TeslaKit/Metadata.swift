import Foundation

enum SignatureTag: UInt8 {
    case signatureType = 0
    case domain = 1
    case personalization = 2
    case epoch = 3
    case expiresAt = 4
    case counter = 5
    case challenge = 6
    case flags = 7
    case requestHash = 8
    case fault = 9
}

enum SignatureType: UInt8 {
    case aesGCMPersonalized = 5
    case hmac = 6
    case hmacPersonalized = 8
    case aesGCMResponse = 9
}

/// Tag-length-value metadata that gets bound into every MAC and AES-GCM tag.
/// See "Metadata serialization" in protocol.md.
struct Metadata {
    private var items: [(tag: UInt8, value: Data)] = []

    mutating func add(_ tag: SignatureTag, _ value: Data) throws {
        guard value.count <= 255 else { throw TeslaError.protocolError("metadata value too long") }
        items.append((tag.rawValue, value))
    }

    mutating func add(_ tag: SignatureTag, byte: UInt8) throws {
        try add(tag, Data([byte]))
    }

    mutating func add(_ tag: SignatureTag, uint32 value: UInt32) throws {
        try add(tag, Data([UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]))
    }

    /// Items sorted by tag, each as tag || length || value, terminated by 0xFF.
    func serialized() -> Data {
        var out = Data()
        for item in items.sorted(by: { $0.tag < $1.tag }) {
            out.append(item.tag)
            out.append(UInt8(item.value.count))
            out.append(item.value)
        }
        out.append(0xFF)
        return out
    }
}
