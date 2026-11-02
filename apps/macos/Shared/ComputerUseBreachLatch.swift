// ComputerUseBreachLatch.swift — the persistent, auditable breach latch.
//
// ONE source of truth, compiled into the helper (scripts/build-helper.sh) and
// the CMMComputerUseTests bundle (project.yml). Pure Foundation: the helper
// owns the file I/O; every decision is here and pinned by tests.
//
// WHY A LATCH, AND WHY NOT "RESTART THE HELPER"
//
// A verified breach means an action promised no interference and the target
// came in front of the person's work anyway. The helper fails that call
// closed and then refuses further control of that target. Clearing the latch
// is a decision a PERSON takes after looking at what happened, so:
//
// - the latch is written to disk and survives a helper restart (a restart is
//   not an unlock, and a crash loop must not become one);
// - the only supported unlock is `breach.rearm`, issued by a client the policy
//   identifies by code signature AND grants the administrative operation
//   `breach.rearm` explicitly (CMM Console), with a non-empty reason;
// - a client never rearms a breach it caused (separation of duties: the agent
//   that broke the promise cannot clear it);
// - every latch, rearm and anomaly is appended to an audit log.
//
// An unreadable or malformed latch file is NOT "no latch": it refuses every
// control action until an administrator resets it, audited.

import Foundation

/// Administrative operations a client grant may carry (`"admin": [...]` in a
/// version-2 client entry). Closed set: an unknown value refuses the document.
public let bridgeAdminOperations: Set<String> = ["breach.rearm"]

/// One recorded breach. No window titles, no element text, no user content.
public struct BridgeBreachRecord: Equatable, Sendable {
    public let id: String
    /// Lower-cased bundle id of the application that came to the front.
    public let targetBundle: String
    public let targetName: String
    /// Client that issued the action (`""` for a legacy, unidentified client).
    public let clientID: String
    public let kind: String
    public let policy: String
    /// Seconds since 1970.
    public let at: Double
    public let verdict: String
    public let focusBecameTarget: Bool
    public let windowRaisedOverPerson: Bool
    public let targetFrontAtMs: Int?

    public init(
        id: String, targetBundle: String, targetName: String, clientID: String,
        kind: String, policy: String, at: Double, verdict: String,
        focusBecameTarget: Bool, windowRaisedOverPerson: Bool, targetFrontAtMs: Int?
    ) {
        self.id = id
        self.targetBundle = targetBundle.lowercased()
        self.targetName = targetName
        self.clientID = clientID
        self.kind = kind
        self.policy = policy
        self.at = at
        self.verdict = verdict
        self.focusBecameTarget = focusBecameTarget
        self.windowRaisedOverPerson = windowRaisedOverPerson
        self.targetFrontAtMs = targetFrontAtMs
    }

    public func dictionary() -> [String: Any] {
        var wire: [String: Any] = [
            "id": id, "target_bundle": targetBundle, "target_name": targetName,
            "client_id": clientID, "kind": kind, "policy": policy, "at": at,
            "verdict": verdict, "focus_became_target": focusBecameTarget,
            "window_raised_over_person": windowRaisedOverPerson,
        ]
        if let targetFrontAtMs { wire["target_front_at_ms"] = targetFrontAtMs }
        return wire
    }

    public init?(dictionary d: [String: Any]) {
        guard let id = d["id"] as? String, !id.isEmpty,
              let bundle = d["target_bundle"] as? String, !bundle.isEmpty,
              let at = (d["at"] as? NSNumber)?.doubleValue
        else { return nil }
        self.init(
            id: id, targetBundle: bundle,
            targetName: d["target_name"] as? String ?? "",
            clientID: d["client_id"] as? String ?? "",
            kind: d["kind"] as? String ?? "",
            policy: d["policy"] as? String ?? "",
            at: at,
            verdict: d["verdict"] as? String ?? "",
            focusBecameTarget: d["focus_became_target"] as? Bool ?? false,
            windowRaisedOverPerson: d["window_raised_over_person"] as? Bool ?? false,
            targetFrontAtMs: (d["target_front_at_ms"] as? NSNumber)?.intValue)
    }
}

/// The set of open breaches.
public struct BridgeBreachLatchState: Equatable, Sendable {
    public static let formatVersion = 1
    public private(set) var records: [BridgeBreachRecord]

    public init(records: [BridgeBreachRecord] = []) { self.records = records }

    public func record(forTarget bundle: String) -> BridgeBreachRecord? {
        let key = bundle.lowercased()
        return records.first { $0.targetBundle == key }
    }

    public func record(id: String) -> BridgeBreachRecord? {
        records.first { $0.id == id }
    }

    public mutating func latch(_ record: BridgeBreachRecord) {
        guard self.record(id: record.id) == nil else { return }
        records.append(record)
    }

    @discardableResult
    public mutating func remove(id: String) -> BridgeBreachRecord? {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return nil }
        return records.remove(at: index)
    }

    public func encoded() -> Data {
        let document: [String: Any] = [
            "version": Self.formatVersion,
            "breaches": records.map { $0.dictionary() },
        ]
        return (try? JSONSerialization.data(
            withJSONObject: document, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }
}

/// What reading the latch file produced.
public enum BridgeBreachLatchLoad: Equatable, Sendable {
    case loaded(BridgeBreachLatchState)
    /// The file exists but cannot be trusted. Fail closed.
    case invalid(reason: String)

    public var state: BridgeBreachLatchState? {
        if case .loaded(let state) = self { return state }
        return nil
    }
}

/// Parse the latch file. `nil` data means "no file": nothing latched.
public func bridgeLoadBreachLatch(data: Data?) -> BridgeBreachLatchLoad {
    guard let data else { return .loaded(BridgeBreachLatchState()) }
    guard let object = try? JSONSerialization.jsonObject(with: data),
          let document = object as? [String: Any]
    else { return .invalid(reason: "not_json") }
    guard document["version"] as? Int == BridgeBreachLatchState.formatVersion else {
        return .invalid(reason: "unknown_version")
    }
    guard let raw = document["breaches"] as? [[String: Any]] else {
        return .invalid(reason: "no_breaches_array")
    }
    var state = BridgeBreachLatchState()
    for entry in raw {
        guard let record = BridgeBreachRecord(dictionary: entry) else {
            return .invalid(reason: "malformed_record")
        }
        state.latch(record)
    }
    return .loaded(state)
}

/// Must this control action be refused because of the latch?
///
/// Applies to accessibility-class control kinds (press, set value, scroll); the
/// caller passes `isControl`. `wait`/`finish` and observation are not control.
public func bridgeLatchRefusal(
    load: BridgeBreachLatchLoad, targetBundle: String?, isControl: Bool,
    mode: BridgeInteractionMode
) -> BridgePolicyRefusal? {
    guard isControl else { return nil }
    switch load {
    case .invalid(let reason):
        return BridgePolicyRefusal(
            code: "ACTION_FAILED",
            message: "The breach latch file cannot be read; control is suspended until CMM Console resets it.",
            detail: "policy=\(mode.rawValue);reason=breach_latch_invalid;cause=\(reason)")
    case .loaded(let state):
        guard let targetBundle, let record = state.record(forTarget: targetBundle) else { return nil }
        return BridgePolicyRefusal(
            code: "ACTION_FAILED",
            message: "An earlier action on this application took the person's focus; control is suspended until it is rearmed from CMM Console.",
            detail: "policy=\(mode.rawValue);reason=breach;target=\(record.targetBundle);breach_id=\(record.id)")
    }
}

// MARK: - Rearm

public enum BridgeRearmDecision: Equatable, Sendable {
    case rearm(BridgeBreachRecord, reason: String)
    /// Replace an untrustworthy latch file with an empty one.
    case resetInvalid(reason: String)
    case refused(BridgePolicyRefusal)
}

public let bridgeRearmReasonMaxChars = 500

/// Operator-supplied text, made safe for a log line.
public func bridgeSanitizedReason(_ raw: Any?) -> String? {
    guard let text = raw as? String else { return nil }
    let cleaned = String(text.unicodeScalars.map {
        CharacterSet.controlCharacters.contains($0) ? " " : Character($0)
    }).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return nil }
    return String(cleaned.prefix(bridgeRearmReasonMaxChars))
}

/// Decide a `breach.rearm` request.
///
/// `arguments`: `{breach_id, reason}` or `{reset_invalid_state: true, reason}`.
public func bridgeRearmDecision(
    arguments: [String: Any],
    client: BridgeClientGrant?,
    clientAuthorization: BridgeClientAuthorization,
    load: BridgeBreachLatchLoad
) -> BridgeRearmDecision {
    func refuse(_ code: String, _ message: String, _ detail: String) -> BridgeRearmDecision {
        .refused(BridgePolicyRefusal(code: code, message: message, detail: detail))
    }
    guard clientAuthorization == .required else {
        return refuse("APPROVAL_REJECTED",
            "Rearming needs a deployment that identifies its clients (policy version 2).",
            "auth=rearm_requires_client_identity;want=breach.rearm")
    }
    guard let client else {
        return refuse("APPROVAL_REJECTED",
            "This process has no verified client identity.",
            "auth=client_not_authorized;want=breach.rearm")
    }
    guard client.adminOperations.contains("breach.rearm") else {
        return refuse("APPROVAL_REJECTED",
            "This client is not granted breach.rearm.",
            "auth=rearm_not_granted;client=\(client.clientID)")
    }
    guard let reason = bridgeSanitizedReason(arguments["reason"]) else {
        return refuse("ACTION_FAILED", "A rearm needs a reason.", "reason=rearm_reason_missing")
    }
    if arguments["reset_invalid_state"] as? Bool == true {
        guard case .invalid = load else {
            return refuse("ACTION_FAILED", "The latch file is valid; rearm breaches by id.",
                "reason=latch_state_valid")
        }
        return .resetInvalid(reason: reason)
    }
    guard let state = load.state else {
        return refuse("ACTION_FAILED",
            "The latch file cannot be read; reset it with reset_invalid_state.",
            "reason=breach_latch_invalid")
    }
    guard let id = arguments["breach_id"] as? String, !id.isEmpty else {
        return refuse("ACTION_FAILED", "A rearm names one breach_id.", "reason=breach_id_missing")
    }
    guard let record = state.record(id: id) else {
        return refuse("ACTION_FAILED", "No open breach has that id.", "reason=unknown_breach")
    }
    if !record.clientID.isEmpty,
       record.clientID.caseInsensitiveCompare(client.clientID) == .orderedSame {
        return refuse("APPROVAL_REJECTED",
            "A client cannot rearm a breach its own action caused.",
            "auth=self_rearm_not_permitted;client=\(client.clientID)")
    }
    return .rearm(record, reason: reason)
}

// MARK: - Audit

/// One append-only audit line. `event`: latched | rearmed | reset_invalid |
/// cleared_outside_console | latch_write_failed.
public func bridgeBreachAuditEntry(
    event: String, at: Double, record: BridgeBreachRecord?, actorClientID: String?,
    actorSigningID: String?, reason: String?, extra: [String: Any] = [:]
) -> [String: Any] {
    var entry: [String: Any] = ["event": event, "at": at]
    if let record { entry["breach"] = record.dictionary() }
    if let actorClientID { entry["actor_client_id"] = actorClientID }
    if let actorSigningID { entry["actor_signing_id"] = actorSigningID }
    if let reason { entry["reason"] = reason }
    for (key, value) in extra { entry[key] = value }
    return entry
}

/// Records present before a reload and absent after it, cleared by something
/// other than `breach.rearm` (e.g. the file was edited or deleted).
public func bridgeBreachesClearedOutside(
    before: BridgeBreachLatchState, after: BridgeBreachLatchState
) -> [BridgeBreachRecord] {
    before.records.filter { after.record(id: $0.id) == nil }
}
