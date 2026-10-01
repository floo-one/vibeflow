// swift-tools-version: 6.0
// VibeFlowCore: capture, speech providers, session state machine, smart read and settings.
// Plain Swift behind injectable protocols so everything is testable without the app,
// Accessibility permission or a network. The app target supplies the real implementations.
import PackageDescription

let package = Package(
    name: "VibeFlowCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VibeFlowCore", targets: ["VibeFlowCore"]),
    ],
    targets: [
        .target(
            name: "VibeFlowCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "VibeFlowCoreTests",
            dependencies: ["VibeFlowCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
