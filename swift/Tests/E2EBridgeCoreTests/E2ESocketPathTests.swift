import XCTest
@testable import E2EBridgeCore

/// Verifies the socket path derivation — bundle-id shape, instance suffix, empty-instance handling,
/// and the nil/empty bundle-id fallback.
final class E2ESocketPathTests: XCTestCase {
    private let home = "/Users/test"

    func testDefaultPathShape() {
        XCTAssertEqual(
            E2ESocketPath.default(bundleID: "com.example.app", instance: nil, home: home),
            "/Users/test/Library/Application Support/com.example.app/e2e.sock"
        )
    }

    func testInstanceSuffix() {
        // A non-empty instance token appends `.<instance>` so sessions do not collide.
        XCTAssertEqual(
            E2ESocketPath.default(bundleID: "com.example.app", instance: "abc", home: home),
            "/Users/test/Library/Application Support/com.example.app.abc/e2e.sock"
        )
    }

    func testEmptyInstanceIgnored() {
        // An empty-string instance is treated as nil (no suffix).
        XCTAssertEqual(
            E2ESocketPath.default(bundleID: "com.example.app", instance: "", home: home),
            "/Users/test/Library/Application Support/com.example.app/e2e.sock"
        )
    }

    func testNilOrEmptyBundleIDFallsBack() {
        XCTAssertEqual(
            E2ESocketPath.default(bundleID: nil, instance: nil, home: home),
            "/Users/test/Library/Application Support/e2e-app/e2e.sock"
        )
        XCTAssertEqual(
            E2ESocketPath.default(bundleID: "", instance: nil, home: home),
            "/Users/test/Library/Application Support/e2e-app/e2e.sock"
        )
    }

    func testDifferentInstancesDoNotCollide() {
        let a = E2ESocketPath.default(bundleID: "com.example.app", instance: "a", home: home)
        let b = E2ESocketPath.default(bundleID: "com.example.app", instance: "b", home: home)
        XCTAssertNotEqual(a, b)
    }
}
