// swift-tools-version: 6.0
import PackageDescription

// A minimal, bare SwiftPM executable that embeds the kit's E2EBridge package and drives its own
// accessibility tree — the kit's self-verification target (see ../../README.md, harness.sh).
let package = Package(
    name: "DemoApp",
    platforms: [.macOS(.v14)],
    dependencies: [
        // The kit's Swift package, referenced by relative path from this example.
        .package(path: "../../swift"),
    ],
    targets: [
        .executableTarget(
            name: "DemoApp",
            dependencies: [
                // Path-based dependency: the package identity is the directory name ("swift").
                .product(name: "E2EBridge", package: "swift"),
            ]
        ),
    ]
)
