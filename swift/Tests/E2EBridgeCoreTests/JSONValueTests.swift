import XCTest
@testable import E2EBridgeCore

/// Verifies `JSONValue.intValue`, in particular that it never traps — a wire-reachable arg is
/// untrusted input, so the `.double` branch must be total rather than crashing the host app inside
/// a registry handler.
final class JSONValueTests: XCTestCase {

    // MARK: - .int

    func testIntValueOnInt() {
        XCTAssertEqual(JSONValue.int(42).intValue, 42)
    }

    // MARK: - .double, in-range (truncation toward zero)

    func testIntValueTruncatesPositiveDoubleTowardZero() {
        XCTAssertEqual(JSONValue.double(3.9).intValue, 3)
    }

    func testIntValueTruncatesNegativeDoubleTowardZero() {
        XCTAssertEqual(JSONValue.double(-3.9).intValue, -3)
    }

    // MARK: - .double, out of range / non-finite (must not trap)

    func testIntValueOnHugeDoubleReturnsNil() {
        XCTAssertNil(JSONValue.double(1e19).intValue, "out of Int64 range → nil, not a trap")
    }

    func testIntValueOnPositiveInfinityReturnsNil() {
        XCTAssertNil(JSONValue.double(.infinity).intValue)
    }

    func testIntValueOnNegativeInfinityReturnsNil() {
        XCTAssertNil(JSONValue.double(-.infinity).intValue)
    }

    func testIntValueOnNaNReturnsNil() {
        XCTAssertNil(JSONValue.double(.nan).intValue)
    }

    // MARK: - Non-numeric cases

    func testIntValueOnNonNumericReturnsNil() {
        XCTAssertNil(JSONValue.string("42").intValue)
        XCTAssertNil(JSONValue.bool(true).intValue)
        XCTAssertNil(JSONValue.null.intValue)
        XCTAssertNil(JSONValue.array([.int(1)]).intValue)
        XCTAssertNil(JSONValue.object(["a": .int(1)]).intValue)
    }

    // MARK: - End-to-end decode path

    func testHugeIntegerLiteralDecodesAsDoubleAndIntValueReturnsNil() throws {
        // Int decode is attempted before Double in JSONValue's init(from:) (see the ordering
        // comment there), but this literal overflows Int64 (max ~9.2e18) so that attempt fails and
        // falls through to Double, which represents it as 1e19. Confirms both the decode-path
        // ordering and that intValue stays total end-to-end.
        let data = Data("10000000000000000000".utf8)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .double(let value) = decoded else {
            XCTFail("expected the huge literal to decode as .double, got \(decoded)")
            return
        }
        XCTAssertEqual(value, 1e19)
        XCTAssertNil(decoded.intValue)
    }
}
