// ComputerUseReliability.swift — retry classes, outcomes and the operation
// ledger (0.3.3 Reliability Engine).
//
// The rule this file exists to enforce: a timeout does not mean an action did
// not run. A client that lost the answer to `ui.press` cannot know whether the
// button was pressed, so it must NEVER resend it on its own. What it can do is
//   * resend with the SAME operation id, which the helper answers from its
//     ledger (replay) instead of executing a second time, or
//   * ask `action.outcome` for that id, and
//   * report `unknown` when neither can answer (the helper restarted).
// Reads and idempotent helper bookkeeping may be retried with bounded backoff.

import CryptoKit
import Foundation

public enum BridgeRetryClass: String, Sendable {
    /// No effect on the person's applications: safe to retry.
    case read
    /// Changes helper bookkeeping only, idempotently (stop, close, release).
    case idempotent
    /// May change the person's applications or the helper's security state:
    /// never retried automatically.
    case mutating
}

/// Classify one request for automatic retry. Unknown operations and actions of
/// unknown kind fail closed as `mutating`.
public func bridgeRetryClass(operation: String, kind: String?) -> BridgeRetryClass {
    switch operation {
    case "action.execute":
        return kind == "wait" || kind == "finish" ? .read : .mutating
    case "bridge.ping", "permissions.status", "policy.status", "breach.status", "apps.list",
         "policy.requirements.check", "observation.describe", "observation.capture_screen",
         "observation.stream_frame", "observation.stream_status", "workspace.status",
         "workspace.context_list", "workspace.context_status", "action.outcome",
         "browser.state", "browser.wait", "download.status", "download.wait", "download.list":
        return .read
    // `download.expect` touches no application: it records a baseline. With
    // an op_id (clients always send one) a resend returns the SAME
    // expectation; without one it declares another, equally harmless.
    case "observation.release", "observation.stream_stop", "workspace.context_close", "policy.reload",
         "download.forget", "download.expect":
        return .idempotent
    default:
        return .mutating
    }
}

/// Bounded backoff (seconds) for the retries a class allows.
public func bridgeRetryDelays(_ retryClass: BridgeRetryClass) -> [Double] {
    switch retryClass {
    case .read: return [0.25, 0.75]
    case .idempotent: return [0.25]
    case .mutating: return []
    }
}

/// What happened to an action, as far as anyone can know.
public enum BridgeExecutionOutcome: String, Sendable {
    /// It ran and reported success.
    case succeeded
    /// It ran and failed (or ran and broke the background promise).
    case failed
    /// It was refused before anything touched the machine.
    case notExecuted = "not_executed"
    /// Nobody can tell (the answer was lost and the ledger cannot answer).
    case unknown
}

public func bridgeExecutionOutcome(executed: Bool, ok: Bool) -> BridgeExecutionOutcome {
    guard executed else { return .notExecuted }
    return ok ? .succeeded : .failed
}

/// Shape of a client-chosen operation id: 8–80 of [A-Za-z0-9_-].
public func bridgeValidOperationID(_ value: String) -> Bool {
    guard (8...80).contains(value.count) else { return false }
    return value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
}

/// What a resend must match to be the same action: kind, context and every
/// parameter except the operation id. A digest, so typed text is never kept.
public func bridgeActionFingerprint(kind: String, contextID: String?, params: [String: Any]) -> String {
    var canonical = kind + "|" + (contextID ?? "-")
    for key in params.keys.sorted() where key != "op_id" {
        canonical += "|" + key + "=" + String(describing: params[key] ?? "")
    }
    return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
}

public struct BridgeOperationRecord<Payload> {
    public let opID: String
    public let fingerprint: String
    public let outcome: BridgeExecutionOutcome
    public let payload: Payload
    public let at: Double
}

public enum BridgeOperationLookup<Payload> {
    case new
    case replay(outcome: BridgeExecutionOutcome, payload: Payload)
    /// The id was used for a DIFFERENT action: refused, never executed.
    case conflict
}

extension BridgeOperationLookup: Equatable where Payload: Equatable {}

/// Recent action outcomes by operation id, per principal, bounded (oldest
/// dropped first). In memory: a helper restart forgets it, which is why the
/// helper publishes an `instance_id` — a client that sees it change knows its
/// in-flight action's outcome is `unknown`.
public final class BridgeOperationLedger<Payload> {
    public let capacity: Int
    private var records: [BridgePrincipal: [BridgeOperationRecord<Payload>]] = [:]

    public init(capacity: Int = 256) {
        self.capacity = max(1, capacity)
    }

    public func lookup(principal: BridgePrincipal, opID: String, fingerprint: String) -> BridgeOperationLookup<Payload> {
        guard let record = records[principal]?.last(where: { $0.opID == opID }) else { return .new }
        guard record.fingerprint == fingerprint else { return .conflict }
        return .replay(outcome: record.outcome, payload: record.payload)
    }

    public func record(principal: BridgePrincipal, opID: String, fingerprint: String,
                       outcome: BridgeExecutionOutcome, payload: Payload, at: Double) {
        var list = records[principal] ?? []
        list.removeAll { $0.opID == opID }
        list.append(BridgeOperationRecord(opID: opID, fingerprint: fingerprint, outcome: outcome, payload: payload, at: at))
        if list.count > capacity { list.removeFirst(list.count - capacity) }
        records[principal] = list
    }

    public func outcome(principal: BridgePrincipal, opID: String) -> BridgeOperationRecord<Payload>? {
        records[principal]?.last { $0.opID == opID }
    }

    public func count(principal: BridgePrincipal) -> Int { records[principal]?.count ?? 0 }
}

/// Random per helper process. A change between two answers means the helper
/// restarted: contexts, streams and the ledger are gone.
public func bridgeRandomInstanceID() -> String { bridgeRandomID(prefix: "ins") }

// MARK: - Helper identity (audit X-09)

/// The version and build `bridge.ping` reports for THIS helper, read from the
/// bundle's Info.plist. A host uses them (and the `capabilities` beside them)
/// to detect a helper that is older than the adapter it is paired with. Never
/// echoes anything that is not a short printable string.
public func bridgeHelperIdentity(info: [String: Any]?) -> (version: String, build: String) {
    func clean(_ value: Any?) -> String {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces),
              !text.isEmpty, text.count <= 40,
              !text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return "unknown" }
        return text
    }
    return (clean(info?["CFBundleShortVersionString"]), clean(info?["CFBundleVersion"]))
}

// MARK: - Bounded reads (audit X-03)

/// The accessibility messaging timeout of the whole helper process, in
/// seconds, set ONCE at start. It used to be set to 100 ms by the interference
/// sampler (`AXUIElementSetMessagingTimeout` on the system-wide element is
/// process-wide), which truncated trees, emptied titles and made a press that
/// had run look failed. 2 s bounds a hung application well under the 6 s
/// system default without cutting a slow but healthy one.
public let bridgeAXMessagingTimeoutSeconds: Double = 2.0

/// Runs a read that may hang on another process and bounds how long the caller
/// waits, WITHOUT lowering any process-wide timeout. A read that does not
/// finish in time yields the last value that did (or `fallback`); while it is
/// still running no second one is started, so a hung application costs one
/// parked thread, not a pile of them.
public final class BridgeBoundedReader<Value: Sendable>: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var inFlight = false
    private var last: Value

    public init(label: String, fallback: Value) {
        queue = DispatchQueue(label: label)
        last = fallback
    }

    public func read(timeout: TimeInterval, _ work: @escaping @Sendable () -> Value) -> Value {
        lock.lock()
        if inFlight {
            let value = last
            lock.unlock()
            return value
        }
        inFlight = true
        lock.unlock()
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            let value = work()
            lock.lock()
            last = value
            inFlight = false
            lock.unlock()
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
        lock.lock()
        defer { lock.unlock() }
        return last
    }
}
