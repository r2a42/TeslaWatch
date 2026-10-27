import Foundation

public enum TeslaError: Error, Equatable, LocalizedError {
    case bluetoothUnavailable(String)
    case vehicleNotFound
    case timeout
    case invalidVIN
    case keyNotEnrolled
    case enrollmentTimedOut
    case busy
    case protocolError(String)
    /// `UniversalMessage.MessageFault_E` reported by the car.
    case vehicleFault(UInt32)
    /// `Errors.GenericError_E` reported by VCSEC.
    case vehicleRefused(UInt64)
    case keychainFull
    case keychain(String)

    public var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable(let why): return "Bluetooth unavailable: \(why)"
        case .vehicleNotFound: return "Car not found. Get closer and try again."
        case .timeout: return "The car didn't respond."
        case .invalidVIN: return "That doesn't look like a valid VIN."
        case .keyNotEnrolled: return "This watch isn't paired with the car yet."
        case .enrollmentTimedOut: return "Pairing wasn't approved in time."
        case .busy: return "The car is busy. Try again."
        case .protocolError(let why): return "Protocol error: \(why)"
        case .vehicleFault(let code): return "The car rejected the command (fault \(code): \(Self.faultName(code)))."
        case .vehicleRefused(let code): return "The car refused the command (error \(code))."
        case .keychainFull: return "The car's key list is full."
        case .keychain(let why): return "Key storage error: \(why)"
        }
    }

    static func faultName(_ code: UInt32) -> String {
        switch code {
        case 3: return "unknown key"
        case 4: return "inactive key"
        case 5: return "invalid signature"
        case 6: return "bad counter"
        case 7: return "insufficient privileges"
        case 12: return "wrong VIN"
        case 15: return "wrong epoch"
        case 17: return "expired"
        case 28: return "response encryption required"
        default: return "see MessageFault_E"
        }
    }

    /// Faults that mean our session state is stale and a fresh handshake will likely fix it.
    var isSessionDesync: Bool {
        guard case .vehicleFault(let code) = self else { return false }
        return code == 5 || code == 6 || code == 15 || code == 17
    }
}
