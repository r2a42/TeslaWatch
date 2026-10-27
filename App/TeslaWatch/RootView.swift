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
                if let message = model.message {
                    Text(message).font(.footnote)
                }
                Button("Change VIN", role: .destructive) { model.reset() }
                    .font(.footnote)
            }
        }
    }
}

struct ControlsView: View {
    @ObservedObject var model: CarModel

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                HStack {
                    action("Unlock", "lock.open.fill", .green, .unlock)
                    action("Lock", "lock.fill", .red, .lock)
                }
                HStack {
                    action("Frunk", "car.front.waves.up.fill", .gray, .openFrunk)
                    action("Trunk", "car.rear.fill", .gray, .openTrunk)
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
    }

    private var statusLine: some View {
        HStack(spacing: 4) {
            if model.busy {
                ProgressView()
            } else if let locked = model.lockState {
                Image(systemName: locked ? "lock.fill" : "lock.open.fill")
                Text(locked ? "Locked" : "Unlocked")
            } else {
                Text("Tap to refresh").foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
        .onTapGesture { Task { await model.refreshStatus() } }
    }

    private func action(_ title: String, _ symbol: String, _ tint: Color, _ action: VehicleAction) -> some View {
        Button {
            Task { await model.perform(action) }
        } label: {
            VStack {
                Image(systemName: symbol)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .tint(tint)
        .disabled(model.busy)
    }
}

struct SettingsView: View {
    @ObservedObject var model: CarModel

    var body: some View {
        List {
            Text("VIN \(model.vin)").font(.footnote)
            Button("Forget car and key", role: .destructive) { model.reset() }
            Text("To fully revoke this watch, also delete its key in the car under Controls › Locks.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
