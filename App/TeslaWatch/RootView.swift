import SwiftUI
import TeslaKit

/// Large, full-width button used for the main action on a screen, so it is easy to hit on a watch.
private struct BigButton: View {
    let title: String
    var role: ButtonRole?
    var prominent = true
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Text(title)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.bordered)
        .modifier(ProminentIf(prominent))
        .controlSize(.large)
    }
}

private struct ProminentIf: ViewModifier {
    let on: Bool
    init(_ on: Bool) { self.on = on }

    func body(content: Content) -> some View {
        if on { content.buttonStyle(.borderedProminent).tint(.blue) } else { content }
    }
}

struct RootView: View {
    @StateObject private var model = CarModel()

    var body: some View {
        NavigationStack {
            switch model.step {
            case .needsKey: AddKeyView(model: model, isFirstKey: true)
            case .needsPairing: PairingView(model: model)
            case .ready: ControlsView(model: model)
            }
        }
    }
}

struct AddKeyView: View {
    @ObservedObject var model: CarModel
    var isFirstKey = false
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var vin = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text(isFirstKey ? "Add your car" : "Add a key")
                    .font(.title3.bold())
                TextField("Name", text: $name)
                TextField("17-character VIN", text: $vin)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                if let message = model.message {
                    Text(message).font(.body).foregroundStyle(.red)
                }
                BigButton(title: "Add key") {
                    if model.addKey(name: name, vin: vin), !isFirstKey { dismiss() }
                }
                .disabled(vin.count < 17)
                NavigationLink("Log") { LogView() }
                    .font(.body)
                    .padding(.top, 20)
            }
        }
    }
}

struct PairingView: View {
    @ObservedObject var model: CarModel

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text("Pair \(model.selected?.name ?? "key")")
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                if model.busy {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Waiting for the car").font(.body)
                    }
                } else {
                    Text("Sit in the car with your key card. Tap Pair, then touch the card to the center console.")
                        .font(.body)
                        .multilineTextAlignment(.center)
                }
                if !model.busy {
                    BigButton(title: "Pair") { Task { await model.pair() } }
                }
                if let message = model.message {
                    Text(message)
                        .font(.body)
                        .multilineTextAlignment(.center)
                }
                if model.busy {
                    BigButton(title: "Cancel", role: .destructive, prominent: false) { model.cancelPairing() }
                } else {
                    // Kept apart from Pair, and hidden while pairing, so they can't be hit by mistake.
                    VStack(spacing: 10) {
                        NavigationLink("Keys") { KeysView(model: model) }
                        NavigationLink("Log") { LogView() }
                    }
                    .font(.body)
                    .padding(.top, 24)
                }
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
                Text(model.selected?.name ?? "")
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
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
                NavigationLink("Settings") { SettingsView(model: model) }
                    .font(.body)
                    .padding(.top, 12)
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
            NavigationLink("Keys") { KeysView(model: model) }
            Toggle("Warn before frunk", isOn: Binding(get: { !skipFrunkWarning }, set: { skipFrunkWarning = !$0 }))
            NavigationLink("Log") { LogView() }
            Text("\(model.selected?.name ?? "") \u{00B7} VIN \(model.vin)").font(.footnote)
        }
    }
}

struct KeysView: View {
    @ObservedObject var model: CarModel

    var body: some View {
        List {
            ForEach(model.profiles) { profile in
                NavigationLink {
                    KeyDetailView(model: model, id: profile.id)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(profile.name).font(.headline)
                            if model.selected?.id == profile.id {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                        }
                        Text("\u{2026}\(profile.vinTail) \u{00B7} \(profile.enrolled ? "Paired" : "Not paired")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
            }
            NavigationLink("Add key") { AddKeyView(model: model) }
        }
        .navigationTitle("Keys")
    }
}

struct KeyDetailView: View {
    @ObservedObject var model: CarModel
    let id: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var confirmingDelete = false

    private var profile: KeyProfile? { model.profiles.first { $0.id == id } }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                TextField("Name", text: $name)
                    .onSubmit { model.rename(id, to: name) }
                if let profile {
                    Text("VIN \(profile.vin)").font(.footnote).foregroundStyle(.secondary)
                    if model.selected?.id != id {
                        BigButton(title: "Use this key") {
                            model.rename(id, to: name)
                            model.select(id)
                            dismiss()
                        }
                    }
                    if profile.enrolled {
                        BigButton(title: "Pair again", prominent: false) {
                            model.rename(id, to: name)
                            model.markUnpaired(id)
                        }
                    }
                    BigButton(title: "Delete", role: .destructive, prominent: false) { confirmingDelete = true }
                        .padding(.top, 16)
                }
            }
        }
        .onAppear { name = profile?.name ?? "" }
        .onDisappear { model.rename(id, to: name) }
        .alert("Delete this key?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                model.delete(id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It stays on the car's key list until you remove it there under Controls > Locks.")
        }
    }
}
