import Foundation

/// Debug-only observe/control bridge for a running app — the dispatcher delegates `debug.*`
/// ops to this bridge.
///
/// The implementation is owned by the app target (it needs AppKit) and injected into the
/// dispatcher by the host. Release builds do not inject one (`nil`), so the dispatcher rejects
/// `debug.*` with `unsupported` — only the contract (this protocol) lives in the core.
/// Observe ops: screen capture (`screenshot`) and the accessibility tree (`uiTree`).
///
/// `@MainActor` — window/view rendering is main-thread only, so the entire bridge surface is
/// pinned to the main actor.
@MainActor
public protocol DebugBridge {
    /// Captures the app's currently visible windows via an in-process render. Independent of
    /// focus/occlusion and needs no screen-recording (TCC) permission.
    func screenshot() -> [ScreenshotShot]

    /// Dumps the running app's accessibility tree via `AXUIElement` (one node per window/root).
    /// Captures SwiftUI's synthesized tree as well.
    ///
    /// Querying your own process **synchronously** on the main thread deadlocks — the AX server
    /// calls back into the app's main run loop to answer, but if the main thread is blocked inside
    /// an AX call it cannot respond (25s IPC timeout). So the tree walk runs off-main (background)
    /// and this surface is `async`: while the caller `await`s, the main actor is free to service the
    /// AX callback. May require Accessibility (TCC) permission (handled at runtime).
    func uiTree() async -> [AXNode]

    /// Presses the element with the given accessibility identifier (AXPress). Same off-main rule as
    /// uiTree because it queries the app's own process (async).
    func perform(identifier: String) async throws -> AXActionResult

    /// Sets the value of the element (e.g. a text field) with the given accessibility identifier.
    func setValue(identifier: String, value: String) async throws -> AXActionResult

    /// Types text into the focused (or `identifier`-targeted) element via **real key events**. Unlike
    /// `setValue`, which only mutates the AX value and can miss SwiftUI bindings (@State/@Binding),
    /// this drives the real input path so form validation and submission (`canSubmit`/`.onSubmit`)
    /// react exactly as if a person typed. When `identifier` is nil, types into the current focus.
    func type(identifier: String?, text: String) async throws -> AXActionResult

    /// Sends a named key (with optional modifiers) to the app — e.g. return+command to submit,
    /// escape to dismiss, tab to move focus. The "input" phase of the observe→input loop; it fires
    /// key equivalents and onSubmit just as a person pressing the key would.
    func key(name: String, modifiers: [String]) async throws -> AXActionResult

    /// Brings the app to the foreground: reverses background-driven mode (`.accessory` back to
    /// `.regular`) when active, then activates the app and surfaces a window. In-process
    /// self-activation — needs no TCC permission.
    func activate()
}

extension DebugBridge {
    /// Default no-op so pre-existing custom conformers keep compiling — `debug.activate` then
    /// answers ok without doing anything; implement `activate()` to support foregrounding.
    public func activate() {}
}

/// One captured window — base64 image + logical size (pt) and window title. The bridge serializes
/// it verbatim across the wire.
public struct ScreenshotShot: Sendable, Codable, Equatable {
    /// Window title (or identifier/`window` if absent). A label to tell multiple windows apart
    /// (main + sheet).
    public let title: String
    /// `"image/png"` or `"image/jpeg"` (size-overflow fallback). The mimeType of the image content.
    public let contentType: String
    /// Base64 of the image bytes — carried as the `data` of the image content.
    public let dataBase64: String
    /// Logical width (pt) of the captured content view.
    public let width: Int
    /// Logical height (pt) of the captured content view.
    public let height: Int

    public init(title: String, contentType: String, dataBase64: String, width: Int, height: Int) {
        self.title = title
        self.contentType = contentType
        self.dataBase64 = dataBase64
        self.width = width
        self.height = height
    }
}

/// An accessibility tree node — the UI structure (role, identifier, label, value, state, frame)
/// built by walking a window's content view in-process. Each window's root becomes one array
/// element (returned by `uiTree()`).
public struct AXNode: Sendable, Codable, Equatable {
    /// Accessibility role (e.g. `"AXWindow"`/`"AXButton"`).
    public let role: String
    /// View identifier (nil if absent) — the accessibility identifier used as a stable selector.
    public let identifier: String?
    /// Label/title (nil if absent).
    public let label: String?
    /// Value (nil if absent) — e.g. text-field contents.
    public let value: String?
    /// Whether the element is enabled.
    public let enabled: Bool
    /// Whether the element is focused.
    public let focused: Bool
    /// Screen-coordinate frame (pt).
    public let frame: AXFrame
    /// Child nodes (empty array for a leaf).
    public let children: [AXNode]

    public init(role: String, identifier: String?, label: String?, value: String?,
                enabled: Bool, focused: Bool, frame: AXFrame, children: [AXNode]) {
        self.role = role
        self.identifier = identifier
        self.label = label
        self.value = value
        self.enabled = enabled
        self.focused = focused
        self.frame = frame
        self.children = children
    }
}

/// Screen-coordinate frame of an accessibility element (pt).
public struct AXFrame: Sendable, Codable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Result of a control op (`perform`/`setValue`) — a summary of the matched/manipulated element.
/// The bridge serializes it verbatim across the wire.
public struct AXActionResult: Sendable, Codable, Equatable {
    /// The target identifier (the requested accessibility identifier verbatim).
    public let identifier: String
    /// The AX role of the matched element (e.g. `"AXButton"`).
    public let role: String
    /// Title/description (if any).
    public let label: String?
    /// set_value: the new value that was set; perform: the current value if readable (else nil).
    public let value: String?

    public init(identifier: String, role: String, label: String?, value: String?) {
        self.identifier = identifier
        self.role = role
        self.label = label
        self.value = value
    }
}

/// A control-op failure — the dispatcher converts each case's `code`/`message` into an error
/// envelope (only the contract lives in the AX-free core).
public enum DebugBridgeError: Error, Sendable {
    /// No element with that identifier (code `"not_found"`).
    case notFound(String)
    /// The element has no AXPress action (code `"action_unavailable"`).
    case actionUnavailable(String)
    /// `AXUIElementPerformAction` did not return `.success` (code `"perform_failed"`).
    case performFailed(String)
    /// The value could not be set / setting failed (code `"set_failed"`).
    case setFailed(String)

    /// Stable error code — each case maps to a fixed string (branched on at the bridge/wire boundary).
    public var code: String {
        switch self {
        case .notFound: return "not_found"
        case .actionUnavailable: return "action_unavailable"
        case .performFailed: return "perform_failed"
        case .setFailed: return "set_failed"
        }
    }

    /// Human-readable reason — the associated string verbatim.
    public var message: String {
        switch self {
        case .notFound(let message),
             .actionUnavailable(let message),
             .performFailed(let message),
             .setFailed(let message):
            return message
        }
    }
}
