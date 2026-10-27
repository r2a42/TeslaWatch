#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import XCTest
@testable import TeslaKit

// Test keys published in Tesla's protocol.md. The private keys are public, so never enroll
// them on a real car.
private let clientPrivate = Data(hex: "2538CDC29A97C19C1E99A637D6CF4F8C970C118B56EDE1E6323E6D162C4B30DB")
private let vehiclePrivate = Data(hex: "344EE5B466A7CF1EEB12B6F50331DB2E5EC5834EF5F4BEFCFD8CBE55C2528D70")
private let vin = "5YJ30123456789ABC"
private let routing = Data(hex: "2c907bd76c640d360b3027dc7404efde")
private let requestUUID = Data(hex: "1588d5a30eabc6f8fc9a951b11f6fd11")
private let epoch = Data(hex: "4c463f9cc0d3d26906e982ed224adde6")
private let handshakeTime = Date(timeIntervalSince1970: 1_800_000_000)

private var clientKey: SoftwareClientKey { try! SoftwareClientKey(rawRepresentation: clientPrivate) }
private var vehiclePublic: Data {
    try! P256.KeyAgreement.PrivateKey(rawRepresentation: vehiclePrivate).publicKey.x963Representation
}

final class TeslaKitTests: XCTestCase {
    // MARK: Helpers

    private func establishedSession() throws -> SecureSession {
        var reply = RoutableMessage()
        reply.payload = .sessionInfo(Data(hex: Golden.sessionInfo))
        var signature = SignatureData()
        signature.sessionInfoTag = Data(hex: Golden.sessionInfoTag)
        reply.signatureData = signature
        return try SecureSession.establish(
            clientKey: clientKey, vin: vin, domain: .vehicleSecurity, challenge: requestUUID,
            response: reply, receivedAt: handshakeTime)
    }

    private func unlockRequest() -> RoutableMessage {
        var request = RoutableMessage()
        request.to = Destination(domain: .vehicleSecurity)
        request.from = Destination(routingAddress: routing)
        request.payload = .message(Data(hex: Golden.unlockPlaintext))
        request.uuid = requestUUID
        request.flags = 2
        return request
    }

    // MARK: Basics

    func testAdvertisedNameMatchesSpecExample() {
        XCTAssertEqual(VehicleName.advertised(vin: "5YJS0000000000000"), "S1a87a5a75f3df858C")
    }

    func testMetadataSerializationMatchesSpecExample() throws {
        var md = Metadata()
        try md.add(.counter, uint32: 100)
        try md.add(.personalization, Data("abc".utf8))
        XCTAssertEqual(md.serialized().hex, "0203616263050400000064ff")
    }

    func testVINValidation() {
        XCTAssertTrue(VehicleName.isPlausibleVIN("5YJ30123456789ABC"))
        XCTAssertFalse(VehicleName.isPlausibleVIN("5YJ3012345678OABC")) // letter O
        XCTAssertFalse(VehicleName.isPlausibleVIN("5YJ3012345"))
    }

    func testBLEFraming() {
        var buffer = BLEFrameBuffer()
        let a = Data([1, 2, 3, 4, 5])
        let b = Data([9, 9])
        let wire = BLEFrameBuffer.frame(a) + BLEFrameBuffer.frame(b)
        let chunks = BLEFrameBuffer.chunks(of: wire, size: 4)
        XCTAssertGreaterThan(chunks.count, 1)
        var out = [Data]()
        let t = Date()
        for chunk in chunks { out += buffer.append(chunk, now: t) }
        XCTAssertEqual(out, [a, b])
    }

    func testBLEFramingDropsStalePartialMessage() {
        var buffer = BLEFrameBuffer()
        let t = Date()
        _ = buffer.append(Data([0, 5, 1, 2]), now: t)                     // partial
        let out = buffer.append(BLEFrameBuffer.frame(Data([7])), now: t.addingTimeInterval(2))
        XCTAssertEqual(out, [Data([7])])
    }

    // MARK: Crypto against the spec's test vectors

    func testSharedKeyMatchesSpec() throws {
        let secret = try clientKey.sharedSecret(vehiclePublicKey: vehiclePublic)
        let key = SecureSession.sessionKey(sharedSecret: secret)
        XCTAssertEqual(key.withUnsafeBytes { Data($0) }.hex, Golden.k)
    }

    func testSessionInfoTagValidation() throws {
        let secret = try clientKey.sharedSecret(vehiclePublicKey: vehiclePublic)
        let key = SecureSession.sessionKey(sharedSecret: secret)
        let info = Data(hex: Golden.sessionInfo)
        let tag = Data(hex: Golden.sessionInfoTag)
        XCTAssertTrue(try SecureSession.isValidSessionInfoTag(
            key: key, vin: Data(vin.utf8), challenge: requestUUID, encodedInfo: info, tag: tag))

        var forged = tag
        forged[0] ^= 1
        XCTAssertFalse(try SecureSession.isValidSessionInfoTag(
            key: key, vin: Data(vin.utf8), challenge: requestUUID, encodedInfo: info, tag: forged))
        XCTAssertFalse(try SecureSession.isValidSessionInfoTag(
            key: key, vin: Data(vin.utf8), challenge: Data(count: 16), encodedInfo: info, tag: tag))
    }

    func testEstablishRejectsBadTag() throws {
        var reply = RoutableMessage()
        reply.payload = .sessionInfo(Data(hex: Golden.sessionInfo))
        var signature = SignatureData()
        signature.sessionInfoTag = Data(count: 32)
        reply.signatureData = signature
        XCTAssertThrowsError(try SecureSession.establish(
            clientKey: clientKey, vin: vin, domain: .vehicleSecurity, challenge: requestUUID, response: reply))
    }

    func testEstablishReportsUnenrolledKey() {
        var info = ProtoWriter()
        info.varint(5, 1) // SESSION_INFO_STATUS_KEY_NOT_ON_WHITELIST
        var reply = RoutableMessage()
        reply.payload = .sessionInfo(info.data)
        XCTAssertThrowsError(try SecureSession.establish(
            clientKey: clientKey, vin: vin, domain: .vehicleSecurity, challenge: requestUUID, response: reply)) {
            XCTAssertEqual($0 as? TeslaError, .keyNotEnrolled)
        }
    }

    // MARK: Wire format against the Python/official-binding reference

    func testSessionInfoRequestEncoding() {
        var request = RoutableMessage()
        request.to = Destination(domain: .vehicleSecurity)
        request.from = Destination(routingAddress: routing)
        request.payload = .sessionInfoRequest(SessionInfoRequest(publicKey: clientKey.publicKey))
        request.uuid = requestUUID
        XCTAssertEqual(request.serialized().hex, Golden.sessionInfoRequest)
    }

    func testCommandPlaintexts() {
        XCTAssertEqual(UnsignedMessage.rke(.unlock).hex, Golden.unlockPlaintext)
        XCTAssertEqual(UnsignedMessage.rke(.lock).hex, Golden.lockPlaintext)
        XCTAssertEqual(UnsignedMessage.closureMove(.frontTrunk).hex, Golden.frunkPlaintext)
        XCTAssertEqual(UnsignedMessage.closureMove(.rearTrunk).hex, Golden.trunkPlaintext)
    }

    func testAddKeyEnvelope() {
        let envelope = UnsignedMessage.addKeyRequest(
            publicKey: clientKey.publicKey, role: .driver, formFactor: .iosDevice)
        XCTAssertEqual(envelope.hex, Golden.addKeyEnvelope)
    }

    func testSignedUnlockMatchesReference() throws {
        let session = try establishedSession()
        XCTAssertEqual(session.counter, 6)
        let (signed, requestHash) = try session.encrypt(
            unlockRequest(), expiresIn: 5, now: handshakeTime, nonce: Data(hex: "dbf79447fa156674dae1caed"))
        XCTAssertEqual(signed.serialized().hex, Golden.unlockMessage)
        XCTAssertEqual(requestHash.hex, Golden.requestHash)
        XCTAssertEqual(session.counter, 7)
    }

    func testSignedMessageRoundTripsThroughDecoder() throws {
        let session = try establishedSession()
        let (signed, _) = try session.encrypt(unlockRequest(), now: handshakeTime)
        let decoded = try RoutableMessage(serialized: signed.serialized())
        XCTAssertEqual(decoded.signatureData?.aesGCMPersonalized?.counter, 7)
        XCTAssertEqual(decoded.signatureData?.signerPublicKey, clientKey.publicKey)
        XCTAssertEqual(decoded.uuid, requestUUID)
        XCTAssertEqual(decoded.flags, 2)
    }

    // MARK: Responses

    func testDecryptsEmptySuccessReply() throws {
        let session = try establishedSession()
        let reply = try RoutableMessage(serialized: Data(hex: Golden.encryptedResponse))
        let plaintext = try session.decrypt(reply, requestHash: Data(hex: Golden.requestHash))
        let parsed = try FromVCSECMessage(serialized: plaintext)
        XCTAssertNil(parsed.commandStatus)
        XCTAssertNil(parsed.nominalError)
    }

    func testDecryptsWaitReply() throws {
        let session = try establishedSession()
        let reply = try RoutableMessage(serialized: Data(hex: Golden.encryptedResponseWait))
        let plaintext = try session.decrypt(reply, requestHash: Data(hex: Golden.requestHash))
        XCTAssertEqual(try FromVCSECMessage(serialized: plaintext).commandStatus?.operationStatus, .wait)
    }

    func testRejectsReplayedAndMisboundReplies() throws {
        let session = try establishedSession()
        let reply = try RoutableMessage(serialized: Data(hex: Golden.encryptedResponse))
        _ = try session.decrypt(reply, requestHash: Data(hex: Golden.requestHash))
        XCTAssertThrowsError(try session.decrypt(reply, requestHash: Data(hex: Golden.requestHash))) // same counter

        let fresh = try establishedSession()
        var wrongRequest = Data(hex: Golden.requestHash)
        wrongRequest[1] ^= 1
        XCTAssertThrowsError(try fresh.decrypt(reply, requestHash: wrongRequest)) // bound to another request
    }

    func testFromVCSECParsing() throws {
        XCTAssertEqual(try FromVCSECMessage(serialized: Data(hex: Golden.fromVcsecWait)).commandStatus?.operationStatus, .wait)
        let wl = try FromVCSECMessage(serialized: Data(hex: Golden.fromVcsecWlOk)).commandStatus?.whitelistOperationStatus
        XCTAssertEqual(wl?.information, 0)
        XCTAssertEqual(wl?.operationStatus, .ok)
    }
}

// MARK: - Hex

extension Data {
    init(hex: String) {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
