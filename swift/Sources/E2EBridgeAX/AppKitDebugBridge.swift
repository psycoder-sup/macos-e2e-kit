import AppKit
import E2EBridgeCore

/// The `DebugBridge` implementation for AppKit/SwiftUI apps — the concrete driver `E2EBridgeServer` uses by
/// default. Delegates observation (screenshot, uiTree) to `WindowCapture`/`AXTreeCapture` and control
/// (perform, setValue, type, key) to `AXPerform`. Host apps inject one instance when wiring up the debug
/// bridge (see docs/integration.md).
@MainActor
public final class AppKitDebugBridge: DebugBridge {
    /// Constructing the bridge is the one thing every onboarded app does at launch, so it doubles as
    /// the hook that keeps a harness-driven run from stealing the user's focus.
    public init() {
        BackgroundDrivenMode.applyIfRequested()
    }

    public func screenshot() -> [ScreenshotShot] {
        WindowCapture.captureVisibleWindows()
    }

    public func uiTree() async -> [AXNode] {
        await AXTreeCapture.captureTrees()
    }

    public func perform(identifier: String) async throws -> AXActionResult {
        try AXPerform.perform(identifier: identifier)
    }

    public func setValue(identifier: String, value: String) async throws -> AXActionResult {
        try AXPerform.setValue(identifier: identifier, value: value)
    }

    public func type(identifier: String?, text: String) async throws -> AXActionResult {
        try AXPerform.type(identifier: identifier, text: text)
    }

    public func key(name: String, modifiers: [String]) async throws -> AXActionResult {
        try AXPerform.key(name: name, modifiers: modifiers)
    }

    public func activate() {
        BackgroundDrivenMode.foreground()
        for window in NSApp.windows where window.isMiniaturized { window.deminiaturize(nil) }
        (NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible })?
            .makeKeyAndOrderFront(nil)
    }
}
