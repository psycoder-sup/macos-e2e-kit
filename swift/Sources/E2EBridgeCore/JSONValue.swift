import Foundation

/// A lightweight representation that carries an arbitrary JSON value verbatim — the IPC wire's
/// `args`/`result` use this.
///
/// A client (an unprivileged bridge process) sends tool input as `{ op, args }` and the app answers
/// with `{ ok, result }`. Both payloads are un-typed JSON, so Codable synthesis cannot be used and
/// this value passes them through. The dispatcher moves between typed models and this value with
/// `decoded(as:decoder:)` / `init(encoding:encoder:)`.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            // Try Int after Bool (JSONDecoder does not decode `true` as Int, so there is no ambiguity).
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value.")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - Access helpers

public extension JSONValue {
    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    /// Reads this value as an `Int`, if possible.
    ///
    /// `.int` returns the stored value directly. `.double` truncates toward zero (`3.9` → `3`,
    /// `-3.9` → `-3`) like the old behavior, but is total: non-finite doubles (`.infinity`, `.nan`)
    /// and doubles outside `Int`'s representable range (e.g. a wire literal like
    /// `10000000000000000000`, which decodes as `.double` since it overflows `Int` first) return
    /// `nil` instead of trapping. All other cases return `nil`.
    var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value):
            guard value.isFinite else { return nil }
            return Int(exactly: value.rounded(.towardZero))
        default: return nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// When this is an object, looks up a child value by key (else nil).
    subscript(_ key: String) -> JSONValue? { objectValue?[key] }
}

// MARK: - Typed model ↔ JSONValue conversion

public extension JSONValue {
    /// Encodes an Encodable value and moves it into a JSONValue. `encoder` applies domain rules
    /// (date formats, etc.); it defaults to a plain `JSONEncoder`.
    init<T: Encodable>(encoding value: T, encoder: JSONEncoder = JSONEncoder()) throws {
        let data = try encoder.encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Decodes this JSONValue into a Decodable type. `decoder` handles ISO-8601 dates, etc.; it
    /// defaults to a plain `JSONDecoder`.
    func decoded<T: Decodable>(as type: T.Type = T.self, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try decoder.decode(T.self, from: data)
    }
}
