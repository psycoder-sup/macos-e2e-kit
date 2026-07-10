import Foundation

/// The Unix domain socket server the E2E client connects to.
///
/// `NWListener` does not expose the peer's audit token, so this is implemented directly on a **raw
/// POSIX socket** — every accepted fd must pass `PeerVerifier.verify` (code-signature check), then
/// one length-prefixed request is read and handed to `handler` (the dispatcher), a single response
/// is written, and the connection is closed (one request/response per connection).
public final class E2ESocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (IPCRequest) async -> IPCResponse

    private let socketPath: String
    private let verifier: PeerVerifier
    private let handler: Handler
    private let queue = DispatchQueue(label: "dev.e2ebridge.socket")

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    public init(socketPath: String, verifier: PeerVerifier, handler: @escaping Handler) {
        self.socketPath = socketPath
        self.verifier = verifier
        self.handler = handler
    }

    // MARK: - Lifecycle

    /// Binds and listens on the socket and installs the background accept loop. A stale socket file
    /// is unlinked first.
    public func start() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw E2ESocketError.socketFailed(errno) }

        // Ensure the parent directory exists.
        let directory = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true, attributes: nil
        )

        // Remove a stale socket file left by a previous run (bind cannot overwrite an existing path).
        unlink(socketPath)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            close(fd)
            throw E2ESocketError.pathTooLong(socketPath)
        }
        withUnsafeMutablePointer(to: &address.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: capacity) { dest in
                for (index, byte) in pathBytes.enumerated() { dest[index] = CChar(bitPattern: byte) }
                dest[pathBytes.count] = 0
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw E2ESocketError.bindFailed(errno)
        }

        // Keep the backlog generous (128) — a client opens a new connection per tool call, so an MCP
        // client firing tools concurrently causes a burst of simultaneous connects. A small backlog
        // would refuse some with ECONNREFUSED.
        guard listen(fd, 128) == 0 else {
            close(fd)
            unlink(socketPath)
            throw E2ESocketError.listenFailed(errno)
        }

        // Owner-only access (0700). Under the user Library the squatting risk is low, but narrow the
        // permissions anyway.
        chmod(socketPath, 0o700)

        self.listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.setCancelHandler { close(fd) }
        self.acceptSource = source
        source.resume()
    }

    /// Stops the accept loop, closes the socket, and removes the file.
    public func stop() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            if listenFD >= 0 {
                // The cancel handler closes the fd; guard against the no-source case with a final unlink.
                listenFD = -1
            }
            unlink(socketPath)
        }
    }

    // MARK: - accept → verify → dispatch → respond

    private func acceptOne() {
        let clientFD = accept(listenFD, nil, nil)
        guard clientFD >= 0 else { return }

        // If the peer disconnects first, keep a write from killing the app via SIGPIPE (guards against
        // an early client exit).
        var noSigPipe: Int32 = 1
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        // Peer verification (code signing) is a fast synchronous step — on failure, close without a
        // response (do not talk to an untrusted peer).
        do {
            try verifier.verify(fd: clientFD)
        } catch {
            close(clientFD)
            return
        }

        // Move blocking read/write and any main-actor dispatch off the accept queue so it is not blocked.
        let handler = self.handler
        Task.detached {
            defer { close(clientFD) }
            guard let payload = E2ESocketServer.readFrame(fd: clientFD) else { return }
            let response: IPCResponse
            do {
                let request = try JSONDecoder().decode(IPCRequest.self, from: payload)
                response = await handler(request)
            } catch {
                response = .failure(code: "bad_request", message: "Could not parse the request: \(error)")
            }
            if let data = try? JSONEncoder().encode(response) {
                E2ESocketServer.writeFrame(fd: clientFD, payload: data)
            }
        }
    }

    // MARK: - Length-prefixed blocking I/O

    /// Reads one frame (4-byte header + payload). nil on EOF/error/oversized length.
    static func readFrame(fd: Int32) -> Data? {
        guard let header = readExactly(fd: fd, count: 4),
              let length = IPCWire.payloadLength(header: header),
              length >= 0, length <= IPCWire.maxPayloadBytes
        else { return nil }
        if length == 0 { return Data() }
        return readExactly(fd: fd, count: length)
    }

    /// Reads exactly `count` bytes from the fd (accumulating short reads). nil if short.
    private static func readExactly(fd: Int32, count: Int) -> Data? {
        var buffer = Data()
        buffer.reserveCapacity(count)
        var remaining = count
        var chunk = [UInt8](repeating: 0, count: min(count, 64 * 1024))
        while remaining > 0 {
            let want = min(remaining, chunk.count)
            let read = chunk.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress, want)
            }
            if read > 0 {
                buffer.append(contentsOf: chunk[0..<read])
                remaining -= read
            } else if read == 0 {
                return nil // EOF before the end — a truncated frame.
            } else {
                if errno == EINTR { continue }
                return nil
            }
        }
        return buffer
    }

    /// Wraps the payload in a frame and writes it fully (accumulating short writes).
    static func writeFrame(fd: Int32, payload: Data) {
        let framed = IPCWire.frame(payload)
        framed.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = Darwin.write(fd, pointer, remaining)
                if written > 0 {
                    pointer = pointer.advanced(by: written)
                    remaining -= written
                } else {
                    if written < 0 && errno == EINTR { continue }
                    return
                }
            }
        }
    }
}

public enum E2ESocketError: Error, Sendable, Equatable {
    case socketFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case pathTooLong(String)
}
