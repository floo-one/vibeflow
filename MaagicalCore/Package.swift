// swift-tools-version: 6.0
// MaagicalCore: capture, speech providers, session state machine, smart read and settings.
// Plain Swift behind injectable protocols so everything is testable without the app,
// Accessibility permission or a network. The app target supplies the real implementations.
import PackageDescription

let package = Package(
    name: "MaagicalCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MaagicalCore", targets: ["MaagicalCore"]),
    ],
    targets: [
        .target(
            name: "MaagicalCore",
            resources: [.copy("Clock/Resources/time-zones.json")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Local prompt eval runner (evals/README.md); not part of the app.
        .executableTarget(
            name: "vf-eval",
            dependencies: ["MaagicalCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MaagicalCoreTests",
            dependencies: ["MaagicalCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
