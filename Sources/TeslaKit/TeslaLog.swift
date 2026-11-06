import Foundation

/// Diagnostic trace of the BLE and handshake steps. Set `sink` to capture lines; unset it logs nothing.
/// Lines never contain private key material; raw message bytes appear only when `detailed` is on.
public enum TeslaLog {
    private static let lock = NSLock()
    private static var _sink: (@Sendable (String) -> Void)?
    private static var _muted = false
    private static var _detailed = false

    /// Whether lines may include the raw bytes of messages (ciphertext, the car's public key, plaintext status).
    /// Off by default so a shared log doesn't carry them; turn it on to diagnose protocol problems.
    public static var detailed: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _detailed }
        set { lock.lock(); defer { lock.unlock() }; _detailed = newValue }
    }

    /// Suppresses all lines while true. The app sets it around routine background status polls so they
    /// don't bury the pairing and command traces.
    public static var isMuted: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _muted }
        set { lock.lock(); defer { lock.unlock() }; _muted = newValue }
    }

    public static var sink: (@Sendable (String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _sink }
        set { lock.lock(); defer { lock.unlock() }; _sink = newValue }
    }

    static func log(_ line: @autoclosure () -> String) {
        guard !isMuted, let sink else { return }
        sink(line())
    }
}
