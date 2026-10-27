// swift-tools-version: 5.9
import PackageDescription

// Apple platforms use the system CryptoKit. Linux (used only to run the unit tests in CI or a
// container) gets the API-compatible swift-crypto.
#if os(Linux)
let linuxDependencies: [Package.Dependency] = [.package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")]
let linuxTargetDependencies: [Target.Dependency] = [.product(name: "Crypto", package: "swift-crypto")]
#else
let linuxDependencies: [Package.Dependency] = []
let linuxTargetDependencies: [Target.Dependency] = []
#endif

let package = Package(
    name: "TeslaKit",
    platforms: [.watchOS(.v10), .iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "TeslaKit", targets: ["TeslaKit"]),
    ],
    dependencies: linuxDependencies,
    targets: [
        .target(name: "TeslaKit", dependencies: linuxTargetDependencies),
        .testTarget(name: "TeslaKitTests", dependencies: ["TeslaKit"] + linuxTargetDependencies),
    ]
)
