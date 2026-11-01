// ComputerUseRequirement.swift — does a client requirement actually mean what
// its author thinks it means?
//
// WHY THIS FILE EXISTS
//
// A version-2 policy names each client by a code-signing designated requirement.
// That string is the ONLY load-bearing field of the client dimension: the
// `client_id` beside it is a label the caller could have invented. So the
// question an administrator has to be able to answer BEFORE writing the file is
// not "is the JSON well formed" but:
//
//   1. does the requirement COMPILE? A typo compiles to nothing, matches
//      nothing, and — before this file existed — could not be told apart from
//      "valid requirement, the peer simply did not match".
//   2. if it compiles, does it describe the identity we expected? Evaluating it
//      against a concrete code object (the signing peer itself, or an
//      application bundle on disk) turns a guess into an observation.
//
// Both answers come from the same Security framework the enforcement path uses,
// so the answer the administrator sees and the decision the helper makes cannot
// drift apart.
//
// READ-ONLY BY CONSTRUCTION
//
// Nothing here writes, grants, or reloads anything. It compiles expressions and
// evaluates them against code objects. The only new information it exposes over
// the socket is what any process running as the same user could already obtain
// with `codesign -d -r- <path>` and `codesign --verify`; no administrative
// authority is added, and there is no path from a verdict to a policy write.

import CryptoKit
import Foundation
import Security

/// Version of the requirement-validation contract.
///
/// Bump when the shape of a verdict or the canonicalization of the digests
/// changes. A host that does not know this number must treat the answers as
/// unavailable rather than guess.
public let bridgeRequirementContractVersion = 1
/// The wire operation that answers these questions.
public let bridgeRequirementContractName = "policy.requirements.check"

/// What the Security framework said about one requirement string.
public struct BridgeRequirementVerdict: Equatable, Sendable {
    /// `SecRequirementCreateWithString` returned errSecSuccess.
    public let compiles: Bool
    /// The raw OSStatus, kept so a host can log the exact failure.
    public let status: Int32
    /// A symbolic code (`ok`, `invalid_requirement`, `unsupported_requirement`),
    /// never the requirement text and never a localized string whose wording
    /// would change between OS versions.
    public let message: String
    /// SHA-256 of the trimmed requirement text, hex. Lets a host prove that the
    /// helper compiled the exact string it wrote without the helper echoing
    /// policy text back over the socket.
    public let digest: String

    public init(compiles: Bool, status: Int32, message: String, digest: String) {
        self.compiles = compiles
        self.status = status
        self.message = message
        self.digest = digest
    }
}

/// Symbolic name for the OSStatus values this file distinguishes.
///
/// Everything else is reported as `invalid_requirement`: the enforcement path
/// treats every failure the same way (it matches nothing), so inventing finer
/// categories here would be a claim the helper cannot support.
public func bridgeRequirementStatusName(_ status: Int32) -> String {
    switch status {
    case errSecSuccess: return "ok"
    case errSecCSReqInvalid: return "invalid_requirement"
    case errSecCSReqUnsupported: return "unsupported_requirement"
    case errSecCSReqFailed: return "requirement_not_matched"
    case errSecCSUnsigned: return "code_unsigned"
    case errSecCSNoSuchCode: return "code_not_found"
    default: return "invalid_requirement"
    }
}

/// Compile one requirement the way the enforcement path does.
public func bridgeCompileRequirement(_ text: String) -> BridgeRequirementVerdict {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let digest = bridgeRequirementDigest(trimmed)
    var requirement: SecRequirement?
    let status = SecRequirementCreateWithString(trimmed as CFString, [], &requirement)
    let compiled = status == errSecSuccess && requirement != nil
    return BridgeRequirementVerdict(
        compiles: compiled,
        status: status,
        message: bridgeRequirementStatusName(status),
        digest: digest)
}

/// Does `text` match the code identity of `peer`?
///
/// A requirement that does not compile matches nothing, as in enforcement.
public func bridgeRequirementMatches(_ text: String, peer: BridgePeerCode?) -> Bool {
    guard let peer, peer.validSignature else { return false }
    return peer.satisfies(requirement: text)
}

/// Does `text` match the code object stored at `path`?
///
/// Returns nil when no code object could be read at all (missing file, not a
/// binary, sandbox denial). Nil is "could not tell", never "no match".
public func bridgeRequirementMatches(_ text: String, codeAtPath path: String) -> Bool? {
    var staticCode: SecStaticCode?
    let created = SecStaticCodeCreateWithPath(
        URL(fileURLWithPath: path) as CFURL, [], &staticCode)
    guard created == errSecSuccess, let staticCode else { return nil }
    return bridgeRequirementMatches(text, staticCode: staticCode)
}

/// Does `text` match an already-resolved static code object?
public func bridgeRequirementMatches(_ text: String, staticCode: SecStaticCode) -> Bool {
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
          let requirement
    else { return false }
    return SecStaticCodeCheckValidity(staticCode, [], requirement) == errSecSuccess
}

/// Signing facts about a code object, without evaluating any requirement.
public struct BridgeCodeSummary: Equatable, Sendable {
    public let available: Bool
    public let identifier: String?
    public let teamID: String?
    public let validSignature: Bool

    public init(available: Bool, identifier: String?, teamID: String?, validSignature: Bool) {
        self.available = available
        self.identifier = identifier
        self.teamID = teamID
        self.validSignature = validSignature
    }

    /// Secret-free dictionary for a protocol frame.
    public var summary: [String: Any] {
        var value: [String: Any] = [
            "available": available,
            "valid_signature": validSignature,
        ]
        if let identifier, !identifier.isEmpty { value["identifier"] = identifier }
        if let teamID, !teamID.isEmpty { value["team_id"] = teamID }
        return value
    }
}

/// Read the signing identity of an application bundle or executable.
public func bridgeCodeSummary(atPath path: String) -> BridgeCodeSummary {
    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
          let staticCode
    else {
        return BridgeCodeSummary(available: false, identifier: nil, teamID: nil, validSignature: false)
    }
    let valid = SecStaticCodeCheckValidity(staticCode, [], nil) == errSecSuccess
    var information: CFDictionary?
    var identifier: String?
    var teamID: String?
    if SecCodeCopySigningInformation(
        staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
       let dictionary = information as? [String: Any] {
        identifier = dictionary[kSecCodeInfoIdentifier as String] as? String
        teamID = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }
    return BridgeCodeSummary(
        available: true, identifier: identifier, teamID: teamID, validSignature: valid)
}

// MARK: - Canonical digests
//
// These two functions ARE the contract a host mirrors. They are stated here, in
// the process that enforces the policy, so a host that wants to compare its
// bytes with what the helper compiled has one definition to follow:
//
//   requirement_sha256 = hex(SHA256(utf8(trimmed requirement)))
//   apps_sha256        = hex(SHA256(utf8(sorted unique lowercase identifiers
//                                        joined by "\n", each trimmed)))
//
// An empty list hashes the empty string. Lowercasing matches the helper's own
// case-insensitive comparison rule; sorting removes array-order noise.

public func bridgeSHA256Hex(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

public func bridgeRequirementDigest(_ text: String) -> String {
    bridgeSHA256Hex(Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
}

public func bridgeAppsDigest(_ apps: [String]) -> String {
    var seen = Set<String>()
    var normalized: [String] = []
    for entry in apps {
        let value = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, !seen.contains(value) else { continue }
        seen.insert(value)
        normalized.append(value)
    }
    normalized.sort()
    return bridgeSHA256Hex(Data(normalized.joined(separator: "\n").utf8))
}

// MARK: - Load-time audit

/// The requirement verdicts for a whole document.
public struct BridgeRequirementAudit: Equatable, Sendable {
    /// Client ids whose requirement does not compile, in document order.
    public let invalidClientIDs: [String]
    /// Verdict per client id, for diagnostics.
    public let verdicts: [String: BridgeRequirementVerdict]

    public init(invalidClientIDs: [String], verdicts: [String: BridgeRequirementVerdict]) {
        self.invalidClientIDs = invalidClientIDs
        self.verdicts = verdicts
    }

    public var isValid: Bool { invalidClientIDs.isEmpty }

    public static let empty = BridgeRequirementAudit(invalidClientIDs: [], verdicts: [:])
}

/// Compile every client requirement in a parsed document.
///
/// A document whose client requirement cannot compile is not a document with a
/// strict client: it is a document that authorizes nothing for that client while
/// looking, on screen, like one that does. The loader refuses it whole, and this
/// function is what makes that refusal explainable.
public func bridgeAuditClientRequirements(
    _ policy: BridgeAuthorizationPolicy
) -> BridgeRequirementAudit {
    guard !policy.clients.isEmpty else { return .empty }
    var invalid: [String] = []
    var verdicts: [String: BridgeRequirementVerdict] = [:]
    for client in policy.clients {
        let verdict = bridgeCompileRequirement(client.requirement)
        verdicts[client.clientID] = verdict
        if !verdict.compiles { invalid.append(client.clientID) }
    }
    return BridgeRequirementAudit(invalidClientIDs: invalid, verdicts: verdicts)
}
