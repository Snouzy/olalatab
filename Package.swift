// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "olalatab",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "olalatab", targets: ["olalatab"]),
    ],
    targets: [
        // Thin C bridge over private SkyLight / HIServices symbols (loaded with dlsym).
        .target(name: "CSkyLight"),
        // Window filtering, ordering, Tab cycling, config and stats: testable without a keyboard.
        .target(name: "OlalaCore"),
        .executableTarget(name: "olalatab", dependencies: ["OlalaCore", "CSkyLight"]),
        // Small AppKit app with three windows, used by the bench (and frozen with SIGSTOP).
        .executableTarget(name: "olala-fixture"),
        .testTarget(name: "OlalaCoreTests", dependencies: ["OlalaCore"]),
    ]
)
