#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

enum VehicleName {
    /// BLE local name the car advertises: "S" + hex(first 8 bytes of SHA1(VIN)) + "C".
    static func advertised(vin: String) -> String {
        let digest = Array(Insecure.SHA1.hash(data: Data(vin.utf8)))
        return "S" + digest.prefix(8).map { String(format: "%02x", $0) }.joined() + "C"
    }

    /// 17 characters, digits and capital letters except I, O and Q.
    static func isPlausibleVIN(_ vin: String) -> Bool {
        vin.count == 17 && vin.allSatisfy { c in
            c.isASCII && (c.isNumber || c.isUppercase) && !"IOQ".contains(c)
        }
    }
}
