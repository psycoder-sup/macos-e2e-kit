import AppKit
import Foundation

/// Keeps a harness-driven app out of the user's way: when the E2E harness launched this process
/// (`E2E_INSTANCE` is exported), the app runs with the `.accessory` activation policy — no Dock icon,
/// no activation at launch, no focus stolen from whatever the user is doing. Windows still order in
/// and render, so `shot`/`tree`/`perform` all keep working; `AXPerform` sends key events
/// window-direct, so typing works without the app ever becoming active.
///
/// Call `applyIfRequested()` as early as possible — before AppKit decides to activate the app:
/// - SwiftUI lifecycle: from `App.init()` (REQUIRED — SwiftUI activates the app during scene
///   bring-up, so by `applicationDidFinishLaunching` it's too late; verified live).
/// - AppKit `main` owners: before `app.run()` — see the DemoApp example.
/// `AppKitDebugBridge.init` also applies it as a best-effort backstop (with a launch-window
/// observer that hands focus back if the app was activated anyway), but don't rely on the
/// backstop alone for SwiftUI apps.
///
/// Set `E2E_FOREGROUND=1` to opt out and watch the app being driven in the foreground.
public enum BackgroundDrivenMode {
    /// True when the process is harness-driven (`E2E_INSTANCE` present — the explicitly-empty value
    /// counts, it's a valid instance token) and `E2E_FOREGROUND` doesn't override.
    public static var isRequested: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["E2E_INSTANCE"] != nil && (env["E2E_FOREGROUND"] ?? "").isEmpty
    }

    /// Switches the app to `.accessory` when driven (idempotent, no-op otherwise).
    ///
    /// The policy alone isn't enough for SwiftUI-lifecycle apps: SwiftUI activates the app during
    /// scene bring-up *after* the delegate callbacks where the bridge is constructed, and an
    /// `.accessory` app can still be activated programmatically — so the launch would steal focus
    /// anyway. `NSApp.deactivate()` can't undo it either (a no-op under macOS 14 cooperative
    /// activation). What works is a focus *hand-back*: remember which app the user had frontmost
    /// (captured here, before any launch activation), and the first time this app becomes active
    /// within the launch window, re-activate that app and disarm — a user who deliberately clicks
    /// the window later keeps their focus.
    @MainActor
    public static func applyIfRequested() {
        guard isRequested else { return }
        // NSApplication.shared, not NSApp: callable from SwiftUI's App.init, which runs before
        // AppKit publishes the NSApp global (shared creates the app object on demand).
        let app = NSApplication.shared
        if app.activationPolicy() != .accessory { app.setActivationPolicy(.accessory) }
        guard launchObserver == nil else { return }
        // Early in launch, frontmostApplication can be nil — menuBarOwningApplication is the
        // sturdier "who has the user's focus" probe. If both fail, hide→unhideWithoutActivation
        // makes macOS itself return focus to the previous app (the unhide restores the windows
        // on the next runloop turn, without re-activating).
        let previous = (NSWorkspace.shared.frontmostApplication ?? NSWorkspace.shared.menuBarOwningApplication)
            .flatMap { $0.processIdentifier == getpid() ? nil : $0 }
        let deadline = ProcessInfo.processInfo.systemUptime + launchWindowSeconds
        let handBack: @MainActor () -> Void = {
            if let previous {
                previous.activate()
            } else {
                NSApplication.shared.hide(nil)
                DispatchQueue.main.async { NSApplication.shared.unhideWithoutActivation() }
            }
        }
        launchObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                if ProcessInfo.processInfo.systemUptime < deadline { handBack() }
                disarm()
            }
        }
        if app.isActive { handBack(); disarm() }
    }

    /// Explicit foreground request (`debug.activate`, i.e. `harness.sh up --open`) — the inverse of
    /// `applyIfRequested()`. Disarms the launch hand-back first so this activation isn't mistaken
    /// for launch noise and immediately handed back, restores the `.regular` policy (Dock icon,
    /// focusable), and activates the app. Idempotent; also safe when background-driven mode was
    /// never applied (e.g. `E2E_FOREGROUND=1` runs).
    @MainActor
    public static func foreground() {
        disarm()
        let app = NSApplication.shared
        if app.activationPolicy() != .regular { app.setActivationPolicy(.regular) }
        app.activate(ignoringOtherApps: true)
    }

    /// How long after `applyIfRequested()` a self-activation still counts as launch noise.
    private static let launchWindowSeconds: TimeInterval = 5

    @MainActor private static var launchObserver: NSObjectProtocol?

    @MainActor private static func disarm() {
        if let observer = launchObserver {
            NotificationCenter.default.removeObserver(observer)
            launchObserver = nil
        }
    }
}
