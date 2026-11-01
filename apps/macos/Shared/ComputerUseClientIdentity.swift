// ComputerUseClientIdentity.swift — who is on the other end of the socket.
//
// WHY THIS FILE EXISTS
//
// Version 1 of the protocol had no client dimension: any process running as the
// same user could connect, and the socket boundary was the file system. That is
// acceptable for a single-operator bridge and unacceptable as soon as one
// machine runs more than one agent: "which program may read that application"
// is a different question from "which application is authorized at all".
//
// A self-declared identifier is not an answer. Any caller can write
// `"client_id": "cmm-console"` into a request. So the identity is taken from the
// KERNEL's view of the peer, not from anything the peer says:
//
//   1. the peer's uid (getpeereid) must equal the helper's own user;
//   2. the peer's audit token (LOCAL_PEERTOKEN) identifies the process that
//      actually opened the socket — an audit token, not a pid, because a pid can
//      be recycled between accept() and the lookup;
//   3. SecCodeCopyGuestWithAttributes turns that token into a SecCode;
//   4. the code must be validly signed (SecCodeCheckValidity);
//   5. and it must satisfy the designated requirement the policy names for that
//      client (SecRequirementCreateWithString + SecCodeCheckValidity).
//
// Only after all five does a client "match". Anything unresolved denies: the
// failure mode of this file is always "not authorized", never "assume local".
//
// Not linked into the pure-Foundation policy tests on purpose: this needs
// Security, and the decision rules it feeds stay in ComputerUseAuthorization.swift.

import Foundation
import Security

/// `LOCAL_PEERTOKEN` from <sys/un.h>: the peer's audit token.
private let localPeerTokenOption: Int32 = 0x006
/// `LOCAL_PEERPID` from <sys/un.h>: the peer's pid, used only when the audit
/// token is unavailable. Weaker, because a pid can be recycled.
private let localPeerPidOption: Int32 = 0x002

/// The verified identity of the process that opened a connection.
///
/// Holds a `SecCode` and is therefore not `Sendable`: it lives for the lifetime
/// of one connection, on that connection's thread.
public final class BridgePeerCode {
    /// The peer's running code: what the validity/requirement APIs evaluate.
    private let code: SecCode
    /// The same peer as static code: what the signing-information API reads.
    /// `SecCodeCopyStaticCode` is the supported bridge between the two; no
    /// bit-casting is involved.
    private let staticCode: SecStaticCode
    /// The peer's pid. Diagnostic only: authorization uses the audit token.
    public let pid: Int32
    public let userID: uid_t
    /// Reported signing identity, when the code is signed.
    public let identifier: String?
    public let teamID: String?
    /// The code passed `SecCodeCheckValidity`: it is a validly signed binary.
    public let validSignature: Bool

    init(code: SecCode, staticCode: SecStaticCode, pid: Int32, userID: uid_t,
         identifier: String?, teamID: String?, validSignature: Bool) {
        self.code = code
        self.staticCode = staticCode
        self.pid = pid
        self.userID = userID
        self.identifier = identifier
        self.teamID = teamID
        self.validSignature = validSignature
    }

    /// Does this peer satisfy the designated requirement?
    ///
    /// A requirement that does not compile matches nothing. That is deliberate:
    /// a typo in the policy must lock the client out, not wave it through.
    public func satisfies(requirement text: String) -> Bool {
        var requirement: SecRequirement?
        let created = SecRequirementCreateWithString(text as CFString, [], &requirement)
        guard created == errSecSuccess, let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// Secret-free facts for `policy.status` diagnostics.
    public var summary: [String: Any] {
        var value: [String: Any] = [
            "pid": Int(pid),
            "valid_signature": validSignature,
        ]
        if let identifier, !identifier.isEmpty { value["identifier"] = identifier }
        if let teamID, !teamID.isEmpty { value["team_id"] = teamID }
        return value
    }
}

/// Resolve the peer of an accepted Unix-domain socket.
///
/// Returns nil when the peer cannot be identified at all (different user, no
/// audit token and no pid, or no Security framework answer). Nil is not
/// "probably fine": callers must treat it as unauthorized.
public func bridgePeerCode(fd: Int32) -> BridgePeerCode? {
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard getpeereid(fd, &uid, &gid) == 0 else { return nil }
    // Same-user is the baseline the file system already gives us; anything else
    // is not this deployment's business.
    guard uid == geteuid() else { return nil }

    var pid: pid_t = 0
    var pidLength = socklen_t(MemoryLayout<pid_t>.size)
    let havePid = getsockopt(fd, SOL_LOCAL, localPeerPidOption, &pid, &pidLength) == 0

    var attributes: [String: Any] = [:]
    var auditToken = audit_token_t()
    var tokenLength = socklen_t(MemoryLayout<audit_token_t>.size)
    if getsockopt(fd, SOL_LOCAL, localPeerTokenOption, &auditToken, &tokenLength) == 0 {
        let data = withUnsafeBytes(of: &auditToken) { Data($0) }
        attributes[kSecGuestAttributeAudit as String] = data
    } else if havePid {
        attributes[kSecGuestAttributePid as String] = NSNumber(value: pid)
    } else {
        return nil
    }

    var code: SecCode?
    guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code) == errSecSuccess,
          let code
    else { return nil }

    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
        return nil
    }

    // Is it validly signed at all? An unsigned process fails here, which is the
    // documented outcome: the deployment cannot describe who it is.
    let valid = SecCodeCheckValidity(code, [], nil) == errSecSuccess

    var information: CFDictionary?
    var identifier: String?
    var teamID: String?
    if SecCodeCopySigningInformation(
        staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
       let dictionary = information as? [String: Any] {
        identifier = dictionary[kSecCodeInfoIdentifier as String] as? String
        teamID = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    return BridgePeerCode(
        code: code, staticCode: staticCode,
        pid: havePid ? Int32(pid) : 0,
        userID: uid,
        identifier: identifier,
        teamID: teamID,
        validSignature: valid)
}

/// The client grant whose requirement this peer satisfies, if any.
///
/// First match wins, and a client whose requirement fails to compile simply
/// never matches. An empty list (a v2 document with no clients) matches nothing.
public func bridgeMatchingClient(
    _ peer: BridgePeerCode?, policy: BridgeAuthorizationPolicy
) -> BridgeClientGrant? {
    guard policy.clientAuthorization == .required, let peer else { return nil }
    guard peer.validSignature else { return nil }
    for client in policy.clients where peer.satisfies(requirement: client.requirement) {
        return client
    }
    return nil
}
