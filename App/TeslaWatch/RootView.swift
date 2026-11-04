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
                .frame(maxWidth: .infinity, minHeight: 44)
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

/// Top-corner button that opens Settings (keys, log, options). Replaces a text link that cost a row of height.
private struct SettingsGear: ToolbarContent {
    let model: CarModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            NavigationLink { SettingsView(model: model) } label: { Image(systemName: "gearshape.fill") }
        }
    }
}

/// Key name with one dot per key beside it, so the page dots don't cover the bottom of the screen.
private struct KeyHeader: View {
    @ObservedObject var model: CarModel
    let title: String
    let profile: KeyProfile

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
            HStack(spacing: 3) {
                ForEach(model.profiles) { other in
                    Circle()
                        .fill(other.id == profile.id ? Color.primary : Color.secondary.opacity(0.45))
                        .frame(width: 6, height: 6)
                }
            }
        }
    }
}

struct RootView: View {
    @StateObject private var model = CarModel()

    var body: some View {
        NavigationStack {
            if model.profiles.isEmpty {
                AddKeyView(model: model, isFirstKey: true)
            } else {
                KeyPager(model: model)
            }
        }
    }
}

/// One page per key; swipe sideways to switch. The page you land on becomes the key in use.
struct KeyPager: View {
    @ObservedObject var model: CarModel

    var body: some View {
        TabView(selection: Binding(
            get: { model.selected?.id ?? UUID() },
            set: { model.select($0) }
        )) {
            ForEach(model.profiles) { profile in
                Group {
                    if profile.enrolled {
                        ControlsView(model: model, profile: profile)
                    } else {
                        PairingView(model: model, profile: profile)
                    }
                }
                .tag(profile.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .toolbar { SettingsGear(model: model) }
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
            VStack(spacing: 6) {
                TextField("Name", text: $name)
                TextField("VIN", text: $vin)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                if let message = model.message {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
                BigButton(title: "Add key") {
                    if model.addKey(name: name, vin: vin), !isFirstKey { dismiss() }
                }
                .disabled(vin.count < 17)
            }
        }
        .toolbar { if isFirstKey { SettingsGear(model: model) } }
    }
}

struct PairingView: View {
    @ObservedObject var model: CarModel
    let profile: KeyProfile

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if model.busy {
                    // One block of text and the Cancel button, so Cancel is always on screen.
                    if let message = model.message {
                        Text(message)
                            .font(.body)
                            .multilineTextAlignment(.center)
                    } else {
                        VStack(spacing: 4) {
                            ProgressView()
                            Text("Waiting for the car").font(.body)
                        }
                    }
                    BigButton(title: "Cancel", role: .destructive, prominent: false) { model.cancelPairing() }
                } else {
                    if model.profiles.count > 1 {
                        KeyHeader(model: model, title: "Pair \(profile.name)", profile: profile)
                    }
                    Text("Tap Pair, then tap your key card on the console.")
                        .font(.body)
                        .multilineTextAlignment(.center)
                    BigButton(title: "Pair") { Task { await model.pair() } }
                    if let message = model.message {
                        Text(message)
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                    }
                }
            }
        }
    }
}

struct ControlsView: View {
    @ObservedObject var model: CarModel
    let profile: KeyProfile
    @AppStorage("skipFrunkWarning") private var skipFrunkWarning = false
    @State private var confirmingFrunk = false
    @Environment(\.scenePhase) private var scenePhase

    private var isCurrent: Bool { model.selected?.id == profile.id }
    /// Poll only while this page is in use and the app is on screen.
    private var shouldPoll: Bool { isCurrent && scenePhase == .active }
    // Only the page in use shows state, and only while the car is reachable. Neighbours are previews while you swipe.
    private var showsState: Bool { isCurrent && model.carReachable != false }
    private var lockState: Bool? { showsState ? model.lockState : nil }
    private var frunkOpen: Bool { showsState && model.frunkOpen == true }
    private var trunkOpen: Bool { showsState && model.trunkOpen == true }

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                // The page dots already show there are several keys; the name matters only then.
                if model.profiles.count > 1 {
                    KeyHeader(model: model, title: profile.name, profile: profile)
                }
                if isCurrent && model.carReachable == false {
                    // Out of range: only the message and Reconnect, no command buttons.
                    outOfRange
                } else {
                    HStack {
                        action("Unlock", "lock.open.fill", .green, .unlock)
                        action("Lock", "lock.fill", .red, .lock)
                    }
                    HStack {
                        action(frunkOpen ? "Frunk open" : "Frunk", "car.front.waves.up.fill", .gray, .openFrunk)
                        action(trunkOpen ? "Close trunk" : "Trunk", "car.rear.fill", .gray, .openTrunk)
                    }
                    statusLine
                }
            }
        }
        #if os(iOS)
        .refreshable { await model.pollOnce() }
        #endif
        .disabled(!isCurrent)
        .task(id: shouldPoll) { if shouldPoll { await model.pollLoop() } }
        .alert("Open frunk?", isPresented: $confirmingFrunk) {
            Button("Open") { Task { await model.perform(.openFrunk) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Close it by hand afterwards.")
        }
    }

    /// The car's state, refreshed automatically every 5 seconds while this screen is showing. When the car can't
    /// be reached the screen shows only "Car not in range" and a Reconnect button; it keeps checking every 15
    /// seconds in the background, and Reconnect tries straight away.
    @ViewBuilder
    private var statusLine: some View {
        // An error replaces the status text rather than adding a row, so everything stays on screen.
        if isCurrent, let message = model.message {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 28)
        } else {
            stateText
        }
    }

    private var outOfRange: some View {
        VStack(spacing: 6) {
            Label("Car not in range", systemImage: "antenna.radiowaves.left.and.right.slash")
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            BigButton(title: model.reconnecting ? "Reconnecting\u{2026}" : "Reconnect") {
                Task { await model.reconnect() }
            }
            .disabled(model.reconnecting)
        }
    }

    private var stateText: some View {
        HStack(spacing: 6) {
            if let locked = lockState {
                Image(systemName: locked ? "lock.fill" : "lock.open.fill")
                    .contentTransition(.symbolEffect(.replace))
                Text(statusText(locked: locked))
            } else if model.busy {
                ProgressView()
            } else {
                Text("Checking\u{2026}")
            }
        }
        .font(.body)
        .foregroundStyle(lockState == nil ? .secondary : .primary)
        .frame(maxWidth: .infinity, minHeight: 28)
        .contentShape(Rectangle())
        .animation(.default, value: lockState)
        .onTapGesture { Task { await model.pollOnce() } }
    }

    private func statusText(locked: Bool) -> String {
        // Open frunk and trunk show on their own buttons, which keeps this to one line.
        locked ? "Locked" : "Unlocked"
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
                .frame(height: 20)
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 40)
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
            Toggle("Frunk alert", isOn: Binding(get: { !skipFrunkWarning }, set: { skipFrunkWarning = !$0 }))
            NavigationLink("Log") { LogView() }
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
                        Text("\u{2026}\(profile.vinTail) \u{00B7} \(profile.enrolled ? "Paired" : "Unpaired")")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 2)
                }
            }
            NavigationLink("Add key") { AddKeyView(model: model) }
            #if os(iOS)
            Button("Add test key (not paired)") { model.addTestKey() }
            #endif
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

    /// "Last: 5:10 PM Unlock" for today, "Last: Nov 2 Unlock" for earlier days.
    private func lastCommandText(_ profile: KeyProfile) -> String {
        guard let at = profile.lastCommandAt else { return "No command yet" }
        let when = Calendar.current.isDateInToday(at)
            ? at.formatted(date: .omitted, time: .shortened)
            : at.formatted(.dateTime.month(.abbreviated).day())
        return "Last: \(when)" + (profile.lastCommand.map { " \($0)" } ?? "")
    }

    private func smallButton(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Text(title).font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.bordered)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                TextField("Name", text: $name)
                    .onSubmit { model.rename(id, to: name) }
                if let profile {
                    // Tapping the last-command line explains how to name this key on the car, which that time helps with.
                    NavigationLink { NamingHelpView() } label: {
                        Label(lastCommandText(profile), systemImage: "info.circle")
                            .font(.footnote)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        if profile.enrolled {
                            smallButton("Re-pair") {
                                model.rename(id, to: name)
                                model.markUnpaired(id)
                            }
                        }
                        smallButton("Delete", role: .destructive) { confirmingDelete = true }
                    }
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

/// How to give a key a name on the car itself, which the app can't do because the pairing request has no name field.
struct NamingHelpView: View {
    var body: some View {
        ScrollView {
            Text("On the car, open Controls > Locks. Send a command from this app. The key moves to the top. Tap its edit button to name it.")
                .font(.body)
        }
        .navigationTitle("Naming keys")
    }
}
