import AppKit
import E2EBridgeCore

/// Renders the running app's visible windows in-process and captures them as images (for E2E observation).
///
/// `cacheDisplay(in:to:)` redraws the window into an offscreen bitmap — it doesn't read screen pixels, so it
/// works regardless of focus/occlusion/off-screen position and needs no Screen Recording (TCC) permission.
/// Targets are the main window and any open sheets (child windows). MenuBarExtra popovers (transient
/// NSPanels) and window-server-composited vibrancy/glass backgrounds may not be captured this way (acceptable
/// since the goal is observing foreground content/layout).
@MainActor
enum WindowCapture {
    /// Max long edge (px) of a captured image — larger images are downscaled proportionally to comfortably
    /// fit the IPC frame (4MiB).
    static let maxPixelSize = 1280

    /// Per-image raw size ceiling — kept low enough that even after base64 (~1.37x) there's headroom in the
    /// frame (IPCWire.maxPayloadBytes = 4 MiB).
    static let maxImageBytes = 2_400_000        // ~3.3 MiB as base64
    /// Total base64 ceiling for one response — kept below the frame limit (4 MiB) with headroom (multiple
    /// windows plus the JSON envelope).
    static let maxTotalBase64Bytes = 3_500_000

    /// Captures all currently visible app windows (main + open sheets). Windows that fail to capture are
    /// silently skipped.
    ///
    /// Serializes multiple windows' base64 into one frame, so it stops just before exceeding the cumulative
    /// budget (`maxTotalBase64Bytes`) — a partial result beats total failure, and putting the key/main window
    /// first means the most relevant window survives.
    static func captureVisibleWindows() -> [ScreenshotShot] {
        var shots: [ScreenshotShot] = []
        var total = 0
        for window in targetWindows() {
            guard let shot = shot(for: window) else { continue }
            // Adding this window would exceed the frame budget and we already have at least one — stop (a
            // partial result beats total failure).
            if !shots.isEmpty, total + shot.dataBase64.count > maxTotalBase64Bytes { break }
            shots.append(shot)
            total += shot.dataBase64.count
        }
        return shots
    }

    /// Capture targets — visible, has a contentView, not an NSPanel (menu bar popovers etc.), and at least a
    /// standard size. Puts the key/main window first (so a partial result keeps the most relevant window),
    /// preserving relative order otherwise. Exposed as internal so `AXTreeCapture` can reuse exactly the same
    /// window set as the screenshot.
    static func targetWindows() -> [NSWindow] {
        let filtered = NSApp.windows.filter { window in
            window.isVisible
                && !(window is NSPanel)
                && window.contentView != nil
                && window.frame.width >= 200
                && window.frame.height >= 100
        }
        // Stable partition — `sorted(by:)` doesn't guarantee relative order within equal rank, so filter and
        // concatenate instead.
        return filtered.filter { rank($0) == 0 } + filtered.filter { rank($0) == 1 }
    }

    /// Puts the key/main window first (so a partial result keeps the most relevant window). Otherwise
    /// preserves order.
    private static func rank(_ window: NSWindow) -> Int {
        (window.isKeyWindow || window.isMainWindow) ? 0 : 1
    }

    /// Renders one window's content view into a `ScreenshotShot`. nil on failure.
    private static func shot(for window: NSWindow) -> ScreenshotShot? {
        guard let view = window.contentView else { return nil }
        let bounds = view.bounds
        guard bounds.width >= 1, bounds.height >= 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        guard let payload = try? ImageAttachment.normalize(
            png, filename: "window.png", maxPixelSize: maxPixelSize, maxByteSize: maxImageBytes
        ) else { return nil }
        let title = window.title.isEmpty ? (window.identifier?.rawValue ?? "window") : window.title
        return ScreenshotShot(
            title: title,
            contentType: payload.contentType,
            dataBase64: payload.dataBase64,
            width: Int(bounds.width.rounded()),
            height: Int(bounds.height.rounded())
        )
    }
}
