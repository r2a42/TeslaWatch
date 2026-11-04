#if canImport(CoreBluetooth)
import Foundation

/// The only commands this library can send. It is for retrieving things from the car (locking, unlocking,
/// opening the trunk or frunk), not for driving. There is deliberately no start, remote drive or keyless
/// driving command, and none should be added.
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
    private let activeLock = NSLock()
    private var activeLink: VehicleLink?
    private var cancelRequested = false
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
        // Trunk and frunk moves toggle, so a second send after a "wait" reply could undo the first.
        let repeatable = (action == .lock || action == .unlock)
        try await withLink(deadline: commandDeadline) { link in
            try await link.execute(payload, retryWhenBusy: repeatable)
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
            let started = Date()
            func elapsed() -> String { String(format: "+%.1fs", Date().timeIntervalSince(started)) }
            TeslaLog.log("Enroll: start (role \(role), timeout \(Int(timeout))s)")
            do {
                try await link.handshake()
                TeslaLog.log("Enroll: already enrolled, nothing to do")
                return // already enrolled
            } catch TeslaError.keyNotEnrolled {
                TeslaLog.log("Enroll: key not on the car yet (expected), sending add-key request")
            }

            let request = UnsignedMessage.addKeyRequest(
                publicKey: self.key.publicKey,
                role: role == .owner ? .owner : .driver,
                formFactor: .iosDevice)
            try await link.transport.send(request)
            TeslaLog.log("Enroll: add-key request sent (\(request.count)B) \(elapsed()); waiting for card tap and car confirmation")
            onAwaitingApproval()

            let deadline = Date().addingTimeInterval(timeout)
            var poll = 0
            while Date() < deadline {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                poll += 1
                TeslaLog.log("Enroll: poll #\(poll) \(elapsed())")
                do {
                    try await link.handshake()
                    TeslaLog.log("Enroll: key accepted after \(poll) polls \(elapsed())")
                    return
                } catch TeslaError.keyNotEnrolled {
                    TeslaLog.log("Enroll: poll #\(poll): not enrolled yet")
                    continue
                } catch TeslaError.timeout {
                    TeslaLog.log("Enroll: poll #\(poll): no reply (car busy waiting for the card tap?)")
                    continue
                } catch TeslaError.vehicleFault(let code) where code == 1 || code == 2 {
                    TeslaLog.log("Enroll: poll #\(poll): car busy/timeout fault \(code)")
                    continue
                } catch TeslaError.protocolError("session info authentication failed") {
                    TeslaLog.log("Enroll: poll #\(poll): unauthenticated session info; retrying")
                    continue
                }
            }
            TeslaLog.log("Enroll: gave up after \(poll) polls \(elapsed())")
            throw TeslaError.enrollmentTimedOut
        }
    }

    public enum EnrollmentRole {
        case driver
        case owner
    }

    // MARK: Plumbing

    /// Drops the current connection so a stuck operation, such as waiting for pairing approval, ends now.
    public func cancel() {
        activeLock.lock()
        cancelRequested = true
        let link = activeLink
        activeLock.unlock()
        TeslaLog.log("Vehicle: cancel requested (link active: \(link != nil))")
        link?.transport.disconnect()
    }

    private func withLink<T>(deadline: TimeInterval, _ body: (VehicleLink) async throws -> T) async throws -> T {
        let link = VehicleLink(vin: vin, key: key)
        activeLock.lock()
        cancelRequested = false
        activeLink = link
        activeLock.unlock()
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
            link.transport.disconnect()
        }
        defer {
            watchdog.cancel()
            link.transport.disconnect()
            activeLock.lock()
            activeLink = nil
            activeLock.unlock()
        }
        TeslaLog.log("Vehicle: opening link")
        do {
            try await link.connect()
            let result = try await body(link)
            TeslaLog.log("Vehicle: done")
            return result
        } catch {
            activeLock.lock()
            let wasCancelled = cancelRequested
            activeLock.unlock()
            if wasCancelled {
                TeslaLog.log("Vehicle: cancelled (underlying: \(error.localizedDescription))")
                throw TeslaError.cancelled
            }
            TeslaLog.log("Vehicle: failed: \(error.localizedDescription) [\(error)]")
            throw error
        }
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
    private func nextReply(timeout: TimeInterval, requestUUID: Data? = nil,
                           accept: (RoutableMessage) -> Bool = { _ in true }) async throws -> RoutableMessage {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw TeslaError.timeout }
            let raw = try await transport.receive(timeout: remaining)
            guard let message = try? RoutableMessage(serialized: raw) else {
                TeslaLog.log("Vehicle: rx \(raw.count)B undecodable: \(raw.hexPreview())")
                continue
            }
            TeslaLog.log("Vehicle: rx \(raw.count)B \(message.logSummary) hex=\(raw.hexPreview())")
            guard message.to?.routingAddress == routingAddress else {
                TeslaLog.log("Vehicle: skipped (not addressed to this client)")
                continue
            }
            if let requestUUID, !message.requestUUID.isEmpty, message.requestUUID != requestUUID {
                TeslaLog.log("Vehicle: skipped stale reply (answers \(message.requestUUID.shortHex), waiting for \(requestUUID.shortHex))")
                continue
            }
            guard accept(message) else {
                TeslaLog.log("Vehicle: skipped (not the awaited reply)")
                continue
            }
            return message
        }
    }

    // MARK: Handshake

    func handshake() async throws {
        let request = newRequest(payload: .sessionInfoRequest(SessionInfoRequest(publicKey: key.publicKey)))
        TeslaLog.log("Vehicle: handshake, request uuid \(request.uuid.shortHex)")
        try await transport.send(request.serialized())
        let reply = try await nextReply(timeout: 5, requestUUID: request.uuid) { reply in
            if case .sessionInfo? = reply.payload { return true }
            return (reply.status?.fault ?? 0) != 0
        }
        session = try SecureSession.establish(
            clientKey: key, vin: vin, domain: .vehicleSecurity, challenge: request.uuid, response: reply)
        TeslaLog.log("Vehicle: session established")
    }

    // MARK: Signed commands

    /// Sends an `UnsignedMessage` to VCSEC and waits for the terminal reply, re-syncing the session
    /// or retrying when the car says it is busy.
    func execute(_ plaintext: Data, retryWhenBusy: Bool = true) async throws {
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
                if error == .busy, retryWhenBusy, busyRetries < 3 {
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
            let reply = try await nextReply(timeout: 10, requestUUID: request.uuid)
            if let fault = reply.status?.fault, fault != 0 { throw TeslaError.vehicleFault(fault) }
            // We asked for encrypted replies, so one without the encryption data didn't come from our session.
            guard reply.signatureData?.aesGCMResponse != nil else {
                TeslaLog.log("Vehicle: skipped an unauthenticated command reply")
                continue
            }
            let body = try session.decrypt(reply, requestHash: requestHash)
            let fromVCSEC: FromVCSECMessage
            do { fromVCSEC = try FromVCSECMessage(serialized: body) } catch {
                TeslaLog.log("Vehicle: undecodable command reply (\(body.count)B)")
                throw TeslaError.protocolError("unreadable reply")
            }
            TeslaLog.log("Vehicle: command reply: \(fromVCSEC.logSummary)")
            try Self.checkForError(fromVCSEC)
            // VCSEC sends up to three replies; an empty one (no command status) is the final success.
            if fromVCSEC.commandStatus == nil { return }
        }
    }

    private static func checkForError(_ reply: FromVCSECMessage) throws {
        if let code = reply.nominalError, code != 0 { throw TeslaError.vehicleRefused(code) }
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
            TeslaLog.log("Vehicle: status reply: \(fromVCSEC.logSummary) hex=\(reply.messageBytes.hexPreview())")
            try Self.checkForError(fromVCSEC)
            if let status = fromVCSEC.vehicleStatus { return status }
        }
    }
}
#endif
