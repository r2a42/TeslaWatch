import SwiftUI
import TeslaKit

struct RootView: View {
    @StateObject private var model = CarModel()

    var body: some View {
        NavigationStack {
            switch model.step {
            case .needsVIN: VINEntryView(model: model)
            case .needsPairing: PairingView(model: model)
            case .ready: ControlsView(model: model)
            }
        }
    }
}

struct VINEntryView: View {
    @ObservedObject var model: CarModel
    @State private var text = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("Enter your car's VIN")
                    .font(.headline)
                TextField("17-character VIN", text: $text)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                Button("Continue") { model.saveVIN(text) }
                    .disabled(text.count < 17)
                NavigationLink("Log") { LogView() }
                    .font(.footnote)
                if let message = model.message {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
            }
        }
    }
}

struct PairingView: View {
    @ObservedObject var model: CarModel

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("Pair with your car")
                    .font(.headline)
                Text("Sit in the car with your key card, then tap Pair.")
                    .font(.footnote)
                Button {
                    Task { await model.pair() }
                } label: {
                    if model.busy { ProgressView() } else { Text("Pair") }
                }
                .disabled(model.busy)
                if model.busy {
                    Button("Cancel", role: .cancel) { model.cancelPairing() }
                }
                if let message = model.message {
                    Text(message).font(.footnote)
                }
                Button("Change VIN", role: .destructive) { model.reset() }
                    .font(.footnote)
                NavigationLink("Log") { LogView() }
                    .font(.footnote)
            }
        }
    }
}

struct ControlsView: View {
    @ObservedObject var model: CarModel
    @AppStorage("skipFrunkWarning") private var skipFrunkWarning = false
    @State private var confirmingFrunk = false

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                HStack {
                    action("Unlock", "lock.open.fill", .green, .unlock)
                    action("Lock", "lock.fill", .red, .lock)
                }
                HStack {
                    action("Frunk", "car.front.waves.up.fill", .gray, .openFrunk)
                    action(model.trunkOpen == true ? "Close trunk" : "Trunk", "car.rear.fill", .gray, .openTrunk)
                }
                statusLine
                if let message = model.message {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                NavigationLink("Settings") { SettingsView(model: model) }
            }
        }
        .task { await model.refreshStatus(quiet: true) }
        .alert("Open the frunk?", isPresented: $confirmingFrunk) {
            Button("Open") { Task { await model.perform(.openFrunk) } }
            Button("Open, don't ask again") {
                skipFrunkWarning = true
                Task { await model.perform(.openFrunk) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This app can't close the frunk. You'll need to close it by hand.")
        }
    }

    private var statusLine: some View {
        HStack(spacing: 4) {
            if model.busy {
                ProgressView()
            } else if let locked = model.lockState {
                Image(systemName: locked ? "lock.fill" : "lock.open.fill")
                    .contentTransition(.symbolEffect(.replace))
                Text(statusText(locked: locked))
            } else {
                Text("Tap to refresh").foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
        .animation(.default, value: model.lockState)
        .onTapGesture { Task { await model.refreshStatus() } }
    }

    private func statusText(locked: Bool) -> String {
        var parts = [locked ? "Locked" : "Unlocked"]
        if model.frunkOpen == true { parts.append("frunk open") }
        if model.trunkOpen == true { parts.append("trunk open") }
        return parts.joined(separator: ", ")
    }

    private func trigger(_ action: VehicleAction) {
        if action == .openFrunk && !skipFrunkWarning {
            confirmingFrunk = true
        } else {
            Task { await model.perform(action) }
        }
    }

    private func action(_ title: String, _ symbol: String, _ tint: Color, _ action: VehicleAction) -> some View {
        let result = model.feedback?.action == action ? model.feedback : nil
        return Button {
            trigger(action)
        } label: {
            VStack {
                ZStack {
                    if model.activeAction == action {
                        ProgressView()
                    } else if let result {
                        Image(systemName: result.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result.succeeded ? .green : .red)
                            .symbolEffect(.bounce, value: result.id)
                    } else {
                        Image(systemName: symbol)
                    }
                }
                .frame(height: 24)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .tint(tint)
        .disabled(model.busy)
        .animation(.easeInOut(duration: 0.2), value: model.activeAction)
        .animation(.easeInOut(duration: 0.2), value: model.feedback)
    }
}

struct SettingsView: View {
    @ObservedObject var model: CarModel
    @AppStorage("skipFrunkWarning") private var skipFrunkWarning = false

    var body: some View {
        List {
            Text("VIN \(model.vin)").font(.footnote)
            NavigationLink("Log") { LogView() }
            Toggle("Warn before frunk", isOn: Binding(get: { !skipFrunkWarning }, set: { skipFrunkWarning = !$0 }))
            Button("Forget car and key", role: .destructive) { model.reset() }
            Text("To fully revoke this watch, also delete its key in the car under Controls › Locks.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
