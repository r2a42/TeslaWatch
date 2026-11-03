import Foundation

/// Diagnostic trace of the BLE and handshake steps. Set `sink` to capture lines; unset it logs nothing.
/// Lines never contain key material, only step names, sizes and error descriptions.
public enum TeslaLog {
    private static let lock = NSLock()
    private static var _sink: (@Sendable (String) -> Void)?

    public static var sink: (@Sendable (String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _sink }
        set { lock.lock(); defer { lock.unlock() }; _sink = newValue }
    }

    static func log(_ line: @autoclosure () -> String) {
        guard let sink else { return }
        sink(line())
    }
}
