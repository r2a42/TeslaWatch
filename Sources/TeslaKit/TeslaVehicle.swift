#if canImport(CoreBluetooth)
import Foundation

public enum VehicleAction: Equatable {
    case lock
    case unlock
    case openTrunk
    case openFrunk
}

/// Talks to one car over Bluetooth LE using Tesla's Vehicle Command Protocol (VCSEC domain).
/// Everything here runs on the watch; no phone and no network are involved.
public final class TeslaVehicle {
    public let vin: String
    private let key: ClientKey

    /// Hard cap on one connect + handshake + command round trip.
    private let commandDeadline: TimeInterval = 20

    public init(vin: String, key: ClientKey) throws {
        let normalized = vin.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isPlausibleVIN(normalized) else { throw TeslaError.invalidVIN }
        self.vin = normalized
        self.key = key
    }

    public static func isPlausibleVIN(_ vin: String) -> Bool {
        VehicleName.isPlausibleVIN(vin)
    }

    // MARK: Commands

    public func perform(_ action: VehicleAction) async throws {
        let payload: Data
        switch action {
        case .lock: payload = UnsignedMessage.rke(.lock)
        case .unlock: payload = UnsignedMessage.rke(.unlock)
        case .openTrunk: payload = UnsignedMessage.closureMove(.rearTrunk)
        case .openFrunk: payload = UnsignedMessage.closureMove(.frontTrunk)
        }
        try await withLink(deadline: commandDeadline) { link in
            try await link.execute(payload)
        }
    }

    public func status() async throws -> VehicleStatus {
        try await withLink(deadline: commandDeadline) { link in
            try await link.fetchStatus()
        }
    }

    /// Whether the car already trusts this watch's key.
    public func isEnrolled() async throws -> Bool {
        try await withLink(deadline: commandDeadline) { link in
            do {
                try await link.handshake()
                return true
            } catch TeslaError.keyNotEnrolled {
                return false
            }
        }
    }

    // MARK: Enrollment

    /// Asks the car to add this watch's key. The user then taps their NFC key card on the center
    /// console and confirms on the car's screen. Completes once the car trusts the key.
    ///
    /// - Parameter onAwaitingApproval: called once the request has been sent.
    public func enroll(role: EnrollmentRole = .driver, timeout: TimeInterval = 90,
                       onAwaitingApproval: @escaping @Sendable () -> Void = {}) async throws {
        try await withLink(deadline: timeout + 15) { link in
            do {
                try await link.handshake()
                return // already enrolled
            } catch TeslaError.keyNotEnrolled {
                // expected; continue
            }

            let request = UnsignedMessage.addKeyRequest(
                publicKey: self.key.publicKey,
                role: role == .owner ? .owner : .driver,
                formFactor: .iosDevice)
            try await link.transport.send(request)
            onAwaitingApproval()

            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                do {
                    try await link.handshake()
                    return
                } catch TeslaError.keyNotEnrolled {
                    continue
                } catch TeslaError.timeout {
                    continue // car is busy waiting for the card tap
                } catch TeslaError.vehicleFault(let code) where code == 1 || code == 2 {
                    continue // BUSY / TIMEOUT
                }
            }
            throw TeslaError.enrollmentTimedOut
        }
    }

    public enum EnrollmentRole {
        case driver
        case owner
    }

    // MARK: Plumbing

    private func withLink<T>(deadline: TimeInterval, _ body: (VehicleLink) async throws -> T) async throws -> T {
        let link = VehicleLink(vin: vin, key: key)
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
            link.transport.disconnect()
        }
        defer {
            watchdog.cancel()
            link.transport.disconnect()
        }
        try await link.connect()
        return try await body(link)
    }
}

// MARK: - VehicleLink

/// A single connection plus the secure session negotiated over it.
final class VehicleLink {
    let transport = BLETransport()
    private let vin: String
    private let key: ClientKey
    private let routingAddress = VehicleLink.randomBytes(16)
    private var session: SecureSession?

    /// `1 << FLAG_ENCRYPT_RESPONSE`, which the official client sets on every request.
    private static let requestFlags: UInt32 = 1 << 1

    init(vin: String, key: ClientKey) {
        self.vin = vin
        self.key = key
    }

    static func randomBytes(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    func connect() async throws {
        try await transport.connect(advertisedName: VehicleName.advertised(vin: vin), timeout: 10)
    }

    private func newRequest(payload: Payload, uuid: Data = VehicleLink.randomBytes(16)) -> RoutableMessage {
        var message = RoutableMessage()
        message.to = Destination(domain: .vehicleSecurity)
        message.from = Destination(routingAddress: routingAddress)
        message.payload = payload
        message.uuid = uuid
        return message
    }

    /// Next reply addressed to us that satisfies `accept`. Undecodable or unrelated frames are skipped.
    private func nextReply(timeout: TimeInterval, accept: (RoutableMessage) -> Bool = { _ in true }) async throws -> RoutableMessage {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw TeslaError.timeout }
            let raw = try await transport.receive(timeout: remaining)
            guard let message = try? RoutableMessage(serialized: raw),
                  message.to?.routingAddress == routingAddress,
                  accept(message)
            else { continue }
            return message
        }
    }

    // MARK: Handshake

    func handshake() async throws {
        let request = newRequest(payload: .sessionInfoRequest(SessionInfoRequest(publicKey: key.publicKey)))
        try await transport.send(request.serialized())
        let reply = try await nextReply(timeout: 5) { reply in
            if case .sessionInfo? = reply.payload { return true }
            return (reply.status?.fault ?? 0) != 0
        }
        session = try SecureSession.establish(
            clientKey: key, vin: vin, domain: .vehicleSecurity, challenge: request.uuid, response: reply)
    }

    // MARK: Signed commands

    /// Sends an `UnsignedMessage` to VCSEC and waits for the terminal reply, re-syncing the session
    /// or retrying when the car says it is busy.
    func execute(_ plaintext: Data) async throws {
        var resynced = false
        var busyRetries = 0
        while true {
            do {
                if session == nil { try await handshake() }
                try await sendSigned(plaintext)
                return
            } catch let error as TeslaError {
                if error.isSessionDesync, !resynced {
                    resynced = true
                    session = nil
                    continue
                }
                if error == .busy, busyRetries < 3 {
                    busyRetries += 1
                    try await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }
                throw error
            }
        }
    }

    private func sendSigned(_ plaintext: Data) async throws {
        guard let session else { throw TeslaError.protocolError("no session") }
        var request = newRequest(payload: .message(plaintext))
        request.flags = Self.requestFlags
        let (signed, requestHash) = try session.encrypt(request)
        try await transport.send(signed.serialized())

        while true {
            let reply = try await nextReply(timeout: 10)
            if let fault = reply.status?.fault, fault != 0 { throw TeslaError.vehicleFault(fault) }
            let body = try session.decrypt(reply, requestHash: requestHash)
            let fromVCSEC: FromVCSECMessage
            do { fromVCSEC = try FromVCSECMessage(serialized: body) } catch {
                throw TeslaError.protocolError("unreadable reply")
            }
            try Self.checkForError(fromVCSEC)
            // VCSEC sends up to three replies; an empty one (no command status) is the final success.
            if fromVCSEC.commandStatus == nil { return }
        }
    }

    private static func checkForError(_ reply: FromVCSECMessage) throws {
        if let code = reply.nominalError { throw TeslaError.vehicleRefused(code) }
        guard let status = reply.commandStatus else { return }
        switch status.operationStatus {
        case .ok:
            break
        case .wait:
            throw TeslaError.busy
        case .error:
            if let info = status.whitelistOperationStatus?.information, info != 0 {
                throw (info == 3 || info == 4 || info == 18) ? TeslaError.keychainFull : TeslaError.vehicleRefused(info)
            }
            if !status.hasSignedMessageStatus { throw TeslaError.protocolError("unknown vehicle error") }
        }
    }

    // MARK: Status (unauthenticated information request)

    func fetchStatus() async throws -> VehicleStatus {
        let request = newRequest(payload: .message(UnsignedMessage.getStatus))
        try await transport.send(request.serialized())
        while true {
            let reply = try await nextReply(timeout: 5)
            if let fault = reply.status?.fault, fault != 0 { throw TeslaError.vehicleFault(fault) }
            guard let fromVCSEC = try? FromVCSECMessage(serialized: reply.messageBytes) else { continue }
            try Self.checkForError(fromVCSEC)
            if let status = fromVCSEC.vehicleStatus { return status }
        }
    }
}
#endif
