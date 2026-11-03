import SwiftUI
import TeslaKit
#if os(watchOS)
import WatchKit
#else
import UIKit
#endif

/// One named key: its own VIN and its own Secure Enclave key. `slot` is the keychain slot ("" is the key from
/// before profiles existed, so an already-paired key keeps working).
struct KeyProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var vin: String
    var enrolled = false
    var slot: String
    /// When a command last went through this key, and which one. Lets you match it to the car's key list,
    /// where the car moves the key you just used to the top.
    var lastCommandAt: Date?
    var lastCommand: String?

    var vinTail: String { String(vin.suffix(6)) }
}

@MainActor
final class CarModel: ObservableObject {
    enum Step { case needsKey, needsPairing, ready }

    @AppStorage("profiles") private var profilesJSON = ""
    @AppStorage("selectedProfile") private var selectedID = ""
    // Single-key storage from before profiles existed; read once for migration.
    @AppStorage("vin") private var legacyVIN = ""
    @AppStorage("enrolled") private var legacyEnrolled = false

    @Published private(set) var profiles: [KeyProfile] = []
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var lockState: Bool?
    @Published private(set) var frunkOpen: Bool?
    @Published private(set) var trunkOpen: Bool?
    /// Whether the last status poll reached the car. nil until the first poll finishes.
    @Published private(set) var carReachable: Bool?
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
    private var pollInFlight: Task<Bool, Never>?

    init() {
        _ = DebugLog.shared
        load()
    }

    // MARK: Profiles

    var selected: KeyProfile? { profiles.first { $0.id.uuidString == selectedID } ?? profiles.first }

    var step: Step {
        guard let selected else { return .needsKey }
        return selected.enrolled ? .ready : .needsPairing
    }

    var vin: String { selected?.vin ?? "" }

    private func load() {
        if let data = profilesJSON.data(using: .utf8), let decoded = try? JSONDecoder().decode([KeyProfile].self, from: data) {
            profiles = decoded
        } else if !legacyVIN.isEmpty {
            // Existing single key becomes the first profile, in the original keychain slot.
            profiles = [KeyProfile(name: "My car", vin: legacyVIN, enrolled: legacyEnrolled, slot: "")]
            selectedID = profiles[0].id.uuidString
            save()
            DebugLog.shared.add("App: migrated the existing key into a profile (paired: \(legacyEnrolled))")
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(profiles), let text = String(data: data, encoding: .utf8) {
            profilesJSON = text
        }
    }

    private func clearVehicleState() {
        vehicle = nil
        lockState = nil
        frunkOpen = nil
        trunkOpen = nil
        carReachable = nil
        message = nil
    }

    /// Adds a key with its own fresh Secure Enclave key and selects it. Returns false if the VIN is invalid.
    @discardableResult
    func addKey(name rawName: String, vin raw: String) -> Bool {
        let vin = raw.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard TeslaVehicle.isPlausibleVIN(vin) else {
            message = TeslaError.invalidVIN.localizedDescription
            return false
        }
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "Key \(profiles.count + 1)" : trimmed
        let profile = KeyProfile(name: name, vin: vin, slot: UUID().uuidString)
        profiles.append(profile)
        selectedID = profile.id.uuidString
        save()
        clearVehicleState()
        DebugLog.shared.add("App: added key \"\(name)\" (VIN ending \(profile.vinTail))")
        return true
    }

    func select(_ id: UUID) {
        guard !busy, profiles.contains(where: { $0.id == id }) else { return }
        selectedID = id.uuidString
        clearVehicleState()
        DebugLog.shared.add("App: selected key \"\(selected?.name ?? "?")\"")
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        profiles[i].name = trimmed
        save()
    }

    /// Marks a key as not paired so it can be paired again, for example after removing it from the car.
    func markUnpaired(_ id: UUID) {
        guard !busy, let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[i].enrolled = false
        save()
        if selected?.id == id { clearVehicleState() }
    }

    /// Deletes the key from this device. The car keeps trusting it until it is removed under Controls > Locks.
    func delete(_ id: UUID) {
        guard !busy, let profile = profiles.first(where: { $0.id == id }) else { return }
        KeyStore.delete(slot: profile.slot)
        profiles.removeAll { $0.id == id }
        if selectedID == id.uuidString { selectedID = profiles.first?.id.uuidString ?? "" }
        save()
        clearVehicleState()
        DebugLog.shared.add("App: deleted key \"\(profile.name)\"")
    }

    private func makeVehicle() throws -> TeslaVehicle {
        if let vehicle { return vehicle }
        guard let selected else { throw TeslaError.invalidVIN }
        let v = try TeslaVehicle(vin: selected.vin, key: try KeyStore.loadOrCreate(slot: selected.slot))
        vehicle = v
        return v
    }

    /// Ends a pairing attempt that is stuck waiting for the car.
    func cancelPairing() {
        DebugLog.shared.add("App: pairing cancel tapped")
        vehicle?.cancel()
    }

    func pair() async {
        guard let id = selected?.id else { return }
        await stopPolling()
        await run("pair", success: false) {
            let v = try self.makeVehicle()
            try await v.enroll(onAwaitingApproval: {
                Task { @MainActor in
                    self.message = "Tap your key card on the center console, then confirm on the car's screen."
                }
            })
            if let i = self.profiles.firstIndex(where: { $0.id == id }) {
                self.profiles[i].enrolled = true
                self.save()
            }
            self.message = nil
        }
    }

    func perform(_ action: VehicleAction) async {
        let id = selected?.id
        await stopPolling()
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
        if succeeded, let id, let i = profiles.firstIndex(where: { $0.id == id }) {
            profiles[i].lastCommandAt = Date()
            profiles[i].lastCommand = action.label
            save()
        }
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
            await pollOnce()
        }
    }

    // MARK: Status polling

    /// Ends any status poll in flight so a command or pairing gets the car's Bluetooth connection straight away.
    private func stopPolling() async {
        guard let poll = pollInFlight else { return }
        vehicle?.cancel()
        _ = await poll.value
    }

    /// One quiet status read. It never sets `busy`, so the buttons stay enabled, and it is silent in the log
    /// except when the car's reachability or state changes. Returns false if the car couldn't be reached.
    @discardableResult
    func pollOnce() async -> Bool {
        guard !busy else { return true }
        if let running = pollInFlight { return await running.value }
        let task = Task { @MainActor () -> Bool in
            TeslaLog.isMuted = true
            defer { TeslaLog.isMuted = false }
            do {
                let status = try await self.makeVehicle().status()
                self.setReachable(true)
                self.apply(status)
                return true
            } catch TeslaError.cancelled {
                return true // a command took over; not a failure
            } catch {
                self.setReachable(false)
                return false
            }
        }
        pollInFlight = task
        let ok = await task.value
        pollInFlight = nil
        return ok
    }

    /// Polls every 5 seconds until cancelled. Stops at the first failure: the screen then shows "Car not in
    /// range" with a Reconnect button, so nothing keeps scanning while you're away from the car.
    func pollLoop() async {
        while !Task.isCancelled {
            guard await pollOnce() else { return }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    /// Tries the car again after "Car not in range". Success restarts the polling.
    func reconnect() async {
        DebugLog.shared.add("App: reconnect tapped")
        carReachable = nil
        await pollOnce()
    }

    private func setReachable(_ reachable: Bool) {
        guard carReachable != reachable else { return }
        carReachable = reachable
        DebugLog.shared.add("App: car \(reachable ? "in range" : "not reachable")")
    }

    private func apply(_ status: VehicleStatus) {
        let changed = lockState != status.isLocked || frunkOpen != status.frunkOpen || trunkOpen != status.trunkOpen
        lockState = status.isLocked
        frunkOpen = status.frunkOpen
        trunkOpen = status.trunkOpen
        if changed {
            DebugLog.shared.add("App: state locked=\(String(describing: status.isLocked)) frunkOpen=\(status.frunkOpen) trunkOpen=\(status.trunkOpen) doorOpen=\(status.anyDoorOpen)")
        }
    }

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

private extension VehicleAction {
    var label: String {
        switch self {
        case .lock: return "Lock"
        case .unlock: return "Unlock"
        case .openTrunk: return "Trunk"
        case .openFrunk: return "Frunk"
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
