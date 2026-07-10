import ApplicationServices
import Foundation

/// **Shared** constants, element helpers, and root selection for in-process accessibility tree walks of our
/// own process. Both observation (`AXTreeCapture`) and manipulation (`AXPerform`) share this one place
/// (avoids duplication) so that attribute-copying or traversal-budget tweaks don't let the two paths
/// silently diverge. This is pure AX reads, so it's **thread-agnostic** — which thread calls it is up to
/// the caller (self-queries drive SwiftUI `@MainActor` body evaluation, so callers call it on main — see
/// the `AXTreeCapture`/`AXPerform` comments).
enum AXElement {
    /// Traversal ceiling (shared by observation and manipulation) that guards against SwiftUI tree blowups
    /// and cycles.
    static let maxDepth = 60
    static let maxNodes = 8000
    static let maxValueChars = 200

    /// Traversal roots: the app's windows (if none, the app's children; if none of those, the app element
    /// itself). Callers give each root an **independent** node budget — so one window exhausting the budget
    /// doesn't starve traversal of another window.
    static func roots(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        let windows = copyChildren(app, kAXWindowsAttribute) ?? []
        let children = windows.isEmpty ? (copyChildren(app, kAXChildrenAttribute) ?? []) : windows
        return children.isEmpty ? [app] : children
    }

    // MARK: - Attribute copying (best-effort — nil unless the copy succeeds)

    /// Copies the attribute's raw CFTypeRef (the shared base for string/bool/children/value parsing). nil on failure.
    static func copyRaw(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref
    }

    /// String attribute (role, identifier, title, etc.). Only succeeds and casts to String give a value.
    static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        copyRaw(element, attribute) as? String
    }

    /// Bool attribute (enabled, focused, etc.). Only a CFBoolean → Bool cast gives a value (nil if the
    /// attribute is absent → caller falls back to a default).
    static func copyBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        copyRaw(element, attribute) as? Bool
    }

    /// Element-array attribute (windows, children). Only a CFArray → [AXUIElement] cast gives a value (nil
    /// if absent → leaf/fallback).
    static func copyChildren(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        copyRaw(element, attribute) as? [AXUIElement]
    }

    /// Stringifies the value attribute (may not be a String, so uses String(describing:)), truncated to the
    /// cap. nil if the read fails.
    static func stringValue(_ element: AXUIElement) -> String? {
        copyRaw(element, kAXValueAttribute).map { String(String(describing: $0).prefix(maxValueChars)) }
    }
}
