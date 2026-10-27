import SwiftUI
import TeslaKit
import WatchKit

@MainActor
final class CarModel: ObservableObject {
    enum Step { case needsVIN, needsPairing, ready }

    @AppStorage("vin") private var storedVIN = ""
    @AppStorage("enrolled") private var enrolled = false

    @Published private(set) var step: Step = .needsVIN
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var lockState: Bool?

    private var vehicle: TeslaVehicle?

    init() { refreshStep() }

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

    func pair() async {
        await run(success: false) {
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
        await run(success: true) {
            let v = try self.makeVehicle()
            try await v.perform(action)
            switch action {
            case .lock: self.lockState = true
            case .unlock: self.lockState = false
            default: break
            }
        }
    }

    func refreshStatus() async {
        await run(success: false) {
            let status = try await self.makeVehicle().status()
            self.lockState = status.isLocked
        }
    }

    func reset() {
        KeyStore.deleteAll()
        storedVIN = ""
        enrolled = false
        vehicle = nil
        lockState = nil
        message = nil
        refreshStep()
    }

    var vin: String { storedVIN }

    private func run(success haptic: Bool, _ body: @escaping () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        message = nil
        defer { busy = false }
        do {
            try await body()
            if haptic { WKInterfaceDevice.current().play(.success) }
        } catch {
            message = error.localizedDescription
            WKInterfaceDevice.current().play(.failure)
        }
    }
}
