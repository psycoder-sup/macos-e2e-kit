import Foundation
import Security

/// A seam that decides whether to trust a connecting peer (the bridge process).
///
/// The trust boundary is **code signing** — with no shared secret, only clients signed by the same
/// Developer ID (team) are accepted. Tests inject a stub to exercise the dispatch path only; the
/// real signature check is done by `SecCodePeerVerifier`.
public protocol PeerVerifier: Sendable {
    /// Verifies the peer on an accepted socket fd. Returns normally to accept, throws to reject.
    func verify(fd: Int32) throws
}

public enum PeerVerifierError: Error, Sendable, Equatable {
    case peerTokenUnavailable(Int32)
    case codeCopyFailed(OSStatus)
    case requirementFailed(OSStatus)
    case validityFailed(OSStatus)
    case peerEUIDUnavailable
    case untrustedPeer
}

/// macOS code-signing based peer verification.
///
/// 1. Reads the peer process's audit token from the accepted socket (`LOCAL_PEERTOKEN`).
/// 2. Builds the peer's `SecCode` from the audit token (`SecCodeCopyGuestWithAttributes`).
/// 3. Reads **this app's own** team identifier (if signed) and enforces, via `SecRequirement`, that
///    the peer is signed by the same team.
///
/// **dev/ad-hoc (unsigned) relaxation:** if the app is not team-signed (`-`/ad-hoc), it lowers the
/// check from team enforcement to same-EUID verification — so dogfooding works before a Developer ID
/// signature exists. Team matching is enforced only on release builds that carry a team identifier.
public struct SecCodePeerVerifier: PeerVerifier {
    public init() {}

    public func verify(fd: Int32) throws {
        guard let teamID = Self.ownTeamIdentifier(), !teamID.isEmpty else {
            // Unsigned / no team (dev·ad-hoc) → same-EUID relaxation.
            try Self.verifySameEUID(fd: fd)
            return
        }
        try Self.verifyTeam(fd: fd, teamID: teamID)
    }

    // MARK: - Team-signature enforcement (release)

    private static func verifyTeam(fd: Int32, teamID: String) throws {
        let auditData = try peerAuditToken(fd: fd)

        let attributes = [kSecGuestAttributeAudit: auditData] as CFDictionary
        var guest: SecCode?
        let copyStatus = SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest)
        guard copyStatus == errSecSuccess, let peerCode = guest else {
            throw PeerVerifierError.codeCopyFailed(copyStatus)
        }

        // anchor apple generic = a valid Apple cert chain · leaf OU = the Developer ID team.
        let requirementText = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
        var requirement: SecRequirement?
        let reqStatus = SecRequirementCreateWithString(requirementText as CFString, [], &requirement)
        guard reqStatus == errSecSuccess, let requirement else {
            throw PeerVerifierError.requirementFailed(reqStatus)
        }

        let validity = SecCodeCheckValidity(peerCode, [], requirement)
        guard validity == errSecSuccess else {
            throw PeerVerifierError.validityFailed(validity)
        }
    }

    /// Reads the peer's audit token (8×uint32 = 32 bytes) from the accepted socket and returns it as Data.
    private static func peerAuditToken(fd: Int32) throws -> Data {
        // <sys/un.h>: SOL_LOCAL=0, LOCAL_PEERTOKEN=0x006. The Darwin module may not expose them, so
        // they are kept as literals.
        let solLocal: Int32 = 0
        let localPeerToken: Int32 = 0x006

        var token = [UInt32](repeating: 0, count: 8)
        var length = socklen_t(MemoryLayout<UInt32>.size * 8)
        let result = token.withUnsafeMutableBytes { raw in
            getsockopt(fd, solLocal, localPeerToken, raw.baseAddress, &length)
        }
        guard result == 0, length == socklen_t(MemoryLayout<UInt32>.size * 8) else {
            throw PeerVerifierError.peerTokenUnavailable(errno)
        }
        return token.withUnsafeBytes { Data($0) }
    }

    // MARK: - same-EUID relaxation (dev/ad-hoc)

    private static func verifySameEUID(fd: Int32) throws {
        var euid: uid_t = 0
        var egid: gid_t = 0
        guard getpeereid(fd, &euid, &egid) == 0 else {
            throw PeerVerifierError.peerEUIDUnavailable
        }
        guard euid == geteuid() else {
            throw PeerVerifierError.untrustedPeer
        }
    }

    // MARK: - This app's own team identifier

    /// Reads this process's own team identifier from its code signature. nil if unsigned/ad-hoc.
    static func ownTeamIdentifier() -> String? {
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(selfCode, [], &staticCode) == errSecSuccess, let staticCode else { return nil }

        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dictionary = info as? [String: Any]
        else { return nil }

        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
