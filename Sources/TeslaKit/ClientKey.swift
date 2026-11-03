#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// The watch's long-term P-256 identity. The car stores the public half after the owner
/// approves enrollment with the NFC key card.
public protocol ClientKey {
    /// ANSI X9.63 uncompressed point: 0x04 || X || Y (65 bytes).
    var publicKey: Data { get }
    /// Raw ECDH shared secret (the 32-byte X coordinate) with the vehicle's public key.
    func sharedSecret(vehiclePublicKey: Data) throws -> Data
}

public struct SoftwareClientKey: ClientKey {
    private let key: P256.KeyAgreement.PrivateKey

    public init() { key = P256.KeyAgreement.PrivateKey() }

    public init(rawRepresentation: Data) throws {
        key = try P256.KeyAgreement.PrivateKey(rawRepresentation: rawRepresentation)
    }

    public var rawRepresentation: Data { key.rawRepresentation }
    public var publicKey: Data { key.publicKey.x963Representation }

    public func sharedSecret(vehiclePublicKey: Data) throws -> Data {
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: vehiclePublicKey)
        let secret = try key.sharedSecretFromKeyAgreement(with: peer)
        return secret.withUnsafeBytes { Data($0) }
    }
}

#if canImport(Security)
import Security

public struct SecureEnclaveClientKey: ClientKey {
    private let key: SecureEnclave.P256.KeyAgreement.PrivateKey

    public init() throws { key = try SecureEnclave.P256.KeyAgreement.PrivateKey() }

    public init(dataRepresentation: Data) throws {
        key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: dataRepresentation)
    }

    /// Opaque blob only this device's Secure Enclave can use. Safe to store in the keychain.
    public var dataRepresentation: Data { key.dataRepresentation }
    public var publicKey: Data { key.publicKey.x963Representation }

    public func sharedSecret(vehiclePublicKey: Data) throws -> Data {
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: vehiclePublicKey)
        let secret = try key.sharedSecretFromKeyAgreement(with: peer)
        return secret.withUnsafeBytes { Data($0) }
    }
}

/// Persists client keys in the keychain, preferring the Secure Enclave. Each key lives in a named slot, so one
/// device can hold several keys. The default (empty) slot is the original single-key location.
public enum KeyStore {
    private static let service = "TeslaWatch.clientkey"
    private enum Kind: String {
        case secureEnclave = "secure-enclave-v1"
        case software = "software-v1"
    }

    /// Returns the key in `slot`, creating one on first use.
    public static func loadOrCreate(slot: String = "") throws -> ClientKey {
        if let blob = try read(.secureEnclave, slot), let key = try? SecureEnclaveClientKey(dataRepresentation: blob) {
            return key
        }
        if let raw = try read(.software, slot), let key = try? SoftwareClientKey(rawRepresentation: raw) {
            return key
        }
        if SecureEnclave.isAvailable, let key = try? SecureEnclaveClientKey() {
            try write(key.dataRepresentation, .secureEnclave, slot)
            return key
        }
        // Simulator and devices without a Secure Enclave.
        let key = SoftwareClientKey()
        try write(key.rawRepresentation, .software, slot)
        return key
    }

    public static func existingKey(slot: String = "") -> ClientKey? {
        if let blob = try? read(.secureEnclave, slot), let key = try? SecureEnclaveClientKey(dataRepresentation: blob) {
            return key
        }
        if let raw = try? read(.software, slot), let key = try? SoftwareClientKey(rawRepresentation: raw) {
            return key
        }
        return nil
    }

    /// Deletes the key in `slot`. The car keeps trusting the old public key until you remove it in the
    /// car's Controls > Locks screen.
    public static func delete(slot: String) {
        for kind in [Kind.secureEnclave, .software] {
            SecItemDelete(query(kind, slot) as CFDictionary)
        }
    }

    /// Deletes every key this app has stored, in all slots.
    public static func deleteAll() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(q as CFDictionary)
    }

    private static func query(_ kind: Kind, _ slot: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: slot.isEmpty ? kind.rawValue : "\(kind.rawValue).\(slot)",
        ]
    }

    private static func read(_ kind: Kind, _ slot: String) throws -> Data? {
        var q = query(kind, slot)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw TeslaError.keychain("read failed (\(status))")
        }
        return data
    }

    private static func write(_ data: Data, _ kind: Kind, _ slot: String) throws {
        SecItemDelete(query(kind, slot) as CFDictionary)
        var q = query(kind, slot)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw TeslaError.keychain("write failed (\(status))") }
    }
}
#endif
