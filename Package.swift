// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FinderRescue",
    platforms: [.macOS(.v15)],
    targets: [
        // Monitoring, detection and repair logic — no UI, unit-tested.
        .target(name: "FinderRescueCore", path: "Sources/FinderRescueCore"),
        // The menu-bar app.
        .executableTarget(name: "FinderRescue", dependencies: ["FinderRescueCore"], path: "Sources/FinderRescue"),
        .testTarget(name: "FinderRescueCoreTests", dependencies: ["FinderRescueCore"], path: "Tests/FinderRescueCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
