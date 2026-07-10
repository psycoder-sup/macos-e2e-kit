import AppKit
import E2EBridgeAX
import E2EBridgeCore
import SwiftUI

// This demo ships as a *bare* SwiftPM executable — no .app bundle, no Info.plist — so
// `Bundle.main.bundleIdentifier` is nil at runtime and the bridge can't derive a socket directory
// from it. We pass an explicit, stable bundle id instead; harness.sh computes the same path from its
// BUNDLE_ID, so both sides agree on where the socket lives.
private let demoBundleID = "dev.macos-e2e-kit.demo"

/// Owns the window, model, and E2E bridge, wiring them up once AppKit has finished launching.
///
/// Bringing the window up (and starting the bridge) from `applicationDidFinishLaunching` — rather
/// than before `app.run()` — is what makes the accessibility tree populate for a bare executable:
/// the process must be a fully-initialized `.regular` GUI app before its own AX tree is queryable.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = ItemsModel()
    private var window: NSWindow?
    private var bridge: E2EBridgeServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "DemoApp"
        window.contentView = NSHostingView(rootView: ContentView(model: model))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)

        // Start the bridge now that the window exists, so a connecting client sees a populated AX
        // tree. The socket opens only on start(), and PeerVerifier gates every connection.
        let bridge = E2EBridgeServer(
            driver: AppKitDebugBridge(),
            socketPath: E2ESocketPath.default(bundleID: demoBundleID)
        )
        // App-specific side-channel op: encode the current items array so tests can cross-check the
        // model directly instead of only reading it back out of the AX tree.
        bridge.registry.register("demo.state") { [model] _ in
            let items = await MainActor.run { model.items }
            return try JSONValue(encoding: items)
        }
        try? bridge.start()
        self.bridge = bridge
    }
}

let app = NSApplication.shared
// .regular makes this bare executable a real, focusable GUI app (dock, menu bar, visible window) —
// required for its window to appear in the accessibility tree.
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
