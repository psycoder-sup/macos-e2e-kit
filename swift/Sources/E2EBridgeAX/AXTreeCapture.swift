import ApplicationServices
import E2EBridgeCore
import Foundation

/// Queries the running app via the `AXUIElement` API and dumps the full accessibility tree SwiftUI composed,
/// as `AXNode` (for E2E observation/addressing). Same path as Accessibility Inspector — an in-process
/// `NSAccessibility` walk only surfaces AppKit-backing elements and yields an almost-empty tree for SwiftUI
/// apps, while `AXUIElement` returns the composed tree.
///
/// Traversal happens on the **main actor**. Self AX queries evaluate SwiftUI's accessibility providers
/// (view bodies) **inline on the calling thread**, and those bodies read `@MainActor` state — so evaluating
/// off-main hits an isolation assert and **SIGTRAPs** (confirmed live via E2E — an off-main ui_tree call
/// while the accessibility cache is dirty crashed mid-evaluation of `InboxView.topbarTrailing`). Because
/// self AX calls run inline on the calling thread, calling on main doesn't deadlock, and the body evaluates
/// on main safely. The depth/node ceilings guard against both SwiftUI tree blowups and any accidental cycles.
///
/// Shared constants, attribute copying, and root selection are owned by `AXElement` (shared with the
/// manipulation path, `AXPerform`).
enum AXTreeCapture {
    /// Walks the running app's accessibility tree **on the main actor** (see the doc comment above — off-main
    /// self-queries crash). Stays `async` to match the call contract (`AppKitDebugBridge.uiTree` is `await`ed)
    /// — there's no actual suspension point.
    @MainActor
    static func captureTrees() async -> [AXNode] {
        AXElement.roots(pid: getpid()).compactMap { root in
            var budget = AXElement.maxNodes
            return node(from: root, depth: 0, budget: &budget)
        }
    }

    /// Turns one element into an `AXNode`. nil past the depth/budget ceiling. Attribute copying is
    /// failure-tolerant (falls back to defaults — best-effort).
    private static func node(from element: AXUIElement, depth: Int, budget: inout Int) -> AXNode? {
        guard depth < AXElement.maxDepth, budget > 0 else { return nil }
        budget -= 1

        let role = AXElement.copyString(element, kAXRoleAttribute) ?? "AXUnknown"
        let idRaw = AXElement.copyString(element, kAXIdentifierAttribute)
        let identifier = (idRaw?.isEmpty == false) ? idRaw : nil
        let label = AXElement.copyString(element, kAXTitleAttribute) ?? AXElement.copyString(element, kAXDescriptionAttribute)
        // The value type may not be a String (numbers, toggles, etc.), so stringify with String(describing:)
        // and truncate to the cap.
        let value = AXElement.stringValue(element)
        let enabled = AXElement.copyBool(element, kAXEnabledAttribute) ?? true
        let focused = AXElement.copyBool(element, kAXFocusedAttribute) ?? false
        let frame = copyFrame(element)

        var children: [AXNode] = []
        if let kids = AXElement.copyChildren(element, kAXChildrenAttribute) {
            for kid in kids {
                if budget <= 0 { break }
                if let child = node(from: kid, depth: depth + 1, budget: &budget) { children.append(child) }
            }
        }
        return AXNode(role: role, identifier: identifier, label: label, value: value,
                      enabled: enabled, focused: focused, frame: frame, children: children)
    }

    /// Combines position (kAXPosition) + size (kAXSize) AXValues into a screen-coordinate frame
    /// (observation-only — manipulation doesn't need it). Missing axes default to 0.
    private static func copyFrame(_ element: AXUIElement) -> AXFrame {
        var origin = CGPoint.zero
        var size = CGSize.zero
        if let posRef = AXElement.copyRaw(element, kAXPositionAttribute), CFGetTypeID(posRef) == AXValueGetTypeID() {
            AXValueGetValue(posRef as! AXValue, .cgPoint, &origin)
        }
        if let sizeRef = AXElement.copyRaw(element, kAXSizeAttribute), CFGetTypeID(sizeRef) == AXValueGetTypeID() {
            AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        }
        // SwiftUI elements can report non-finite axes (e.g. an un-laid-out view or a
        // `.frame(maxWidth: .infinity)` surfaced literally). A default JSONEncoder rejects
        // non-finite Doubles ("data couldn't be written… correct format"), which would fail
        // the whole `tree` op — clamp to 0 so capture stays serializable.
        func finite(_ v: CGFloat) -> Double { let d = Double(v); return d.isFinite ? d : 0 }
        return AXFrame(x: finite(origin.x), y: finite(origin.y),
                       width: finite(size.width), height: finite(size.height))
    }
}
