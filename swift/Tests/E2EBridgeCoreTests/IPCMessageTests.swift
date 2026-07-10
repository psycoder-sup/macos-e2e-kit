import XCTest
@testable import E2EBridgeCore

/// Verifies the pure behavior of the IPC wire types (JSONValue, IPCRequest, IPCResponse) and the
/// length-prefixed framing.
final class IPCMessageTests: XCTestCase {

    // MARK: - Length-prefixed framing

    func testFrameAddsBigEndianLengthHeader() throws {
        let payload = Data("hello".utf8) // 5 bytes
        let framed = IPCWire.frame(payload)
        XCTAssertEqual(framed.count, 4 + 5)
        XCTAssertEqual(Array(framed.prefix(4)), [0x00, 0x00, 0x00, 0x05], "4-byte big-endian length header")
        XCTAssertEqual(IPCWire.payloadLength(header: framed), 5)
        XCTAssertEqual(Data(framed.dropFirst(4)), payload)
    }

    func testPayloadLengthRequiresFourBytes() {
        XCTAssertNil(IPCWire.payloadLength(header: Data([0x00, 0x01])), "under 4 bytes → nil")
    }

    func testRequestFrameRoundTrip() throws {
        let request = IPCRequest(op: "debug.ui_perform", args: .object([
            "identifier": .string("save-button"),
        ]))
        let framed = try IPCWire.encodeFrame(request)
        let decoded = try IPCWire.decodeFrame(IPCRequest.self, from: framed)
        XCTAssertEqual(decoded, request)
    }

    func testResponseFrameRoundTrip() throws {
        let response = IPCResponse.success(.object(["count": .int(3), "ok": .bool(true)]))
        let framed = try IPCWire.encodeFrame(response)
        let decoded = try IPCWire.decodeFrame(IPCResponse.self, from: framed)
        XCTAssertEqual(decoded, response)
        XCTAssertTrue(decoded.ok)
    }

    func testDecodeFrameRejectsLengthMismatch() {
        var framed = IPCWire.frame(Data("abc".utf8))
        framed.append(0xFF) // payload longer than the header length.
        XCTAssertThrowsError(try IPCWire.decodeFrame(IPCResponse.self, from: framed))
    }

    // MARK: - IPCRequest decoding

    func testRequestArgsDefaultsToNullWhenAbsent() throws {
        let data = Data(#"{"op":"debug.ping"}"#.utf8)
        let request = try JSONDecoder().decode(IPCRequest.self, from: data)
        XCTAssertEqual(request.op, "debug.ping")
        XCTAssertEqual(request.args, .null, "an absent args key decodes to .null (an op with no arguments)")
    }

    // MARK: - IPCResponse envelope

    func testSuccessEnvelopeOmitsError() throws {
        let json = try JSONEncoder().encode(IPCResponse.success(.string("ok")))
        let object = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        XCTAssertEqual(object?["ok"] as? Bool, true)
        XCTAssertNil(object?["error"], "a success envelope has no error key")
    }

    func testFailureEnvelopeCarriesCodeAndMessage() throws {
        let response = IPCResponse.failure(code: "unsupported", message: "not supported")
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "unsupported")
        XCTAssertNil(response.result, "a failure envelope has no result")
    }

    // MARK: - JSONValue round-trip

    func testJSONValueRoundTripPreservesShapeAndIntVsDouble() throws {
        let value: JSONValue = .object([
            "n": .int(42),
            "f": .double(3.5),
            "s": .string("string"),
            "b": .bool(false),
            "nil": .null,
            "arr": .array([.int(1), .string("two"), .null]),
            "nested": .object(["k": .string("v")]),
        ])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, value)
        // Integers stay integers (they do not drift to Double).
        XCTAssertEqual(decoded["n"]?.intValue, 42)
        if case .int = decoded["n"] {} else { XCTFail("an integer should stay .int") }
    }

    func testJSONValueEncodesTypedModel() throws {
        // A typed Encodable model round-trips through JSONValue and back.
        let node = AXNode(role: "AXButton", identifier: "save", label: "Save", value: nil,
                          enabled: true, focused: false,
                          frame: AXFrame(x: 1, y: 2, width: 3, height: 4), children: [])
        let value = try JSONValue(encoding: node)
        let restored = try value.decoded(as: AXNode.self)
        XCTAssertEqual(restored, node)
        XCTAssertEqual(value["identifier"]?.stringValue, "save")
        XCTAssertEqual(value["role"]?.stringValue, "AXButton")
    }
}
