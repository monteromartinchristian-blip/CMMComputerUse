// WindowStream.swift — live window surfaces (ScreenCaptureKit SCStream).
//
// `SCScreenshotManager` answers "what does this window look like NOW" once per
// call, and that is the ceiling of the old mirror: every frame costs a full
// capture round trip, measured at ~3 fps against a real Safari window. A
// person watching "share screen" expects 10–30 fps, so the helper keeps a
// stream open per mirrored window, converts each delivered surface to JPEG on
// that stream's own sample queue, and hands the last frame to whoever owns it.
// No capture per request: the frame endpoint is a memory read.
//
// 0.3.3: up to TWO streams at once (Shared/ComputerUseStreams.swift), each
// with its own SCStream, sink, delegate, queue, frame index, health and
// recovery, owned by the principal that opened it. Starting or stopping one
// never touches the other; a third is refused; another client can neither read
// nor stop them. 0.3.2 callers (no `stream_id`) get their own single stream,
// replaced on a new start exactly as before — but never another client's.
//
// Identity is the one published by `capture_screen` (`window_id`, `pid`,
// `bundle`). A stream is bound to a WINDOW, not to a title: the title follows
// the active tab, so a mirror keyed on it would die when the person navigates.
//
// Policy is decided BEFORE a stream exists and re-decided when the policy is
// reloaded: the same `authorization.decision(scope: .observe)` that guards a
// capture guards a stream, because a stream is a capture that keeps happening.

import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import ScreenCaptureKit

/// Ceiling for one mirrored JPEG. A window frame at core size is ~100–400 KB;
/// anything near this bound means the encoder produced something that is not a
/// screenshot, and it is dropped instead of shipped.
let maxStreamFrameBytes = 4_000_000

/// Frames per second each stream is asked for: enough for the mirror to feel
/// live without turning the helper into a video encoder. The panel's transport
/// paces itself below this, so a faster capture would only burn CPU.
let streamTargetFPS = 15
let streamFrameInterval = CMTime(value: 1, timescale: CMTimeScale(streamTargetFPS))

/// One captured surface, as the frame endpoint publishes it.
struct WindowStreamFrame {
    let jpeg: Data
    let streamID: String
    let key: String?
    let windowID: Int
    let windowTitle: String
    let bundleID: String
    let pid: Int
    let frameIndex: Int
    let ageMilliseconds: Int
    let health: BridgeStreamHealth
}

/// Receives ONE stream's sample buffers and keeps its last complete frame.
///
/// `SCStreamOutput` delivers on that stream's own queue; the lock is the only
/// shared state between that queue and a bridge connection thread, so a frame
/// read can never observe a half-written buffer. Delivery and idle buffers are
/// reported to the registry (frame index, heartbeat) through `onDelivery`.
final class WindowFrameSink: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private let context: CIContext
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let quality: Double
    private let maximumBytes: Int
    private let onDelivery: @Sendable (_ frame: Bool, _ at: Double) -> Void
    private var latest: Data?
    private var lastFrameAt: TimeInterval = 0
    private var frameCount = 0
    private var encodeFailures = 0
    private var skippedStatus = 0
    private var idleBuffers = 0

    init(quality: Double = 0.7, maximumBytes: Int = maxStreamFrameBytes,
         onDelivery: @escaping @Sendable (_ frame: Bool, _ at: Double) -> Void) {
        self.quality = quality
        self.maximumBytes = maximumBytes
        self.onDelivery = onDelivery
        // Intermediates are pure overhead for one-shot conversions, and a
        // software renderer would compete with the app being mirrored.
        self.context = CIContext(options: [.cacheIntermediates: false])
        super.init()
    }

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              CMSampleBufferIsValid(sampleBuffer)
        else { return }
        // ScreenCaptureKit also emits status-only buffers (idle, blank,
        // stopped) that carry no new pixels. Encoding one would publish a
        // duplicate or empty frame as if the window had changed — but an IDLE
        // buffer is proof the stream is alive while the window is unchanged,
        // which is what tells "nothing moved" from "frozen".
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int
        else {
            lock.lock(); skippedStatus += 1; lock.unlock()
            return
        }
        guard rawStatus == SCFrameStatus.complete.rawValue, CMSampleBufferDataIsReady(sampleBuffer) else {
            lock.lock()
            skippedStatus += 1
            if rawStatus == SCFrameStatus.idle.rawValue { idleBuffers += 1 }
            lock.unlock()
            if rawStatus == SCFrameStatus.idle.rawValue { onDelivery(false, Date().timeIntervalSince1970) }
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            lock.lock(); encodeFailures += 1; lock.unlock()
            return
        }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let jpeg = context.jpegRepresentation(
            of: image, colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]),
              !jpeg.isEmpty
        else {
            lock.lock(); encodeFailures += 1; lock.unlock()
            return
        }
        let now = Date().timeIntervalSince1970
        lock.lock()
        let accepted = jpeg.count <= maximumBytes
        if accepted {
            latest = jpeg
            lastFrameAt = now
            frameCount += 1
        } else {
            encodeFailures += 1
        }
        lock.unlock()
        if accepted { onDelivery(true, now) }
    }

    /// The last complete frame of THIS stream, with its age at read time.
    func latestFrame() -> (jpeg: Data, ageMilliseconds: Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard let latest, frameCount > 0 else { return nil }
        return (latest, Int(max(0, Date().timeIntervalSince1970 - lastFrameAt) * 1000))
    }

    func statistics() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return [
            "frames_since_start": frameCount,
            "encode_failures": encodeFailures,
            "skipped_buffers": skippedStatus,
            "idle_buffers": idleBuffers,
        ]
    }
}

/// Notices ONE stream ending on its own (window closed, capture revoked) and
/// marks only that stream failed, so its panel reports an error instead of a
/// frozen image — and its sibling keeps running.
final class WindowStreamDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
    let streamID: String

    init(streamID: String) {
        self.streamID = streamID
        super.init()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("window stream \(streamID) stopped by the system: \(error.localizedDescription)")
        markWindowStreamFailed(id: streamID, stream: stream, reason: "stopped_by_system")
    }
}

/// What the registry keeps per stream.
final class WindowStreamResource: @unchecked Sendable {
    let stream: SCStream
    let sink: WindowFrameSink
    let delegate: WindowStreamDelegate
    let queue: DispatchQueue

    init(stream: SCStream, sink: WindowFrameSink, delegate: WindowStreamDelegate, queue: DispatchQueue) {
        self.stream = stream
        self.sink = sink
        self.delegate = delegate
        self.queue = queue
    }
}

/// The registry, behind its own lock: frame reads are served OUTSIDE
/// `dispatchLock` (an action can hold that for a second), and sinks report
/// delivery from their capture queues.
private let streamRegistryLock = NSLock()
nonisolated(unsafe) private var streamRegistry = BridgeStreamRegistry<WindowStreamResource>()
/// Earliest time each stream may attempt its next recovery (backoff).
nonisolated(unsafe) private var recoveryNotBefore: [String: Double] = [:]

private func withRegistry<T>(_ body: (BridgeStreamRegistry<WindowStreamResource>) -> T) -> T {
    streamRegistryLock.lock()
    defer { streamRegistryLock.unlock() }
    return body(streamRegistry)
}

func markWindowStreamFailed(id: String, stream: SCStream, reason: String) {
    withRegistry { registry in
        // A late callback from a stream that recovery already replaced must
        // not fail its successor.
        guard let entry = registry.entry(id: id), entry.resource?.stream === stream else { return }
        registry.markFailure(id: id, reason: reason)
    }
}

/// Holds a stream so a `Task` can stop it under Swift 6 strict concurrency:
/// `SCStream` is not `Sendable`, and a bare capture of it in a sending closure
/// is a data-race diagnostic even though `stopCapture()` is the only touch.
private final class WindowStreamStopBox: @unchecked Sendable {
    let stream: SCStream
    init(_ stream: SCStream) { self.stream = stream }
}

/// Stop one SCStream, bounded. Already-stopped streams throw; the registration
/// is gone either way, which is what the caller needs.
private func stopCapture(_ resource: WindowStreamResource?) {
    guard let resource else { return }
    let stopper = WindowStreamStopBox(resource.stream)
    let sema = DispatchSemaphore(value: 0)
    Task {
        do { try await stopper.stream.stopCapture() } catch {
            log("window stream stop: \(error.localizedDescription)")
        }
        sema.signal()
    }
    _ = sema.wait(timeout: .now() + 5)
}

/// Mutable result of an asynchronous selection/start, filled on the Task's
/// executor and read once the semaphore releases the caller.
private final class WindowStreamStartBox: @unchecked Sendable {
    var failure: String?
    var refusal: BridgePolicyRefusal?
    var identity: BridgeStreamIdentity?
    var resource: WindowStreamResource?
}

/// Select exactly one authorized window (same rules as a capture) and, when
/// `streamID` is given and `check` passes, start a stream on it. With no
/// `streamID` it only identifies: nothing is opened. Runs on a Task; the
/// caller waits.
private func selectAndOpen(
    app: String?, title: String, windowID: Int?, client: BridgeClientGrant?,
    streamID: String?,
    check: @escaping @Sendable (BridgeStreamIdentity) -> BridgePolicyRefusal? = { _ in nil }
) -> WindowStreamStartBox {
    let box = WindowStreamStartBox()
    let sema = DispatchSemaphore(value: 0)
    Task {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            var pairs: [(BridgeWindowCandidate, SCWindow)] = []
            for window in content.windows {
                guard window.windowLayer == 0,
                      window.frame.width >= 40,
                      window.frame.height >= 40
                else { continue }
                let candidate = BridgeWindowCandidate(
                    windowID: Int(window.windowID),
                    title: window.title ?? "",
                    app: window.owningApplication?.applicationName ?? "",
                    bundleID: window.owningApplication?.bundleIdentifier ?? "",
                    width: Int(window.frame.width),
                    height: Int(window.frame.height))
                pairs.append((candidate, window))
            }
            let selection: BridgeWindowSelection
            if let windowID {
                selection = bridgeResolveWindowById(
                    windowID: windowID, app: app, candidates: pairs.map { $0.0 })
            } else {
                selection = bridgeSelectWindow(
                    request: title, app: app, candidates: pairs.map { $0.0 })
            }
            switch selection {
            case .notFound:
                box.failure = windowID == nil ? "window_not_found" : "window_not_found_by_id"
            case .ambiguous(let matches):
                box.failure = "window_ambiguous:" + matches.joined(separator: " | ")
            case .selected(let chosen):
                guard let pair = pairs.first(where: { $0.0 == chosen }) else {
                    box.failure = "window_not_found"
                    break
                }
                // A stream is a capture that keeps happening: the same
                // observation grant must cover the window's OWNER and title,
                // for THIS client (0.3.2 omitted the client here, so a
                // client-required policy refused every stream).
                if let refusal = authorization.decision(
                    bundleID: pair.0.bundleID, name: pair.0.app,
                    windowTitle: pair.0.title, scope: .observe, client: client
                ).refusal {
                    box.refusal = refusal
                    break
                }
                let identity = BridgeStreamIdentity(
                    bundleID: pair.0.bundleID,
                    pid: pair.1.owningApplication?.processID ?? 0,
                    windowID: Int(pair.1.windowID), windowTitle: pair.0.title,
                    appName: pair.0.app)
                box.identity = identity
                guard let streamID else { break }  // identify only
                if let refusal = check(identity) {
                    box.refusal = refusal
                    break
                }
                let filter = SCContentFilter(desktopIndependentWindow: pair.1)
                let configuration = SCStreamConfiguration()
                configuration.width = max(2, Int(pair.1.frame.width))
                configuration.height = max(2, Int(pair.1.frame.height))
                configuration.showsCursor = false
                configuration.minimumFrameInterval = streamFrameInterval
                configuration.queueDepth = 3
                configuration.pixelFormat = kCVPixelFormatType_32BGRA
                configuration.scalesToFit = false
                let sink = WindowFrameSink { frame, at in
                    withRegistry { registry in
                        if frame { registry.recordFrame(id: streamID, at: at) }
                        else { registry.recordHeartbeat(id: streamID, at: at) }
                    }
                }
                let delegate = WindowStreamDelegate(streamID: streamID)
                let queue = DispatchQueue(
                    label: "com.cmm.chat.computer-use.window-stream.\(streamID)",
                    qos: .userInitiated)
                let stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
                try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: queue)
                try await stream.startCapture()
                box.resource = WindowStreamResource(stream: stream, sink: sink, delegate: delegate, queue: queue)
            }
        } catch {
            box.failure = "stream_start_failed"
            log("window stream failed to start: \(error)")
        }
        sema.signal()
    }
    guard sema.wait(timeout: .now() + 15) == .success else {
        log("window stream start timed out")
        box.failure = "timeout"
        box.refusal = nil
        return box
    }
    return box
}

/// Open (or reuse) the stream for one authorized window in one slot.
///
/// `key` is the slot: a context id, a client label ("A"/"B"), or nil for the
/// 0.3.2 single stream. `expectedBundle`/`expectedPID` come from a verified
/// observation and are checked against the selected window BEFORE any surface
/// is opened. Returns a refusal frame or the stream's identity.
func startWindowStream(
    app: String?, title: String, windowID: Int?, key: String?,
    expectedBundle: String?, expectedPID: Int32?
) -> (failure: String?, refusal: BridgePolicyRefusal?, result: [String: Any]?) {
    guard CGPreflightScreenCaptureAccess() else {
        return ("screen_recording_denied", nil, nil)
    }
    let principal = currentPrincipal
    let client = currentClient
    // 1. Identify and authorize the window (nothing is opened), 2. let the
    //    registry decide (reuse, replace the caller's own slot, or refuse a
    //    third stream), 3. open the capture under the reserved id, checking
    //    the window did not change in between.
    var reservedID = ""
    var replacing: String?
    var reusedID: String?
    let box = selectAndOpen(app: app, title: title, windowID: windowID, client: client, streamID: nil)
    if let refusal = box.refusal { return (nil, refusal, nil) }
    guard let selected = box.identity else { return (box.failure ?? "stream_start_failed", nil, nil) }
    if let refusal = bridgeStreamExpectationRefusal(
        expectedBundle: expectedBundle, expectedPID: expectedPID, selected: selected) {
        return (nil, refusal, nil)
    }
    switch withRegistry({ $0.reserve(principal: principal, key: key, identity: selected) }) {
    case .failure(let refusal):
        return (nil, refusal, nil)
    case .success(.existing(let id)):
        reusedID = id
    case .success(.start(let id, let old)):
        reservedID = id
        replacing = old
    }
    if let reusedID {
        return (nil, nil, streamDescription(id: reusedID, reused: true))
    }
    // Replace the caller's OWN stream in this slot (0.3.2 semantics for a
    // legacy start), never another slot's or another client's.
    if let replacing {
        let old = withRegistry { $0.remove(id: replacing, now: Date().timeIntervalSince1970) }
        stopCapture(old?.resource)
    }
    let opened = selectAndOpen(
        app: app, title: title, windowID: selected.windowID, client: client, streamID: reservedID
    ) { identity in
        bridgeStreamIdentityDrift(started: selected, current: identity).map {
            BridgePolicyRefusal(code: "STREAM_IDENTITY_MISMATCH",
                                message: "The window changed while the stream was starting.",
                                detail: "reason=\($0);window_id=\(selected.windowID)")
        }
    }
    if let refusal = opened.refusal { stopCapture(opened.resource); return (nil, refusal, nil) }
    guard let resource = opened.resource, let identity = opened.identity else {
        return (opened.failure ?? "stream_start_failed", nil, nil)
    }
    withRegistry {
        $0.activate(id: reservedID, principal: principal, key: key, identity: identity,
                    resource: resource, now: Date().timeIntervalSince1970)
    }
    log("WINDOW_STREAM_STARTED id=\(reservedID) key=\(key ?? "legacy") window_id=\(identity.windowID) pid=\(identity.pid)")
    return (nil, nil, streamDescription(id: reservedID, reused: false))
}

/// Public description of one stream (no pixels).
func streamDescription(id: String, reused: Bool = false) -> [String: Any] {
    let now = Date().timeIntervalSince1970
    return withRegistry { registry -> [String: Any] in
        guard let entry = registry.entry(id: id) else { return ["stream_id": id, "phase": "closed"] }
        let health = registry.health(entry, now: now)
        var description: [String: Any] = [
            "stream": reused ? "existing" : "started",
            "stream_id": entry.id,
            "key": entry.key as Any,
            "legacy": entry.legacy,
            "phase": health.phase.rawValue,
            "phase_reason": health.reason as Any,
            "unchanged": health.unchanged,
            "frame_index": entry.frameIndex,
            "last_frame_age_ms": entry.lastFrameAt > 0 ? Int(max(0, now - entry.lastFrameAt) * 1000) : -1,
            "restarts": entry.restarts,
            "recoveries": entry.recoveries,
            "seconds_open": Int(max(0, now - entry.startedAt)),
            "target_fps": streamTargetFPS,
            "view_identity": [
                "bundle": entry.identity.bundleID,
                "pid": Int(entry.identity.pid),
                "window": entry.identity.windowTitle,
                "window_id": entry.identity.windowID,
                "app": entry.identity.appName,
            ],
        ]
        if let stats = entry.resource?.sink.statistics() { description.merge(stats) { _, new in new } }
        return description
    }
}

/// Stop one stream of the caller (`id == nil`: its 0.3.2 stream). Idempotent.
func stopWindowStream(id: String?) -> Result<[String: Any], BridgePolicyRefusal> {
    let principal = currentPrincipal
    let now = Date().timeIntervalSince1970
    guard let id = id ?? withRegistry({ $0.legacyStream(principal: principal)?.id }) else {
        // 0.3.2: stopping nothing is a successful no-op.
        return .success(["stopped": false, "active": false])
    }
    switch withRegistry({ $0.stop(principal: principal, id: id, now: now) }) {
    case .failure(let refusal):
        return .failure(refusal)
    case .success(let stop):
        stopCapture(stop.resource)
        recoveryNotBefore.removeValue(forKey: id)
        var result: [String: Any] = [
            "stopped": stop.stopped, "already_stopped": stop.alreadyStopped,
            "active": false, "stream_id": id,
        ]
        if let entry = stop.entry {
            result["window_id"] = entry.identity.windowID
            result["bundle"] = entry.identity.bundleID
            result["frame_index"] = entry.frameIndex
        }
        if stop.stopped { log("WINDOW_STREAM_STOPPED id=\(id)") }
        return .success(result)
    }
}

/// Stop a stream without an ownership check (context closed or reaped,
/// authorization revoked). Never exposed as an operation.
func stopWindowStreamInternal(id: String, reason: String) {
    let entry = withRegistry { $0.remove(id: id, now: Date().timeIntervalSince1970) }
    stopCapture(entry?.resource)
    recoveryNotBefore.removeValue(forKey: id)
    if entry != nil { log("WINDOW_STREAM_STOPPED id=\(id) reason=\(reason)") }
}

/// The caller's last frame for one stream (`id == nil`: its 0.3.2 stream).
/// Never captures: a memory read, served outside `dispatchLock`. `principal`
/// is resolved by the caller from the connection's verified peer.
func windowStreamFrame(principal: BridgePrincipal, id: String?) -> (frame: WindowStreamFrame?, failure: String?) {
    let now = Date().timeIntervalSince1970
    let found: BridgeStreamEntry<WindowStreamResource>? = withRegistry { registry in
        if let id {
            if case .success(let entry) = registry.entry(principal: principal, id: id) { return entry }
            return nil
        }
        return registry.legacyStream(principal: principal)
    }
    guard let entry = found else { return (nil, id == nil ? "stream_not_active" : "stream_unknown") }
    let health = withRegistry { $0.health(entry, now: now) }
    guard let snapshot = entry.resource?.sink.latestFrame() else {
        return (nil, health.phase == .warming ? "stream_warming" : "stream_\(health.phase.rawValue)")
    }
    return (WindowStreamFrame(
        jpeg: snapshot.jpeg, streamID: entry.id, key: entry.key,
        windowID: entry.identity.windowID, windowTitle: entry.identity.windowTitle,
        bundleID: entry.identity.bundleID, pid: Int(entry.identity.pid),
        frameIndex: entry.frameIndex, ageMilliseconds: snapshot.ageMilliseconds,
        health: health), nil)
}

/// The caller's streams, with health. Also checks, for each, that its process
/// is still the one it was opened for (a relaunched app is another identity).
func windowStreamStatus(id: String?) -> Result<[String: Any], BridgePolicyRefusal> {
    let principal = currentPrincipal
    let entries: [BridgeStreamEntry<WindowStreamResource>]
    if let id {
        switch withRegistry({ $0.entry(principal: principal, id: id) }) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let entry): entries = [entry]
        }
    } else {
        entries = withRegistry { $0.entries(principal: principal) }
    }
    for entry in entries where entry.failure == nil {
        // `kill(pid, 0)` only asks the kernel whether the process exists.
        if entry.identity.pid > 0, kill(entry.identity.pid, 0) != 0, errno == ESRCH {
            withRegistry { $0.markFailure(id: entry.id, reason: "pid_changed") }
        }
    }
    let limits = withRegistry { $0.limits }
    return .success([
        "streams": entries.map { streamDescription(id: $0.id) },
        "max_streams": limits.maxStreams,
        "max_per_client": limits.maxPerPrincipal,
    ])
}

/// Recover ONE failed or stale stream of the caller: same id, same slot,
/// same window (by window id), authorization decided again. Bounded by the
/// registry's attempt limit and paced by its backoff; the sibling stream is
/// never touched.
func recoverWindowStream(id: String) -> Result<[String: Any], BridgePolicyRefusal> {
    let principal = currentPrincipal
    let client = currentClient
    let now = Date().timeIntervalSince1970
    if let notBefore = recoveryNotBefore[id], now < notBefore {
        return .failure(BridgePolicyRefusal(
            code: "STREAM_RECOVERY_BACKOFF",
            message: "Too soon to recover this stream again.",
            detail: "reason=backoff;retry_after_ms=\(Int((notBefore - now) * 1000))"))
    }
    let plan: BridgeStreamRecoveryPlan<WindowStreamResource>
    switch withRegistry({ $0.beginRecovery(principal: principal, id: id, now: now) }) {
    case .failure(let refusal): return .failure(refusal)
    case .success(let found): plan = found
    }
    recoveryNotBefore[id] = now + plan.delay
    stopCapture(plan.previousResource)
    guard CGPreflightScreenCaptureAccess() else {
        withRegistry { $0.finishRecovery(id: id, resource: nil, now: now, failure: "screen_recording_denied") }
        return .failure(BridgePolicyRefusal(code: "ACTION_FAILED", message: "Screen Recording is not granted.",
                                            detail: "reason=screen_recording_denied"))
    }
    let original = plan.identity
    let opened = selectAndOpen(
        app: original.bundleID, title: "", windowID: original.windowID,
        client: client, streamID: id
    ) { identity in
        bridgeStreamIdentityDrift(started: original, current: identity).map {
            BridgePolicyRefusal(code: "STREAM_IDENTITY_MISMATCH",
                                message: "The window is no longer the one this stream was opened for.",
                                detail: "reason=\($0);window_id=\(original.windowID)")
        }
    }
    let finished = Date().timeIntervalSince1970
    if let resource = opened.resource, opened.refusal == nil {
        withRegistry { $0.finishRecovery(id: id, resource: resource, now: finished) }
        log("WINDOW_STREAM_RECOVERED id=\(id) attempt=\(plan.attempt)")
        var result = streamDescription(id: id)
        result["recovered"] = true
        result["attempt"] = plan.attempt
        return .success(result)
    }
    stopCapture(opened.resource)
    let reason = opened.refusal.map { _ in "recovery_refused" } ?? (opened.failure ?? "recovery_failed")
    withRegistry { $0.finishRecovery(id: id, resource: nil, now: finished, failure: reason) }
    if let refusal = opened.refusal { return .failure(refusal) }
    return .failure(BridgePolicyRefusal(
        code: "ACTION_FAILED", message: "The stream could not be recovered.",
        detail: "reason=\(reason);attempt=\(plan.attempt);retry_after_ms=\(Int(plan.delay * 1000))"))
}

/// After a policy reload: a stream whose window is no longer authorized for
/// its owner is stopped. Evaluated against the identity it was opened for.
func revalidateWindowStreams(clientFor: (BridgePrincipal) -> BridgeClientGrant?) {
    let entries = withRegistry { $0.all }
    for entry in entries {
        let decision = authorization.decision(
            bundleID: entry.identity.bundleID, name: entry.identity.appName,
            windowTitle: entry.identity.windowTitle, scope: .observe, client: clientFor(entry.principal))
        if decision.refusal != nil {
            stopWindowStreamInternal(id: entry.id, reason: "authorization_revoked")
        }
    }
}

/// For `bridge.ping` (no client identity needed): counts only. Which windows
/// another client streams is not this caller's business.
func windowStreamSummary() -> [String: Any] {
    let (all, limits) = withRegistry { ($0.all, $0.limits) }
    let mine = all.filter { $0.principal == currentPrincipal }
    var summary: [String: Any] = [
        "active": !mine.isEmpty,
        "streams": all.count,
        "own_streams": mine.count,
        "max_streams": limits.maxStreams,
        "target_fps": streamTargetFPS,
    ]
    // 0.3.2 shape for a caller with exactly its legacy stream.
    if let legacy = mine.first(where: { $0.legacy }) {
        summary["window_id"] = legacy.identity.windowID
        summary["bundle"] = legacy.identity.bundleID
        summary["pid"] = Int(legacy.identity.pid)
    }
    return summary
}
