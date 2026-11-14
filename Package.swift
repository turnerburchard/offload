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
        // SwiftUI app.
        .executableTarget(name: "Offload", dependencies: ["OffloadCore", "Updater"]),
        // Self-test against fake volumes in a temp dir (XCTest isn't available with Command Line Tools only).
        .executableTarget(name: "offload-selftest", dependencies: ["OffloadCore", "Updater"]),
    ],
    swiftLanguageModes: [.v5]
)
