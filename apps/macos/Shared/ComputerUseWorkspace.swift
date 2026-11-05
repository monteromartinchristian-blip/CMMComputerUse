// ComputerUseWorkspace.swift — the Multi-App Workspace (0.3.3).
//
// 0.3.2 held ONE process-wide element table and ONE generation counter: an
// observation of application B replaced application A's handles, and a handle
// produced for one client resolved for any other. This file replaces that
// singleton with a bounded registry of CONTEXTS:
//
//   * a context is one application (and the window/document observed in it),
//     owned by one PRINCIPAL — the verified identity of the caller;
//   * each context has its own current generation (numbered from ONE
//     workspace-wide counter, so a snapshot number names one context), its own
//     observation clock, its own released generations and its own handles;
//   * a handle resolves only inside the context that produced it, and only for
//     the principal that owns that context;
//   * a context id is opaque and random, and it is NEVER an authorization:
//     every observation and action is still decided by the application grant
//     (`authorization.decision`) at the moment it runs.
//
// Pure and generic over the handle type, so the helper stores live AX
// references and the tests store strings. Not thread-safe by design: the helper
// mutates it only under `dispatchLock`, exactly like the table it replaces.

import CryptoKit
import Foundation
import Security

// MARK: - Principals

/// How strongly a principal was identified. Reported, never upgraded.
public enum BridgePrincipalStrength: String, Sendable {
    /// Matched a policy client by code-signing requirement (protocol v2).
    case verifiedClient = "verified_client"
    /// No policy clients (v1 document): the peer's validly signed code identity.
    case codeIdentity = "code_identity"
    /// An unsigned peer: only its process is known.
    case process
    /// stdio mode: the process that spawned the helper.
    case local
}

/// Who owns contexts and streams. Derived from the kernel's view of the peer
/// (Shared/ComputerUseClientIdentity.swift), never from a request field.
public struct BridgePrincipal: Hashable, Sendable {
    public let key: String
    public let strength: BridgePrincipalStrength

    public init(key: String, strength: BridgePrincipalStrength) {
        self.key = key
        self.strength = strength
    }
}

/// The principal for one request. A verified policy client wins; otherwise the
/// validly signed code identity; otherwise the process. An unsigned identifier
/// is a claim anyone can make, so it never names a principal.
public func bridgePrincipal(
    clientID: String?, peerIdentifier: String?, peerTeamID: String?,
    peerValidSignature: Bool, peerPID: Int32?
) -> BridgePrincipal {
    if let clientID, !clientID.isEmpty {
        return BridgePrincipal(key: "client:\(clientID)", strength: .verifiedClient)
    }
    if peerValidSignature, let identifier = peerIdentifier, !identifier.isEmpty {
        return BridgePrincipal(key: "code:\(identifier)@\(peerTeamID ?? "-")", strength: .codeIdentity)
    }
    if let peerPID, peerPID > 0 {
        return BridgePrincipal(key: "pid:\(peerPID)", strength: .process)
    }
    return BridgePrincipal(key: "local", strength: .local)
}

// MARK: - Opaque ids

/// `<prefix>_` + 128 random bits in hex. Unpredictable (SecRandomCopyBytes), so
/// an id cannot be guessed; it is still not an authorization.
public func bridgeRandomID(prefix: String) -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
        // The system CSPRNG does not fail in practice; if it ever did, a UUID
        // (also random) keeps the id unpredictable rather than sequential.
        let uuid = UUID().uuid
        bytes = [uuid.0, uuid.1, uuid.2, uuid.3, uuid.4, uuid.5, uuid.6, uuid.7,
                 uuid.8, uuid.9, uuid.10, uuid.11, uuid.12, uuid.13, uuid.14, uuid.15]
    }
    return prefix + "_" + bytes.map { String(format: "%02x", $0) }.joined()
}

public func bridgeRandomContextID() -> String { bridgeRandomID(prefix: "ctx") }

/// Shape check for ids arriving in requests: bounded, no path or control text.
public func bridgeValidContextID(_ value: String) -> Bool {
    bridgeValidOpaqueID(value, prefix: "ctx")
}

public func bridgeValidOpaqueID(_ value: String, prefix: String) -> Bool {
    guard value.hasPrefix(prefix + "_"), value.count <= 80 else { return false }
    let body = value.dropFirst(prefix.count + 1)
    return !body.isEmpty && body.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
}

// MARK: - Document identity (tab / document inside one window)

/// What document a window was showing. A browser tab switch keeps the window
/// (and its window id) and changes the document, so the window alone does not
/// identify what the handles were taken from.
///
/// Only identities the application exposes through supported accessibility
/// attributes count as VERIFIED: `AXDocument` on the window, else the `AXURL`
/// of its web area. Nothing is invented: when neither exists the identity is
/// `title_only`, which is evidence, not proof. The value itself is never
/// stored or reported, only a digest.
public struct BridgeDocumentIdentity: Equatable, Sendable {
    public enum Source: String, Sendable {
        case axDocument = "ax_document"
        case axURL = "ax_url"
        case titleOnly = "title_only"
    }

    public let source: Source
    /// First 16 hex chars of SHA-256 of the document value; "" for title_only.
    public let digest: String
    public let title: String

    public init(axDocument: String?, axURL: String?, title: String) {
        self.title = title
        if let document = axDocument?.trimmingCharacters(in: .whitespacesAndNewlines), !document.isEmpty {
            source = .axDocument
            digest = bridgeDocumentDigest(document)
        } else if let url = axURL?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
            source = .axURL
            digest = bridgeDocumentDigest(url)
        } else {
            source = .titleOnly
            digest = ""
        }
    }

    public var verified: Bool { source != .titleOnly }

    public var dictionary: [String: Any] {
        ["source": source.rawValue, "verified": verified, "digest": digest]
    }
}

func bridgeDocumentDigest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
}

/// Refuse a handle whose document is no longer the one it was taken from.
///
/// * Verified → verified with another digest: the document changed (a tab
///   switch, a navigation, another file in the same window).
/// * Verified → unverifiable: the evidence is gone, so sameness cannot be
///   proven — refused in `strict` (explicit 0.3.3 contexts).
/// * Title-only: a different title is NOT proof of another document, but it is
///   all there is. `strict` refuses and asks for a new observation; the 0.3.2
///   default context keeps its old semantics (re-authorize by title only).
public func bridgeDocumentRefusal(
    observed: BridgeDocumentIdentity, current: BridgeDocumentIdentity,
    strict: Bool, mode: BridgeInteractionMode
) -> BridgePolicyRefusal? {
    let reason: String?
    if observed.verified && current.verified {
        reason = observed.digest == current.digest ? nil : "document_changed"
    } else if observed.verified {
        reason = strict ? "document_changed;evidence=lost" : nil
    } else {
        reason = strict && observed.title != current.title ? "document_unverified" : nil
    }
    guard let reason else { return nil }
    return BridgePolicyRefusal(
        code: "ACTION_FAILED",
        message: "The document this element belongs to is no longer the one that was observed; observe again.",
        detail: "policy=\(mode.rawValue);reason=\(reason)")
}

// MARK: - Contexts

/// The application/window/document a context observed last.
public struct BridgeContextIdentity: Equatable, Sendable {
    public let bundleID: String
    public let pid: Int32
    public let appName: String
    public let windowID: Int?
    public let windowTitle: String
    public let document: BridgeDocumentIdentity

    public init(bundleID: String, pid: Int32, appName: String, windowID: Int?,
                windowTitle: String, document: BridgeDocumentIdentity) {
        self.bundleID = bundleID
        self.pid = pid
        self.appName = appName
        self.windowID = windowID
        self.windowTitle = windowTitle
        self.document = document
    }

    /// Which facts differ from `previous` (diagnostics for the caller).
    func changes(from previous: BridgeContextIdentity) -> [String] {
        var changed: [String] = []
        if bundleID != previous.bundleID { changed.append("bundle") }
        if pid != previous.pid { changed.append("pid") }
        if windowID != previous.windowID || windowTitle != previous.windowTitle { changed.append("window") }
        if document.source != previous.document.source || document.digest != previous.document.digest {
            changed.append("document")
        }
        return changed
    }
}

public struct BridgeContextRecord<Handle> {
    public let id: String
    public let principal: BridgePrincipal
    /// "A", "B", … for explicit contexts; "default" for the 0.3.2 context.
    public let label: String
    /// The implicit context of a caller that never names one (0.3.2 tools).
    public let legacy: Bool
    /// Bundle the context was created for, when the caller named one.
    public let boundBundle: String?
    public internal(set) var identity: BridgeContextIdentity?
    public internal(set) var generation: Int = 0
    public internal(set) var capturedAt: Double = 0
    public internal(set) var released: Set<Int> = []
    public internal(set) var handles: [Int: Handle] = [:]
    public let createdAt: Double
    public internal(set) var lastUsedAt: Double
    /// Why the current generation was last retired, if it was.
    public internal(set) var invalidation: String?
    public internal(set) var streamID: String?
}

public struct BridgeWorkspaceLimits: Equatable, Sendable {
    /// Explicit contexts one principal may hold at once (the 0.3.3 contract: 2).
    public var maxContextsPerPrincipal: Int
    /// Explicit contexts across every principal: a resource bound.
    public var maxContextsTotal: Int
    /// A context unused this long is reaped with its handles and stream.
    public var idleSeconds: Double
    /// Closed ids remembered per principal, so a repeated close is a no-op.
    public var closedMemory: Int

    public init(maxContextsPerPrincipal: Int = 2, maxContextsTotal: Int = 16,
                idleSeconds: Double = 1800, closedMemory: Int = 32) {
        self.maxContextsPerPrincipal = maxContextsPerPrincipal
        self.maxContextsTotal = maxContextsTotal
        self.idleSeconds = idleSeconds
        self.closedMemory = closedMemory
    }
}

public struct BridgeObservationStart: Equatable, Sendable {
    public let generation: Int
    /// "bundle", "pid", "window", "document" — what moved since the last one.
    public let identityChanges: [String]
}

public struct BridgeContextClose: Equatable, Sendable {
    public let closed: Bool
    public let alreadyClosed: Bool
    public let releasedHandles: Int
    /// The stream bound to the context; the caller stops it.
    public let streamID: String?
}

public struct BridgeResolvedHandle<Handle> {
    public let context: BridgeContextRecord<Handle>
    public let handle: Handle
    public let elementID: Int
}

/// The refusal an unknown context gets. Identical whether the id never existed
/// or belongs to someone else: a caller learns nothing about other contexts.
func bridgeUnknownContextRefusal() -> BridgePolicyRefusal {
    BridgePolicyRefusal(
        code: "CONTEXT_UNKNOWN",
        message: "No such context for this client; create one with workspace.context_create.",
        detail: "reason=context_unknown")
}

public final class BridgeWorkspace<Handle> {
    public let limits: BridgeWorkspaceLimits
    private let makeID: () -> String
    private var contexts: [String: BridgeContextRecord<Handle>] = [:]
    /// One generation counter for the whole workspace (audit X-04): a
    /// snapshot number names exactly ONE context, so an action that cites the
    /// wrong context (or none) can never resolve "snapshot 1, element 7" of
    /// another application. Per-context numbering made that possible.
    private var lastGeneration = 0

    private func nextGeneration() -> Int {
        lastGeneration += 1
        return lastGeneration
    }
    private var legacyIDs: [BridgePrincipal: String] = [:]
    private var closed: [BridgePrincipal: [String]] = [:]

    public init(limits: BridgeWorkspaceLimits = BridgeWorkspaceLimits(),
                makeID: @escaping () -> String = bridgeRandomContextID) {
        self.limits = limits
        self.makeID = makeID
    }

    private func freshID() -> String {
        var id = makeID()
        while contexts[id] != nil { id = makeID() }
        return id
    }

    private func explicit(_ principal: BridgePrincipal) -> [BridgeContextRecord<Handle>] {
        contexts.values.filter { $0.principal == principal && !$0.legacy }
    }

    // MARK: lifecycle

    /// Open an explicit context. `target` is the RESOLVED bundle id the context
    /// is bound to (nil: bound by its first observation).
    public func create(
        principal: BridgePrincipal, target: String?, now: Double
    ) -> Result<BridgeContextRecord<Handle>, BridgePolicyRefusal> {
        let mine = explicit(principal)
        guard mine.count < limits.maxContextsPerPrincipal else {
            return .failure(BridgePolicyRefusal(
                code: "CONTEXT_LIMIT",
                message: "This client already holds the maximum number of contexts; close one first.",
                detail: "reason=context_limit;scope=client;active=\(mine.count);max=\(limits.maxContextsPerPrincipal)"))
        }
        let total = contexts.values.filter { !$0.legacy }.count
        guard total < limits.maxContextsTotal else {
            return .failure(BridgePolicyRefusal(
                code: "CONTEXT_LIMIT",
                message: "The helper holds the maximum number of contexts.",
                detail: "reason=context_limit;scope=helper;active=\(total);max=\(limits.maxContextsTotal)"))
        }
        let used = Set(mine.map { $0.label })
        let label = bridgeContextLabels.first { !used.contains($0) } ?? "C\(mine.count + 1)"
        let record = BridgeContextRecord<Handle>(
            id: freshID(), principal: principal, label: label, legacy: false,
            boundBundle: (target?.isEmpty ?? true) ? nil : target,
            createdAt: now, lastUsedAt: now)
        contexts[record.id] = record
        return .success(record)
    }

    /// The context a 0.3.2 caller (no `context_id`) uses: one per principal,
    /// created on first use, not counted against the explicit limit.
    public func legacyContext(principal: BridgePrincipal, now: Double) -> BridgeContextRecord<Handle> {
        if let id = legacyIDs[principal], var record = contexts[id] {
            record.lastUsedAt = now
            contexts[id] = record
            return record
        }
        let record = BridgeContextRecord<Handle>(
            id: freshID(), principal: principal, label: "default", legacy: true,
            boundBundle: nil, createdAt: now, lastUsedAt: now)
        contexts[record.id] = record
        legacyIDs[principal] = record.id
        return record
    }

    /// Mark a context as in use (audit M-03): a read of something that belongs
    /// to it — a download it declared — keeps it from expiring under that
    /// work. Only its owner can; unknown or foreign ids change nothing.
    @discardableResult
    public func touch(principal: BridgePrincipal, id: String, now: Double) -> Bool {
        guard var record = contexts[id], record.principal == principal else { return false }
        record.lastUsedAt = now
        contexts[id] = record
        return true
    }

    /// Resolve a context for `principal`. `id == nil` is the legacy default.
    public func context(
        principal: BridgePrincipal, id: String?, now: Double
    ) -> Result<BridgeContextRecord<Handle>, BridgePolicyRefusal> {
        guard let id else { return .success(legacyContext(principal: principal, now: now)) }
        guard bridgeValidContextID(id) || contexts[id] != nil else { return .failure(bridgeUnknownContextRefusal()) }
        if var record = contexts[id], record.principal == principal {
            record.lastUsedAt = now
            contexts[id] = record
            return .success(record)
        }
        if closed[principal]?.contains(id) == true {
            return .failure(BridgePolicyRefusal(
                code: "CONTEXT_CLOSED",
                message: "This context was closed; create a new one.",
                detail: "reason=context_closed"))
        }
        return .failure(bridgeUnknownContextRefusal())
    }

    public func list(principal: BridgePrincipal) -> [BridgeContextRecord<Handle>] {
        contexts.values.filter { $0.principal == principal }
            .sorted { ($0.legacy ? "~" : $0.label) < ($1.legacy ? "~" : $1.label) }
    }

    public var count: Int { contexts.count }

    /// Close a context. Idempotent for its owner; unknown for anyone else.
    public func close(
        principal: BridgePrincipal, id: String
    ) -> Result<BridgeContextClose, BridgePolicyRefusal> {
        if let record = contexts[id], record.principal == principal {
            remove(id)
            return .success(BridgeContextClose(
                closed: true, alreadyClosed: false, releasedHandles: record.handles.count,
                streamID: record.streamID))
        }
        if closed[principal]?.contains(id) == true {
            return .success(BridgeContextClose(closed: false, alreadyClosed: true, releasedHandles: 0, streamID: nil))
        }
        return .failure(bridgeUnknownContextRefusal())
    }

    private func remove(_ id: String) {
        guard let record = contexts.removeValue(forKey: id) else { return }
        if record.legacy { legacyIDs.removeValue(forKey: record.principal) }
        var memory = closed[record.principal] ?? []
        memory.append(id)
        if memory.count > max(1, limits.closedMemory) { memory.removeFirst(memory.count - limits.closedMemory) }
        closed[record.principal] = memory
    }

    /// Drop contexts idle past `limits.idleSeconds`. Returned so the caller can
    /// stop their streams.
    public func reap(now: Double) -> [BridgeContextRecord<Handle>] {
        let stale = contexts.values.filter { now - $0.lastUsedAt > limits.idleSeconds }
            .sorted { $0.createdAt < $1.createdAt }
        stale.forEach { remove($0.id) }
        return stale
    }

    /// A helper-wide failure: every context is gone, honestly, for everyone.
    public func removeAll() -> [BridgeContextRecord<Handle>] {
        let all = Array(contexts.values)
        all.forEach { remove($0.id) }
        return all
    }

    // MARK: observation

    /// An explicit context is ONE application. Observing another one through it
    /// would make its handles, stream and panel describe two things at once.
    public func targetMismatch(id: String, bundleID: String) -> BridgePolicyRefusal? {
        guard let record = contexts[id], !record.legacy else { return nil }
        guard let bound = record.identity?.bundleID ?? record.boundBundle, bound != bundleID else { return nil }
        return BridgePolicyRefusal(
            code: "CONTEXT_TARGET_MISMATCH",
            message: "This context belongs to another application; use or create a context for this one.",
            detail: "reason=context_target_mismatch;bound=\(bound)")
    }

    /// Start a new generation in ONE context: its table is emptied and its
    /// clock restarts. No other context moves.
    public func beginObservation(
        id: String, identity: BridgeContextIdentity, now: Double
    ) -> BridgeObservationStart? {
        guard var record = contexts[id] else { return nil }
        let changes = record.identity.map { identity.changes(from: $0) } ?? []
        record.handles.removeAll()
        record.generation = nextGeneration()
        record.capturedAt = now
        record.lastUsedAt = now
        record.identity = identity
        record.invalidation = nil
        contexts[id] = record
        return BridgeObservationStart(generation: record.generation, identityChanges: changes)
    }

    /// Store the handles an observation produced — only if that observation is
    /// still the context's current one (a superseded walk is dropped).
    public func commit(id: String, generation: Int, handles: [Int: Handle]) {
        guard var record = contexts[id], record.generation == generation else { return }
        record.handles = handles
        contexts[id] = record
    }

    /// Retire the current generation of ONE context (release / USER_TAKEOVER),
    /// with the same rule 0.3.2 applied to the single table.
    @discardableResult
    public func invalidate(id: String, reason: String, now: Double) -> BridgeObservationRetirement? {
        guard var record = contexts[id] else { return nil }
        let retirement = bridgeRetireObservation(
            generation: record.generation, releasedSnapshots: record.released, now: now)
        record.handles.removeAll()
        record.released = retirement.releasedSnapshots
        // The new current generation comes from the workspace-wide counter
        // (audit X-04); what is REPORTED must be that number, not the one the
        // shared rule computed for a single table.
        let current = nextGeneration()
        record.generation = current
        record.capturedAt = retirement.capturedAt
        record.invalidation = reason
        contexts[id] = record
        return BridgeObservationRetirement(
            retired: retirement.retired, generation: current, capturedAt: retirement.capturedAt,
            releasedSnapshots: retirement.releasedSnapshots)
    }

    public func bindStream(id: String, streamID: String?) {
        guard var record = contexts[id] else { return }
        record.streamID = streamID
        contexts[id] = record
    }

    public func record(id: String) -> BridgeContextRecord<Handle>? { contexts[id] }

    // MARK: handles

    /// Everything a handle must prove before it is touched, in 0.3.2's order:
    /// released, expired, superseded, unknown — now inside ONE context that
    /// the caller owns.
    public func resolveHandle(
        principal: BridgePrincipal, id: String?, snapshot: Int?, elementID: Int?,
        mode: BridgeInteractionMode, now: Double
    ) -> Result<BridgeResolvedHandle<Handle>, BridgePolicyRefusal> {
        let record: BridgeContextRecord<Handle>
        switch context(principal: principal, id: id, now: now) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let found): record = found
        }
        if let refusal = bridgeReleasedSnapshotRefusal(
            requested: snapshot, releasedSnapshots: record.released,
            current: record.generation, mode: mode) {
            return .failure(refusal)
        }
        if bridgeObservationExpired(capturedAt: record.capturedAt, now: now, mode: mode) {
            return .failure(BridgePolicyRefusal(
                code: "ACTION_FAILED",
                message: "The observation this element belongs to has expired; observe again.",
                detail: "policy=\(mode.rawValue);reason=expired;age=\(Int(now - record.capturedAt))s;snapshot=\(record.generation)"))
        }
        if let refusal = bridgeSnapshotRefusal(current: record.generation, requested: snapshot, mode: mode) {
            return .failure(refusal)
        }
        guard let elementID, let handle = record.handles[elementID] else {
            return .failure(BridgePolicyRefusal(
                code: "ACTION_FAILED",
                message: "The referenced UI element is no longer on screen.",
                detail: "policy=\(mode.rawValue);reason=unknown_element"))
        }
        return .success(BridgeResolvedHandle(context: record, handle: handle, elementID: elementID))
    }
}

/// Panel labels, in order. The workspace contract is two; the list is longer
/// only so a raised limit stays readable.
public let bridgeContextLabels = ["A", "B", "C", "D"]

/// Public, bounded description of a context. Never handles, never content.
public func bridgeContextSummary<Handle>(_ record: BridgeContextRecord<Handle>, now: Double,
                                         mode: BridgeInteractionMode) -> [String: Any] {
    var summary: [String: Any] = [
        "context_id": record.id,
        "label": record.label,
        "legacy": record.legacy,
        "snapshot": record.generation,
        "handles": record.handles.count,
        "observed": record.identity != nil,
        "expired": record.identity == nil
            ? false : bridgeObservationExpired(capturedAt: record.capturedAt, now: now, mode: mode),
        "idle_seconds": Int(max(0, now - record.lastUsedAt)),
        "stream_id": record.streamID as Any,
        "invalidation": record.invalidation as Any,
    ]
    if let bound = record.boundBundle { summary["bound_bundle"] = bound }
    if let identity = record.identity {
        summary["identity"] = [
            "bundle": identity.bundleID,
            "pid": Int(identity.pid),
            "app": identity.appName,
            "window": identity.windowTitle,
            "window_id": identity.windowID as Any,
            "document": identity.document.dictionary,
        ]
    }
    return summary
}

/// Workspace operations return `Result<_, BridgePolicyRefusal>`; a refusal is
/// the typed failure, never thrown across the dispatch boundary.
extension BridgePolicyRefusal: Error {}
