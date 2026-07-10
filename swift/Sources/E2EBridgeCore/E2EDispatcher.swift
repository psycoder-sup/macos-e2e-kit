import Foundation

/// Routes an `IPCRequest` to its handler and builds a response envelope.
///
/// Dispatch order:
///   1. `debug.*` ops → the injected `DebugBridge` driver (observe/control the host UI). With no
///      driver injected they are rejected as `unsupported`, except `debug.ping`, which always
///      answers so a client can probe liveness.
///   2. Registry ops → app-specific side-channel handlers registered by the host.
///   3. Fallback closure → a host-provided catch-all consulted after a registry miss.
///   4. Otherwise → `unknown_op`.
///
/// `@MainActor` — the `DebugBridge` surface is main-actor pinned (window/view rendering is
/// main-thread only), so the dispatcher is pinned too. Registry handlers are `@Sendable` async
/// closures and hop off the main actor when awaited.
@MainActor
public final class E2EDispatcher {
    /// `nonisolated(unsafe)` so the `nonisolated init` can store this non-Sendable, main-actor
    /// existential from a non-isolated context. Safe because it is a write-once `let` and is only
    /// ever read from `handleDebug`, which runs on the main actor.
    nonisolated(unsafe) private let driver: (any DebugBridge)?
    private let registry: E2EOpRegistry
    private let fallback: (@Sendable (IPCRequest) async -> IPCResponse?)?

    /// `nonisolated` so a non-isolated facade (`E2EBridgeServer`) can construct the dispatcher; it
    /// only stores the injected values and touches no isolated state.
    public nonisolated init(
        driver: (any DebugBridge)?,
        registry: E2EOpRegistry,
        fallback: (@Sendable (IPCRequest) async -> IPCResponse?)? = nil
    ) {
        self.driver = driver
        self.registry = registry
        self.fallback = fallback
    }

    /// Handles an op and produces a response envelope. Bad arguments, control failures, and host
    /// errors are all converted into structured error envelopes.
    public func handle(_ request: IPCRequest) async -> IPCResponse {
        // Debug ops (screenshot, ui_tree, etc.) are handled first — no auth gate, so login/loading
        // screens can be observed too. `debug.ping` answers even without a driver.
        if request.op.hasPrefix("debug.") {
            return await handleDebug(request)
        }
        // Registry ops — app-specific side-channel handlers.
        if let handler = registry.lookup(request.op) {
            do {
                return .success(try await handler(argsOrNil(request)))
            } catch let error as E2EOpError {
                // A host-thrown E2EOpError carries a stable code/message → surface it verbatim.
                return .failure(code: error.code, message: error.message)
            } catch {
                return .failure(code: "internal", message: error.localizedDescription)
            }
        }
        // Fallback — host-provided catch-all consulted after a registry miss.
        if let fallback, let response = await fallback(request) {
            return response
        }
        return .failure(code: "unknown_op", message: "Unknown op: \(request.op)")
    }

    // MARK: - debug.* (observe/control bridge)

    private func handleDebug(_ request: IPCRequest) async -> IPCResponse {
        // debug.ping answers even without a driver — it only reports process liveness/version.
        if request.op == "debug.ping" {
            return .success(.object([
                "ok": .bool(true),
                "pid": .int(Int(ProcessInfo.processInfo.processIdentifier)),
                "version": .string(E2EBridgeVersion.current),
            ]))
        }
        // No driver injected (e.g. a release build without the debug driver) → unsupported.
        guard let driver else {
            return .failure(code: "unsupported", message: "debug ops are not supported in this build (no driver injected).")
        }
        do {
            switch request.op {
            case "debug.screenshot": return try encode(ScreenshotResult(windows: driver.screenshot()))
            case "debug.ui_tree": return try encode(UITreeResult(windows: await driver.uiTree()))
            case "debug.ui_perform":
                let args = try decodeArgs(PerformArgs.self, request)
                return try encode(try await driver.perform(identifier: args.identifier))
            case "debug.ui_set_value":
                let args = try decodeArgs(SetValueArgs.self, request)
                return try encode(try await driver.setValue(identifier: args.identifier, value: args.value))
            case "debug.type":
                let args = try decodeArgs(TypeArgs.self, request)
                return try encode(try await driver.type(identifier: args.identifier, text: args.text))
            case "debug.key":
                let args = try decodeArgs(KeyArgs.self, request)
                return try encode(try await driver.key(name: args.key, modifiers: args.modifiers ?? []))
            default:
                return .failure(code: "unknown_op", message: "Unknown debug op: \(request.op)")
            }
        } catch let error as DispatchError {
            // Bad arguments (decodeArgs failure) → invalid_args, not lumped into internal.
            return .failure(code: "invalid_args", message: error.message)
        } catch let error as DebugBridgeError {
            // Control failures thrown by the bridge map to stable codes (not_found, perform_failed, …).
            return .failure(code: error.code, message: error.message)
        } catch {
            return .failure(code: "internal", message: error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private func encode<T: Encodable>(_ value: T) throws -> IPCResponse {
        .success(try JSONValue(encoding: value))
    }

    /// Maps `.null` args to nil for the registry handler (an op invoked with no arguments).
    private func argsOrNil(_ request: IPCRequest) -> JSONValue? {
        if case .null = request.args { return nil }
        return request.args
    }

    private func decodeArgs<T: Decodable>(_ type: T.Type, _ request: IPCRequest) throws -> T {
        do {
            return try request.args.decoded(as: T.self)
        } catch {
            throw DispatchError.invalidArgs("Invalid arguments for op '\(request.op)': \(error)")
        }
    }

    // MARK: - Argument / result models

    private struct PerformArgs: Decodable { let identifier: String }
    private struct SetValueArgs: Decodable { let identifier: String; let value: String }
    private struct TypeArgs: Decodable { let identifier: String?; let text: String }
    private struct KeyArgs: Decodable { let key: String; let modifiers: [String]? }

    /// `debug.screenshot` result — the captured windows (main + open sheets).
    private struct ScreenshotResult: Encodable {
        let windows: [ScreenshotShot]
    }

    /// `debug.ui_tree` result — the per-window accessibility tree roots.
    private struct UITreeResult: Encodable {
        let windows: [AXNode]
    }
}

/// Bad-arguments error raised by the dispatcher's arg decoding; mapped to `invalid_args`.
enum DispatchError: Error, Sendable {
    case invalidArgs(String)

    var message: String {
        switch self {
        case .invalidArgs(let message): return message
        }
    }
}
