// ComputerUseStreams.swift — the bounded registry of live window streams (0.3.3).
//
// 0.3.2 kept ONE SCStream per helper: a second `observation.stream_start`, from
// ANY client, stopped the first. The Multi-App Workspace needs two windows
// mirrored at once, each with its own sink, frame index, health and recovery,
// and it needs a stream to belong to the principal that opened it.
//
// This file is the bookkeeping only — which slots exist, who owns them, what
// state they are in — generic over the resource the helper keeps per stream
// (the SCStream and its sink). Opening and closing the real capture stays in
// apps/macos/CMMComputerUse/WindowStream.swift. Not thread-safe: the helper
// wraps it in its own lock because frame reads are served outside
// `dispatchLock`.

import Foundation

public struct BridgeStreamIdentity: Equatable, Sendable {
    public let bundleID: String
    public let pid: Int32
    public let windowID: Int
    public let windowTitle: String
    public let appName: String

    public init(bundleID: String, pid: Int32, windowID: Int, windowTitle: String, appName: String) {
        self.bundleID = bundleID
        self.pid = pid
        self.windowID = windowID
        self.windowTitle = windowTitle
        self.appName = appName
    }
}

public enum BridgeStreamPhase: String, Sendable {
    case connecting, warming, live, stale, recovering, error, closed
}

public struct BridgeStreamLimits: Equatable, Sendable {
    /// Concurrent streams across the helper (ScreenCaptureKit cost).
    public var maxStreams: Int
    /// Concurrent streams one principal may hold.
    public var maxPerPrincipal: Int
    /// A stream with no frame yet is "warming" this long, then "stale".
    public var warmupSeconds: Double
    /// No new frame AND no idle heartbeat for this long: "stale" (frozen).
    public var staleSeconds: Double
    /// Recovery attempts per stream before it stays in "error".
    public var maxRecoveries: Int
    public var stoppedMemory: Int

    public init(maxStreams: Int = 2, maxPerPrincipal: Int = 2, warmupSeconds: Double = 3,
                staleSeconds: Double = 2, maxRecoveries: Int = 5, stoppedMemory: Int = 32) {
        self.maxStreams = maxStreams
        self.maxPerPrincipal = maxPerPrincipal
        self.warmupSeconds = warmupSeconds
        self.staleSeconds = staleSeconds
        self.maxRecoveries = maxRecoveries
        self.stoppedMemory = stoppedMemory
    }
}

public struct BridgeStreamHealth: Equatable, Sendable {
    public let phase: BridgeStreamPhase
    public let reason: String?
    /// Live, but the window has not changed since the last frame: the stream
    /// is delivering idle buffers, which prove it is not frozen.
    public let unchanged: Bool
}

/// The one honest phase of a stream. An old frame is never "live": either the
/// stream delivered pixels recently, or it delivered idle buffers recently
/// (alive, nothing changed), or it is stale.
public func bridgeStreamHealth(
    startedAt: Double, frames: Int, lastFrameAt: Double, lastHeartbeatAt: Double,
    failure: String?, recovering: Bool, stopped: Bool, now: Double, limits: BridgeStreamLimits
) -> BridgeStreamHealth {
    if stopped { return BridgeStreamHealth(phase: .closed, reason: nil, unchanged: false) }
    if recovering { return BridgeStreamHealth(phase: .recovering, reason: failure, unchanged: false) }
    if let failure { return BridgeStreamHealth(phase: .error, reason: failure, unchanged: false) }
    if frames == 0 || lastFrameAt <= 0 {
        return now - startedAt <= limits.warmupSeconds
            ? BridgeStreamHealth(phase: .warming, reason: nil, unchanged: false)
            : BridgeStreamHealth(phase: .stale, reason: "no_first_frame", unchanged: false)
    }
    if now - lastFrameAt <= limits.staleSeconds {
        return BridgeStreamHealth(phase: .live, reason: nil, unchanged: false)
    }
    if lastHeartbeatAt > 0, now - lastHeartbeatAt <= limits.staleSeconds {
        return BridgeStreamHealth(phase: .live, reason: "unchanged", unchanged: true)
    }
    return BridgeStreamHealth(phase: .stale, reason: "frozen", unchanged: false)
}

/// Bounded exponential backoff for recovering ONE stream: 0.5, 1, 2, 4, 8 s.
public func bridgeRecoveryDelay(attempt: Int) -> Double {
    let step = max(1, attempt)
    return min(8.0, 0.5 * pow(2.0, Double(step - 1)))
}

/// Why a running stream no longer shows what it was authorized for, or nil.
/// The title is not identity (it follows the active tab), so it never drops a
/// stream; the window, the process and the bundle do.
public func bridgeStreamIdentityDrift(started: BridgeStreamIdentity, current: BridgeStreamIdentity?) -> String? {
    guard let current else { return "window_gone" }
    if current.bundleID != started.bundleID { return "bundle_changed" }
    if current.pid != started.pid { return "pid_changed" }
    if current.windowID != started.windowID { return "window_changed" }
    return nil
}

/// A host that knows which process and bundle it expects (from a verified
/// observation) has the helper check them BEFORE any surface is opened.
public func bridgeStreamExpectationRefusal(
    expectedBundle: String?, expectedPID: Int32?, selected: BridgeStreamIdentity
) -> BridgePolicyRefusal? {
    var reason: String?
    if let expectedBundle, !expectedBundle.isEmpty, expectedBundle != selected.bundleID {
        reason = "bundle_changed"
    } else if let expectedPID, expectedPID > 0, expectedPID != selected.pid {
        reason = "pid_changed"
    }
    guard let reason else { return nil }
    return BridgePolicyRefusal(
        code: "STREAM_IDENTITY_MISMATCH",
        message: "The window is no longer the one that was observed; observe again before streaming it.",
        detail: "reason=\(reason);window_id=\(selected.windowID)")
}

/// Client-chosen slot key ("A", "B", or a context id): bounded, no paths.
public func bridgeValidStreamKey(_ key: String) -> Bool {
    guard !key.isEmpty, key.count <= 80 else { return false }
    return key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
}

public func bridgeRandomStreamID() -> String { bridgeRandomID(prefix: "str") }

public enum BridgeStreamReservation: Equatable, Sendable {
    /// Open a new stream under `streamID`; stop `replacing` first if set (the
    /// caller's OWN stream in the same slot).
    case start(streamID: String, replacing: String?)
    /// The slot already streams that window: nothing to do.
    case existing(streamID: String)
}

public struct BridgeStreamEntry<Resource> {
    public let id: String
    public let principal: BridgePrincipal
    /// Slot key: a context id, "A"/"B", or nil for the 0.3.2 single stream.
    public let key: String?
    public internal(set) var identity: BridgeStreamIdentity
    public internal(set) var resource: Resource?
    public let startedAt: Double
    public internal(set) var restartedAt: Double
    public internal(set) var frameIndex = 0
    public internal(set) var lastFrameAt: Double = 0
    public internal(set) var lastHeartbeatAt: Double = 0
    public internal(set) var failure: String?
    public internal(set) var recovering = false
    public internal(set) var recoveries = 0
    public internal(set) var restarts = 0

    public var legacy: Bool { key == nil }
}

public struct BridgeStreamStop<Resource> {
    public let stopped: Bool
    public let alreadyStopped: Bool
    public let resource: Resource?
    public let entry: BridgeStreamEntry<Resource>?
}

public struct BridgeStreamRecoveryPlan<Resource> {
    public let attempt: Int
    public let delay: Double
    public let previousResource: Resource?
    public let identity: BridgeStreamIdentity
}

func bridgeUnknownStreamRefusal() -> BridgePolicyRefusal {
    BridgePolicyRefusal(
        code: "STREAM_UNKNOWN",
        message: "No such stream for this client.",
        detail: "reason=stream_unknown")
}

public final class BridgeStreamRegistry<Resource> {
    public let limits: BridgeStreamLimits
    private let makeID: () -> String
    private var streams: [String: BridgeStreamEntry<Resource>] = [:]
    private var stopped: [BridgePrincipal: [String]] = [:]

    public init(limits: BridgeStreamLimits = BridgeStreamLimits(),
                makeID: @escaping () -> String = bridgeRandomStreamID) {
        self.limits = limits
        self.makeID = makeID
    }

    private func slot(_ principal: BridgePrincipal, _ key: String?) -> BridgeStreamEntry<Resource>? {
        streams.values.first { $0.principal == principal && $0.key == key }
    }

    public func legacyStream(principal: BridgePrincipal) -> BridgeStreamEntry<Resource>? {
        slot(principal, nil)
    }

    public func stream(principal: BridgePrincipal, key: String?) -> BridgeStreamEntry<Resource>? {
        slot(principal, key)
    }

    /// Decide whether a start opens a stream, reuses one, or is refused.
    /// Pure decision: nothing is registered until ``activate``.
    public func reserve(
        principal: BridgePrincipal, key: String?, identity: BridgeStreamIdentity
    ) -> Result<BridgeStreamReservation, BridgePolicyRefusal> {
        let current = slot(principal, key)
        if let current, current.identity.windowID == identity.windowID,
           current.identity.pid == identity.pid, current.failure == nil {
            return .success(.existing(streamID: current.id))
        }
        let replacing = current?.id
        let mine = streams.values.filter { $0.principal == principal && $0.id != replacing }.count
        guard mine < limits.maxPerPrincipal else {
            return .failure(BridgePolicyRefusal(
                code: "STREAM_LIMIT",
                message: "This client already streams the maximum number of windows; stop one first.",
                detail: "reason=stream_limit;scope=client;active=\(mine);max=\(limits.maxPerPrincipal)"))
        }
        let total = streams.values.filter { $0.id != replacing }.count
        guard total < limits.maxStreams else {
            return .failure(BridgePolicyRefusal(
                code: "STREAM_LIMIT",
                message: "The helper already streams the maximum number of windows.",
                detail: "reason=stream_limit;scope=helper;active=\(total);max=\(limits.maxStreams)"))
        }
        var id = makeID()
        while streams[id] != nil { id = makeID() }
        return .success(.start(streamID: id, replacing: replacing))
    }

    /// Register a stream whose capture really started.
    public func activate(id: String, principal: BridgePrincipal, key: String?,
                         identity: BridgeStreamIdentity, resource: Resource, now: Double) {
        streams[id] = BridgeStreamEntry(
            id: id, principal: principal, key: key, identity: identity, resource: resource,
            startedAt: now, restartedAt: now)
    }

    public func entry(principal: BridgePrincipal, id: String) -> Result<BridgeStreamEntry<Resource>, BridgePolicyRefusal> {
        guard let entry = streams[id], entry.principal == principal else { return .failure(bridgeUnknownStreamRefusal()) }
        return .success(entry)
    }

    /// For internal callbacks (the SCStream delegate) that hold only the id.
    public func entry(id: String) -> BridgeStreamEntry<Resource>? { streams[id] }

    public func entries(principal: BridgePrincipal) -> [BridgeStreamEntry<Resource>] {
        streams.values.filter { $0.principal == principal }.sorted { $0.startedAt < $1.startedAt }
    }

    public var all: [BridgeStreamEntry<Resource>] {
        streams.values.sorted { $0.startedAt < $1.startedAt }
    }

    /// Unregister without an ownership check (replacement, reaping, teardown).
    @discardableResult
    public func remove(id: String, now: Double) -> BridgeStreamEntry<Resource>? {
        guard let entry = streams.removeValue(forKey: id) else { return nil }
        var memory = stopped[entry.principal] ?? []
        memory.append(id)
        if memory.count > max(1, limits.stoppedMemory) { memory.removeFirst(memory.count - limits.stoppedMemory) }
        stopped[entry.principal] = memory
        return entry
    }

    /// Stop one stream. Idempotent for its owner; unknown for anyone else.
    public func stop(principal: BridgePrincipal, id: String, now: Double)
        -> Result<BridgeStreamStop<Resource>, BridgePolicyRefusal>
    {
        if let entry = streams[id], entry.principal == principal {
            remove(id: id, now: now)
            return .success(BridgeStreamStop(stopped: true, alreadyStopped: false, resource: entry.resource, entry: entry))
        }
        if stopped[principal]?.contains(id) == true {
            return .success(BridgeStreamStop(stopped: false, alreadyStopped: true, resource: nil, entry: nil))
        }
        return .failure(bridgeUnknownStreamRefusal())
    }

    public func removeAll() -> [BridgeStreamEntry<Resource>] {
        let removed = all
        removed.forEach { remove(id: $0.id, now: 0) }
        return removed
    }

    // MARK: delivery

    public func recordFrame(id: String, at: Double) {
        guard var entry = streams[id] else { return }
        entry.frameIndex += 1
        entry.lastFrameAt = at
        entry.lastHeartbeatAt = at
        // A recovered stream that has delivered for a while earns its budget
        // back: the bound is on consecutive failures, not on a stream's age.
        if entry.recoveries > 0, at - entry.restartedAt > 30 { entry.recoveries = 0 }
        streams[id] = entry
    }

    public func recordHeartbeat(id: String, at: Double) {
        guard var entry = streams[id] else { return }
        entry.lastHeartbeatAt = at
        streams[id] = entry
    }

    public func markFailure(id: String, reason: String) {
        guard var entry = streams[id] else { return }
        entry.failure = reason
        streams[id] = entry
    }

    public func updateIdentity(id: String, identity: BridgeStreamIdentity) {
        guard var entry = streams[id] else { return }
        entry.identity = identity
        streams[id] = entry
    }

    public func health(_ entry: BridgeStreamEntry<Resource>, now: Double) -> BridgeStreamHealth {
        bridgeStreamHealth(
            startedAt: entry.restartedAt, frames: entry.frameIndex, lastFrameAt: entry.lastFrameAt,
            lastHeartbeatAt: entry.lastHeartbeatAt, failure: entry.failure, recovering: entry.recovering,
            stopped: false, now: now, limits: limits)
    }

    // MARK: recovery

    /// Begin recovering ONE stream: its id, slot and frame index survive; its
    /// sibling is not touched. Bounded by ``BridgeStreamLimits/maxRecoveries``.
    public func beginRecovery(principal: BridgePrincipal, id: String, now: Double)
        -> Result<BridgeStreamRecoveryPlan<Resource>, BridgePolicyRefusal>
    {
        guard var entry = streams[id], entry.principal == principal else { return .failure(bridgeUnknownStreamRefusal()) }
        guard entry.recoveries < limits.maxRecoveries else {
            return .failure(BridgePolicyRefusal(
                code: "STREAM_RECOVERY_EXHAUSTED",
                message: "This stream failed to recover too many times; stop it and start a new one.",
                detail: "reason=recovery_exhausted;attempts=\(entry.recoveries);max=\(limits.maxRecoveries)"))
        }
        entry.recoveries += 1
        entry.recovering = true
        let previous = entry.resource
        entry.resource = nil
        streams[id] = entry
        return .success(BridgeStreamRecoveryPlan(
            attempt: entry.recoveries, delay: bridgeRecoveryDelay(attempt: entry.recoveries),
            previousResource: previous, identity: entry.identity))
    }

    /// Complete a recovery with the new resource, or record why it failed.
    public func finishRecovery(id: String, resource: Resource?, now: Double, failure: String? = nil) {
        guard var entry = streams[id] else { return }
        entry.recovering = false
        if let resource, failure == nil {
            entry.resource = resource
            entry.failure = nil
            entry.restarts += 1
            entry.restartedAt = now
            entry.lastHeartbeatAt = 0
        } else {
            entry.failure = failure ?? "recovery_failed"
        }
        streams[id] = entry
    }
}

// MARK: - Re-judging a stream on the window's current title (audit X-05)

/// A stream is a capture that keeps happening, and a window grant is decided
/// on the window's TITLE, which follows the active tab and the open document.
/// A stream authorized while the window was titled "CMM – Docs" kept sending
/// frames after a tab switch to a window nobody had granted. The decision is
/// taken again on the CURRENT title.
///
/// Returns the refusal when the grant no longer covers the window, and the
/// identity carrying the current title (so `view_identity` is never stale).
/// `currentTitle == nil` (the window is gone or unreadable) invents no verdict:
/// the stream's own health reports a missing window.
public func bridgeStreamRecheck(
    policy: BridgeAuthorizationPolicy, client: BridgeClientGrant?, identity: BridgeStreamIdentity,
    currentTitle: String?
) -> (refusal: BridgePolicyRefusal?, identity: BridgeStreamIdentity) {
    guard let currentTitle else { return (nil, identity) }
    let current = BridgeStreamIdentity(
        bundleID: identity.bundleID, pid: identity.pid, windowID: identity.windowID,
        windowTitle: currentTitle, appName: identity.appName)
    let refusal = policy.decision(
        bundleID: identity.bundleID, name: identity.appName, windowTitle: currentTitle,
        scope: .observe, client: client).refusal
    return (refusal, current)
}

/// The title is read at most twice a second per stream: frames come at 15 fps.
public func bridgeStreamRecheckDue(lastCheckedAt: Double?, now: Double, interval: Double = 0.5) -> Bool {
    guard let lastCheckedAt else { return true }
    return now - lastCheckedAt >= interval
}
