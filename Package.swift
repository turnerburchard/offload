// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Offload",
    platforms: [.macOS(.v14)],
    targets: [
        // UI-free engine: card scan, planning, rsync, MD5 verification, verdict, logs.
        .target(name: "OffloadCore"),
        // GitHub Releases self-updater (no UI; tested offline by the self-test).
        .target(name: "Updater"),
        // "Ask Claude": runs Claude Code on this app's own source, verifies + commits the result (no UI).
        .target(name: "Assistant", dependencies: ["Updater"]),
        // SwiftUI app.
        .executableTarget(name: "Offload", dependencies: ["OffloadCore", "Updater", "Assistant"]),
        // Self-test against fake volumes in a temp dir (XCTest isn't available with Command Line Tools only).
        .executableTarget(name: "offload-selftest", dependencies: ["OffloadCore", "Updater", "Assistant"]),
    ],
    swiftLanguageModes: [.v5]
)
