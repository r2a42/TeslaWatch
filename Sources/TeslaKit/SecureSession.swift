#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Authenticated session with one vehicle domain (here: VCSEC). Implements the handshake,
/// AES-GCM command encryption and response decryption from protocol.md.
final class SecureSession {
    let domain: Domain
    private let vin: Data
    private let key: SymmetricKey
    private let clientPublicKey: Data
    private(set) var epoch: Data
    private(set) var counter: UInt32
    /// Local time corresponding to second 0 of the vehicle's clock for this epoch.
    private let timeZero: Date
    private var seenResponseCounters: [Data: Set<UInt32>] = [:]

    private init(domain: Domain, vin: Data, key: SymmetricKey, clientPublicKey: Data, info: SessionInfo, receivedAt: Date) {
        self.domain = domain
        self.vin = vin
        self.key = key
        self.clientPublicKey = clientPublicKey
        self.epoch = info.epoch
        self.counter = info.counter
        self.timeZero = receivedAt.addingTimeInterval(-TimeInterval(info.clockTime))
    }

    // MARK: Handshake

    /// K = SHA1(ECDH x-coordinate)[:16]
    static func sessionKey(sharedSecret: Data) -> SymmetricKey {
        SymmetricKey(data: Data(Array(Insecure.SHA1.hash(data: sharedSecret)).prefix(16)))
    }

    private static func subkey(_ key: SymmetricKey, label: String) -> SymmetricKey {
        SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(label.utf8), using: key)))
    }

    /// Checks the HMAC the vehicle attaches to its SessionInfo, binding it to our challenge.
    static func isValidSessionInfoTag(key: SymmetricKey, vin: Data, challenge: Data, encodedInfo: Data, tag: Data) throws -> Bool {
        var md = Metadata()
        try md.add(.signatureType, byte: SignatureType.hmac.rawValue)
        try md.add(.personalization, vin)
        try md.add(.challenge, challenge)
        let message = md.serialized() + encodedInfo
        return HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: message, using: subkey(key, label: "session info"))
    }

    /// Builds a session from the vehicle's reply to a session-info request.
    /// - Parameter challenge: the `uuid` of the request that triggered this reply.
    static func establish(clientKey: ClientKey, vin: String, domain: Domain, challenge: Data,
                          response: RoutableMessage, receivedAt: Date = Date()) throws -> SecureSession {
        if let fault = response.status?.fault, fault != 0 {
            // UNKNOWN_KEY_ID: the car has never heard of our public key.
            throw fault == 3 ? TeslaError.keyNotEnrolled : TeslaError.vehicleFault(fault)
        }
        guard case .sessionInfo(let encodedInfo)? = response.payload else {
            throw TeslaError.protocolError("handshake reply had no session info")
        }
        let info: SessionInfo
        do { info = try SessionInfo(serialized: encodedInfo) } catch { throw TeslaError.protocolError("bad session info") }
        guard info.status == .ok else { throw TeslaError.keyNotEnrolled }
        guard info.publicKey.count == 65, info.publicKey.first == 0x04, info.epoch.count == 16 else {
            throw TeslaError.protocolError("malformed session info")
        }

        let vinData = Data(vin.utf8)
        let secret: Data
        do { secret = try clientKey.sharedSecret(vehiclePublicKey: info.publicKey) } catch {
            throw TeslaError.protocolError("key agreement failed")
        }
        let key = sessionKey(sharedSecret: secret)

        guard let tag = response.signatureData?.sessionInfoTag,
              try isValidSessionInfoTag(key: key, vin: vinData, challenge: challenge, encodedInfo: encodedInfo, tag: tag)
        else { throw TeslaError.protocolError("session info authentication failed") }

        return SecureSession(domain: domain, vin: vinData, key: key, clientPublicKey: clientKey.publicKey,
                             info: info, receivedAt: receivedAt)
    }

    // MARK: Commands

    /// Encrypts the plaintext `.message` payload of `message` and attaches signature data.
    /// Returns the request hash needed to decrypt the vehicle's replies.
    func encrypt(_ message: RoutableMessage, expiresIn: TimeInterval = 5, now: Date = Date(),
                 nonce: Data? = nil) throws -> (message: RoutableMessage, requestHash: Data) {
        guard case .message(let plaintext)? = message.payload else {
            throw TeslaError.protocolError("nothing to encrypt")
        }
        guard counter < UInt32.max else { throw TeslaError.protocolError("counter rollover") }
        counter += 1

        let seconds = now.addingTimeInterval(expiresIn).timeIntervalSince(timeZero)
        let expiresAt = UInt32(clamping: Int64(seconds.rounded(.down)))

        var md = Metadata()
        try md.add(.signatureType, byte: SignatureType.aesGCMPersonalized.rawValue)
        try md.add(.domain, byte: UInt8(domain.rawValue))
        try md.add(.personalization, vin)
        try md.add(.epoch, epoch)
        try md.add(.expiresAt, uint32: expiresAt)
        try md.add(.counter, uint32: counter)
        if message.flags != 0 { try md.add(.flags, uint32: message.flags) }
        let aad = Data(SHA256.hash(data: md.serialized()))

        let box: AES.GCM.SealedBox
        do {
            let gcmNonce = try nonce.map { try AES.GCM.Nonce(data: $0) } ?? AES.GCM.Nonce()
            box = try AES.GCM.seal(plaintext, using: key, nonce: gcmNonce, authenticating: aad)
        } catch {
            throw TeslaError.protocolError("encryption failed")
        }

        var signature = SignatureData()
        signature.signerPublicKey = clientPublicKey
        signature.aesGCMPersonalized = AESGCMPersonalizedData(
            epoch: epoch, nonce: Data(box.nonce), counter: counter, expiresAt: expiresAt, tag: box.tag)

        var out = message
        out.payload = .message(box.ciphertext)
        out.signatureData = signature
        // Request hash: signature type byte || tag. (VCSEC truncates to 17 bytes; GCM tags are 16.)
        return (out, Data([SignatureType.aesGCMPersonalized.rawValue]) + box.tag)
    }

    /// Returns the plaintext payload of a vehicle reply, decrypting it if the car encrypted it.
    func decrypt(_ response: RoutableMessage, requestHash: Data) throws -> Data {
        guard let gcm = response.signatureData?.aesGCMResponse else {
            return response.messageBytes
        }
        var seen = seenResponseCounters[requestHash, default: []]
        guard !seen.contains(gcm.counter) else { throw TeslaError.protocolError("replayed response") }

        var md = Metadata()
        try md.add(.signatureType, byte: SignatureType.aesGCMResponse.rawValue)
        try md.add(.domain, byte: UInt8((response.from?.domain ?? domain).rawValue))
        try md.add(.personalization, vin)
        try md.add(.counter, uint32: gcm.counter)
        try md.add(.flags, uint32: response.flags) // always present in response metadata
        try md.add(.requestHash, requestHash)
        try md.add(.fault, uint32: response.status?.fault ?? 0)
        let aad = Data(SHA256.hash(data: md.serialized()))

        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: gcm.nonce),
                                            ciphertext: response.messageBytes, tag: gcm.tag)
            let plaintext = try AES.GCM.open(box, using: key, authenticating: aad)
            seen.insert(gcm.counter)
            seenResponseCounters[requestHash] = seen
            return plaintext
        } catch {
            throw TeslaError.protocolError("could not authenticate vehicle reply")
        }
    }
}
