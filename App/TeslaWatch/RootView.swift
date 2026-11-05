import SwiftUI
import TeslaKit

/// Sizes that differ between the watch and the iPhone test build, which has far more room.
private enum Metrics {
    #if os(iOS)
    static let buttonHeight: CGFloat = 56
    static let tileHeight: CGFloat = 120
    static let tileSymbol: CGFloat = 38
    static let tileFont = Font.title3.weight(.semibold)
    static let statusFont = Font.title2.weight(.medium)
    static let spacing: CGFloat = 14
    #else
    static let buttonHeight: CGFloat = 44
    static let tileHeight: CGFloat = 40
    static let tileSymbol: CGFloat = 17
    static let tileFont = Font.caption2
    static let statusFont = Font.body
    static let spacing: CGFloat = 6
    #endif
}

/// A small side-on Model Y facing left, with the tailgate (hinged at the top of the roof) or the frunk hood (hinged
/// at the base of the windshield) swinging up. It takes about as long as the car does to open the trunk, so the
/// icon doubles as the progress indicator.
private struct CarLidIcon: View {
    let open: Bool
    var front = false
    /// Only animate a change that comes from a command the car accepted, never from switching keys or a status read.
    var animated = false
    let size: CGFloat

    /// The whole car as one shape, drawn on a 100 x 43 grid (ground at y = 41.5) and scaled to fit.
    /// `angle` is how far the lid has swung, in radians.
    private struct CarShape: Shape {
        var angle: Double
        var front: Bool
        var animatableData: Double {
            get { angle }
            set { angle = newValue }
        }

        static let wheels: [CGFloat] = [22, 77.5]
        static let wheelY: CGFloat = 34.2
        static let tire: CGFloat = 7.3
        static let arch: CGFloat = 8.9
        static let sill: CGFloat = 36.4
        static let thickness: CGFloat = 2.6

        /// The upper outline from the front bumper to the rear bumper, as cubic Bezier segments (start, control 1,
        /// control 2, end), running clockwise on screen.
        static let skin: [[CGPoint]] = [
            [(7.5, 36.4), (4.6, 36.4), (3.8, 33), (4, 30)],        // nose
            [(4, 30), (4.2, 26), (6, 23.9), (8.5, 23.4)],
            [(8.5, 23.4), (13, 21.9), (21, 20.6), (26, 20.4)],     // domed hood
            [(26, 20.4), (34, 15.4), (42, 11.4), (49, 10.4)],      // windshield
            [(49, 10.4), (60, 9), (82, 9.8), (89.5, 16.4)],        // roof
            [(89.5, 16.4), (91.5, 16.4), (92.7, 16.9), (93, 18)],  // ducktail
            [(93, 18), (92.8, 22), (94.6, 26), (94.2, 29.5)],      // tail
            [(94.2, 29.5), (94.2, 32.8), (93.3, 34.4), (91.5, 34.4)], // high rear bumper
        ].map { $0.map { CGPoint(x: $0.0, y: $0.1) } }

        static func bezier(_ s: [CGPoint], _ t: CGFloat) -> CGPoint {
            let u = 1 - t
            let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
            return CGPoint(x: a * s[0].x + b * s[1].x + c * s[2].x + d * s[3].x,
                           y: a * s[0].y + b * s[1].y + c * s[2].y + d * s[3].y)
        }

        /// A lid: the sheet between the skin and `thickness` inside it, over the given stretches of skin
        /// (segment, start t, end t). `out` widens it outward so it can cleanly cut its own slot from the body.
        static func sheet(_ spans: [(Int, CGFloat, CGFloat)], out: CGFloat = 0) -> Path {
            var pts: [CGPoint] = []
            for (seg, t0, t1) in spans {
                for i in (pts.isEmpty ? 0 : 1)...40 { pts.append(bezier(skin[seg], t0 + (t1 - t0) * CGFloat(i) / 40)) }
            }
            var outer: [CGPoint] = [], inner: [CGPoint] = []
            for i in pts.indices {
                let a = pts[max(i - 2, 0)], b = pts[min(i + 2, pts.count - 1)]
                let dx = b.x - a.x, dy = b.y - a.y, l = max((dx * dx + dy * dy).squareRoot(), 0.0001)
                let n = CGPoint(x: -dy / l, y: dx / l) // points into the body
                outer.append(CGPoint(x: pts[i].x - out * n.x, y: pts[i].y - out * n.y))
                inner.append(CGPoint(x: pts[i].x + thickness * n.x, y: pts[i].y + thickness * n.y))
            }
            return Path { p in
                p.addLines(outer + inner.reversed())
                p.closeSubpath()
            }
        }

        /// Body outline with the wheel arches cut in.
        static var silhouette: Path {
            var p = Path()
            p.move(to: skin[0][0])
            for seg in skin { p.addCurve(to: seg[3], control1: seg[1], control2: seg[2]) }
            for cx in wheels.reversed() {
                let dy = sill - wheelY, dx = (arch * arch - dy * dy).squareRoot()
                p.addLine(to: CGPoint(x: cx + dx, y: sill))
                let a0 = atan2(Double(dy), Double(dx))
                for i in 1...24 {
                    let a = a0 - (Double.pi + 2 * a0) * Double(i) / 24 // up and over the top of the wheel
                    p.addLine(to: CGPoint(x: cx + arch * CGFloat(cos(a)), y: wheelY + arch * CGFloat(sin(a))))
                }
            }
            p.closeSubpath()
            return p
        }

        /// Side windows, split by the B and C pillars.
        static var windows: Path {
            var w = Path()
            w.move(to: CGPoint(x: 32.5, y: 19.8))
            w.addLine(to: CGPoint(x: 48.8, y: 12.5))
            w.addCurve(to: CGPoint(x: 77.2, y: 15.6), control1: CGPoint(x: 60, y: 10.8), control2: CGPoint(x: 71, y: 11.4))
            w.addQuadCurve(to: CGPoint(x: 76.4, y: 18.1), control: CGPoint(x: 78.2, y: 17.2))
            w.addQuadCurve(to: CGPoint(x: 32.5, y: 19.8), control: CGPoint(x: 55, y: 18.6))
            w.closeSubpath()
            let pillars = Path { p in
                p.addRect(CGRect(x: 55.6, y: 0, width: 1.9, height: 30))
                p.addRect(CGRect(x: 70.2, y: 0, width: 1.5, height: 30))
            }
            return w.subtracting(pillars)
        }

        static func polygon(_ points: [(CGFloat, CGFloat)]) -> Path {
            Path { p in
                p.addLines(points.map { CGPoint(x: $0.0, y: $0.1) })
                p.closeSubpath()
            }
        }

        static func disc(_ c: CGPoint, _ radius: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: 2 * radius, height: 2 * radius))
        }

        func skin(_ seg: Int, _ t: CGFloat) -> CGPoint { Self.bezier(Self.skin[seg], t) }

        func path(in r: CGRect) -> Path {
            // Each lid is a thin sheet of the car's own skin (see `sheet`). The body keeps the exact slot it leaves,
            // so the two fit back together like puzzle pieces.
            let spans: [(Int, CGFloat, CGFloat)], hinge: CGPoint, turn: Double
            if front {
                spans = [(2, 0.04, 1)]                          // hood top only: front edge back to the windshield base
                hinge = skin(2, 1)
                turn = angle // clockwise on screen: the nose end rises
            } else {
                spans = [(4, 0.61, 1), (5, 0, 1), (6, 0, 0.93)] // liftgate: top rear of the roof down to the bumper
                hinge = skin(4, 0.61)
                turn = -angle // anticlockwise on screen: the lower edge swings up and back
            }
            let body = Self.silhouette
            let sheet = Self.sheet(spans)
            let lid = sheet.applying(CGAffineTransform(translationX: -hinge.x, y: -hinge.y)
                .concatenating(CGAffineTransform(rotationAngle: turn))
                .concatenating(CGAffineTransform(translationX: hinge.x, y: hinge.y)))
            // Closed, the car is one piece with no seam. As the liftgate moves, its slot in the body shows; the hood
            // is a plate lying on the hood, so the body under it stays whole.
            var car = angle > 0.001 && !front ? body.subtracting(Self.sheet(spans, out: 0.5)) : body
            car = car.subtracting(Self.windows).union(lid)
            for cx in Self.wheels {
                let c = CGPoint(x: cx, y: Self.wheelY)
                car = car.union(Self.disc(c, Self.tire).subtracting(Self.disc(c, 4.3)).union(Self.disc(c, 3.0)))
            }
            let k = min(r.width / 100, r.height / 43)
            return car.applying(CGAffineTransform(scaleX: k, y: k)
                .concatenating(CGAffineTransform(translationX: r.midX - 50 * k, y: r.midY - 21.5 * k)))
        }
    }

    var body: some View {
        CarShape(angle: open ? (front ? 0.96 : 1.13) : 0, front: front)
            .fill()
            .frame(width: size * 2.1, height: size * 0.9)
            .animation(animated ? .easeInOut(duration: 3.5) : nil, value: open)
    }
}

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
                .frame(maxWidth: .infinity, minHeight: Metrics.buttonHeight)
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
            VStack(spacing: Metrics.spacing) {
                // The page dots already show there are several keys; the name matters only then.
                if model.profiles.count > 1 {
                    KeyHeader(model: model, title: profile.name, profile: profile)
                }
                if isCurrent && model.carReachable == false {
                    // Out of range: only the message and Reconnect, no command buttons.
                    outOfRange
                } else {
                    HStack(spacing: Metrics.spacing) {
                        action("Unlock", "lock.open.fill", .green, .unlock)
                        action("Lock", "lock.fill", .red, .lock)
                    }
                    HStack(spacing: Metrics.spacing) {
                        action(frunkOpen ? "Frunk open" : "Open frunk", "car.front.waves.up.fill", .gray, .openFrunk,
                               lid: frunkOpen)
                        action(trunkOpen ? "Close trunk" : "Open trunk", "car.rear.fill", .gray, .openTrunk,
                               lid: trunkOpen)
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
        .font(Metrics.statusFont)
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

    /// `lid` is non-nil for the trunk and frunk, whose icon animates open or closed instead of showing a spinner.
    private func action(_ title: String, _ symbol: String, _ tint: Color, _ action: VehicleAction, lid: Bool? = nil) -> some View {
        let result = model.feedback?.action == action ? model.feedback : nil
        return Button {
            trigger(action)
        } label: {
            VStack {
                ZStack {
                    if let lid, !(result?.succeeded == false) {
                        // The lid starts moving only once the car has accepted the command; until then it waits.
                        CarLidIcon(open: lid, front: action == .openFrunk,
                                   animated: isCurrent && model.lidMotion == action, size: Metrics.tileSymbol)
                            .opacity(model.activeAction == action ? 0.35 : 1)
                            .overlay { if model.activeAction == action { ProgressView() } }
                    } else if model.activeAction == action {
                        ProgressView()
                    } else if let result {
                        Image(systemName: result.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result.succeeded ? .green : .red)
                            .symbolEffect(.bounce, value: result.id)
                    } else {
                        Image(systemName: symbol)
                    }
                }
                .font(.system(size: Metrics.tileSymbol))
                .frame(height: Metrics.tileSymbol + 3)
                Text(title)
                    .font(Metrics.tileFont)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: Metrics.tileHeight)
        }
        #if os(iOS)
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 20))
        .tint(tint.opacity(0.85))
        #else
        .tint(tint)
        #endif
        .disabled(model.busy)
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
