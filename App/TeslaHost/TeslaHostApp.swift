import SwiftUI

/// Container app. The App Store only accepts a watch app embedded in an iOS app, so this carries
/// TeslaWatch and does nothing else. All functionality lives on the watch.
@main
struct TeslaHostApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Watch Key Test runs on your Apple Watch. Open it from the watch home screen.")
                .multilineTextAlignment(.center)
                .padding()
        }
    }
}
