import XCTest
@testable import E2EBridgeCore

/// Verifies E2EDispatcher routing: `debug.*` delegation to the driver, registry ops, the fallback
/// closure, and the `unknown_op` terminal. The driver is a stub so no live app is needed.
@MainActor
final class E2EDispatcherTests: XCTestCase {

    // MARK: - Test doubles

    /// Stub bridge for debug.* delegation — observe ops return the given captures/tree, control ops
    /// return the given result. When `actionError` is set, control ops throw it (error-mapping check).
    @MainActor private final class StubDebugBridge: DebugBridge {
        let shots: [ScreenshotShot]
        let axNodes: [AXNode]
        /// Result perform/setValue returns (defaults to a stub — setValue echoes the value set).
        let actionResult: AXActionResult?
        /// When set, perform/setValue throw this instead of returning a result.
        let actionError: DebugBridgeError?
        init(shots: [ScreenshotShot] = [], axNodes: [AXNode] = [],
             actionResult: AXActionResult? = nil, actionError: DebugBridgeError? = nil) {
            self.shots = shots
            self.axNodes = axNodes
            self.actionResult = actionResult
            self.actionError = actionError
        }
        func screenshot() -> [ScreenshotShot] { shots }
        func uiTree() async -> [AXNode] { axNodes }
        func perform(identifier: String) async throws -> AXActionResult {
            if let actionError { throw actionError }
            return actionResult ?? AXActionResult(identifier: identifier, role: "AXButton", label: nil, value: nil)
        }
        func setValue(identifier: String, value: String) async throws -> AXActionResult {
            if let actionError { throw actionError }
            return actionResult ?? AXActionResult(identifier: identifier, role: "AXTextField", label: nil, value: value)
        }
        func type(identifier: String?, text: String) async throws -> AXActionResult {
            if let actionError { throw actionError }
            return actionResult ?? AXActionResult(identifier: identifier ?? "(focused)", role: "AXTextField", label: nil, value: text)
        }
        func key(name: String, modifiers: [String]) async throws -> AXActionResult {
            if let actionError { throw actionError }
            return actionResult ?? AXActionResult(identifier: (modifiers + [name]).joined(separator: "+"), role: "AXKey", label: nil, value: nil)
        }
    }

    /// Mirrors the dispatcher's private `ScreenshotResult` to decode the result JSONValue.
    private struct ScreenshotResultMirror: Decodable { let windows: [ScreenshotShot] }
    /// Mirrors the dispatcher's private `UITreeResult` to decode the result JSONValue.
    private struct UITreeResultMirror: Decodable { let windows: [AXNode] }

    /// A non-E2EOpError thrown by a registry handler (must map to `internal`).
    private struct BoomError: Error {}

    private func makeDispatcher(
        driver: (any DebugBridge)? = nil,
        registry: E2EOpRegistry = E2EOpRegistry(),
        fallback: (@Sendable (IPCRequest) async -> IPCResponse?)? = nil
    ) -> E2EDispatcher {
        E2EDispatcher(driver: driver, registry: registry, fallback: fallback)
    }

    // MARK: - debug.screenshot

    func testScreenshotReturnsWindows() async throws {
        // The injected bridge's capture list is serialized verbatim into result.windows.
        let shot = ScreenshotShot(title: "Demo", contentType: "image/png", dataBase64: "AAAA", width: 1180, height: 780)
        let response = await makeDispatcher(driver: StubDebugBridge(shots: [shot])).handle(IPCRequest(op: "debug.screenshot"))
        XCTAssertTrue(response.ok)
        let decoded = try XCTUnwrap(response.result).decoded(as: ScreenshotResultMirror.self)
        XCTAssertEqual(decoded.windows, [shot])
    }

    func testScreenshotUnsupportedWhenNoDriver() async {
        // No driver injected → unsupported.
        let response = await makeDispatcher().handle(IPCRequest(op: "debug.screenshot"))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "unsupported")
    }

    // MARK: - debug.ui_tree

    func testUITreeReturnsWindows() async throws {
        // The injected bridge's accessibility tree is serialized verbatim into result.windows.
        let node = AXNode(role: "AXWindow", identifier: "main", label: "Demo", value: nil,
                          enabled: true, focused: true,
                          frame: AXFrame(x: 0, y: 0, width: 1180, height: 780), children: [])
        let response = await makeDispatcher(driver: StubDebugBridge(axNodes: [node])).handle(IPCRequest(op: "debug.ui_tree"))
        XCTAssertTrue(response.ok)
        let decoded = try XCTUnwrap(response.result).decoded(as: UITreeResultMirror.self)
        XCTAssertEqual(decoded.windows, [node])
    }

    func testUITreeUnsupportedWhenNoDriver() async {
        let response = await makeDispatcher().handle(IPCRequest(op: "debug.ui_tree"))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "unsupported")
    }

    // MARK: - debug.ui_perform (AXPress)

    func testUIPerformReturnsResult() async throws {
        // The injected bridge's AXActionResult is serialized directly as the result (no wrapper).
        let result = AXActionResult(identifier: "save-button", role: "AXButton", label: "Save", value: nil)
        let response = await makeDispatcher(driver: StubDebugBridge(actionResult: result)).handle(
            IPCRequest(op: "debug.ui_perform", args: .object(["identifier": .string("save-button")]))
        )
        XCTAssertTrue(response.ok)
        let decoded = try XCTUnwrap(response.result).decoded(as: AXActionResult.self)
        XCTAssertEqual(decoded, result)
        XCTAssertEqual(response.result?["role"]?.stringValue, "AXButton")
    }

    func testUIPerformUnsupportedWhenNoDriver() async {
        let response = await makeDispatcher().handle(
            IPCRequest(op: "debug.ui_perform", args: .object(["identifier": .string("save-button")]))
        )
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "unsupported")
    }

    func testUIPerformMissingIdentifierIsInvalidArgs() async {
        // Missing identifier → invalid_args (DispatchError caught before internal).
        let response = await makeDispatcher(driver: StubDebugBridge()).handle(
            IPCRequest(op: "debug.ui_perform", args: .object([:]))
        )
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "invalid_args")
    }

    func testUIPerformNotFoundMapsToErrorCode() async {
        // A DebugBridgeError thrown by the bridge maps to a stable code (not_found), not internal.
        let response = await makeDispatcher(driver: StubDebugBridge(actionError: .notFound("No element with that identifier."))).handle(
            IPCRequest(op: "debug.ui_perform", args: .object(["identifier": .string("missing")]))
        )
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "not_found")
        XCTAssertEqual(response.error?.message, "No element with that identifier.")
    }

    // MARK: - debug.ui_set_value

    func testUISetValueEchoesValue() async {
        // The default stub echoes the value that was set.
        let response = await makeDispatcher(driver: StubDebugBridge()).handle(
            IPCRequest(op: "debug.ui_set_value", args: .object(["identifier": .string("title-field"), "value": .string("New title")]))
        )
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?["identifier"]?.stringValue, "title-field")
        XCTAssertEqual(response.result?["value"]?.stringValue, "New title")
    }

    func testUISetValueMissingValueIsInvalidArgs() async {
        // Missing value → invalid_args (SetValueArgs decode failure).
        let response = await makeDispatcher(driver: StubDebugBridge()).handle(
            IPCRequest(op: "debug.ui_set_value", args: .object(["identifier": .string("title-field")]))
        )
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "invalid_args")
    }

    // MARK: - debug.type / debug.key

    func testTypeReturnsResult() async {
        let response = await makeDispatcher(driver: StubDebugBridge()).handle(
            IPCRequest(op: "debug.type", args: .object(["text": .string("hello")]))
        )
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?["value"]?.stringValue, "hello")
    }

    func testKeyReturnsResult() async {
        let response = await makeDispatcher(driver: StubDebugBridge()).handle(
            IPCRequest(op: "debug.key", args: .object(["key": .string("return"), "modifiers": .array([.string("command")])]))
        )
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?["identifier"]?.stringValue, "command+return")
    }

    // MARK: - debug.ping (always answers)

    func testDebugPingWorksWithNilDriverAndReturnsPid() async {
        // Answers even without a driver, reporting process liveness/version.
        let response = await makeDispatcher(driver: nil).handle(IPCRequest(op: "debug.ping"))
        XCTAssertTrue(response.ok)
        if case .bool(true) = response.result?["ok"] {} else { XCTFail("ping should report ok=true") }
        XCTAssertEqual(response.result?["pid"]?.intValue, Int(ProcessInfo.processInfo.processIdentifier))
        XCTAssertEqual(response.result?["version"]?.stringValue, E2EBridgeVersion.current)
    }

    // MARK: - Registry ops

    func testRegistryHitReturnsResult() async throws {
        let registry = E2EOpRegistry()
        registry.register("todos.count") { _ in try JSONValue(encoding: 3) }
        let response = await makeDispatcher(registry: registry).handle(IPCRequest(op: "todos.count"))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?.intValue, 3)
    }

    func testRegistryReceivesArgs() async {
        let registry = E2EOpRegistry()
        registry.register("echo") { args in args?["id"] ?? .null }
        let response = await makeDispatcher(registry: registry).handle(
            IPCRequest(op: "echo", args: .object(["id": .string("abc")]))
        )
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?.stringValue, "abc")
    }

    func testRegistryHandlerThrowingE2EOpErrorSurfacesCode() async {
        let registry = E2EOpRegistry()
        registry.register("boom") { _ in throw E2EOpError(code: "custom_code", message: "custom message") }
        let response = await makeDispatcher(registry: registry).handle(IPCRequest(op: "boom"))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "custom_code")
        XCTAssertEqual(response.error?.message, "custom message")
    }

    func testRegistryHandlerThrowingOtherErrorIsInternal() async {
        let registry = E2EOpRegistry()
        registry.register("boom") { _ in throw BoomError() }
        let response = await makeDispatcher(registry: registry).handle(IPCRequest(op: "boom"))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "internal")
    }

    // MARK: - Fallback + unknown op

    func testFallbackConsultedAfterRegistryMiss() async {
        let response = await makeDispatcher(fallback: { request in
            .success(.object(["fell_back": .string(request.op)]))
        }).handle(IPCRequest(op: "not.registered"))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?["fell_back"]?.stringValue, "not.registered")
    }

    func testRegistryTakesPrecedenceOverFallback() async {
        let registry = E2EOpRegistry()
        registry.register("shared") { _ in .string("from-registry") }
        let response = await makeDispatcher(registry: registry, fallback: { _ in .success(.string("from-fallback")) })
            .handle(IPCRequest(op: "shared"))
        XCTAssertEqual(response.result?.stringValue, "from-registry")
    }

    func testUnknownOpWhenNoRegistryOrFallback() async {
        let response = await makeDispatcher().handle(IPCRequest(op: "nope"))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "unknown_op")
    }

    func testFallbackReturningNilFallsThroughToUnknownOp() async {
        // A fallback that declines (nil) still ends at unknown_op.
        let response = await makeDispatcher(fallback: { _ in nil }).handle(IPCRequest(op: "nope"))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "unknown_op")
    }
}
