import Foundation

// Hand-written subset of Tesla's universal_message.proto, signatures.proto, vcsec.proto and
// keys.proto. Encoders emit fields in ascending field-number order, as the official bindings do.

enum Domain: Int {
    case broadcast = 0
    case vehicleSecurity = 2
    case infotainment = 3
}

// MARK: - universal_message.proto

struct Destination: Equatable {
    var domain: Domain?
    var routingAddress: Data?

    init(domain: Domain) { self.domain = domain }
    init(routingAddress: Data) { self.routingAddress = routingAddress }

    fileprivate func write(into w: inout ProtoWriter, field: Int) {
        var body = ProtoWriter()
        if let domain { body.varint(1, UInt64(domain.rawValue)) }
        if let routingAddress { body.bytes(2, routingAddress) }
        w.message(field, body)
    }

    init(serialized: Data) throws {
        var r = ProtoReader(serialized)
        while let (field, value) = try r.next() {
            switch field {
            case 1: domain = value.uint64.flatMap { Domain(rawValue: Int($0)) }
            case 2: routingAddress = value.data
            default: break
            }
        }
    }
}

struct SessionInfoRequest: Equatable {
    var publicKey: Data
    var challenge = Data()

    fileprivate func write(into w: inout ProtoWriter, field: Int) {
        var body = ProtoWriter()
        if !publicKey.isEmpty { body.bytes(1, publicKey) }
        if !challenge.isEmpty { body.bytes(2, challenge) }
        w.message(field, body)
    }
}

enum OperationStatus: UInt64 {
    case ok = 0, wait = 1, error = 2
}

struct MessageStatus: Equatable {
    var operationStatus: OperationStatus = .ok
    /// `UniversalMessage.MessageFault_E`. 0 means no fault.
    var fault: UInt32 = 0

    init(serialized: Data) throws {
        var r = ProtoReader(serialized)
        while let (field, value) = try r.next() {
            switch field {
            case 1: operationStatus = value.uint64.flatMap(OperationStatus.init(rawValue:)) ?? .ok
            case 2: fault = value.uint32 ?? 0
            default: break
            }
        }
    }
}

enum Payload: Equatable {
    case message(Data)
    case sessionInfoRequest(SessionInfoRequest)
    case sessionInfo(Data)
}

struct RoutableMessage: Equatable {
    var to: Destination?
    var from: Destination?
    var payload: Payload?
    var signatureData: SignatureData?
    var status: MessageStatus?
    var requestUUID = Data()
    var uuid = Data()
    var flags: UInt32 = 0

    init() {}

    func serialized() -> Data {
        var w = ProtoWriter()
        to?.write(into: &w, field: 6)
        from?.write(into: &w, field: 7)
        switch payload {
        case .message(let data): w.bytes(10, data)
        case .sessionInfoRequest(let req): req.write(into: &w, field: 14)
        case .sessionInfo(let data): w.bytes(15, data)
        case nil: break
        }
        signatureData?.write(into: &w, field: 13)
        if !uuid.isEmpty { w.bytes(51, uuid) }
        if flags != 0 { w.varint(52, UInt64(flags)) }
        return w.data
    }

    init(serialized: Data) throws {
        var r = ProtoReader(serialized)
        while let (field, value) = try r.next() {
            switch field {
            case 6: to = try value.data.map(Destination.init(serialized:))
            case 7: from = try value.data.map(Destination.init(serialized:))
            case 10: payload = value.data.map(Payload.message)
            case 15: payload = value.data.map(Payload.sessionInfo)
            case 13: signatureData = try value.data.map(SignatureData.init(serialized:))
            case 12: status = try value.data.map(MessageStatus.init(serialized:))
            case 50: requestUUID = value.data ?? Data()
            case 51: uuid = value.data ?? Data()
            case 52: flags = value.uint32 ?? 0
            default: break
            }
        }
    }

    /// The payload bytes for `.message` payloads, empty otherwise.
    var messageBytes: Data {
        if case .message(let data) = payload { return data }
        return Data()
    }
}

// MARK: - signatures.proto

struct AESGCMPersonalizedData: Equatable {
    var epoch: Data
    var nonce: Data
    var counter: UInt32
    var expiresAt: UInt32
    var tag: Data
}

struct AESGCMResponseData: Equatable {
    var nonce = Data()
    var counter: UInt32 = 0
    var tag = Data()
}

struct SignatureData: Equatable {
    var signerPublicKey: Data?
    var aesGCMPersonalized: AESGCMPersonalizedData?
    var sessionInfoTag: Data?
    var aesGCMResponse: AESGCMResponseData?

    init() {}

    fileprivate func write(into w: inout ProtoWriter, field: Int) {
        var body = ProtoWriter()
        if let key = signerPublicKey {
            var identity = ProtoWriter()
            identity.bytes(1, key)
            body.message(1, identity)
        }
        if let g = aesGCMPersonalized {
            var gcm = ProtoWriter()
            gcm.bytes(1, g.epoch)
            gcm.bytes(2, g.nonce)
            if g.counter != 0 { gcm.varint(3, UInt64(g.counter)) }
            if g.expiresAt != 0 { gcm.fixed32(4, g.expiresAt) }
            gcm.bytes(5, g.tag)
            body.message(5, gcm)
        }
        w.message(field, body)
    }

    init(serialized: Data) throws {
        var r = ProtoReader(serialized)
        while let (field, value) = try r.next() {
            switch field {
            case 1:
                signerPublicKey = try value.data.flatMap { try ProtoReader.firstValue(of: 1, in: $0) }?.data
            case 6:
                sessionInfoTag = try value.data.flatMap { try ProtoReader.firstValue(of: 1, in: $0) }?.data
            case 5:
                guard let body = value.data else { break }
                var gcm = AESGCMPersonalizedData(epoch: Data(), nonce: Data(), counter: 0, expiresAt: 0, tag: Data())
                var gr = ProtoReader(body)
                while let (f, v) = try gr.next() {
                    switch f {
                    case 1: gcm.epoch = v.data ?? Data()
                    case 2: gcm.nonce = v.data ?? Data()
                    case 3: gcm.counter = v.uint32 ?? 0
                    case 4: gcm.expiresAt = v.uint32 ?? 0
                    case 5: gcm.tag = v.data ?? Data()
                    default: break
                    }
                }
                aesGCMPersonalized = gcm
            case 9:
                guard let body = value.data else { break }
                var resp = AESGCMResponseData()
                var gr = ProtoReader(body)
                while let (f, v) = try gr.next() {
                    switch f {
                    case 1: resp.nonce = v.data ?? Data()
                    case 2: resp.counter = v.uint32 ?? 0
                    case 3: resp.tag = v.data ?? Data()
                    default: break
                    }
                }
                aesGCMResponse = resp
            default: break
            }
        }
    }
}

struct SessionInfo: Equatable {
    enum Status: UInt64 { case ok = 0, keyNotOnWhitelist = 1 }

    var counter: UInt32 = 0
    var publicKey = Data()
    var epoch = Data()
    var clockTime: UInt32 = 0
    var status: Status = .ok

    init(serialized: Data) throws {
        var r = ProtoReader(serialized)
        while let (field, value) = try r.next() {
            switch field {
            case 1: counter = value.uint32 ?? 0
            case 2: publicKey = value.data ?? Data()
            case 3: epoch = value.data ?? Data()
            case 4: clockTime = value.uint32 ?? 0
            case 5: status = value.uint64.flatMap(Status.init(rawValue:)) ?? .ok
            default: break
            }
        }
    }
}

// MARK: - vcsec.proto

enum KeyRole: UInt64 {
    case owner = 2
    case driver = 3
}

enum KeyFormFactor: UInt64 {
    case unknown = 0
    case nfcCard = 1
    case iosDevice = 6
    case androidDevice = 7
    case cloudKey = 9
}

enum RKEAction: UInt64 {
    case unlock = 0
    case lock = 1
    case wakeVehicle = 30
}

enum ClosureMoveType: UInt64 {
    case move = 1
}

enum Closure {
    case rearTrunk
    case frontTrunk

    fileprivate var field: Int {
        switch self {
        case .rearTrunk: return 5
        case .frontTrunk: return 6
        }
    }
}

/// `VCSEC.UnsignedMessage` builders. Only the commands this app sends are covered.
enum UnsignedMessage {
    static func rke(_ action: RKEAction) -> Data {
        // Oneof member: emitted even when the enum value is 0 (unlock).
        var w = ProtoWriter()
        w.varint(2, action.rawValue)
        return w.data
    }

    static func closureMove(_ closure: Closure) -> Data {
        var request = ProtoWriter()
        request.varint(closure.field, ClosureMoveType.move.rawValue)
        var w = ProtoWriter()
        w.message(4, request)
        return w.data
    }

    static let getStatus: Data = {
        var request = ProtoWriter()
        request.varint(1, 0) // INFORMATION_REQUEST_TYPE_GET_STATUS
        var w = ProtoWriter()
        w.message(1, request)
        return w.data
    }()

    /// `VCSEC.ToVCSECMessage` asking the car to enroll `publicKey`. Not wrapped in a
    /// RoutableMessage and not signed: the car asks the user to tap an NFC key card instead.
    static func addKeyRequest(publicKey: Data, role: KeyRole, formFactor: KeyFormFactor) -> Data {
        var key = ProtoWriter()
        key.bytes(1, publicKey)
        var permission = ProtoWriter()
        permission.message(1, key)
        permission.varint(4, role.rawValue)
        var metadata = ProtoWriter()
        metadata.varint(1, formFactor.rawValue)
        var operation = ProtoWriter()
        operation.message(5, permission)   // addKeyToWhitelistAndAddPermissions
        operation.message(6, metadata)     // metadataForKey
        var unsigned = ProtoWriter()
        unsigned.message(16, operation)    // WhitelistOperation

        var signed = ProtoWriter()
        signed.bytes(2, unsigned.data)     // protobufMessageAsBytes
        signed.varint(3, 2)                // SIGNATURE_TYPE_PRESENT_KEY
        var envelope = ProtoWriter()
        envelope.message(1, signed)
        return envelope.data
    }
}

struct WhitelistOperationStatus: Equatable {
    var information: UInt64 = 0
    var operationStatus: OperationStatus = .ok
}

struct CommandStatus: Equatable {
    var operationStatus: OperationStatus = .ok
    var hasSignedMessageStatus = false
    var whitelistOperationStatus: WhitelistOperationStatus?
}

enum LockState: UInt64 {
    case unlocked = 0, locked = 1, internalLocked = 2, selectiveUnlocked = 3
}

public struct VehicleStatus: Equatable {
    public var isLocked: Bool?
    public var frunkOpen: Bool
    public var trunkOpen: Bool
    public var anyDoorOpen: Bool
}

struct FromVCSECMessage: Equatable {
    var commandStatus: CommandStatus?
    var nominalError: UInt64?
    var vehicleStatus: VehicleStatus?

    init() {}

    init(serialized: Data) throws {
        var r = ProtoReader(serialized)
        while let (field, value) = try r.next() {
            switch field {
            case 1: vehicleStatus = try value.data.map(Self.parseVehicleStatus)
            case 4: commandStatus = try value.data.map(Self.parseCommandStatus)
            case 46:
                nominalError = try value.data.flatMap { try ProtoReader.firstValue(of: 1, in: $0) }?.uint64 ?? 0
            default: break
            }
        }
    }

    private static func parseCommandStatus(_ data: Data) throws -> CommandStatus {
        var status = CommandStatus()
        var r = ProtoReader(data)
        while let (field, value) = try r.next() {
            switch field {
            case 1:
                status.operationStatus = value.uint64.flatMap(OperationStatus.init(rawValue:)) ?? .ok
            case 2:
                status.hasSignedMessageStatus = true
            case 3:
                var wl = WhitelistOperationStatus()
                var wr = ProtoReader(value.data ?? Data())
                while let (f, v) = try wr.next() {
                    switch f {
                    case 1: wl.information = v.uint64 ?? 0
                    case 3: wl.operationStatus = v.uint64.flatMap(OperationStatus.init(rawValue:)) ?? .ok
                    default: break
                    }
                }
                status.whitelistOperationStatus = wl
            default: break
            }
        }
        return status
    }

    private static func parseVehicleStatus(_ data: Data) throws -> VehicleStatus {
        var locked: Bool?
        var frunk = false, trunk = false, door = false
        var r = ProtoReader(data)
        while let (field, value) = try r.next() {
            switch field {
            case 1:
                var cr = ProtoReader(value.data ?? Data())
                while let (f, v) = try cr.next() {
                    // CLOSURESTATE_CLOSED = 0; anything else counts as not closed.
                    let open = (v.uint64 ?? 0) != 0
                    switch f {
                    case 1...4: door = door || open
                    case 5: trunk = open
                    case 6: frunk = open
                    default: break
                    }
                }
            case 2:
                if let raw = value.uint64, let state = LockState(rawValue: raw) {
                    locked = (state != .unlocked)
                }
            default: break
            }
        }
        return VehicleStatus(isLocked: locked, frunkOpen: frunk, trunkOpen: trunk, anyDoorOpen: door)
    }
}
