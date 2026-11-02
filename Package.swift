// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Pixora",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Pixora", targets: ["Pixora"]),
        .executable(name: "pixora-eval", targets: ["PixoraEval"]),
    ],
    targets: [
        // Everything that is not UI: database, scanning, faces, matching, export. No third-party deps.
        .target(name: "PixoraCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "Pixora", dependencies: ["PixoraCore"]),
        // Command-line accuracy harness used to calibrate thresholds on a labelled face dataset.
        .executableTarget(name: "PixoraEval", dependencies: ["PixoraCore"]),
        .testTarget(name: "PixoraCoreTests", dependencies: ["PixoraCore"]),
    ]
)
