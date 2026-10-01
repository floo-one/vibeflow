// swift-tools-version: 6.0
// OutflowCore: capture, speech providers, session state machine, smart read and settings.
// Plain Swift behind injectable protocols so everything is testable without the app,
// Accessibility permission or a network. The app target supplies the real implementations.
import PackageDescription

let package = Package(
    name: "OutflowCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "OutflowCore", targets: ["OutflowCore"]),
    ],
    targets: [
        .target(
            name: "OutflowCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "OutflowCoreTests",
            dependencies: ["OutflowCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
