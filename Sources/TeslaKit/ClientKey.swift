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

/// Persists the client key in the keychain, preferring the Secure Enclave.
public enum KeyStore {
    private static let service = "TeslaWatch.clientkey"
    private enum Account: String {
        case secureEnclave = "secure-enclave-v1"
        case software = "software-v1"
    }

    /// Returns the stored key, creating one on first use.
    public static func loadOrCreate() throws -> ClientKey {
        if let blob = try read(.secureEnclave), let key = try? SecureEnclaveClientKey(dataRepresentation: blob) {
            return key
        }
        if let raw = try read(.software), let key = try? SoftwareClientKey(rawRepresentation: raw) {
            return key
        }
        if SecureEnclave.isAvailable, let key = try? SecureEnclaveClientKey() {
            try write(key.dataRepresentation, .secureEnclave)
            return key
        }
        // Simulator and devices without a Secure Enclave.
        let key = SoftwareClientKey()
        try write(key.rawRepresentation, .software)
        return key
    }

    public static func existingKey() -> ClientKey? {
        if let blob = try? read(.secureEnclave), let key = try? SecureEnclaveClientKey(dataRepresentation: blob) {
            return key
        }
        if let raw = try? read(.software), let key = try? SoftwareClientKey(rawRepresentation: raw) {
            return key
        }
        return nil
    }

    /// Deletes the key. The car keeps trusting the old public key until you remove it in the
    /// car's Controls > Locks screen.
    public static func deleteAll() {
        for account in [Account.secureEnclave, .software] {
            SecItemDelete(query(account) as CFDictionary)
        }
    }

    private static func query(_ account: Account) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
    }

    private static func read(_ account: Account) throws -> Data? {
        var q = query(account)
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

    private static func write(_ data: Data, _ account: Account) throws {
        SecItemDelete(query(account) as CFDictionary)
        var q = query(account)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw TeslaError.keychain("write failed (\(status))") }
    }
}
#endif
