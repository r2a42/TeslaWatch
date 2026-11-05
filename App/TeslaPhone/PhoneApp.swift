import SwiftUI

/// iPhone test harness. Runs the same views and TeslaKit code as the watch app so the BLE protocol
/// can be tried on a phone. Not part of the App Store submission: separate bundle ID, installed from Xcode.
@main
struct TeslaPhoneApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(maxWidth: 520)
        }
    }
}
