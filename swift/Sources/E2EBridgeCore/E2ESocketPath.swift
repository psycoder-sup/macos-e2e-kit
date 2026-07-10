import Foundation

/// Derives the Unix-socket path the bridge server binds and clients connect to.
///
/// The path lives under the app's Application Support directory, derived from the host's bundle
/// identifier so different builds (e.g. a `.debug` variant and the installed release) are isolated
/// automatically instead of fighting over one socket.
///
/// An optional instance token (`E2E_INSTANCE`) appends a `.<instance>` suffix to the directory so
/// several E2E sessions can run side by side without colliding. The socket filename is `e2e.sock`.
public enum E2ESocketPath {
    /// Fallback bundle identifier used when the host bundle id is unavailable (nil/empty).
    public static let fallbackBundleID = "e2e-app"

    /// The socket filename shared by the server and its clients.
    public static let socketFilename = "e2e.sock"

    /// `<home>/Library/Application Support/<bundleID>[.<instance>]/e2e.sock`.
    ///
    /// A nil or empty `bundleID` falls back to `fallbackBundleID`. A non-empty `instance` appends
    /// `.<instance>` to the directory name; an empty-string instance is treated as nil. `bundleID`/
    /// `instance`/`home` are injectable for tests — the defaults read the running bundle, the
    /// `E2E_INSTANCE` environment variable, and $HOME.
    public static func `default`(
        bundleID: String? = Bundle.main.bundleIdentifier,
        instance: String? = ProcessInfo.processInfo.environment["E2E_INSTANCE"],
        home: String = NSHomeDirectory()
    ) -> String {
        let base = bundleID.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackBundleID
        let id: String
        if let instance, !instance.isEmpty {
            id = "\(base).\(instance)"
        } else {
            id = base
        }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent(socketFilename)
            .path
    }
}
