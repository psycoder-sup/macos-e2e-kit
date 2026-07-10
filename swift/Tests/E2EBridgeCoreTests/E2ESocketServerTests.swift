import XCTest
@testable import E2EBridgeCore

/// End-to-end checks of E2ESocketServer over a real Unix socket — a stub PeerVerifier bypasses the
/// real SecCode check so only the wiring is exercised (accept → verify → read frame → dispatch →
/// write frame). Real signature verification is covered separately by manual e2e.
final class E2ESocketServerTests: XCTestCase {

    private struct PassVerifier: PeerVerifier {
        func verify(fd: Int32) throws {}
    }
    private struct FailVerifier: PeerVerifier {
        func verify(fd: Int32) throws { throw PeerVerifierError.untrustedPeer }
    }

    private func tempPath(_ name: String) -> String {
        // Keep it short, within the 104-byte sun_path limit (temp dir + pid + name).
        "\(NSTemporaryDirectory())e2esock\(getpid())\(name).sock"
    }

    // MARK: - Happy path: verify passes → dispatch → response

    func testDispatchesFramedRequestAndWritesResponse() throws {
        let path = tempPath("ok")
        let server = E2ESocketServer(socketPath: path, verifier: PassVerifier()) { request in
            IPCResponse.success(.object([
                "echo": .string(request.op),
                "argId": request.args["id"] ?? .null,
            ]))
        }
        try server.start()
        defer { server.stop() }

        let request = IPCRequest(op: "ping", args: .object(["id": .string("abc")]))
        let response = try roundTrip(path: path, request: request, timeout: 5)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?["echo"]?.stringValue, "ping")
        XCTAssertEqual(response.result?["argId"]?.stringValue, "abc", "args reach the dispatcher")
    }

    // MARK: - Rejection path: verify fails → closed without a response

    func testRejectedPeerGetsNoResponse() throws {
        let path = tempPath("reject")
        let server = E2ESocketServer(socketPath: path, verifier: FailVerifier()) { _ in
            XCTFail("a rejected peer must not be dispatched")
            return IPCResponse.success(.null)
        }
        try server.start()
        defer { server.stop() }

        XCTAssertThrowsError(try roundTrip(path: path, request: IPCRequest(op: "ping"), timeout: 5)) { error in
            XCTAssertEqual(error as? ClientError, .eof, "verify failure → connection closed (EOF)")
        }
    }

    // MARK: - E2EBridgeServer facade (end-to-end wiring)

    func testFacadeCompilesWithDefaultArgs() {
        // The documented ~3-line host usage must compile from a non-isolated context.
        let e2e = E2EBridgeServer(driver: nil)
        e2e.registry.register("x") { _ in try JSONValue(encoding: 1) }
        XCTAssertFalse(e2e.socketPath.isEmpty)
        // Not started — the default path lives under real Application Support; avoid side effects.
    }

    // Note: an end-to-end roundtrip through the E2EBridgeServer facade is not tested here because the
    // facade dispatches on the main actor, and XCTest's synchronous socket client would block the main
    // thread and deadlock that dispatch. The facade's dispatch logic is covered by E2EDispatcherTests
    // and its socket wiring by the tests above (with a synchronous handler); this file only verifies
    // the facade's public surface compiles (see testFacadeCompilesWithDefaultArgs).

    // MARK: - Test-only POSIX client

    private enum ClientError: Error, Equatable {
        case socket, connect, eof, timeout
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<IPCResponse, Error>?
        func set(_ result: Result<IPCResponse, Error>) {
            lock.lock(); defer { lock.unlock() }
            value = result
        }
        func get() throws -> IPCResponse {
            lock.lock(); defer { lock.unlock() }
            switch value {
            case .success(let response): return response
            case .failure(let error): throw error
            case nil: throw ClientError.timeout
            }
        }
    }

    /// Connects to the socket, writes the request frame and reads the response frame (with a timeout).
    /// Blocking I/O runs on a background queue.
    private func roundTrip(path: String, request: IPCRequest, timeout: TimeInterval) throws -> IPCResponse {
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do {
                let fd = try Self.connectClient(path: path)
                defer { close(fd) }
                let payload = try JSONEncoder().encode(request)
                E2ESocketServer.writeFrame(fd: fd, payload: payload)
                guard let responseData = E2ESocketServer.readFrame(fd: fd) else {
                    box.set(.failure(ClientError.eof)); semaphore.signal(); return
                }
                box.set(.success(try JSONDecoder().decode(IPCResponse.self, from: responseData)))
            } catch {
                box.set(.failure(error))
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else { throw ClientError.timeout }
        return try box.get()
    }

    private static func connectClient(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.socket }

        // Keep a write from killing the test via SIGPIPE if the server closes first.
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        precondition(pathBytes.count < capacity, "socket path exceeds the sun_path limit: \(path)")
        withUnsafeMutablePointer(to: &address.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: capacity) { dest in
                for (index, byte) in pathBytes.enumerated() { dest[index] = CChar(bitPattern: byte) }
                dest[pathBytes.count] = 0
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { close(fd); throw ClientError.connect }
        return fd
    }
}
