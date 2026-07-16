import Foundation

/// The package version reported by `debug.ping`.
/// Bump together with `.claude-plugin/plugin.json` "version" on every release.
public enum E2EBridgeVersion {
    public static let current = "0.2.0"
}

/// The facade a host wires up to expose an E2E bridge over a Unix domain socket.
///
/// Typical integration (~3 lines, gated to debug builds by the host):
/// ```swift
/// let e2e = E2EBridgeServer(driver: AppKitDebugBridge())
/// try? e2e.start()
/// e2e.registry.register("todos.count") { _ in try JSONValue(encoding: store.count) }
/// ```
///
/// The socket is opened only when `start()` is called, and `PeerVerifier` gates every connection —
/// so shipping this code in a release binary does not, by itself, expose the app.
public final class E2EBridgeServer {
    /// Registered app-specific ops. Registrations made after `start()` are visible to the dispatch
    /// path because the registry is a shared reference type.
    public var registry: E2EOpRegistry

    private let server: E2ESocketServer
    private let path: String

    /// The socket path the server binds (and clients connect to).
    public var socketPath: String { path }

    /// - Parameters:
    ///   - driver: the observe/control bridge for `debug.*` ops; `nil` disables them (`debug.ping`
    ///     still answers).
    ///   - socketPath: where to bind; defaults to the bundle-derived path.
    ///   - verifier: the peer trust check; defaults to code-signature verification.
    ///   - registry: the app-op registry; defaults to an empty one.
    ///   - fallback: an optional catch-all consulted after a registry miss.
    public init(
        driver: (any DebugBridge)?,
        socketPath: String = E2ESocketPath.default(),
        verifier: any PeerVerifier = SecCodePeerVerifier(),
        registry: E2EOpRegistry = .init(),
        fallback: (@Sendable (IPCRequest) async -> IPCResponse?)? = nil
    ) {
        self.registry = registry
        self.path = socketPath
        let dispatcher = E2EDispatcher(driver: driver, registry: registry, fallback: fallback)
        self.server = E2ESocketServer(socketPath: socketPath, verifier: verifier) { request in
            await dispatcher.handle(request)
        }
    }

    /// Binds the socket and starts accepting connections.
    public func start() throws { try server.start() }

    /// Stops accepting connections and removes the socket file.
    public func stop() { server.stop() }
}
