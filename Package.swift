// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WatchFolder",
    platforms: [.macOS(.v13)],
    targets: [
        // All logic lives here so it can be tested without XCTest.
        .target(name: "WatchFolderCore"),
        // The GUI app.
        .executableTarget(name: "WatchFolder", dependencies: ["WatchFolderCore"]),
        // Background process installed by the GUI app's LaunchAgent.
        .executableTarget(name: "WatchFolderService", dependencies: ["WatchFolderCore"]),
        // XCTest replacement: `swift run SelfTests` (exit code 0 = pass).
        .executableTarget(name: "SelfTests", dependencies: ["WatchFolderCore"]),
    ]
)
