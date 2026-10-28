// WindowStream.swift — the live window surface (ScreenCaptureKit SCStream).
//
// `SCScreenshotManager` answers "what does this window look like NOW" once per
// call, and that is the ceiling of the old mirror: every frame costs a full
// capture round trip, measured at ~3 fps against a real Safari window. A
// person watching "share screen" expects 10–30 fps, so the helper keeps ONE
// stream open, converts each delivered surface to JPEG on the sample queue,
// and hands the last frame to whoever asks. No capture per request: the frame
// endpoint is a memory read, not a window-server operation.
//
// Identity is the one already published by `capture_screen` (`window_id`,
// `pid`, `bundle`). The stream is bound to a WINDOW, not to a title: the title
// follows the active tab, so a mirror keyed on it dies when the person
// navigates — the exact defect this module removes.
//
// Policy is unchanged and decided BEFORE the stream exists: the same
// `authorization.decision(scope: .observe)` gate that guards a capture guards
// a stream, because a stream is a capture that keeps happening.

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

/// Frames per second the stream is asked for: enough for the mirror to feel
/// live without turning the helper into a video encoder. The panel's transport
/// paces itself below this, so a faster capture would only burn CPU.
let streamTargetFPS = 15
let streamFrameInterval = CMTime(value: 1, timescale: CMTimeScale(streamTargetFPS))

/// One captured surface, as the frame endpoint publishes it.
struct WindowStreamFrame {
    let jpeg: Data
    let windowID: Int
    let windowTitle: String
    let bundleID: String
    let pid: Int
    let frameIndex: Int
    let ageMilliseconds: Int
    let stale: Bool
}

/// Receives the stream's sample buffers and keeps the last complete frame.
///
/// `SCStreamOutput` delivers on a ScreenCaptureKit-owned queue; the lock is the
/// only shared state between that queue and a bridge connection thread, so a
/// frame read can never observe a half-written buffer.
final class WindowFrameSink: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private let context: CIContext
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let quality: Double
    private let maximumBytes: Int
    private var latest: Data?
    private var lastFrameAt: TimeInterval = 0
    private var frameCount = 0
    private var encodeFailures = 0
    private var skippedStatus = 0

    init(quality: Double = 0.7, maximumBytes: Int = maxStreamFrameBytes) {
        self.quality = quality
        self.maximumBytes = maximumBytes
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
              CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer)
        else { return }
        // ScreenCaptureKit also emits status-only buffers (idle, blank,
        // stopped) that carry no new pixels. Encoding one would publish a
        // duplicate or empty frame as if the window had changed.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int
        else {
            lock.lock(); skippedStatus += 1; lock.unlock()
            return
        }
        guard rawStatus == SCFrameStatus.complete.rawValue else {
            lock.lock(); skippedStatus += 1; lock.unlock()
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
        if jpeg.count <= maximumBytes {
            latest = jpeg
            lastFrameAt = now
            frameCount += 1
        } else {
            encodeFailures += 1
        }
        lock.unlock()
    }

    /// The last complete frame, with how old it is. Age is measured at read
    /// time, so a caller can tell "live" from "the stream went quiet".
    func latestFrame(staleAfter: Double = 2.0) -> (jpeg: Data, ageMilliseconds: Int, index: Int, stale: Bool)? {
        lock.lock()
        defer { lock.unlock() }
        guard let latest, frameCount > 0 else { return nil }
        let age = max(0, Date().timeIntervalSince1970 - lastFrameAt)
        return (latest, Int(age * 1000), frameCount, age > staleAfter)
    }

    func statistics() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return [
            "frames": frameCount,
            "encode_failures": encodeFailures,
            "skipped_buffers": skippedStatus,
            "last_frame_age_ms": lastFrameAt > 0
                ? Int(max(0, Date().timeIntervalSince1970 - lastFrameAt) * 1000) : -1,
        ]
    }
}

/// Notices the stream ending on its own (window closed, capture revoked) so
/// the frame endpoint reports "not active" instead of serving a frozen image
/// forever as if it were live.
final class WindowStreamDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("window stream stopped by the system: \(error.localizedDescription)")
        clearWindowStream(matching: stream)
    }
}

/// The one open stream, with the identity it was authorized for.
private struct ActiveWindowStream {
    let stream: SCStream
    let sink: WindowFrameSink
    let delegate: WindowStreamDelegate
    let windowID: Int
    let windowTitle: String
    let bundleID: String
    let appName: String
    let pid: Int
    let startedAt: TimeInterval
}

nonisolated(unsafe) private var activeWindowStream: ActiveWindowStream?
private let windowStreamLock = NSLock()
/// Serializes start/stop against each other: two connections must not leave
/// two streams running or tear down each other's.
private let windowStreamTransition = NSLock()

private func currentWindowStream() -> ActiveWindowStream? {
    windowStreamLock.lock()
    defer { windowStreamLock.unlock() }
    return activeWindowStream
}

private func setWindowStream(_ value: ActiveWindowStream?) {
    windowStreamLock.lock()
    activeWindowStream = value
    windowStreamLock.unlock()
}

/// Drop the registration for a stream that ended by itself. Only the stream
/// that is still registered is cleared, so a late callback from a stopped
/// stream cannot unregister its replacement.
func clearWindowStream(matching stream: SCStream) {
    windowStreamLock.lock()
    defer { windowStreamLock.unlock() }
    guard let active = activeWindowStream, active.stream === stream else { return }
    activeWindowStream = nil
}

func windowStreamIsActive() -> Bool {
    currentWindowStream() != nil
}

/// The stream's own status, for `bridge.ping`/diagnostics. Never carries a
/// frame.
func windowStreamStatus() -> [String: Any] {
    guard let active = currentWindowStream() else {
        return ["active": false]
    }
    var status: [String: Any] = [
        "active": true,
        "window_id": active.windowID,
        "bundle": active.bundleID,
        "pid": active.pid,
        "seconds_open": Int(max(0, Date().timeIntervalSince1970 - active.startedAt)),
        "target_fps": streamTargetFPS,
    ]
    status.merge(active.sink.statistics()) { _, new in new }
    return status
}

/// Mutable result of an asynchronous stream start, filled on the Task's
/// executor and read once the semaphore releases the caller.
private final class WindowStreamStartBox: @unchecked Sendable {
    var failure: String?
    var refusal: BridgePolicyRefusal?
    var identity: [String: Any]?
    var stream: SCStream?
    var sink: WindowFrameSink?
    var delegate: WindowStreamDelegate?
}

/// Open the live stream for exactly one authorized window.
///
/// Selection reuses the capture path's rules: `window_id` when the client has
/// it (it does not move), the title fragment otherwise. Authorization is the
/// SAME `.observe` decision a capture takes, checked before the stream exists.
/// Returns the same shape as `captureWindowBase64` so the dispatch layer can
/// report a refusal exactly like a refused capture.
func startWindowStream(
    app: String?, title: String, windowID: Int?
) -> (failure: String?, refusal: BridgePolicyRefusal?, identity: [String: Any]?) {
    guard CGPreflightScreenCaptureAccess() else {
        return ("screen_recording_denied", nil, nil)
    }
    windowStreamTransition.lock()
    defer { windowStreamTransition.unlock() }

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
                // observation grant must cover the window's OWNER and title.
                if let refusal = authorization.decision(
                    bundleID: pair.0.bundleID, name: pair.0.app,
                    windowTitle: pair.0.title, scope: .observe
                ).refusal {
                    box.refusal = refusal
                    break
                }
                // One stream at a time: a second start replaces the first
                // instead of leaving an orphan capture running.
                if let previous = currentWindowStream() {
                    try? await previous.stream.stopCapture()
                    clearWindowStream(matching: previous.stream)
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
                let sink = WindowFrameSink()
                let delegate = WindowStreamDelegate()
                let stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
                try stream.addStreamOutput(
                    sink, type: .screen,
                    sampleHandlerQueue: DispatchQueue(
                        label: "com.cmm.chat.computer-use.window-stream",
                        qos: .userInitiated))
                try await stream.startCapture()
                box.stream = stream
                box.sink = sink
                box.delegate = delegate
                box.identity = [
                    "bundle": pair.0.bundleID,
                    "pid": Int(pair.1.owningApplication?.processID ?? 0),
                    "window": pair.0.title,
                    "window_id": Int(pair.1.windowID),
                    "app": pair.0.app,
                    "width": configuration.width,
                    "height": configuration.height,
                    "target_fps": streamTargetFPS,
                ]
            }
        } catch {
            box.failure = "stream_start_failed"
            log("window stream failed to start: \(error)")
        }
        sema.signal()
    }
    guard sema.wait(timeout: .now() + 15) == .success else {
        log("window stream start timed out")
        return ("timeout", nil, nil)
    }
    if let refusal = box.refusal { return (nil, refusal, nil) }
    if let failure = box.failure { return (failure, nil, nil) }
    guard let stream = box.stream, let sink = box.sink, let delegate = box.delegate,
          let identity = box.identity
    else { return ("stream_start_failed", nil, nil) }
    setWindowStream(ActiveWindowStream(
        stream: stream, sink: sink, delegate: delegate,
        windowID: identity["window_id"] as? Int ?? 0,
        windowTitle: identity["window"] as? String ?? "",
        bundleID: identity["bundle"] as? String ?? "",
        appName: identity["app"] as? String ?? "",
        pid: identity["pid"] as? Int ?? 0,
        startedAt: Date().timeIntervalSince1970))
    return (nil, nil, identity)
}

/// Holds a stream so a `Task` can stop it under Swift 6 strict concurrency:
/// `SCStream` is not `Sendable`, and a bare capture of it in a sending closure
/// is a data-race diagnostic even though `stopCapture()` is the only touch.
private final class WindowStreamStopBox: @unchecked Sendable {
    let stream: SCStream
    init(_ stream: SCStream) { self.stream = stream }
}

/// Close the stream. Idempotent: stopping nothing is a successful no-op, so
/// the client can call it on every teardown without bookkeeping.
func stopWindowStream() -> [String: Any] {
    windowStreamTransition.lock()
    defer { windowStreamTransition.unlock() }
    guard let active = currentWindowStream() else {
        return ["stopped": false, "active": false]
    }
    setWindowStream(nil)
    let stats = active.sink.statistics()
    let stopper = WindowStreamStopBox(active.stream)
    let sema = DispatchSemaphore(value: 0)
    Task {
        do {
            try await stopper.stream.stopCapture()
        } catch {
            // Already-stopped streams throw here; the registration is gone
            // either way, which is what the caller needs.
            log("window stream stop: \(error.localizedDescription)")
        }
        sema.signal()
    }
    _ = sema.wait(timeout: .now() + 5)
    var result: [String: Any] = [
        "stopped": true,
        "active": false,
        "window_id": active.windowID,
        "bundle": active.bundleID,
    ]
    result.merge(stats) { _, new in new }
    return result
}

/// The last frame, cached. Never captures: this is the endpoint the mirror
/// polls, so it must cost a memory read and a JSON encode.
func windowStreamFrame() -> (frame: WindowStreamFrame?, failure: String?) {
    guard let active = currentWindowStream() else { return (nil, "stream_not_active") }
    guard let snapshot = active.sink.latestFrame() else { return (nil, "stream_warming") }
    return (WindowStreamFrame(
        jpeg: snapshot.jpeg,
        windowID: active.windowID,
        windowTitle: active.windowTitle,
        bundleID: active.bundleID,
        pid: active.pid,
        frameIndex: snapshot.index,
        ageMilliseconds: snapshot.ageMilliseconds,
        stale: snapshot.stale), nil)
}
