import Foundation

/// A handler for an app-specific side-channel op. Given the request's `args` (nil when absent), it
/// returns a JSON result or throws.
public typealias E2EOpHandler = @Sendable (_ args: JSONValue?) async throws -> JSONValue

/// A structured error a host handler can throw to control the response envelope's code/message.
/// The dispatcher maps a thrown `E2EOpError` to `IPCResponse.failure(code:message:)`; any other
/// error becomes `"internal"`.
public struct E2EOpError: Error, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// A registry of app-specific ops the host registers on the bridge.
///
/// A reference type with lock-protected storage so that registrations made after the server has
/// started are visible to the dispatch path (which resolves handlers by looking them up here). It is
/// `@unchecked Sendable` — the lock, not the compiler, guarantees safe concurrent access (mirroring
/// the socket server's `@unchecked Sendable` style).
public final class E2EOpRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [String: E2EOpHandler] = [:]

    public init() {}

    /// Registers (or replaces) the handler for `op`.
    public func register(_ op: String, _ handler: @escaping E2EOpHandler) {
        lock.lock(); defer { lock.unlock() }
        handlers[op] = handler
    }

    /// Looks up the handler for `op` (nil if none is registered).
    public func lookup(_ op: String) -> E2EOpHandler? {
        lock.lock(); defer { lock.unlock() }
        return handlers[op]
    }
}
