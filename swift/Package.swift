// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "E2EBridge",
    platforms: [.macOS(.v14)],
    products: [
        // One library exporting both targets: the Foundation-only core (protocols, IPC,
        // socket server, dispatcher) and the AppKit driver that observes/controls a live app.
        .library(name: "E2EBridge", targets: ["E2EBridgeCore", "E2EBridgeAX"]),
    ],
    targets: [
        // Foundation-only — testable headless with `swift test`.
        .target(name: "E2EBridgeCore"),
        // AppKit driver (accessibility tree, event synthesis, window capture).
        // Sources are authored separately; this target only depends on the core contracts.
        .target(name: "E2EBridgeAX", dependencies: ["E2EBridgeCore"]),
        .testTarget(name: "E2EBridgeCoreTests", dependencies: ["E2EBridgeCore"]),
    ]
)
