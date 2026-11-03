import Foundation

/// Human-readable summaries of protocol messages for `TeslaLog`. Only public protocol data: routing
/// addresses, status codes, sizes and ciphertext bytes. No private key material is ever passed in here.
extension Data {
    func hexPreview(limit: Int = 300) -> String {
        let shown = prefix(limit).map { String(format: "%02x", $0) }.joined()
        return count > limit ? shown + "...(+\(count - limit)B)" : shown
    }

    var shortHex: String { isEmpty ? "-" : prefix(4).map { String(format: "%02x", $0) }.joined() }
}

extension RoutableMessage {
    var logSummary: String {
        var parts = [String]()
        if let to {
            parts.append("to=" + (to.routingAddress.map { "addr:\($0.shortHex)" } ?? "domain:\(to.domain.map { "\($0)" } ?? "-")"))
        }
        if let from { parts.append("from=" + (from.routingAddress.map { "addr:\($0.shortHex)" } ?? "domain:\(from.domain.map { "\($0)" } ?? "-")")) }
        switch payload {
        case .message(let d)?: parts.append("payload=message(\(d.count)B)")
        case .sessionInfo(let d)?: parts.append("payload=sessionInfo(\(d.count)B)")
        case .sessionInfoRequest?: parts.append("payload=sessionInfoRequest")
        case nil: parts.append("payload=none")
        }
        if let status { parts.append("fault=\(status.fault) op=\(status.operationStatus)") }
        if let sig = signatureData {
            parts.append("sig[tag=\(sig.sessionInfoTag?.count ?? 0)B gcmResponse=\(sig.aesGCMResponse != nil)]")
        }
        parts.append("reqUUID=\(requestUUID.shortHex) uuid=\(uuid.shortHex)")
        return parts.joined(separator: " ")
    }
}

extension FromVCSECMessage {
    var logSummary: String {
        var parts = [String]()
        if let c = commandStatus {
            parts.append("commandStatus(op=\(c.operationStatus) signed=\(c.hasSignedMessageStatus) whitelist=\(c.whitelistOperationStatus.map { "info=\($0.information) op=\($0.operationStatus)" } ?? "-"))")
        }
        if let e = nominalError { parts.append("nominalError=\(e)") }
        if let s = vehicleStatus {
            parts.append("status(locked=\(s.isLocked.map(String.init) ?? "?") frunkOpen=\(s.frunkOpen) trunkOpen=\(s.trunkOpen) doorOpen=\(s.anyDoorOpen))")
        }
        return parts.isEmpty ? "empty" : parts.joined(separator: " ")
    }
}
