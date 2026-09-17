// swift-tools-version: 6.0
import PackageDescription

// Platform-neutral Portlight viewer core. Builds for iOS (the app) and macOS (fast local
// `swift test` against an isolated fixture host, no Xcode required).
let package = Package(
    name: "PortlightKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PortlightKit", targets: ["PortlightKit"]),
    ],
    targets: [
        .target(
            name: "PortlightKit",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "PortlightKitTests",
            dependencies: ["PortlightKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
