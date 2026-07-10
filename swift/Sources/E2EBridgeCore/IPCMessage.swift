import Foundation

/// IPC wire types + length-prefixed framing for the app ↔ bridge channel.
///
/// A client (an unprivileged bridge process) sends a tool call as `IPCRequest{op,args}` and the
/// app answers with `IPCResponse{ok,result|error}`. A frame is a **4-byte big-endian uint32 length
/// + JSON payload** — pure and testable (`IPCWire`).

/// A tool-call request — `op` selects the handler and `args` (JSON) carries the arguments.
public struct IPCRequest: Codable, Sendable, Equatable {
    public let op: String
    public let args: JSONValue

    public init(op: String, args: JSONValue = .null) {
        self.op = op
        self.args = args
    }

    private enum CodingKeys: String, CodingKey { case op, args }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        op = try container.decode(String.self, forKey: .op)
        // Ops that take no arguments may omit the args key.
        args = try container.decodeIfPresent(JSONValue.self, forKey: .args) ?? .null
    }
}

/// A structured error envelope — carries a stable code and a human-readable message.
public struct IPCError: Codable, Sendable, Equatable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// A tool-call response — `result` (JSON) on success, `error` on failure. Exactly one is populated.
public struct IPCResponse: Codable, Sendable, Equatable {
    public let ok: Bool
    public let result: JSONValue?
    public let error: IPCError?

    public init(ok: Bool, result: JSONValue?, error: IPCError?) {
        self.ok = ok
        self.result = result
        self.error = error
    }

    public static func success(_ result: JSONValue) -> IPCResponse {
        IPCResponse(ok: true, result: result, error: nil)
    }

    public static func failure(code: String, message: String) -> IPCResponse {
        IPCResponse(ok: false, result: nil, error: IPCError(code: code, message: message))
    }
}

/// Length-prefixed framing — a 4-byte big-endian uint32 length header + JSON payload. Pure
/// functions only (test target).
public enum IPCWire {
    /// Max payload size per frame (guards against an oversized length header — 4MiB is far more
    /// than any tool response needs).
    public static let maxPayloadBytes = 4 * 1024 * 1024

    /// Prepends a 4-byte big-endian length header to the payload.
    public static func frame(_ payload: Data) -> Data {
        var header = Data(count: 4)
        let length = UInt32(payload.count)
        header[0] = UInt8((length >> 24) & 0xFF)
        header[1] = UInt8((length >> 16) & 0xFF)
        header[2] = UInt8((length >> 8) & 0xFF)
        header[3] = UInt8(length & 0xFF)
        return header + payload
    }

    /// 4-byte header → payload length (bytes). nil if the header is under 4 bytes.
    public static func payloadLength(header: Data) -> Int? {
        guard header.count >= 4 else { return nil }
        let bytes = Array(header.prefix(4))
        let length = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        return Int(length)
    }

    /// Encodes an Encodable to JSON and wraps it in a single frame.
    public static func encodeFrame<T: Encodable>(_ value: T, encoder: JSONEncoder = JSONEncoder()) throws -> Data {
        frame(try encoder.encode(value))
    }

    /// Decodes a single frame (header + payload) into a Decodable — throws on a length mismatch
    /// (used by round-trip tests).
    public static func decodeFrame<T: Decodable>(
        _ type: T.Type, from framed: Data, decoder: JSONDecoder = JSONDecoder()
    ) throws -> T {
        guard let length = payloadLength(header: framed) else {
            throw IPCWireError.shortHeader
        }
        let payload = framed.dropFirst(4)
        guard payload.count == length else {
            throw IPCWireError.lengthMismatch(expected: length, actual: payload.count)
        }
        return try decoder.decode(T.self, from: Data(payload))
    }
}

public enum IPCWireError: Error, Sendable, Equatable {
    case shortHeader
    case lengthMismatch(expected: Int, actual: Int)
    case payloadTooLarge(Int)
}
