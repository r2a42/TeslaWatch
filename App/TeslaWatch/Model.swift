import SwiftUI
import TeslaKit
#if os(watchOS)
import WatchKit
#else
import UIKit
#endif

@MainActor
final class CarModel: ObservableObject {
    enum Step { case needsVIN, needsPairing, ready }

    @AppStorage("vin") private var storedVIN = ""
    @AppStorage("enrolled") private var enrolled = false

    @Published private(set) var step: Step = .needsVIN
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var lockState: Bool?
    @Published private(set) var frunkOpen: Bool?
    @Published private(set) var trunkOpen: Bool?
    /// The command currently in flight, so only that button shows a spinner.
    @Published private(set) var activeAction: VehicleAction?
    /// Result of the last command, shown briefly on its button.
    @Published private(set) var feedback: ActionFeedback?

    struct ActionFeedback: Equatable {
        let id = UUID()
        let action: VehicleAction
        let succeeded: Bool
    }

    private var vehicle: TeslaVehicle?

    init() {
        _ = DebugLog.shared
        refreshStep()
    }

    private func refreshStep() {
        if storedVIN.isEmpty {
            step = .needsVIN
        } else if !enrolled {
            step = .needsPairing
        } else {
            step = .ready
        }
    }

    private func makeVehicle() throws -> TeslaVehicle {
        if let vehicle { return vehicle }
        let v = try TeslaVehicle(vin: storedVIN, key: try KeyStore.loadOrCreate())
        vehicle = v
        return v
    }

    func saveVIN(_ raw: String) {
        let vin = raw.uppercased().trimmingCharacters(in: .whitespaces)
        guard TeslaVehicle.isPlausibleVIN(vin) else {
            message = TeslaError.invalidVIN.localizedDescription
            return
        }
        storedVIN = vin
        vehicle = nil
        message = nil
        refreshStep()
    }

    /// Ends a pairing attempt that is stuck waiting for the car.
    func cancelPairing() {
        DebugLog.shared.add("App: pairing cancel tapped")
        vehicle?.cancel()
    }

    func pair() async {
        await run("pair", success: false) {
            let v = try self.makeVehicle()
            try await v.enroll(onAwaitingApproval: {
                Task { @MainActor in
                    self.message = "Tap your key card on the center console, then confirm on the car's screen."
                }
            })
            self.enrolled = true
            self.message = nil
            self.refreshStep()
        }
    }

    func perform(_ action: VehicleAction) async {
        activeAction = action
        await run("\(action)", success: true) {
            let v = try self.makeVehicle()
            try await v.perform(action)
            switch action {
            case .lock: self.lockState = true
            case .unlock: self.lockState = false
            default: break
            }
        }
        activeAction = nil
        let succeeded = message == nil
        let result = ActionFeedback(action: action, succeeded: succeeded)
        feedback = result
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if feedback == result { feedback = nil }
        }
        if succeeded {
            // Trunk and frunk take a few seconds to move; read the state once they have settled.
            let settle: UInt64 = (action == .openTrunk || action == .openFrunk) ? 4_000_000_000 : 500_000_000
            try? await Task.sleep(nanoseconds: settle)
            await refreshStatus(quiet: true)
        }
    }

    func refreshStatus(quiet: Bool = false) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let status = try await makeVehicle().status()
            lockState = status.isLocked
            frunkOpen = status.frunkOpen
            trunkOpen = status.trunkOpen
            DebugLog.shared.add("App: status ok locked=\(String(describing: status.isLocked)) frunkOpen=\(status.frunkOpen) trunkOpen=\(status.trunkOpen) doorOpen=\(status.anyDoorOpen)")
        } catch {
            DebugLog.shared.add("App: status failed (quiet: \(quiet)): \(error.localizedDescription) [\(error)]")
            if !quiet {
                message = error.localizedDescription
                Haptics.failure()
            }
        }
    }

    func reset() {
        KeyStore.deleteAll()
        storedVIN = ""
        enrolled = false
        vehicle = nil
        lockState = nil
        frunkOpen = nil
        trunkOpen = nil
        message = nil
        refreshStep()
    }

    var vin: String { storedVIN }

    private func run(_ name: String, success haptic: Bool, _ body: @escaping () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        message = nil
        DebugLog.shared.add("App: \(name) started")
        defer { busy = false }
        do {
            try await body()
            DebugLog.shared.add("App: \(name) ok")
            if haptic { Haptics.success() }
        } catch {
            message = error.localizedDescription
            DebugLog.shared.add("App: \(name) failed: \(error.localizedDescription) [\(error)]")
            Haptics.failure()
        }
    }
}

private enum Haptics {
    static func success() {
        #if os(watchOS)
        WKInterfaceDevice.current().play(.success)
        #else
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    static func failure() {
        #if os(watchOS)
        WKInterfaceDevice.current().play(.failure)
        #else
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        #endif
    }
}
