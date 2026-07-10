import AppKit
import ApplicationServices
import E2EBridgeCore
import Foundation

/// Queries the running app via the `AXUIElement` API to find an element by accessibility identifier and
/// **manipulate** it (for E2E actions). Where `AXTreeCapture` observes (reads) the tree, this presses
/// (AXPress) or writes (sets) the value of an element found in it. The identifier is the same accessibility
/// identifier as the `identifier` field in an `AXTreeCapture` dump — used as a stable selector.
/// Shared constants, attribute copying, and root selection are owned by `AXElement` (shared with the
/// observation path).
///
/// ⚠️ Both finding (reading) and manipulating happen on the **main actor**. Self AX calls (Copy/Press/Set)
/// run SwiftUI's accessibility providers and button actions **inline on the calling thread**, and that code
/// enforces `@MainActor` isolation — so off-main **SIGTRAPs** (confirmed live via E2E — an off-main AXPress
/// crashed mid-evaluation of a SwiftUI ButtonAction). Because self calls run inline, calling on main doesn't
/// deadlock, and providers/actions run on main safely.
enum AXPerform {
    /// Presses the element identified by `identifier` (AXPress). Finding, inspecting, pressing, and the
    /// follow-up value read all happen on main.
    @MainActor
    static func perform(identifier: String) throws -> AXActionResult {
        let element = try findElement(pid: getpid(), identifier: identifier)
        // A disabled element can still advertise AXPress and return `.success` while doing nothing, which
        // would be mistaken for a successful press.
        guard AXElement.copyBool(element, kAXEnabledAttribute) ?? true else {
            throw DebugBridgeError.performFailed("Element '\(identifier)' is disabled and cannot be pressed.")
        }
        // Only press elements that support AXPress — otherwise fail early and clearly (wrong selector /
        // non-button element).
        guard copyActionNames(element).contains(kAXPressAction as String) else {
            throw DebugBridgeError.actionUnavailable("Element '\(identifier)' has no AXPress action.")
        }
        let status = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard status == .success else {
            throw DebugBridgeError.performFailed("Failed to perform AXPress on element '\(identifier)' (status: \(status.rawValue)).")
        }
        // Read the current value **after** performing and return it — reflects the latest state of a
        // toggle/counter (returning the pre-press value could make an agent think the press didn't register
        // and re-click).
        return result(element, identifier: identifier, value: AXElement.stringValue(element))
    }

    /// Sets the value of the element (e.g. a text field) identified by `identifier`. Finding, inspecting, and
    /// setting all happen on main.
    @MainActor
    static func setValue(identifier: String, value: String) throws -> AXActionResult {
        let element = try findElement(pid: getpid(), identifier: identifier)
        // Check settability first — throw on a non-settable attribute to avoid a futile set call (e.g. static text).
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue == false {
            throw DebugBridgeError.setFailed("Cannot set the value of element '\(identifier)' (non-settable attribute).")
        }
        let status = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef)
        guard status == .success else {
            throw DebugBridgeError.setFailed("Failed to set the value of element '\(identifier)' (status: \(status.rawValue)).")
        }
        // Return the value that was set, as-is (echoes the requested input — for confirming the manipulation).
        return result(element, identifier: identifier, value: value)
    }

    /// Summarizes a manipulated element as an `AXActionResult` (role/label are read from the element; value
    /// is passed by the caller).
    private static func result(_ element: AXUIElement, identifier: String, value: String?) -> AXActionResult {
        AXActionResult(
            identifier: identifier,
            role: AXElement.copyString(element, kAXRoleAttribute) ?? "AXUnknown",
            label: AXElement.copyString(element, kAXTitleAttribute) ?? AXElement.copyString(element, kAXDescriptionAttribute),
            value: value
        )
    }

    // MARK: - Finding elements (DFS from AXElement.roots, returns the first match)

    private static func findElement(pid: pid_t, identifier: String) throws -> AXUIElement {
        // An empty identifier is meaningless — it could match any element exposing a present-but-EMPTY
        // `kAXIdentifier`. Same convention as `AXTreeCapture` normalizing an empty identifier to nil: fail
        // deterministically with not_found before walking.
        guard !identifier.isEmpty else {
            throw DebugBridgeError.notFound("Identifier is empty.")
        }
        for root in AXElement.roots(pid: pid) {
            var budget = AXElement.maxNodes
            if let found = search(root, identifier: identifier, depth: 0, budget: &budget) {
                return found
            }
        }
        throw DebugBridgeError.notFound("No element found with identifier '\(identifier)'.")
    }

    /// DFS-walks an element's subtree for the first element whose identifier matches. nil past the
    /// depth/budget ceiling (blocks blowups/cycles).
    private static func search(_ element: AXUIElement, identifier: String,
                              depth: Int, budget: inout Int) -> AXUIElement? {
        guard depth < AXElement.maxDepth, budget > 0 else { return nil }
        budget -= 1

        if AXElement.copyString(element, kAXIdentifierAttribute) == identifier { return element }

        if let kids = AXElement.copyChildren(element, kAXChildrenAttribute) {
            for kid in kids {
                if budget <= 0 { break }
                if let found = search(kid, identifier: identifier, depth: depth + 1, budget: &budget) {
                    return found
                }
            }
        }
        return nil
    }

    /// The AX action names an element supports (e.g. `AXPress`). Empty array on failure. (Manipulation path
    /// only — observation doesn't need it.)
    private static func copyActionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    // MARK: - Key input injection (typing · key combos)

    /// Types text into the focused (or `identifier`-specified) element as real key events. Unlike setting the
    /// AX value (`setValue`), this flows NSEvents through the app's event path (`NSApp.sendEvent`) to drive
    /// text insertion (insertText), so SwiftUI bindings update too.
    @MainActor
    static func type(identifier: String?, text: String) throws -> AXActionResult {
        let window = try keyWindow()
        var target: AXUIElement?
        if let identifier {
            // Make the target the first responder first (AX kAXFocused) — so text lands in the right field
            // regardless of drawer auto-focus.
            let element = try findElement(pid: getpid(), identifier: identifier)
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            target = element
        }
        for character in text {
            let s = String(character)
            send(characters: s, ignoring: s, keyCode: 0, flags: [], to: window)
        }
        if let identifier, let target {
            return result(target, identifier: identifier, value: text)
        }
        return AXActionResult(identifier: identifier ?? "(focused)", role: "AXTextField", label: nil, value: text)
    }

    /// Sends a named key (+ modifiers) to the key window (e.g. return+command to submit, escape to dismiss,
    /// tab to move focus). Modifier combos (e.g. ⌘↵) are tried first as a key equivalent — SwiftUI's
    /// `.keyboardShortcut` is handled by the responder chain's `performKeyEquivalent`, and a synthesized
    /// event alone via `NSApp.sendEvent` won't fire it. If the key equivalent doesn't handle it (or there are
    /// no modifiers), falls back to a plain key event (first responder's onSubmit/insertText).
    @MainActor
    static func key(name: String, modifiers: [String]) throws -> AXActionResult {
        let window = try keyWindow()
        let (keyCode, characters) = try keyCodeAndCharacters(for: name)
        let flags = modifierFlags(modifiers)
        var handled = false
        if !flags.isEmpty,
           let down = NSEvent.keyEvent(
               with: .keyDown, location: .zero, modifierFlags: flags,
               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
               context: nil, characters: characters, charactersIgnoringModifiers: characters,
               isARepeat: false, keyCode: keyCode) {
            handled = window.performKeyEquivalent(with: down)
        }
        if !handled {
            send(characters: characters, ignoring: characters, keyCode: keyCode, flags: flags, to: window)
        }
        let combo = (modifiers + [name]).joined(separator: "+")
        return AXActionResult(identifier: combo, role: "AXKey", label: combo, value: handled ? "keyEquivalent" : "keyEvent")
    }

    /// The window to receive key events — if none, activates the app to make the main/target window key
    /// (covers a backgrounded app).
    @MainActor
    private static func keyWindow() throws -> NSWindow {
        if NSApp.keyWindow == nil { NSApp.activate(ignoringOtherApps: true) }
        let window = NSApp.keyWindow ?? NSApp.mainWindow ?? WindowCapture.targetWindows().first
        guard let window else {
            throw DebugBridgeError.performFailed("No window found to send key events to (no window).")
        }
        if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
        return window
    }

    /// Sends a keyDown+keyUp NSEvent pair through the app's event path (`NSApp.sendEvent`) — handles both
    /// key equivalents (⌘↵) and text input (insertText) like real input (a synthesized event still rides the
    /// responder chain).
    @MainActor
    private static func send(characters: String, ignoring: String, keyCode: UInt16,
                             flags: NSEvent.ModifierFlags, to window: NSWindow) {
        let timestamp = ProcessInfo.processInfo.systemUptime
        for phase in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(
                with: phase, location: .zero, modifierFlags: flags, timestamp: timestamp,
                windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: ignoring,
                isARepeat: false, keyCode: keyCode
            ) {
                NSApp.sendEvent(event)
            }
        }
    }

    /// Named key → (virtual key code, character). Unsupported keys fail clearly.
    private static func keyCodeAndCharacters(for name: String) throws -> (UInt16, String) {
        switch name.lowercased() {
        case "return", "enter": return (36, "\r")
        case "escape", "esc": return (53, "\u{1b}")
        case "tab": return (48, "\t")
        case "delete", "backspace": return (51, "\u{8}")
        case "space": return (49, " ")
        default:
            // A single Latin letter/digit (for shortcut E2E like ⌘N) looks up the physical key code via
            // ANSIKeyMap (SSOT independent of IME/layout).
            if let code = ANSIKeyMap.keyCode(for: name) {
                return (code, name.lowercased())
            }
            throw DebugBridgeError.performFailed("Unsupported key: '\(name)'.")
        }
    }

    /// Modifier name list → `NSEvent.ModifierFlags` (unknown names are ignored).
    private static func modifierFlags(_ names: [String]) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for name in names {
            switch name.lowercased() {
            case "command", "cmd": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "option", "alt": flags.insert(.option)
            case "control", "ctrl": flags.insert(.control)
            default: break
            }
        }
        return flags
    }
}
