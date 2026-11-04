import ApplicationServices
import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Launch-time overrides for the LaunchServices lane.
///
/// When this helper is started with `open -n -a CMMComputerUse.app --args …`,
/// LaunchServices owns the process and the screen-capture attribution is the
/// app's (`replayd` resolves the responsible process to the bundle). `open`
/// cannot pass an environment, so the deployment hands the policy file and the
/// log destination as arguments instead of `CMM_COMPUTER_USE_POLICY_FILE`.
nonisolated(unsafe) var policyFileOverride: String?
nonisolated(unsafe) var helperLogFile: String?
nonisolated(unsafe) var helperLogHandle: FileHandle?

// Parse before ANY helper initialization. This lane deliberately does not query
// TCC: even a non-prompting permission observation is not proof of equivalence
// to the installed helper. No policy file is opened, no path/env value emitted.
let launchArguments = parseLaunchArguments()
if launchArguments.preflightOnly {
    let override = ProcessInfo.processInfo.environment["CMM_COMPUTER_USE_POLICY_FILE"]
    let report: [String: Any] = [
        "schema_version": 1,
        "mode": "preflight-only",
        "identity": [
            "bundle_id": Bundle.main.bundleIdentifier as Any? ?? NSNull(),
            "executable_name": "CMMComputerUse",
            "signature_status": "NO_VERIFICADO",
            "tcc_equivalence": false,
        ],
        "policy": [
            "source": (override?.isEmpty == false) ? "environment_override" : "default_user_policy",
            "loaded": false,
            "launch_mode": launchArguments.mode.rawValue,
            "effective_mode": "NO_VERIFICADO",
        ],
        "permissions": ["accessibility": "NO_VERIFICADO", "screen_capture": "NO_VERIFICADO"],
        "limits": ["tcc_queries": false, "gui": false, "socket": false, "policy_read": false, "live": false],
    ]
    do {
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0a]))
        exit(0)
    } catch {
        log("FATAL: preflight serialization failed")
        exit(2)
    }
}

// CMMComputerUse — the CMM Computer Use macOS helper.
//
// The ONLY grantable macOS process identity for Computer Use. CMM OS remains
// the orchestrator: it decides WHAT operation is allowed/requested, and this
// helper performs the narrow native macOS observation/action primitive.
//
// Transport: stdin/stdout, one JSON object per line (NDJSON), protocol
// version 1. Diagnostics go to stderr; stdout carries ONLY protocol frames.
// No TCP port. No shell. No AppleScript. Explicit operation allowlist.
//
// Request:  {"version":1,"id":"...","operation":"...","arguments":{...}}
// Response: {"version":1,"id":"...","ok":true,"result":{...},"error":null}
//           {"version":1,"id":"...","ok":false,"result":null,
//            "error":{"code":"...","message":"...","detail":"..."}}

// MARK: - Protocol constants

let bridgeVersion = 1
let bridgeName = "cmm-computer-use"
let maxRequestBytes = 1_048_576 // 1 MiB: requests are control plane, never media.
let maxTextChars = 65536
let maxElements = 60
/// Content nodes are a separate budget from interactive elements. The
/// observable failure this fixes: an app's ordinary visible content (a file
/// list, a table of results, a message body) is exposed by the accessibility
/// tree as AXStaticText / AXCell / AXImage — none of which are interactive —
/// so a budget shared with toolbars fills up on controls and the content the
/// person actually asked about never arrives.
let maxContentNodes = 240
/// Content can sit deeper than any control: measured content nodes live at
/// depth 7 under AXSplitGroup > AXScrollArea > AXOutline > AXRow > AXCell >
/// AXStaticText, so a depth of 6 structurally cannot reach them.
/// 40, not 12: an Electron/React window nests far deeper than a native one
/// (window > groups > web area > many div-groups > control). 12 stopped the
/// walk above Claude Desktop's controls (2026-11-02). Still bounded by
/// `maxVisitedNodes`.
let maxDepth = 40
/// Text inputs have their own budget: a sidebar full of buttons must not use
/// up the element budget before the walk reaches a composer.
let maxTextInputs = 20
/// Hard ceiling on nodes visited, so a pathological tree costs bounded time
/// and memory no matter how deep or wide it is.
let maxVisitedNodes = 6_000
/// Fan-out cap per node. 40 truncated real content areas mid-way.
let maxChildrenPerNode = 200
let maxScreenshotBytes = 24_000_000 // ~24MB base64 ceiling for one PNG frame.
/// Below this many nodes a window tree is treated as "not materialized":
/// title-bar controls plus a handful of groups.
let sparseTreeThreshold = 24

let interactiveRoles: Set<String> = [
    "AXButton", "AXTextField", "AXTextArea", "AXSecureTextField",
    "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuItem",
    "AXLink", "AXTab", "AXSlider", "AXSwitch", "AXComboBox",
    // Not pressable, but the one handle `ui.scroll` can aim at: listing it
    // gives a scroll area an element id without any global input.
    "AXScrollArea",
]

let allowedActions: Set<String> = [
    "app.open", "app.activate", "window.focus",
    "ui.press", "ui.set_value", "ui.scroll",
    "keyboard.type", "keyboard.shortcut",
    "pointer.click", "pointer.scroll",
    "wait", "finish",
    // F-09: AX-only browser actions (BrowserSupport.swift).
    "browser.select_tab", "browser.save_dialog",
]

// USB HID keycodes (parity with MacComputerRuntime._KEYCODES).
let keycodes: [String: Int] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
    "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
    "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
    "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
    "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37,
    "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
    "n": 45, "m": 46, ".": 47,
    "return": 36, "enter": 36, "tab": 48, "space": 49,
    "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
    "left": 123, "right": 124, "down": 125, "up": 126,
]

// MARK: - Diagnostics (stderr only; never stdout)

func log(_ message: String) {
    let line = "[cmm-computer-use] \(message)\n"
    if let data = line.data(using: .utf8) {
        FileHandle.standardError.write(data)
        if let path = helperLogFile, !path.isEmpty {
            if helperLogHandle == nil {
                if !FileManager.default.fileExists(atPath: path) {
                    FileManager.default.createFile(atPath: path, contents: nil)
                }
                helperLogHandle = FileHandle(forWritingAtPath: path)
            }
            helperLogHandle?.seekToEndOfFile()
            helperLogHandle?.write(data)
        }
    }
}

// MARK: - Workspace (live AX refs stay in-process across requests)

/// One element handle: the live AX reference and what it is bound to. Kept
/// per CONTEXT (Shared/ComputerUseWorkspace.swift), never in a process-wide
/// table: observing application B no longer replaces application A's handles,
/// and a handle resolves only for the principal whose context produced it.
struct BridgeLiveHandle {
    let element: AXUIElement
    let role: String
    /// What identifies window controls (AXZoomButton, …) that background mode
    /// never presses.
    let subrole: String?
    /// The application, process, window and document the handle came from;
    /// re-validated before every action.
    let context: BridgeElementContext
}

// Single-threaded by construction: mutated only under `dispatchLock`. The only
// concurrent scopes (capture Tasks, stream sinks) touch their own boxes.
nonisolated(unsafe) var workspace = BridgeWorkspace<BridgeLiveHandle>()
/// Who is asking, for THIS request: resolved under `dispatchLock` from the
/// verified client (or the peer's code identity), like `currentClient`.
nonisolated(unsafe) var currentPrincipal = BridgePrincipal(key: "local", strength: .local)
/// The context an element action resolved to, for THIS request only. Set by
/// `elementPreconditions`, cleared with `currentClient` after dispatch.
nonisolated(unsafe) var requestContext: BridgeContextRecord<BridgeLiveHandle>?
/// Outcomes of executed actions by operation id (replay instead of re-run).
nonisolated(unsafe) var operationLedger = BridgeOperationLedger<BridgeLedgerFrame>()
/// Random per process: a client that sees it change knows the helper
/// restarted and every context, stream and ledger entry is gone.
let helperInstanceID = bridgeRandomInstanceID()
/// Open breaches (Shared/ComputerUseBreachLatch.swift). Persisted next to the
/// policy file, loaded at start and on `policy.reload`; a restart does NOT
/// clear it. Only `breach.rearm` from an administrator client does.
nonisolated(unsafe) var breachLatch: BridgeBreachLatchLoad = .loaded(BridgeBreachLatchState())

/// A recorded response frame, replayed for a resent operation id.
struct BridgeLedgerFrame {
    let ok: Bool
    let result: Any?
    let error: [String: Any?]?
}

/// The handle of the current request's context, by element id.
func requestHandle(_ elementID: Int) -> BridgeLiveHandle? {
    requestContext?.handles[elementID]
}

// MARK: - Interaction policy (shared rules in ../Shared/ComputerUsePolicy.swift)

/// The mode this helper was LAUNCHED with. A request may narrow it, never
/// widen it (``bridgeEffectiveMode``). Declared by ``--policy``, reported by
/// `bridge.ping`, and printed on stderr at start so `launchctl print` and the
/// log agree about what this process is allowed to do.
nonisolated(unsafe) var deploymentMode: BridgeInteractionMode = .background

// The generation, observation clock and released generations that 0.3.2 kept
// here as process-wide globals now live in each workspace context
// (``BridgeContextRecord``): every `observation.describe` produces a new
// generation IN ITS CONTEXT, so a handle from an older observation of that
// context is refused, and an observation of another context moves nothing.

/// Where the system cursor is.
///
/// `CGEvent(source: nil)` carries the current cursor position and, unlike
/// posting an event, needs no grant and changes nothing. `NSEvent.mouseLocation`
/// is the AppKit fallback (same reading, bottom-left origin); only deltas are
/// published, so the origin never matters.
func cursorLocation() -> CGPoint {
    if let event = CGEvent(source: nil) { return event.location }
    return NSEvent.mouseLocation
}

/// The application that holds keyboard focus according to the accessibility
/// server, read synchronously (no AppKit cache). Empty when unreadable.
func axFocusedApplicationBundle() -> String {
    let systemWide = AXUIElementCreateSystemWide()
    // Bounded: a hung focused application must not stall the sampler.
    AXUIElementSetMessagingTimeout(systemWide, 0.1)
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(
        systemWide, kAXFocusedApplicationAttribute as CFString, &value) == .success,
        let raw = value, CFGetTypeID(raw) == AXUIElementGetTypeID()
    else { return "" }
    var pid: pid_t = 0
    guard AXUIElementGetPid(raw as! AXUIElement, &pid) == .success, pid > 0 else { return "" }
    return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
}

/// Owner of the front-most normal (layer 0), visible, non-trivial window, per
/// the window server's own ordering. Needs no Screen Recording grant: only the
/// owner pid and layer are read, never a title or pixels.
func topWindowOwnerBundle() -> String {
    guard let infos = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return "" }
    for info in infos {
        guard (info[kCGWindowLayer as String] as? Int) == 0 else { continue }
        if let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0 { continue }
        if let bounds = info[kCGWindowBounds as String] as? [String: Any],
           let width = bounds["Width"] as? CGFloat, let height = bounds["Height"] as? CGFloat,
           width < 40 || height < 40 { continue }
        let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
        guard pid > 0 else { continue }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
    }
    return ""
}

/// What the machine looks like right now, as far as interference cares.
///
/// Three readings of "who is in front" (see `BridgeEnvironment`): the cached
/// NSWorkspace frontmost, the live AX focused application and the window
/// server's front-most window. `origin` is a `systemUptime` reference so each
/// sample carries its offset.
func currentEnvironment(origin: Double? = nil) -> BridgeEnvironment {
    let front = NSWorkspace.shared.frontmostApplication
    let cursor = cursorLocation()
    let human = humanInputSample()
    let now = ProcessInfo.processInfo.systemUptime
    return BridgeEnvironment(
        frontmostApp: front?.localizedName ?? "",
        frontmostBundle: front?.bundleIdentifier ?? "",
        cursorX: Double(cursor.x),
        cursorY: Double(cursor.y),
        focusedBundle: AXIsProcessTrusted() ? axFocusedApplicationBundle() : "",
        topWindowBundle: topWindowOwnerBundle(),
        t: origin.map { now - $0 } ?? 0,
        humanInput: human)
}

/// READ-ONLY witness of physical input, for attributing a focus change to
/// the person rather than to an action (Shared: `bridgeFocusAttribution`).
///
/// It QUERIES the combined hardware HID state (`.hidSystemState`, the state of
/// all hardware event sources) for the seconds since the last event of a few
/// types, and the current modifier flags. It creates no event, posts nothing,
/// installs no event tap, moves nothing; it is the same kind of reading an
/// idle timer makes. Only focus-capable types are read — mouse button down,
/// key down, modifier change — never mouse movement.
///
/// A reading that is not a finite, non-negative number makes the sample
/// unreliable, and an unreliable sample anywhere in a measurement makes the
/// attribution `unknown`: the report then keeps the strict behaviour.
func humanInputSample() -> BridgeHumanInputSample {
    let state = CGEventSourceStateID.hidSystemState
    let mouseDown = [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown]
        .map { CGEventSource.secondsSinceLastEventType(state, eventType: $0) }
        .min()
    return BridgeHumanInputSample(
        mouseDownAge: mouseDown,
        keyDownAge: CGEventSource.secondsSinceLastEventType(state, eventType: .keyDown),
        flagsChangedAge: CGEventSource.secondsSinceLastEventType(state, eventType: .flagsChanged),
        commandHeld: CGEventSource.flagsState(state).contains(.maskCommand))
}

// MARK: - Breach latch persistence and audit

/// Same directory as the policy file, so an isolated verification lane
/// (`--policy-file`) gets an isolated latch too.
func breachStateDirectory() -> URL {
    URL(fileURLWithPath: policyFilePath()).deletingLastPathComponent()
}
func breachLatchPath() -> URL { breachStateDirectory().appendingPathComponent("breach-latch.json") }
func breachAuditPath() -> URL { breachStateDirectory().appendingPathComponent("breach-audit.jsonl") }

func loadBreachLatchFromDisk() -> BridgeBreachLatchLoad {
    let path = breachLatchPath().path
    guard FileManager.default.fileExists(atPath: path) else {
        return bridgeLoadBreachLatch(data: nil)
    }
    guard let data = FileManager.default.contents(atPath: path) else {
        return .invalid(reason: "unreadable")
    }
    return bridgeLoadBreachLatch(data: data)
}

/// Atomic write, owner-only. Returns false when the latch could not be made
/// durable; the in-memory latch still holds (fail closed) and the failure is
/// audited.
@discardableResult
func saveBreachLatch(_ state: BridgeBreachLatchState) -> Bool {
    let url = breachLatchPath()
    do {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try state.encoded().write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    } catch {
        log("breach latch write failed: \(error.localizedDescription)")
        return false
    }
}

/// Append one line to the audit log (append-only, owner-only).
func appendBreachAudit(_ entry: [String: Any]) {
    let url = breachAuditPath()
    guard var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
    line.append(0x0A)
    let fm = FileManager.default
    if !fm.fileExists(atPath: url.path) {
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    guard let handle = FileHandle(forWritingAtPath: url.path) else {
        log("breach audit unavailable: \(url.path)")
        return
    }
    defer { try? handle.close() }
    handle.seekToEndOfFile()
    handle.write(line)
}

/// Reload the latch from disk, auditing breaches that vanished without a
/// rearm (the file was edited or deleted by hand).
func reloadBreachLatch() {
    let previous = breachLatch.state
    breachLatch = loadBreachLatchFromDisk()
    if let previous, let current = breachLatch.state {
        for record in bridgeBreachesClearedOutside(before: previous, after: current) {
            appendBreachAudit(bridgeBreachAuditEntry(
                event: "cleared_outside_console", at: Date().timeIntervalSince1970,
                record: record, actorClientID: nil, actorSigningID: nil, reason: nil))
            log("breach \(record.id) for \(record.targetBundle) cleared outside breach.rearm")
        }
    }
    if case .invalid(let reason) = breachLatch {
        log("breach latch invalid (\(reason)): control suspended until reset from CMM Console")
    }
}

func breachStatus() -> [String: Any] {
    var result: [String: Any] = [
        "latch_path": breachLatchPath().path,
        "audit_path": breachAuditPath().path,
        "rearm": "breach.rearm from a v2 client granted admin [\"breach.rearm\"]",
    ]
    switch breachLatch {
    case .loaded(let state):
        result["state"] = "ok"
        result["breaches"] = state.records.map { $0.dictionary() }
    case .invalid(let reason):
        result["state"] = "invalid"
        result["invalid_reason"] = reason
        result["breaches"] = [[String: Any]]()
    }
    return result
}

/// `breach.rearm`: the explicit, audited unlock. Never reachable from the
/// adapter's tool catalog; CMM Console calls it with its own signed identity.
func breachRearm(arguments: [String: Any]) -> (Bool, Any?, [String: Any?]?) {
    let decision = bridgeRearmDecision(
        arguments: arguments, client: currentClient,
        clientAuthorization: authorization.clientAuthorization, load: breachLatch)
    let now = Date().timeIntervalSince1970
    let actor = currentClient?.clientID
    let signing = currentPeer?.identifier
    switch decision {
    case .refused(let refusal):
        appendBreachAudit(bridgeBreachAuditEntry(
            event: "rearm_refused", at: now, record: nil, actorClientID: actor,
            actorSigningID: signing, reason: nil, extra: ["detail": refusal.detail]))
        return (false, nil, refusalFrame(refusal))
    case .resetInvalid(let reason):
        let empty = BridgeBreachLatchState()
        guard saveBreachLatch(empty) else {
            return (false, nil, bridgeError(code: "ACTION_FAILED",
                message: "The latch file could not be rewritten.", detail: "reason=latch_write_failed"))
        }
        breachLatch = .loaded(empty)
        let entry = bridgeBreachAuditEntry(
            event: "reset_invalid", at: now, record: nil, actorClientID: actor,
            actorSigningID: signing, reason: reason)
        appendBreachAudit(entry)
        log("breach latch reset by \(actor ?? "?")")
        return (true, ["reset": true, "audit": entry], nil)
    case .rearm(let record, let reason):
        guard var state = breachLatch.state else {
            return (false, nil, bridgeError(code: "ACTION_FAILED",
                message: "The latch file cannot be read.", detail: "reason=breach_latch_invalid"))
        }
        state.remove(id: record.id)
        guard saveBreachLatch(state) else {
            // Not durable means not rearmed: the breach stays latched.
            return (false, nil, bridgeError(code: "ACTION_FAILED",
                message: "The rearm could not be written; the breach stays latched.",
                detail: "reason=latch_write_failed;breach_id=\(record.id)"))
        }
        breachLatch = .loaded(state)
        let entry = bridgeBreachAuditEntry(
            event: "rearmed", at: now, record: record, actorClientID: actor,
            actorSigningID: signing, reason: reason)
        appendBreachAudit(entry)
        log("breach \(record.id) for \(record.targetBundle) rearmed by \(actor ?? "?")")
        return (true, ["rearmed": record.dictionary(), "audit": entry], nil)
    }
}

/// Resolve the per-request mode, narrowing the deployment's own mode with it.
/// A malformed request value is a refusal, never a fallback.
func effectiveMode(
    _ arguments: [String: Any]
) -> (mode: BridgeInteractionMode, refusal: BridgePolicyRefusal?) {
    bridgeResolveMode(requestedValue: arguments["policy"], deployment: deploymentMode)
}

/// The error frame for a refusal.
func refusalFrame(_ refusal: BridgePolicyRefusal) -> [String: Any?] {
    ["code": refusal.code, "message": refusal.message, "detail": refusal.detail]
}

// MARK: - Authorization (shared rules in ../Shared/ComputerUseAuthorization.swift)

/// Where the deployment's allowlist lives. A user-owned file, never a default
/// baked into the binary: authorizing an application is an explicit act.
func policyFilePath() -> String {
    if let argument = policyFileOverride, !argument.isEmpty {
        return argument
    }
    if let override = ProcessInfo.processInfo.environment["CMM_COMPUTER_USE_POLICY_FILE"],
       !override.isEmpty {
        return override
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cmm/computer-bridge/policy.json").path
}

/// The mode this process was LAUNCHED with (the flag), kept separately so a
/// policy reload can re-apply `min(flag, file)` without ever widening.
nonisolated(unsafe) var launchMode: BridgeInteractionMode = .background

/// The client grant that matched THIS connection, resolved from the peer's code
/// identity. Read only inside the dispatch lock, which is what makes a single
/// global correct: `dispatchLock` serializes every operation, so no two
/// connections can observe each other's client.
nonisolated(unsafe) var currentClient: BridgeClientGrant?

/// The peer of THIS connection, kept alongside `currentClient` and under the
/// same lock. Diagnostics only: `policy.status` reports what the kernel said
/// about the caller, which is how an administrator tells "identified by the
/// system" apart from "declared in a file".
nonisolated(unsafe) var currentPeer: BridgePeerCode?

/// Why the current policy is not loaded, as a symbolic code. `none` when a
/// document loaded. Distinguishing "no file" from "the file is broken" is the
/// difference between the documented deny-all state and a defect worth fixing.
nonisolated(unsafe) var policyLoadError: String = "none"

/// Client ids whose requirement failed to compile in the last load attempt.
/// Ids only: requirement text never travels back over the socket.
nonisolated(unsafe) var invalidPolicyClients: [String] = []

/// Load-time requirement verdicts, keyed by client id.
nonisolated(unsafe) var policyRequirementVerdicts: [String: BridgeRequirementVerdict] = [:]

/// The loaded allowlist. `denyAll` until a valid file is read: a missing or
/// malformed policy denies every target instead of falling back to TCC's
/// process-wide grant.
nonisolated(unsafe) var authorization: BridgeAuthorizationPolicy =
    .denyAll(source: "")

func loadAuthorizationPolicy() -> BridgeAuthorizationPolicy {
    let path = policyFilePath()
    policyLoadError = "none"
    invalidPolicyClients = []
    policyRequirementVerdicts = [:]
    guard let data = FileManager.default.contents(atPath: path) else {
        policyLoadError = "no_policy_file"
        log("AUTHORIZATION: no policy at \(path); every application is denied")
        return .denyAll(source: path)
    }
    guard let policy = BridgeAuthorizationPolicy.parse(data, source: path) else {
        policyLoadError = "policy_malformed"
        log("AUTHORIZATION: policy at \(path) is malformed; every application is denied")
        return .denyAll(source: path)
    }
    // A requirement that does not compile is not a strict client: it is a
    // client that can never authenticate while the file claims it exists. Fail
    // closed on the whole document, so the person sees a refusal instead of an
    // allowlist that silently does nothing for one agent.
    let audit = bridgeAuditClientRequirements(policy)
    policyRequirementVerdicts = audit.verdicts
    guard audit.isValid else {
        policyLoadError = "client_requirement_invalid"
        invalidPolicyClients = audit.invalidClientIDs
        log("AUTHORIZATION: policy at \(path) has \(audit.invalidClientIDs.count) client requirement(s)"
            + " that do not compile; every application is denied")
        return .denyAll(source: path)
    }
    log("AUTHORIZATION: \(policy.grants.count) grant(s) from \(path) mode=\(policy.mode.rawValue)"
        + " clients=\(policy.clients.count)")
    return policy
}

/// Recompute the effective deployment mode: the stricter of the launch flag and
/// the policy file. Called at startup and on an explicit reload.
func applyDeploymentModes() {
    deploymentMode = min(launchMode, authorization.mode)
}

/// The application a grant check talks about: what the bridge resolves for a
/// request, plus its live process identity.
struct BridgeTargetApp {
    let pid: pid_t
    let bundleID: String
    let name: String
}

func bridgeTargetApp(_ app: NSRunningApplication) -> BridgeTargetApp {
    BridgeTargetApp(
        pid: app.processIdentifier,
        bundleID: app.bundleIdentifier ?? "",
        name: app.localizedName ?? "")
}

/// What an element handle is bound to. Captured when the observation walked it,
/// re-checked before any action: an element id that outlived its application,
/// its window, or its authorization must not be pressed.
struct BridgeElementContext {
    let pid: pid_t
    let bundleID: String
    let appName: String
    let windowTitle: String
    let window: AXUIElement?
}

/// The first web area under `window`, bounded (breadth-first, ≤ 400 nodes).
/// Used only to re-read the `AXURL` that identified the observed document.
func currentWebArea(of window: AXUIElement?) -> AXUIElement? {
    guard let window else { return nil }
    var queue: [AXUIElement] = [window]
    var visited = 0
    while !queue.isEmpty, visited < 400 {
        let node = queue.removeFirst()
        visited += 1
        if (axAttr(node, kAXRoleAttribute) as? String) == "AXWebArea" { return node }
        if let children = axAttr(node, kAXChildrenAttribute) as? [AXUIElement] {
            queue.append(contentsOf: children.prefix(maxChildrenPerNode))
        }
    }
    return nil
}

/// What document a window shows, from supported AX attributes only: the
/// window's `AXDocument`, else the `AXURL` of the first web area the walk met.
/// Nothing is inferred from the title (Shared: ``BridgeDocumentIdentity``).
func documentIdentity(window: AXUIElement?, webArea: AXUIElement?, title: String) -> BridgeDocumentIdentity {
    let document = window.flatMap { axAttr($0, kAXDocumentAttribute) as? String }
    var url: String?
    if let webArea, let raw = axAttr(webArea, kAXURLAttribute) {
        if let value = raw as? URL { url = value.absoluteString }
        else if let value = raw as? String { url = value }
    }
    return BridgeDocumentIdentity(axDocument: document, axURL: url, title: title)
}

// MARK: - Interference sampling (during the action, not only around it)

/// Samples the environment while an action runs.
///
/// A before/after comparison cannot see an application that raises itself for
/// 40 ms and drops back: both endpoints agree and the person still watched
/// their window jump. The sampler runs on its own thread at ~2 ms for the
/// duration of the action, and `bridgeInterferenceReport` folds those samples
/// into the verdict. Sampling has a resolution: a flick shorter than the
/// interval can still be missed, which is why the live evidence also uses an
/// independent monitor and why this is reported as measurement, never proof.
final class InterferenceSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [BridgeEnvironment] = []
    private var running = false
    private var thread: Thread?
    /// Each sample now also reads the AX focused application and the window
    /// list (a few ms), so the interval is 5 ms; 2000 samples cover ten
    /// seconds, past `wait` (5 s) plus the longest settle window (2 s).
    private let maxSamples = 2000
    /// `systemUptime` reference shared with the before/after readings.
    let origin: Double
    /// Uptime of the last sample whose readings differed from the previous one.
    private var lastChange: Double

    init(origin: Double) {
        self.origin = origin
        self.lastChange = origin
    }

    /// Seconds since the readings last changed.
    var sinceLastChange: Double {
        lock.lock()
        defer { lock.unlock() }
        return ProcessInfo.processInfo.systemUptime - lastChange
    }

    func start() {
        lock.lock()
        if running {
            lock.unlock()
            return
        }
        running = true
        samples.removeAll(keepingCapacity: true)
        let worker = Thread { [weak self] in
            guard let self else { return }
            while self.isRunning {
                let sample = currentEnvironment(origin: self.origin)
                self.lock.lock()
                if let previous = self.samples.last, !bridgeSameApplication(previous, sample) {
                    self.lastChange = ProcessInfo.processInfo.systemUptime
                }
                if self.samples.count < self.maxSamples {
                    self.samples.append(sample)
                }
                self.lock.unlock()
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        worker.stackSize = 1 << 20
        thread = worker
        lock.unlock()
        worker.start()
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    func stop() -> [BridgeEnvironment] {
        lock.lock()
        running = false
        let collected = samples
        lock.unlock()
        return collected
    }
}

// MARK: - Permissions

func permissionStatus() -> [String: Any] {
    let accessibility = AXIsProcessTrusted()
    let screenRecording = CGPreflightScreenCaptureAccess()
    var missing: [String] = []
    if !accessibility { missing.append("Accesibilidad") }
    if !screenRecording { missing.append("Grabación de pantalla") }
    return [
        "accessibility": accessibility,
        "screen_recording": screenRecording,
        "detail": missing.joined(separator: ", "),
    ]
}

func requestAccessibility() -> [String: Any] {
    // Canonical prompt path: macOS shows the grant dialog itself. We never
    // touch privacy settings; the user grants in System Settings.
    // The string literal equals kAXTrustedCheckOptionPrompt; spelled out so
    // the file also compiles under Swift 6 strict concurrency, where the
    // shared global is not referenceable. The API itself is the canonical one.
    let options = ["AXTrustedCheckOptionPrompt" as CFString: true]
    _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    return permissionStatus()
}

func requestScreenRecording() -> [String: Any] {
    // Canonical ScreenCapture permission request path. Returns the
    // pre-request state; the grant itself is manual in System Settings and
    // may require re-probing afterwards.
    _ = CGRequestScreenCaptureAccess()
    return permissionStatus()
}

/// Ask for what the helper needs, at startup, through the canonical APIs.
///
/// Previously the helper only CHECKED: the request APIs existed but nothing
/// ever called them unless a client explicitly asked over the socket, so a
/// machine whose grants had been revoked sat at "unavailable" with no prompt
/// and no explanation. The request must happen AFTER the AppKit lifecycle is
/// established, otherwise the prompt is attributed to a process the system
/// has not finished launching and never appears.
///
/// Both prompts are the system's own. Nothing here writes to the TCC
/// database and nothing opens privacy settings.
func bootstrapPermissions() {
    let accessibilityBefore = AXIsProcessTrusted()
    let screenBefore = CGPreflightScreenCaptureAccess()
    log("ACCESSIBILITY_BEFORE=\(accessibilityBefore) SCREEN_CAPTURE_BEFORE=\(screenBefore)")

    var accessibilityRequested = false
    if !accessibilityBefore {
        // kAXTrustedCheckOptionPrompt makes macOS show the canonical
        // Accessibility dialog itself.
        let options = ["AXTrustedCheckOptionPrompt" as CFString: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        accessibilityRequested = true
    }

    var screenRequested = false
    if !screenBefore {
        // CGRequestScreenCaptureAccess is the canonical Screen Recording
        // request; the grant itself is made in System Settings and usually
        // only takes effect for a relaunched process.
        _ = CGRequestScreenCaptureAccess()
        screenRequested = true
    }

    log("ACCESSIBILITY_PROMPT_REQUESTED=\(accessibilityRequested) SCREEN_CAPTURE_REQUESTED=\(screenRequested)")

    // Re-probe after a beat so the log states what the request actually did.
    Thread.sleep(forTimeInterval: 2.0)
    let state = permissionStatus()
    log("ACCESSIBILITY_AFTER=\(state["accessibility"] as? Bool ?? false) SCREEN_CAPTURE_AFTER=\(state["screen_recording"] as? Bool ?? false) detail=\(state["detail"] as? String ?? "")")
}

// MARK: - AX helpers

func axAttr(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    let err = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return err == .success ? value : nil
}

func axPoint(_ element: AXUIElement, _ name: String) -> (Int, Int) {
    guard let v = axAttr(element, name) else { return (0, 0) }
    let cfv = v as! AXValue
    var point = CGPoint.zero
    guard AXValueGetValue(cfv, .cgPoint, &point) else { return (0, 0) }
    return (Int(point.x), Int(point.y))
}

func axSize(_ element: AXUIElement, _ name: String) -> (Int, Int) {
    guard let v = axAttr(element, name) else { return (0, 0) }
    let cfv = v as! AXValue
    var size = CGSize.zero
    guard AXValueGetValue(cfv, .cgSize, &size) else { return (0, 0) }
    return (Int(size.width), Int(size.height))
}

/// Accumulates one accessibility traversal. Interactive controls and plain
/// visible content are collected into SEPARATE, independently bounded lists:
/// a control is something to act on, content is something to read, and
/// competing for one budget meant content lost every time.
final class Traversal: @unchecked Sendable {
    var elements: [[String: Any]] = []
    var content: [[String: Any]] = []
    var visited = 0
    /// Which controls are returned (Shared: `BridgeProjectionBudget`): the
    /// regular and text-input budgets, and the optional pushed-down filter.
    var budget: BridgeProjectionBudget
    /// Where the bounded walk stopped short — reported, so "no control found"
    /// can be told apart from "the walk never got there".
    var depthCutoffs = 0
    var childrenCutoffs = 0
    var deepestDepth = 0
    /// Pressable, non-window controls the FILTER left out: the window still
    /// offers them, so a filtered projection never reads as "not actionable".
    var filteredOutActionable = 0
    /// The handles this walk produced. Committed to ONE context afterwards,
    /// and only if that context's observation is still the current one.
    var handles: [Int: BridgeLiveHandle] = [:]
    /// The first web area met: its `AXURL` identifies the document (tab).
    var webArea: AXUIElement?

    init(elementFilter: String = "") {
        budget = BridgeProjectionBudget(
            filter: elementFilter, maxRegular: maxElements, maxTextInputs: maxTextInputs)
    }

    var regularElements: Int { budget.regular }
    var textInputs: Int { budget.textInputs }
    var budgetSkippedControls: Int { budget.budgetSkipped }

    var limits: [String: Any] {
        [
            "visited": visited, "visited_cap": maxVisitedNodes, "visited_cap_hit": visited >= maxVisitedNodes,
            "max_depth": maxDepth, "deepest_depth": deepestDepth, "depth_cutoffs": depthCutoffs,
            "children_cutoffs": childrenCutoffs, "budget_skipped_controls": budgetSkippedControls,
            "element_budget": maxElements, "text_input_budget": maxTextInputs,
        ]
    }

    /// Only when a filter was pushed down.
    var filterSummary: [String: Any]? {
        guard budget.isFiltering else { return nil }
        return ["text": budget.filter, "matched": elements.count,
                "skipped_non_matching": budget.filterSkipped,
                "non_matching_actionable": filteredOutActionable]
    }

    /// Whether a node carries text a person can read.
    ///
    /// Generic, per-role rules: a label that merely repeats the element's own
    /// role ("celda", "fila de esquema", "file row") describes the widget, not
    /// the content, and is dropped. AXStaticText is content by definition.
    /// Nothing here names an application or a product.
    static func contentLabel(_ element: AXUIElement, role: String) -> String? {
        let roleDescription = axAttr(element, kAXRoleDescriptionAttribute) as? String
        for attr in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute,
                     kAXIdentifierAttribute, kAXHelpAttribute]
        {
            guard let raw = axAttr(element, attr) as? String else { continue }
            guard bridgeIsReadableContent(
                label: raw, role: role, roleDescription: roleDescription
            ) else { continue }
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
}

func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    guard let raw = axAttr(element, attribute),
          CFGetTypeID(raw) == AXUIElementGetTypeID()
    else { return nil }
    return raw as! AXUIElement
}

/// Whether a scroll bar's AXValue can be set (the AX-only scroll route).
func scrollBarSettable(_ bar: AXUIElement?) -> Bool {
    guard let bar else { return false }
    var settable: DarwinBoolean = false
    guard AXUIElementIsAttributeSettable(bar, kAXValueAttribute as CFString, &settable) == .success
    else { return false }
    return settable.boolValue
}

/// Count accessibility nodes under `root`, breadth-first, stopping at `limit`.
/// Reads roles' children only: cheap enough to poll.
func countAXNodes(_ root: AXUIElement, limit: Int) -> Int {
    var queue: [(AXUIElement, Int)] = [(root, 0)]
    var count = 0
    var index = 0
    while index < queue.count, count < limit {
        let (element, depth) = queue[index]
        index += 1
        count += 1
        guard depth < maxDepth,
              let children = axAttr(element, kAXChildrenAttribute) as? [AXUIElement]
        else { continue }
        for child in children.prefix(maxChildrenPerNode) { queue.append((child, depth + 1)) }
    }
    return count
}

/// Ask an Electron/Chromium application to build its accessibility tree.
///
/// Chromium does not materialize the web contents' tree until an assistive
/// technology asks for it. Electron documents `AXManualAccessibility` on the
/// application element as THE way for a third-party assistive client to do
/// that (VoiceOver itself uses `AXEnhancedUserInterface`, which also changes
/// window-management behaviour and is NOT used here). It is set:
///
/// - from this helper, the process TCC trusts — no auxiliary process, no
///   script, no change to TCC;
/// - only on an application the policy already authorized for `observe`
///   (the caller decides authorization first);
/// - only when the tree is sparse, so a native app with a real tree is never
///   touched; an app that does not know the attribute answers
///   `attributeUnsupported` and nothing changes.
///
/// It posts no event and requests no activation. Its lasting effect is that
/// the target keeps its accessibility tree enabled for its lifetime (some CPU
/// cost in the target), which the observation reports. The result is VERIFIED
/// by re-counting the tree, never assumed.
func ensureAccessibilityTree(
    appElement: AXUIElement, root: AXUIElement, trigger: BridgeEnrichmentTrigger
) -> [String: Any] {
    let attribute = "AXManualAccessibility"
    let limit = 400
    let before = countAXNodes(root, limit: limit)
    var info: [String: Any] = ["mechanism": attribute, "trigger": trigger.rawValue, "nodes_before": before]
    // Read-only, for the record: VoiceOver's attribute is never SET here.
    if let enhanced = axAttr(appElement, "AXEnhancedUserInterface") as? Bool {
        info["enhanced_user_interface"] = enhanced
    }
    if let current = axAttr(appElement, attribute) as? Bool, current {
        // Already on (by us earlier, or by another assistive client): asking
        // again changes nothing.
        info["state"] = "already_enabled"
        info["nodes_after"] = before
        return info
    }
    let err = AXUIElementSetAttributeValue(appElement, attribute as CFString, true as CFTypeRef)
    switch err {
    case .success:
        break
    case .attributeUnsupported, .actionUnsupported, .notImplemented, .illegalArgument:
        info["state"] = "unsupported"
        info["ax_error"] = Int(err.rawValue)
        info["nodes_after"] = before
        return info
    default:
        info["state"] = "failed"
        info["ax_error"] = Int(err.rawValue)
        info["nodes_after"] = before
        return info
    }
    // Chromium builds the tree asynchronously: poll, bounded, until it grew
    // and two consecutive counts agree. A tree already at the count limit
    // cannot show growth by count, so it just gets the settle time.
    let deadline = ProcessInfo.processInfo.systemUptime + 3.0
    var after = before
    if before >= limit {
        Thread.sleep(forTimeInterval: 1.5)
        after = countAXNodes(root, limit: limit)
    } else {
        var previous = -1
        while ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            after = countAXNodes(root, limit: limit)
            if after > before && after == previous { break }
            previous = after
        }
    }
    info["nodes_after"] = after
    info["grew"] = after > before
    info["state"] = (trigger == .sparse && after < sparseTreeThreshold) ? "enabled_still_sparse" : "enabled"
    log("ax enrichment \(attribute) trigger=\(trigger.rawValue): \(before) -> \(after) nodes")
    return info
}

/// Access class of one traversal (see `bridgeAXAccess`) and its actionable count.
func traversalAccess(_ traversal: Traversal) -> (access: BridgeAXAccess, actionable: Int) {
    var observed = traversal.elements.map {
        BridgeObservedElement(windowChrome: ($0["window_chrome"] as? Bool) == true,
                              actionable: ($0["actionable"] as? Bool) == true)
    }
    // A filter narrows what is RETURNED, not what the window offers: controls
    // it left out still count, so a filtered observation neither looks
    // "not actionable" nor triggers enrichment the unfiltered one would not.
    if traversal.filteredOutActionable > 0 {
        observed.append(BridgeObservedElement(windowChrome: false, actionable: true))
    }
    return (bridgeAXAccess(contentCount: traversal.content.count, elements: observed),
            observed.filter { $0.actionable }.count)
}

/// Opt-in deep scan for diagnosis (`include_ax_diagnostics`): how deep the
/// tree goes, where a bounded walk would stop, which roles exist, and every
/// node that looks like a control — role, actions, AXValue settability and
/// its ancestor path. Read-only: no action is performed, nothing is set.
func axDeepScan(_ root: AXUIElement, maxScanDepth: Int = 64, maxScanVisited: Int = 15_000,
                maxCandidates: Int = 60, maxSettableChecks: Int = 4_000) -> [String: Any] {
    var stack: [(AXUIElement, Int, [String])] = [(root, 0, [])]
    var visited = 0, deepest = 0, depthCut = 0, childCut = 0, settableChecks = 0, totalCandidates = 0
    var roles: [String: Int] = [:]
    var candidates: [[String: Any]] = []
    let ignoredActions: Set<String> = ["AXShowMenu", "AXScrollToVisible", "AXShowDefaultUI", "AXShowAlternateUI"]
    let settableProbeRoles: Set<String> = bridgeTextInputRoles.union(["AXGroup", "AXWebArea", "AXStaticText"])
    while visited < maxScanVisited, let item = stack.popLast() {
        let (element, depth, path) = item
        visited += 1
        deepest = max(deepest, depth)
        let role = (axAttr(element, kAXRoleAttribute) as? String) ?? "AXUnknown"
        roles[role, default: 0] += 1
        var names: CFArray?
        let actions = ((AXUIElementCopyActionNames(element, &names) == .success ? (names as? [String]) : nil) ?? [])
            .filter { !ignoredActions.contains($0) }
        var valueSettable = false
        if settableProbeRoles.contains(role), settableChecks < maxSettableChecks {
            settableChecks += 1
            var settable: DarwinBoolean = false
            if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success {
                valueSettable = settable.boolValue
            }
        }
        if interactiveRoles.contains(role) || !actions.isEmpty || valueSettable {
            totalCandidates += 1
            if candidates.count < maxCandidates {
                let subrole = axAttr(element, kAXSubroleAttribute) as? String
                var label = ""
                for attr in [kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue", kAXHelpAttribute] {
                    if let text = axAttr(element, attr) as? String, !text.isEmpty { label = text; break }
                }
                var candidate: [String: Any] = [
                    "role": role, "depth": depth, "actions": actions, "value_settable": valueSettable,
                    "title": String(label.prefix(80)),
                    "path": path.suffix(6).joined(separator: ">"),
                    "window_chrome": bridgeIsWindowChrome(subrole: subrole),
                ]
                if let subrole { candidate["subrole"] = subrole }
                if let enabled = axAttr(element, kAXEnabledAttribute) as? Bool { candidate["enabled"] = enabled }
                if let value = axAttr(element, kAXValueAttribute) as? String {
                    candidate["value_length"] = value.count
                }
                candidates.append(candidate)
            }
        }
        if depth >= maxScanDepth {
            depthCut += 1
            continue
        }
        guard let children = axAttr(element, kAXChildrenAttribute) as? [AXUIElement] else { continue }
        if children.count > maxChildrenPerNode { childCut += children.count - maxChildrenPerNode }
        for child in children.prefix(maxChildrenPerNode).reversed() {
            stack.append((child, depth + 1, path + [role]))
        }
    }
    let topRoles = roles.sorted { $0.value > $1.value }.prefix(25).map { ["role": $0.key, "count": $0.value] as [String: Any] }
    return [
        "visited": visited, "visited_cap_hit": visited >= maxScanVisited, "deepest_depth": deepest,
        "depth_cutoffs": depthCut, "children_cutoffs": childCut, "settable_checks": settableChecks,
        "roles": topRoles, "candidates": candidates, "candidates_total": totalCandidates,
    ]
}

func walk(
    _ element: AXUIElement, into traversal: Traversal, depth: Int,
    owner: BridgeTargetApp, window: AXUIElement?, windowTitle: String
) {
    if depth > maxDepth {
        traversal.depthCutoffs += 1
        return
    }
    if traversal.visited >= maxVisitedNodes { return }
    // Budgets are per list: running out of controls must not stop content
    // collection, and running out of content must not stop control collection.
    if traversal.budget.isFull && traversal.content.count >= maxContentNodes {
        return
    }
    traversal.visited += 1
    traversal.deepestDepth = max(traversal.deepestDepth, depth)

    let role = (axAttr(element, kAXRoleAttribute) as? String) ?? "AXUnknown"
    if role == "AXWebArea", traversal.webArea == nil { traversal.webArea = element }
    let isTextInput = bridgeTextInputRoles.contains(role)
    var decision: BridgeProjectionBudget.Decision? = nil
    if interactiveRoles.contains(role) {
        // The filter fields are read only when a filter was pushed down.
        decision = traversal.budget.consider(isTextInput: isTextInput) {
            var fields = [role]
            for attr in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute, kAXHelpAttribute,
                         kAXRoleDescriptionAttribute, kAXIdentifierAttribute, "AXPlaceholderValue",
                         kAXSubroleAttribute] {
                if let text = axAttr(element, attr) as? String { fields.append(text) }
            }
            return fields
        }
        if decision == .skipFilter {
            var skippedNames: CFArray?
            let skippedActions = (AXUIElementCopyActionNames(element, &skippedNames) == .success
                ? (skippedNames as? [String]) : nil) ?? []
            if skippedActions.contains("AXPress"),
               !bridgeIsWindowChrome(subrole: axAttr(element, kAXSubroleAttribute) as? String) {
                traversal.filteredOutActionable += 1
            }
        }
    }
    if decision == .admit {
        let elementID = traversal.elements.count + 1
        var actionNames: CFArray?
        let namesErr = AXUIElementCopyActionNames(element, &actionNames)
        let actions = (namesErr == .success ? (actionNames as? [String]) : nil) ?? []
        let (x, y) = axPoint(element, kAXPositionAttribute)
        let (w, h) = axSize(element, kAXSizeAttribute)
        var label = ""
        for attr in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute,
                     kAXHelpAttribute, kAXRoleDescriptionAttribute, kAXIdentifierAttribute,
                     "AXPlaceholderValue"]
        {
            if let s = axAttr(element, attr) as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty {
                label = s.trimmingCharacters(in: .whitespaces)
                break
            }
        }
        let value = (axAttr(element, kAXValueAttribute) as? String) ?? ""
        let subrole = axAttr(element, kAXSubroleAttribute) as? String
        // What this handle is allowed to touch, captured now and re-checked
        // before any action: the application, its process, and the window the
        // element was found in.
        traversal.handles[elementID] = BridgeLiveHandle(
            element: element, role: role, subrole: subrole,
            context: BridgeElementContext(
                pid: owner.pid, bundleID: owner.bundleID, appName: owner.name,
                windowTitle: windowTitle, window: window))
        var entry: [String: Any] = [
            "element_id": elementID,
            "role": role,
            "title": String(label.prefix(120)),
            "value": String(value.prefix(120)),
            "x": x, "y": y, "width": w, "height": h,
            "pressable": actions.contains("AXPress"),
        ]
        if let subrole { entry["subrole"] = subrole }
        if bridgeIsWindowChrome(subrole: subrole) { entry["window_chrome"] = true }
        if traversal.budget.isFiltering { entry["filter_match"] = true }
        let verticalBar = axElement(element, kAXVerticalScrollBarAttribute)
        let scrollPlan = bridgeScrollPlan(
            direction: .down, actions: actions, role: role,
            hasScrollBar: verticalBar != nil,
            scrollBarSettable: scrollBarSettable(verticalBar))
        var scrollable = false
        if role == "AXScrollArea" || scrollPlan != .unsupported(reason: "not_scrollable") {
            if case .unsupported(let reason) = scrollPlan {
                entry["scrollable"] = false
                entry["scroll_unsupported"] = reason
            } else {
                entry["scrollable"] = true
                scrollable = true
            }
        }
        // A text input is a control only if its value can actually be set.
        var valueSettable = false
        if isTextInput {
            var settable: DarwinBoolean = false
            if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success {
                valueSettable = settable.boolValue
            }
            entry["value_settable"] = valueSettable
        }
        entry["actionable"] = bridgeElementIsActionable(
            role: role, pressable: actions.contains("AXPress"), scrollable: scrollable,
            windowChrome: bridgeIsWindowChrome(subrole: subrole), valueSettable: valueSettable)
        traversal.elements.append(entry)
    } else if !interactiveRoles.contains(role),
              traversal.content.count < maxContentNodes,
              let label = Traversal.contentLabel(element, role: role)
    {
        // Content is READ, not acted on: it carries no element id, because
        // nothing here is a verified actionable target.
        let (x, y) = axPoint(element, kAXPositionAttribute)
        let (w, h) = axSize(element, kAXSizeAttribute)
        traversal.content.append([
            "role": role,
            "text": String(label.prefix(200)),
            "x": x, "y": y, "width": w, "height": h,
        ])
    }

    guard let children = axAttr(element, kAXChildrenAttribute) as? [AXUIElement] else { return }
    if children.count > maxChildrenPerNode {
        traversal.childrenCutoffs += children.count - maxChildrenPerNode
    }
    for child in children.prefix(maxChildrenPerNode) {
        walk(child, into: traversal, depth: depth + 1,
             owner: owner, window: window, windowTitle: windowTitle)
        if traversal.visited >= maxVisitedNodes { return }
    }
}

// MARK: - Observation

/// Windows currently on screen, active app first.
///
/// Only windows of applications this deployment authorizes for observation are
/// listed. A window list is content too: returning every title on screen would
/// leak the person's other work through a capability they authorized for one
/// application.
func visibleWindows(frontmostApp: String, targetPID: pid_t?) -> [[String: Any]] {
    var owners: [pid_t: NSRunningApplication] = [:]
    for app in NSWorkspace.shared.runningApplications {
        owners[app.processIdentifier] = app
    }
    var windows: [[String: Any]] = []
    if let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
        for info in infos {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? CGFloat, width >= 40,
                  let height = bounds["Height"] as? CGFloat, height >= 40
            else { continue }
            let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            guard ownerPID == targetPID else { continue }
            let ownerName = (info[kCGWindowOwnerName as String] as? String) ?? ""
            let title = (info[kCGWindowName as String] as? String) ?? ""
            let ownerBundle = owners[ownerPID]?.bundleIdentifier ?? ""
            guard authorization.decision(
                bundleID: ownerBundle, name: ownerName, windowTitle: title,
                scope: .observe, client: currentClient
            ).isAllowed else { continue }
            windows.append([
                "title": title,
                "window_id": (info[kCGWindowNumber as String] as? NSNumber)?.intValue ?? 0,
                "app": ownerName,
                "x": Int((bounds["X"] as? CGFloat) ?? 0),
                "y": Int((bounds["Y"] as? CGFloat) ?? 0),
                "width": Int(width),
                "height": Int(height),
            ])
        }
    }
    windows.sort { ($0["app"] as? String == frontmostApp) && ($1["app"] as? String != frontmostApp) }
    return windows
}

/// The running application a request names, or nil when it is not running.
/// Same rules as `app.activate` (`bridgeResolveApp`), so a target can never be
/// guessed.
func runningApp(named request: String) -> NSRunningApplication? {
    let (running, views) = runningCandidates()
    guard let resolved = bridgeResolveApp(request: request, candidates: views),
          let index = views.firstIndex(of: resolved)
    else { return nil }
    return running[index]
}

/// Observe one application's window tree.
///
/// `targetApp` names a running application (exact localized name or bundle
/// id). Reading another application's accessibility tree does NOT activate it,
/// which is what makes background observation of a chosen app possible. With
/// no target the helper describes the frontmost application, as before.
///
/// `mode` is the EFFECTIVE mode for this request (already narrowed by the
/// caller): it decides whether a screenshot may be a display capture.
///
/// Returns either the observation or a typed refusal; never a half-filled
/// result that a client could mistake for a successful one.
func describe(
    includeScreenshot: Bool, targetApp: String?, mode: BridgeInteractionMode,
    includeDiagnostics: Bool = false, elementFilter: String = "", contextID: String? = nil,
    windowID: Int? = nil
) -> (result: [String: Any]?, refusal: BridgePolicyRefusal?) {
    // The context first: it is the caller's own, or the request is refused
    // before any application is touched. No `context_id` is the 0.3.2 caller,
    // whose implicit default context follows whatever app it names.
    let context: BridgeContextRecord<BridgeLiveHandle>
    switch workspace.context(principal: currentPrincipal, id: contextID, now: Date().timeIntervalSince1970) {
    case .failure(let refusal): return (nil, refusal)
    case .success(let found): context = found
    }

    let workspaceApps = NSWorkspace.shared
    let frontmost = workspaceApps.frontmostApplication

    var target: NSRunningApplication? = frontmost
    var request = targetApp?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    // An explicit context that is already bound observes its own application
    // when the caller does not name one.
    if request.isEmpty, !context.legacy, let bound = context.identity?.bundleID ?? context.boundBundle {
        request = bound
    }
    if !request.isEmpty {
        guard let resolved = runningApp(named: request) else {
            return (nil, BridgePolicyRefusal(
                code: "COMPUTER_TARGET_UNAVAILABLE",
                message: "application not running: \(request)",
                detail: "policy=\(mode.rawValue);target=app"))
        }
        target = resolved
    }
    guard let target else {
        return (nil, BridgePolicyRefusal(
            code: "COMPUTER_TARGET_UNAVAILABLE",
            message: "There is no frontmost application to observe.",
            detail: "policy=\(mode.rawValue);target=frontmost"))
    }

    let owner = bridgeTargetApp(target)
    let frontmostName = frontmost?.localizedName ?? ""

    // Identify the window BEFORE reading anything: the grant may limit which
    // windows of the app are observable, and authorization must be decided
    // against the window that is actually going to be walked.
    var windowElement: AXUIElement?
    var captureTitle = ""
    var windowFollow = "focused"
    let appElement = AXUIElementCreateApplication(owner.pid)
    if AXIsProcessTrusted() {
        windowElement = axElement(appElement, kAXFocusedWindowAttribute)
            ?? axElement(appElement, kAXMainWindowAttribute)
            ?? (axAttr(appElement, kAXWindowsAttribute) as? [AXUIElement])?.first
        // F-09: a window is named by its CGWindowID, never by focus or order.
        // An explicit window_id must exist; an explicit context keeps the
        // window it observed last (same process) instead of following focus,
        // so two contexts on two windows of one browser never swap.
        let bound = context.legacy ? nil
            : (context.identity?.pid == owner.pid ? context.identity?.windowID : nil)
        if let wanted = windowID ?? bound {
            let windows = (axAttr(appElement, kAXWindowsAttribute) as? [AXUIElement]) ?? []
            if let match = windows.first(where: { cgWindowID(of: $0, pid: owner.pid) == wanted }) {
                windowElement = match
                windowFollow = windowID != nil ? "requested" : "bound"
            } else if windowID != nil {
                return (nil, BridgePolicyRefusal(
                    code: "COMPUTER_TARGET_UNAVAILABLE",
                    message: "That window of the application is not open.",
                    detail: "policy=\(mode.rawValue);target=window;reason=window_not_found"))
            } else {
                windowFollow = "bound_window_closed"
            }
        }
        if let windowElement {
            captureTitle = (axAttr(windowElement, kAXTitleAttribute) as? String) ?? ""
        }
    }

    // DENY BY DEFAULT: an application the deployment did not authorize is
    // refused here, before a single AX attribute is read from it. A context id
    // never stands in for this decision.
    if let refusal = authorization.decision(
        bundleID: owner.bundleID, name: owner.name,
        windowTitle: captureTitle, scope: .observe, client: currentClient
    ).refusal {
        log("observation refused: \(refusal.detail)")
        return (nil, refusal)
    }
    // A context is ONE application: its handles, stream and panel never
    // describe two.
    if let refusal = workspace.targetMismatch(id: context.id, bundleID: owner.bundleID) {
        return (nil, refusal)
    }

    var traversal = Traversal(elementFilter: elementFilter)
    var enrichment: [String: Any] = ["state": "not_trusted"]
    var diagnostics: [String: Any] = [:]
    // Scope to the window the person is actually looking at. Walking the
    // whole application spends the element budget on a menu bar and on every
    // other open window. This is generic: it asks the system which window is
    // focused, whatever the app.
    func walkTarget(_ into: Traversal) {
        if let windowElement {
            walk(windowElement, into: into, depth: 0,
                 owner: owner, window: windowElement, windowTitle: captureTitle)
        } else {
            walk(appElement, into: into, depth: 0,
                 owner: owner, window: nil, windowTitle: captureTitle)
        }
    }
    if AXIsProcessTrusted() {
        let root = windowElement ?? appElement
        // 1. What the window offers BEFORE any enrichment.
        walkTarget(traversal)
        let first = traversalAccess(traversal)
        if includeDiagnostics { diagnostics["before"] = axDeepScan(root) }
        // 2. Ask for the full tree only when no control is offered — now also
        //    when the tree is readable but not actionable (Claude Desktop).
        if let trigger = bridgeEnrichmentTrigger(
            nodeCount: countAXNodes(root, limit: sparseTreeThreshold), access: first.access,
            sparseThreshold: sparseTreeThreshold) {
            enrichment = ensureAccessibilityTree(appElement: appElement, root: root, trigger: trigger)
            // 3. The tree may have changed: walk again from scratch (a new
            //    traversal carries no handle of the first walk).
            if let state = enrichment["state"] as? String, state.hasPrefix("enabled") {
                traversal = Traversal(elementFilter: elementFilter)
                walkTarget(traversal)
            }
        } else {
            enrichment = ["state": "not_needed", "mechanism": "AXManualAccessibility", "trigger": "none"]
        }
        // 4. What it offers after.
        let after = traversalAccess(traversal)
        enrichment["access_before"] = first.access.rawValue
        enrichment["actionable_before"] = first.actionable
        enrichment["access_after"] = after.access.rawValue
        enrichment["actionable_after"] = after.actionable
        if includeDiagnostics { diagnostics["after"] = axDeepScan(root) }
    }

    // Commit the walk as a NEW generation of THIS context only. No other
    // context's generation, clock or handles move.
    let windows = visibleWindows(frontmostApp: frontmostName, targetPID: target.processIdentifier)
    let titled = windows.filter { ($0["title"] as? String) == captureTitle }
    let identity = BridgeContextIdentity(
        bundleID: owner.bundleID, pid: owner.pid, appName: owner.name,
        windowID: windowElement.flatMap { cgWindowID(of: $0, pid: owner.pid) }
            ?? (titled.count == 1 ? titled[0]["window_id"] as? Int : nil),
        windowTitle: captureTitle,
        document: documentIdentity(window: windowElement, webArea: traversal.webArea, title: captureTitle))
    guard let start = workspace.beginObservation(
        id: context.id, identity: identity, now: Date().timeIntervalSince1970) else {
        return (nil, bridgeUnknownContextRefusal())
    }
    workspace.commit(id: context.id, generation: start.generation, handles: traversal.handles)
    let committed = workspace.record(id: context.id) ?? context
    // The observation is the new baseline for this context's browser
    // transitions (BrowserSupport.swift); nothing for other applications.
    notePageObserved(contextID: context.id, app: target)

    func finish(_ description: [String: Any]) -> (result: [String: Any]?, refusal: BridgePolicyRefusal?) {
        var description = description
        description["window_follow"] = windowFollow
        return (description, nil)
    }
    var screenshotB64: String? = nil
    var screenshotScope = "none"
    var screenshotError: String? = nil
    if includeScreenshot {
        // Always the target window, never the display: a display capture would
        // include windows this deployment did not authorize. Background mode
        // additionally refuses to guess when the window has no title.
        guard !captureTitle.isEmpty else {
            screenshotError = "window_title_unavailable"
            return finish(buildDescription(
                frontmostName: frontmostName, frontmost: frontmost, target: target,
                traversal: traversal, windowTitle: captureTitle, windows: windows, context: committed,
                start: start, screenshot: nil, scope: "none",
                error: screenshotError, enrichment: enrichment, diagnostics: diagnostics))
        }
        let outcome = captureWindowBase64(app: owner.name, title: captureTitle, snapshot: start.generation)
        screenshotB64 = outcome.image
        screenshotScope = outcome.image == nil ? "none" : "window"
        if let refusal = outcome.refusal { screenshotError = refusal.detail }
        else { screenshotError = outcome.failure }
    }

    return finish(buildDescription(
        frontmostName: frontmostName, frontmost: frontmost, target: target,
        traversal: traversal, windowTitle: captureTitle, windows: windows, context: committed,
        start: start, screenshot: screenshotB64, scope: screenshotScope,
        error: screenshotError, enrichment: enrichment, diagnostics: diagnostics))
}

/// One observation frame. `frontmost_*` is always measured truth; `target_*`
/// is what was actually walked, which differs when a client observes a
/// background application.
func buildDescription(
    frontmostName: String,
    frontmost: NSRunningApplication?,
    target: NSRunningApplication?,
    traversal: Traversal,
    windowTitle: String,
    windows: [[String: Any]],
    context: BridgeContextRecord<BridgeLiveHandle>,
    start: BridgeObservationStart,
    screenshot: String?,
    scope: String,
    error: String?,
    enrichment: [String: Any] = [:],
    diagnostics: [String: Any] = [:]
) -> [String: Any] {
    let matches = windows.filter { ($0["title"] as? String) == windowTitle }
    var result: [String: Any] = [
        "frontmost_app": frontmostName,
        "frontmost_bundle": frontmost?.bundleIdentifier ?? "",
        "target_app": target?.localizedName ?? "",
        "target_bundle": target?.bundleIdentifier ?? "",
        "target_pid": Int(target?.processIdentifier ?? 0),
        "target_window": windowTitle,
        "target_is_frontmost": target?.isActive ?? false,
        "windows": windows,
        "elements": traversal.elements,
        "content": traversal.content,
        "screenshot_base64": screenshot as Any,
        "screenshot_scope": scope,
        // The generation of THIS context (0.3.2: of the process).
        "snapshot": start.generation,
        "captured_at": context.capturedAt,
        // Which context produced the handles, so an action names it back.
        "context_id": context.id,
        "context_label": context.label,
        "identity_changes": start.identityChanges,
    ]
    if let document = context.identity?.document { result["document"] = document.dictionary }
    if let windowID = context.identity?.windowID { result["target_window_id"] = windowID }
    else if matches.count == 1 { result["target_window_id"] = matches[0]["window_id"] }
    if !enrichment.isEmpty { result["ax_enrichment"] = enrichment }
    // Say it when the tree is useless instead of handing over three title-bar
    // buttons as if they were the application: `chrome_only` means every
    // element is a window control and there is no readable content.
    let chromeOnly = !traversal.elements.isEmpty && traversal.content.isEmpty
        && traversal.elements.allSatisfy { ($0["window_chrome"] as? Bool) == true }
    let empty = traversal.elements.isEmpty && traversal.content.isEmpty
    result["ax_tree"] = chromeOnly ? "chrome_only" : (empty ? "empty" : "ok")
    // Readable is not actionable: observing a window is not controlling it.
    let observed = traversal.elements.map {
        BridgeObservedElement(windowChrome: ($0["window_chrome"] as? Bool) == true,
                              actionable: ($0["actionable"] as? Bool) == true)
    }
    result["ax_access"] = traversalAccess(traversal).access.rawValue
    if let filterSummary = traversal.filterSummary { result["ax_filter"] = filterSummary }
    result["ax_counts"] = [
        "content": traversal.content.count,
        "elements": traversal.elements.count,
        "actionable": observed.filter { $0.actionable }.count,
        "window_controls": observed.filter { $0.windowChrome }.count,
        "text_inputs": traversal.textInputs,
        "limits": traversal.limits,
    ]
    if !diagnostics.isEmpty { result["ax_diagnostics"] = diagnostics }
    if let error { result["screenshot_error"] = error }
    return result
}

/// Result slot for `appOpen`'s completion handler; see the note there.
final class LaunchedAppBox: @unchecked Sendable {
    var app: NSRunningApplication?
}

final class WindowCaptureBox: @unchecked Sendable {
    var image: String?
    var identity: [String: Any]?
    var failure: String?
    var refusal: BridgePolicyRefusal?
}

/// Encode one CGImage as a bounded PNG, or nil.
func encodePNG(_ image: CGImage) -> String? {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
    guard data.count <= maxScreenshotBytes else {
        log("screenshot \(data.count) bytes exceeds ceiling; refusing")
        return nil
    }
    return data.base64EncodedString()
}

/// Capture exactly one window, selected by application and title fragment.
///
/// `SCContentFilter(desktopIndependentWindow:)` is the public API for this: it
/// composes the window's own surface, so nothing else on the display can leak
/// into the frame. Whether an occluded or minimized window still renders is
/// the application's and the window server's decision, not ours — a failure
/// here is reported, never papered over with a display capture.
func captureWindowBase64(
    app: String?, title: String, snapshot: Int
) -> (image: String?, failure: String?, refusal: BridgePolicyRefusal?, identity: [String: Any]?) {
    guard CGPreflightScreenCaptureAccess() else {
        return (nil, "screen_recording_denied", nil, nil)
    }
    let box = WindowCaptureBox()
    let sema = DispatchSemaphore(value: 0)
    // The generation of the CALLER'S context, so a capture is tied to the
    // observation line it belongs to (0.3.2: a process-wide counter).
    let captureSnapshot = snapshot
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
            switch bridgeSelectWindow(
                request: title, app: app, candidates: pairs.map { $0.0 })
            {
            case .notFound:
                box.failure = "window_not_found"
            case .ambiguous(let matches):
                box.failure = "window_ambiguous:" + matches.joined(separator: " | ")
            case .selected(let chosen):
                guard let pair = pairs.first(where: { $0.0 == chosen }) else {
                    box.failure = "window_not_found"
                    break
                }
                // The selected window's OWNER must be authorized for
                // observation, with this title: a client cannot reach an
                // unauthorized window by naming it.
                if let refusal = authorization.decision(
                    bundleID: pair.0.bundleID, name: pair.0.app,
                    windowTitle: pair.0.title, scope: .observe, client: currentClient
                ).refusal {
                    box.refusal = refusal
                    break
                }
                let filter = SCContentFilter(desktopIndependentWindow: pair.1)
                let config = SCStreamConfiguration()
                config.width = max(2, Int(pair.1.frame.width))
                config.height = max(2, Int(pair.1.frame.height))
                config.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: config)
                // Identity of the exact authorized surface, not the foreground app.
                box.identity = ["bundle": pair.0.bundleID,
                    "pid": Int(pair.1.owningApplication?.processID ?? 0),
                    "window": pair.0.title, "window_id": Int(pair.1.windowID),
                    "snapshot": captureSnapshot]
                box.image = encodePNG(image)
                if box.image == nil { box.failure = "encode_failed" }
            }
        } catch {
            box.failure = "capture_error"
            log("window capture failed: \(error)")
        }
        sema.signal()
    }
    guard sema.wait(timeout: .now() + 15) == .success else {
        log("window capture timed out")
        return (nil, "timeout", nil, nil)
    }
    if let refusal = box.refusal { return (nil, nil, refusal, nil) }
    if let failure = box.failure { return (nil, failure, nil, nil) }
    return (box.image, nil, nil, box.identity)
}

/// Running applications the deployment authorizes, for a client that needs to
/// choose a target without activating anything.
///
/// Filtered to the allowlist: a full process inventory is metadata the person
/// never authorized for this capability, and a client that cannot act on an app
/// does not need to know it is running.
/// The list of authorized applications is itself information. Under a
/// client-required policy an unidentified caller gets a refusal frame, not an
/// empty array: an empty array would read as "this deployment grants nothing",
/// which is a different and untrue statement.
func clientRequiredRefusal(operation: String) -> BridgePolicyRefusal? {
    guard authorization.clientAuthorization == .required, currentClient == nil else { return nil }
    return BridgePolicyRefusal(
        code: "APPROVAL_REJECTED",
        message: "This deployment requires a verified client identity and this process has none.",
        detail: "auth=client_not_authorized;want=\(operation);clients=\(authorization.clients.count)")
}

func appsList() -> [String: Any] {
    var apps: [[String: Any]] = []
    for candidate in NSWorkspace.shared.runningApplications {
        let name = candidate.localizedName ?? ""
        let bundle = candidate.bundleIdentifier ?? ""
        guard !name.isEmpty || !bundle.isEmpty else { continue }
        guard let grant = authorization.grant(bundleID: bundle, name: name) else { continue }
        // A client that cannot reach this application must not learn it exists
        // in the allowlist by reading apps.list.
        if authorization.clientAuthorization == .required {
            guard let client = currentClient,
                  client.covers(bundleID: grant.bundleID, name: grant.name) else { continue }
        }
        apps.append([
            "name": name,
            "bundle_id": bundle,
            "pid": Int(candidate.processIdentifier),
            "is_active": candidate.isActive,
            "hidden": candidate.isHidden,
            "scopes": grant.scopes.map { $0.rawValue }.sorted(),
            "window_limited": !grant.windowPatterns.isEmpty,
        ])
    }
    apps.sort { ($0["name"] as? String ?? "").lowercased() < ($1["name"] as? String ?? "").lowercased() }
    return ["apps": apps, "authorized_only": true]
}

/// Drop every element handle this helper is holding.
///
/// Release is a privacy primitive, not a convenience: a handle keeps a live
/// reference to another application's UI element and to the window it came
/// from, and a client that has finished with an app should be able to say so
/// without waiting for the next observation to sweep the table.
/// Drop every element handle AND retire the generation that produced them.
///
/// Zeroing the timestamp (the old way) made the next action on an old handle
/// report `reason=expired;age=<seconds since 1970>`. Now the generation moves
/// on and is remembered as released: an old handle is refused with
/// `reason=released` before any UI is touched; a fresh observation works as
/// usual. Idempotent: each call retires the then-current generation.
func releaseObservation(contextID: String?) -> (result: [String: Any]?, refusal: BridgePolicyRefusal?) {
    // Only the caller's own context is released: knowing another client's
    // context id gets the same refusal as an id that never existed.
    switch workspace.context(principal: currentPrincipal, id: contextID, now: Date().timeIntervalSince1970) {
    case .failure(let refusal): return (nil, refusal)
    case .success(let context): return (invalidateObservation(contextID: context.id, reason: "release"), nil)
    }
}

/// The single invalidation of ONE context's element handles, used by
/// `observation.release` and by a `USER_TAKEOVER` (which retires only the
/// context the action ran in). The state change is the pure Shared rule
/// ``bridgeRetireObservation``, applied by ``BridgeWorkspace/invalidate``.
@discardableResult
func invalidateObservation(contextID: String, reason: String) -> [String: Any] {
    let released = workspace.record(id: contextID)?.handles.count ?? 0
    // Shared: `BridgeWorkspace.invalidate` empties THIS context's handle table
    // and applies ``bridgeRetireObservation`` to its generation, its released
    // set and its clock (now, never 0). No other context moves.
    guard let retirement = workspace.invalidate(
        id: contextID, reason: reason, now: Date().timeIntervalSince1970) else {
        return ["released": 0, "context_id": contextID]
    }
    log("OBSERVATION_INVALIDATED reason=\(reason) context=\(contextID) handles=\(released) snapshot=\(retirement.retired) current=\(retirement.generation)")
    return ["released": released, "invalidated_snapshot": retirement.retired, "snapshot": retirement.generation,
            "context_id": contextID]
}

/// The authorization document as diagnostics, never as content.
func authorizationStatus() -> [String: Any] {
    [
        "loaded": authorization.loaded,
        "source": authorization.source,
        "policy_mode": authorization.mode.rawValue,
        "launch_mode": launchMode.rawValue,
        "effective_mode": deploymentMode.rawValue,
        "default": "deny",
        "client_authorization": authorization.clientAuthorization.rawValue,
        // Why nothing is loaded, when nothing is loaded. A host that only saw
        // `loaded:false` could not tell a missing file from a document it should
        // ask the person to repair.
        "load_error": policyLoadError,
        "invalid_clients": invalidPolicyClients,
        "requirement_contract": bridgeRequirementContractVersion,
        // Who the helper believes is asking on THIS connection. Diagnostics for
        // an administrator, never an authorization input.
        "client": [
            "authenticated": currentClient != nil,
            "client_id": currentClient?.clientID ?? "",
        ],
        // What the KERNEL said about the caller: the identity layer behind the
        // `client` above, reported so "identified" is not confused with
        // "declared".
        "peer": currentPeer?.summary ?? ["available": false, "valid_signature": false],
        "clients": authorization.clients.map { client -> [String: Any] in
            [
                "client_id": client.clientID,
                "apps": client.apps.count,
                "scopes": client.scopes.map { $0.rawValue }.sorted(),
                "admin": client.adminOperations.sorted(),
                // The requirement text is policy, not a secret, but it is also
                // long; a host gets its digest and the load-time verdict instead.
                "requirement_present": !client.requirement.isEmpty,
                "requirement_valid": policyRequirementVerdicts[client.clientID]?.compiles ?? false,
                "requirement_sha256": bridgeRequirementDigest(client.requirement),
                "apps_sha256": bridgeAppsDigest(client.apps),
            ]
        },
        "apps": authorization.grants.map { grant -> [String: Any] in
            [
                "bundle_id": grant.bundleID,
                "name": grant.name,
                "scopes": grant.scopes.map { $0.rawValue }.sorted(),
                "windows": grant.windowPatterns.count,
            ]
        },
    ]
}

/// Compile and evaluate client requirements, without touching any policy.
///
/// The three answers an administrator needs, and nothing else:
///   * `compiles` — the expression is a syntactically valid requirement;
///   * `matches_peer` — it describes the process on the other end of this
///     socket (that is how a host checks "the requirement I just wrote names
///     me");
///   * `matches_evaluated_path` — it describes a named application bundle, so a
///     requirement can be checked against the client it is meant to authorize
///     instead of being written and hoped for.
///
/// Absent `evaluate_path` the third answer is null, not false: "not asked" and
/// "asked and did not match" are different facts.
func requirementsCheck(arguments: [String: Any]) -> (Bool, Any?, [String: Any?]?) {
    guard let raw = arguments["requirements"] as? [[String: Any]] else {
        return (false, nil, bridgeError(
            code: "CAPABILITY_UNSUPPORTED",
            message: "policy.requirements.check needs a requirements array of objects."))
    }
    guard raw.count <= 64 else {
        return (false, nil, bridgeError(
            code: "CAPABILITY_UNSUPPORTED",
            message: "At most 64 requirements may be checked at once."))
    }

    // Resolve the optional code object once. A path that cannot be read is
    // reported as unavailable, never as "does not match".
    var evaluatedPath: [String: Any] = ["available": false]
    var staticCode: SecStaticCode?
    if let candidate = arguments["evaluate_path"] as? String, !candidate.isEmpty {
        var summary = bridgeCodeSummary(atPath: candidate)
        var object: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(
            URL(fileURLWithPath: candidate) as CFURL, [], &object)
        if created == errSecSuccess, let object {
            staticCode = object
        } else {
            summary = BridgeCodeSummary(
                available: false, identifier: nil, teamID: nil, validSignature: false)
        }
        evaluatedPath = summary.summary
        evaluatedPath["path"] = candidate
    }

    var results: [[String: Any]] = []
    for entry in raw {
        let identifier = (entry["client_id"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (entry["requirement"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4096 else {
            return (false, nil, bridgeError(
                code: "CAPABILITY_UNSUPPORTED",
                message: "Every requirement must be non-empty and at most 4096 characters."))
        }
        let verdict = bridgeCompileRequirement(text)
        var result: [String: Any] = [
            "compiles": verdict.compiles,
            "status": Int(verdict.status),
            "message": verdict.message,
            "requirement_sha256": verdict.digest,
            "matches_peer": bridgeRequirementMatches(text, peer: currentPeer),
        ]
        if !identifier.isEmpty { result["client_id"] = identifier }
        if let staticCode {
            result["matches_evaluated_path"] = bridgeRequirementMatches(
                text, staticCode: staticCode)
        }
        results.append(result)
    }

    return (true, [
        "contract": bridgeRequirementContractName,
        "contract_version": bridgeRequirementContractVersion,
        "peer": currentPeer?.summary ?? ["available": false, "valid_signature": false],
        "evaluated_path": evaluatedPath,
        "requirements": results,
    ], nil)
}

// MARK: - Actions (allowlisted; no shell, no script, no paths)

func bridgeError(code: String, message: String, detail: String = "") -> [String: Any?] {
    var e: [String: Any?] = ["code": code, "message": message]
    if !detail.isEmpty { e["detail"] = detail }
    return e
}

func resolveElement(params: [String: Any]) -> (Int, AXUIElement)? {
    guard let rawID = params["element_id"] else { return nil }
    let elementID: Int
    if let n = rawID as? Int { elementID = n }
    else if let n = rawID as? NSNumber { elementID = n.intValue }
    else { return nil }
    // Only the context this request resolved (``elementPreconditions``):
    // the same number in another context is another element.
    guard let el = requestHandle(elementID)?.element else { return nil }
    return (elementID, el)
}

func awaitFrontmost(_ app: String, timeout: Double = 10.0) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let name = NSWorkspace.shared.frontmostApplication?.localizedName,
           name.lowercased() == app.lowercased() { return true }
        Thread.sleep(forTimeInterval: 0.2)
    }
    return false
}

// MARK: - Targeting (shared rules in ../Shared/BridgeTargeting.swift)

func runningCandidates() -> (apps: [NSRunningApplication], views: [BridgeAppCandidate]) {
    var apps: [NSRunningApplication] = []
    var views: [BridgeAppCandidate] = []
    for candidate in NSWorkspace.shared.runningApplications {
        apps.append(candidate)
        views.append(BridgeAppCandidate(
            name: candidate.localizedName ?? "",
            bundleID: candidate.bundleIdentifier ?? "",
            isActive: candidate.isActive))
    }
    return (apps, views)
}

/// Activate by resolved display NAME (never by raw request: the request may
/// be a bundle id). Retries transient window-server ignores; reports the
/// `activate()` verdict honestly instead of discarding it.
func attemptActivate(app: NSRunningApplication, name: String, timeout: Double = 6.0) -> [String: Any] {
    var everAccepted = false
    for _ in 0..<3 {
        if !app.activate() {
            Thread.sleep(forTimeInterval: 0.5)
            continue
        }
        everAccepted = true
        if awaitFrontmost(name, timeout: timeout) {
            return ["ok": true, "message": "activated \(name)"]
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
    if awaitFrontmost(name, timeout: 1.0) {
        return ["ok": true, "message": "activated \(name)"]
    }
    // The measured outcome decides the report, never the return value alone.
    switch bridgeActivationOutcome(
        wasActive: false, activateAccepted: everAccepted,
        becameActive: false, name: name
    ) {
    case .activated:
        return ["ok": true, "message": "activated \(name)"]
    case .refused(let reason):
        return ["ok": false, "message": reason]
    case .acceptedButNotFrontmost:
        return ["ok": false, "message": "activation did not bring \(name) to the front"]
    case .alreadyActive:
        return ["ok": true, "message": "activated \(name)"]
    }
}

func appOpen(_ app: String) -> [String: Any] {
    let name = app.trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty, name.count <= 128 else {
        return ["ok": false, "message": "no application name"]
    }
    // NSWorkspace launch by NAME only: no paths, no arguments, no shell.
    let workspace = NSWorkspace.shared
    let (running, views) = runningCandidates()
    var target: NSRunningApplication?
    if let resolved = bridgeResolveApp(request: name, candidates: views),
       let index = views.firstIndex(of: resolved)
    {
        target = running[index]
    }
    if target == nil {
        // Launch by name via the workspace URL lookup (AppKit resolves it;
        // nothing executable passes through us).
        let appURL: URL? = workspace.urlForApplication(withBundleIdentifier: name)
            ?? workspace.fullPath(forApplication: name).map({ URL(fileURLWithPath: $0) })
        if let appURL = appURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            let sema = DispatchSemaphore(value: 0)
            // The completion handler is @Sendable: it may run on another
            // thread, so it writes into a box instead of capturing a `var`
            // (Swift 6 SendableClosureCaptures). The semaphore orders the
            // write before the read, exactly as before.
            let launched = LaunchedAppBox()
            workspace.openApplication(at: appURL, configuration: config) { app, err in
                launched.app = app
                if err != nil { log("open failed: \(err!)") }
                sema.signal()
            }
            _ = sema.wait(timeout: .now() + 15)
            target = launched.app
        } else {
            return ["ok": false, "message": "application not found: \(name)"]
        }
    }
    if let running = target {
        running.activate()
        if awaitFrontmost(name) { return ["ok": true, "message": "opened \(name)"] }
        return ["ok": false, "message": "\(name) opened but did not come to the front"]
    }
    return ["ok": false, "message": "application not found: \(name)"]
}

func appActivate(_ app: String) -> [String: Any] {
    let request = app.trimmingCharacters(in: .whitespaces)
    let (running, views) = runningCandidates()
    guard let resolved = bridgeResolveApp(request: request, candidates: views),
          let index = views.firstIndex(of: resolved)
    else {
        // Unknown stays unknown: never activate a guess. Bundle ids resolve
        // through the shared matcher, so "com.apple.finder" finds Finder.
        return ["ok": false, "message": "application not running: \(request)"]
    }
    // Already frontmost is success, not a no-op failure: idempotent by design.
    return attemptActivate(app: running[index], name: resolved.name)
}

func windowFocus(_ title: String) -> [String: Any] {
    let request = title.trimmingCharacters(in: .whitespaces)
    guard !request.isEmpty else {
        return ["ok": false, "message": "window not found: \(title)"]
    }
    // Search EVERY running app, active first: the old code only looked at the
    // frontmost app, so focusing any background window (the normal case after
    // a task switch) always failed with "window not found" even though the
    // window existed. When the owner is not active, bring it forward first —
    // that is what the planner means by focusing its window.
    let ordered = NSWorkspace.shared.runningApplications.sorted {
        ($0.isActive ? 0 : 1) < ($1.isActive ? 0 : 1)
    }
    for candidate in ordered {
        let appElement = AXUIElementCreateApplication(candidate.processIdentifier)
        guard let wins = axAttr(appElement, kAXWindowsAttribute) as? [AXUIElement] else { continue }
        for window in wins {
            let windowTitle = (axAttr(window, kAXTitleAttribute) as? String) ?? ""
            guard bridgeWindowTitleMatches(windowTitle: windowTitle, request: request) else { continue }
            // Activation must come BEFORE the raise: raising a window owned by
            // a background application produces no visible change at all.
            switch bridgeFocusPlan(ownerIsActive: candidate.isActive) {
            case .activateThenRaise:
                let owner = candidate.localizedName ?? ""
                let brought = attemptActivate(app: candidate, name: owner)
                if brought["ok"] as? Bool != true {
                    return ["ok": false, "message": "could not bring \(owner) to the front to focus \"\(windowTitle)\""]
                }
            case .raiseOnly:
                break
            }
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            Thread.sleep(forTimeInterval: 0.3)
            // Already-focused is success: raising the focused window is a no-op.
            return ["ok": true, "message": "focused \"\(windowTitle)\""]
        }
    }
    return ["ok": false, "message": "window not found: \(title)"]
}

func uiPress(_ params: [String: Any]) -> [String: Any] {
    guard let (_, el) = resolveElement(params: params) else {
        return ["ok": false, "message": "The referenced UI element is no longer on screen."]
    }
    let err = AXUIElementPerformAction(el, kAXPressAction as CFString)
    if err != .success {
        return ["ok": false, "message": "AXPress failed (\(err.rawValue))"]
    }
    Thread.sleep(forTimeInterval: 0.3)
    return ["ok": true, "message": "pressed"]
}

/// AX position of an element along one axis, or nil when it has none.
func axAxisPosition(_ element: AXUIElement, vertical: Bool) -> Double? {
    guard let raw = axAttr(element, kAXPositionAttribute),
          CFGetTypeID(raw) == AXValueGetTypeID()
    else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue(raw as! AXValue, .cgPoint, &point) else { return nil }
    return Double(vertical ? point.y : point.x)
}

/// Measure a scroll position with accessibility reads only (see
/// `BridgeScrollProbe`): the scroll bar's value and the position of the first
/// child that is not a scroll bar.
func scrollProbe(_ element: AXUIElement, direction: BridgeScrollDirection) -> BridgeScrollProbe {
    let vertical = direction.isVertical
    let bar = axElement(element, vertical ? kAXVerticalScrollBarAttribute : kAXHorizontalScrollBarAttribute)
    let value = bar.flatMap { (axAttr($0, kAXValueAttribute) as? NSNumber)?.doubleValue }
    var origin: Double?
    if let children = axAttr(element, kAXChildrenAttribute) as? [AXUIElement] {
        for child in children.prefix(maxChildrenPerNode) {
            if (axAttr(child, kAXRoleAttribute) as? String) == "AXScrollBar" { continue }
            if let position = axAxisPosition(child, vertical: vertical) {
                origin = position
                break
            }
        }
    }
    return BridgeScrollProbe(barValue: value, contentOrigin: origin)
}

func scrollProbeDictionary(_ probe: BridgeScrollProbe) -> [String: Any] {
    var d: [String: Any] = [:]
    if let v = probe.barValue { d["bar_value"] = v }
    if let o = probe.contentOrigin { d["content_origin"] = o }
    return d
}

/// Scroll one observed element with accessibility primitives only, and
/// VERIFY it.
///
/// The return code of an AX scroll action is not the outcome: a live run
/// returned `AXScrollDownByPage failed (-25205)` while the content had moved
/// (AXTextArea y 622 -> 498). So every route is judged by an observable
/// postcondition (`bridgeScrollEffect`):
///
///   1. the element's own `AXScroll<Dir>ByPage`; moved in the requested
///      direction = done, the AX error kept as `ax_error`;
///   2. otherwise, if the element has a settable scroll bar, its AXValue,
///      measured again;
///   3. no AX route at all -> `unsupported` (CAPABILITY_UNSUPPORTED);
///      routes tried but no verifiable effect -> failure with the reason.
///
/// Never a scroll-wheel event, never a cursor move, never CGEvent.
func uiScroll(_ params: [String: Any]) -> [String: Any] {
    guard let (_, el) = resolveElement(params: params) else {
        return ["ok": false, "message": "The referenced UI element is no longer on screen."]
    }
    guard let raw = params["direction"] as? String,
          let direction = BridgeScrollDirection(rawValue: raw.lowercased())
    else {
        return ["ok": false, "unsupported": true,
                "message": "direction must be up, down, left or right",
                "detail": "reason=invalid_direction"]
    }
    let pages = max(1, min(10, (params["pages"] as? NSNumber)?.intValue ?? 1))
    var names: CFArray?
    let actions = (AXUIElementCopyActionNames(el, &names) == .success ? (names as? [String]) : nil) ?? []
    let role = (axAttr(el, kAXRoleAttribute) as? String) ?? "AXUnknown"
    let bar = axElement(el, direction.isVertical
        ? kAXVerticalScrollBarAttribute : kAXHorizontalScrollBarAttribute)
    let barSettable = scrollBarSettable(bar)
    let plan = bridgeScrollPlan(
        direction: direction, actions: actions, role: role,
        hasScrollBar: bar != nil, scrollBarSettable: barSettable)
    if case .unsupported(let reason) = plan {
        return ["ok": false, "unsupported": true,
                "message": "This element offers no accessibility scroll primitive; background mode will not post a scroll-wheel event.",
                "detail": "reason=\(reason);role=\(role)"]
    }

    let initial = scrollProbe(el, direction: direction)
    var attempts: [[String: Any]] = []
    var step: BridgeScrollStep = .tryScrollBar
    var current = initial

    if case .pageAction(let name) = plan {
        var firstError: Int32?
        for _ in 0..<pages {
            let err = AXUIElementPerformAction(el, name as CFString)
            if err != .success && firstError == nil { firstError = err.rawValue }
        }
        Thread.sleep(forTimeInterval: 0.2)
        let after = scrollProbe(el, direction: direction)
        let effect = bridgeScrollEffect(direction: direction, before: current, after: after)
        var attempt: [String: Any] = [
            "route": "page_action", "action": name, "effect": effect.rawValue,
            "before": scrollProbeDictionary(current), "after": scrollProbeDictionary(after)]
        if let firstError { attempt["ax_error"] = Int(firstError) }
        attempts.append(attempt)
        step = bridgeScrollAfterPageAction(
            effect: effect, axError: firstError, scrollBarAvailable: bar != nil && barSettable)
        current = after
    }

    if step == .tryScrollBar, let bar, barSettable {
        let value = (axAttr(bar, kAXValueAttribute) as? NSNumber)?.doubleValue ?? 0
        let target = bridgeScrollBarTarget(current: value, direction: direction, pages: pages)
        let err = AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: target))
        Thread.sleep(forTimeInterval: 0.2)
        let after = scrollProbe(el, direction: direction)
        let effect = bridgeScrollEffect(direction: direction, before: current, after: after)
        let axError: Int32? = err == .success ? nil : err.rawValue
        var attempt: [String: Any] = [
            "route": "scroll_bar", "target": target, "effect": effect.rawValue,
            "before": scrollProbeDictionary(current), "after": scrollProbeDictionary(after)]
        if let axError { attempt["ax_error"] = Int(axError) }
        attempts.append(attempt)
        step = bridgeScrollAfterScrollBar(effect: effect, axError: axError)
        current = after
    }

    var scroll: [String: Any] = [
        "direction": direction.rawValue, "pages": pages,
        "before": scrollProbeDictionary(initial), "after": scrollProbeDictionary(current),
        "attempts": attempts,
    ]
    switch step {
    case .done(let route, let axError):
        scroll["route"] = route
        scroll["effect"] = "moved"
        if let axError { scroll["ax_error"] = Int(axError) }
        let note = axError.map { " (AX returned \($0); effect verified)" } ?? ""
        return ["ok": true, "scroll": scroll,
                "message": "scrolled \(direction.rawValue) \(pages) page(s) via \(route)\(note)"]
    case .failed(let reason):
        scroll["effect"] = reason
        let errors = attempts.compactMap { $0["ax_error"] as? Int }.map { String($0) }.joined(separator: ",")
        return ["ok": false, "scroll": scroll,
                "message": "The scroll had no verifiable effect through accessibility.",
                "detail": "reason=\(reason);role=\(role);routes=\(attempts.compactMap { $0["route"] as? String }.joined(separator: ","))"
                    + (errors.isEmpty ? "" : ";ax_error=\(errors)")]
    case .tryScrollBar:
        // Page action without effect and no settable scroll bar is .failed
        // above; reaching here means no route ran at all.
        return ["ok": false, "unsupported": true, "scroll": scroll,
                "message": "This element offers no accessibility scroll primitive; background mode will not post a scroll-wheel event.",
                "detail": "reason=no_route;role=\(role)"]
    }
}

/// Set one element's AXValue, and VERIFY it by reading it back.
///
/// Before anything is touched: secure fields are refused, and an element
/// whose AXValue is not settable is `unsupported` (CAPABILITY_UNSUPPORTED).
/// After: the value read back must match (`bridgeSetValueCheck`), otherwise
/// the call fails (`reason=value_not_applied|value_unreadable`). The previous
/// content is never echoed — only lengths.
func uiSetValue(_ params: [String: Any]) -> [String: Any] {
    guard let (elementID, el) = resolveElement(params: params) else {
        return ["ok": false, "message": "The referenced UI element is no longer on screen."]
    }
    if requestHandle(elementID)?.role == "AXSecureTextField" {
        return ["ok": false, "message": "secure fields are never modified automatically"]
    }
    let role = requestHandle(elementID)?.role ?? "AXUnknown"
    var settable: DarwinBoolean = false
    let settableErr = AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable)
    guard settableErr == .success, settable.boolValue else {
        return ["ok": false, "unsupported": true,
                "message": "This element's value cannot be set through accessibility.",
                "detail": "reason=value_not_settable;role=\(role)"]
    }
    let text = String((params["text"] as? String ?? "").prefix(maxTextChars))
    let previousLength = (axAttr(el, kAXValueAttribute) as? String)?.count
    let setErr = AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFTypeRef)
    Thread.sleep(forTimeInterval: 0.2)
    let readBack = axAttr(el, kAXValueAttribute) as? String
    let check = bridgeSetValueCheck(requested: text, readBack: readBack)
    var evidence: [String: Any] = [
        "check": check.rawValue, "requested_length": text.count, "role": role,
    ]
    if let previousLength { evidence["previous_length"] = previousLength }
    if let readBack { evidence["read_back_length"] = readBack.count }
    if setErr != .success { evidence["ax_error"] = Int(setErr.rawValue) }
    if check == .verified {
        return ["ok": true, "set_value": evidence,
                "message": "value set and verified" + (setErr == .success ? "" : " (AX returned \(setErr.rawValue))")]
    }
    return ["ok": false, "set_value": evidence,
            "message": "The value did not take (read back does not match).",
            "detail": "reason=value_\(check == .unreadable ? "unreadable" : "not_applied");role=\(role)"
                + (setErr == .success ? "" : ";ax_error=\(setErr.rawValue)")]
}

func keyboardType(_ text: String) -> [String: Any] {
    // Parity with MacComputerRuntime: pasteboard + cmd+v, restoring the
    // previous clipboard. CGEvent posting requires the AX grant.
    let clipped = String(text.prefix(maxTextChars))
    let pasteboard = NSPasteboard.general
    let previous = pasteboard.string(forType: .string)
    pasteboard.clearContents()
    guard pasteboard.setString(clipped, forType: .string) else {
        return ["ok": false, "message": "the text could not be placed on the pasteboard"]
    }
    let vDown = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true)
    vDown?.flags = .maskCommand
    vDown?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.02)
    let vUp = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false)
    vUp?.flags = .maskCommand
    vUp?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.4)
    pasteboard.clearContents()
    if let prev = previous { pasteboard.setString(prev, forType: .string) }
    return ["ok": true, "message": "typed \(clipped.count) characters"]
}

func keyboardShortcut(_ keys: String) -> [String: Any] {
    let parts = keys.replacingOccurrences(of: "+", with: " ").split(separator: " ")
        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    guard !parts.isEmpty else { return ["ok": false, "message": "empty shortcut"] }
    var flags = CGEventFlags()
    var main: String?
    for part in parts {
        switch part {
        case "cmd", "command": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "option", "alt": flags.insert(.maskAlternate)
        case "ctrl", "control": flags.insert(.maskControl)
        default: main = part
        }
    }
    guard let key = main, let code = keycodes[key] else {
        return ["ok": false, "message": "unsupported shortcut keys: \(keys)"]
    }
    let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true)
    down?.flags = flags
    down?.post(tap: .cghidEventTap)
    let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: false)
    up?.flags = flags
    up?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.2)
    return ["ok": true, "message": "shortcut \(keys)"]
}

func pointerClick(_ params: [String: Any]) -> [String: Any] {
    guard let x = (params["x"] as? NSNumber)?.doubleValue,
          let y = (params["y"] as? NSNumber)?.doubleValue,
          x.isFinite, y.isFinite, abs(x) < 100_000, abs(y) < 100_000
    else { return ["ok": false, "message": "invalid pointer coordinates"] }
    let point = CGPoint(x: x, y: y)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.05)
    for kind in [CGEventType.leftMouseDown, CGEventType.leftMouseUp] {
        CGEvent(mouseEventSource: nil, mouseType: kind, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.04)
    }
    return ["ok": true, "message": "clicked (\(Int(x)),\(Int(y)))"]
}

func pointerScroll(_ params: [String: Any]) -> [String: Any] {
    let dy = (params["dy"] as? NSNumber)?.intValue ?? -3
    guard dy >= -100, dy <= 100 else { return ["ok": false, "message": "scroll out of range"] }
    CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: Int32(dy), wheel2: 0, wheel3: 0)?
        .post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.2)
    return ["ok": true, "message": "scrolled \(dy)"]
}

func executeAction(kind: String, params: [String: Any]) -> [String: Any] {
    // The allowlist is the boundary: anything outside it is rejected, never
    // interpreted.
    guard allowedActions.contains(kind) else {
        return ["ok": false, "message": "Unsupported action: \(kind)"]
    }
    switch kind {
    case "app.open": return appOpen(params["app"] as? String ?? "")
    case "app.activate": return appActivate(params["app"] as? String ?? "")
    case "window.focus": return windowFocus(params["title"] as? String ?? "")
    case "ui.press": return uiPress(params)
    case "browser.select_tab": return browserSelectTab(params)
    case "browser.save_dialog": return browserSaveDialog(params)
    case "ui.set_value": return uiSetValue(params)
    case "ui.scroll": return uiScroll(params)
    case "keyboard.type": return keyboardType(params["text"] as? String ?? "")
    case "keyboard.shortcut": return keyboardShortcut(params["keys"] as? String ?? "")
    case "pointer.click": return pointerClick(params)
    case "pointer.scroll": return pointerScroll(params)
    case "wait":
        let seconds = min(5.0, max(0.1, (params["seconds"] as? NSNumber)?.doubleValue ?? 1.0))
        Thread.sleep(forTimeInterval: seconds)
        return ["ok": true, "message": "waited"]
    case "finish": return ["ok": true, "message": "finished"]
    default: return ["ok": false, "message": "Unsupported action: \(kind)"]
    }
}

// MARK: - Request dispatch

/// Everything an element action must prove before it runs: a live observation,
/// the snapshot that produced the element, the SAME process that was
/// authorized, the SAME window the element was found in, and a policy that
/// still grants control of it.
///
/// This closes the gap a stale handle leaves: an element id is a number, and
/// without these checks it would still resolve after the application was
/// relaunched or its window replaced.
func elementPreconditions(
    kind: String, params: [String: Any], mode: BridgeInteractionMode
) -> BridgePolicyRefusal? {
    guard kind == "ui.press" || kind == "ui.set_value" || kind == "ui.scroll" else { return nil }
    // Shared: ``BridgeWorkspace/resolveHandle`` — the caller's OWN context
    // (no context id: the 0.3.2 default), then released, expired, superseded
    // and unknown, in that order (a released generation has no age).
    let contextID = params["context_id"] as? String
    let resolved: BridgeResolvedHandle<BridgeLiveHandle>
    switch workspace.resolveHandle(
        principal: currentPrincipal, id: contextID,
        snapshot: (params["snapshot"] as? NSNumber)?.intValue,
        elementID: (params["element_id"] as? NSNumber)?.intValue,
        mode: mode, now: Date().timeIntervalSince1970) {
    case .failure(let refusal): return refusal
    case .success(let found): resolved = found
    }
    requestContext = resolved.context
    let context = resolved.handle.context
    // The application that was authorized is the one that must still be there.
    guard let app = NSRunningApplication(processIdentifier: context.pid),
          !app.isTerminated,
          app.bundleIdentifier == context.bundleID
    else {
        return BridgePolicyRefusal(
            code: "ACTION_FAILED",
            message: "The application this element belongs to is no longer the observed one.",
            detail: "policy=\(mode.rawValue);reason=pid_changed;pid=\(context.pid)")
    }
    // The window must be the same window, not merely a window with the same title.
    var currentTitle = context.windowTitle
    let element = resolved.handle.element
    if let stored = context.window, let current = axElement(element, kAXWindowAttribute),
       !CFEqual(current, stored) {
        return BridgePolicyRefusal(
            code: "ACTION_FAILED",
            message: "The window this element belongs to has been replaced.",
            detail: "policy=\(mode.rawValue);reason=window_changed;pid=\(context.pid)")
    }
    let currentWindow = axElement(element, kAXWindowAttribute) ?? context.window
    if let currentWindow, let title = axAttr(currentWindow, kAXTitleAttribute) as? String {
        currentTitle = title
    }
    // Same window is not same document: a tab switch keeps the window and
    // changes what the handles were taken from. Verified identities only;
    // explicit (0.3.3) contexts are also conservative with a title-only one.
    if let observed = resolved.context.identity?.document {
        let current = documentIdentity(
            window: currentWindow,
            webArea: observed.source == .axURL ? currentWebArea(of: currentWindow) : nil,
            title: currentTitle)
        if let refusal = bridgeDocumentRefusal(
            observed: observed, current: current, strict: !resolved.context.legacy, mode: mode) {
            return refusal
        }
    }
    // Authorization is re-evaluated with the CURRENT window title: a window
    // renamed out of the authorized set must stop being controllable.
    if let refusal = authorization.decision(
        bundleID: context.bundleID, name: context.appName,
        windowTitle: currentTitle, scope: .control, client: currentClient
    ).refusal {
        return refusal
    }
    return nil
}

/// The bundle of the application an action is aimed at, when one is known.
///
/// It is what lets the interference report distinguish "the frontmost app
/// became MY target" (plausibly caused by this action) from "the person
/// switched to another window" (external activity).
func actionTargetBundle(kind: String, params: [String: Any]) -> String? {
    switch kind {
    case "ui.press", "ui.set_value", "ui.scroll":
        guard let id = (params["element_id"] as? NSNumber)?.intValue,
              let handle = requestHandle(id)
        else { return nil }
        return handle.context.bundleID
    case "app.activate", "app.open":
        let request = (params["app"] as? String) ?? ""
        return runningApp(named: request)?.bundleIdentifier
    case "browser.select_tab", "browser.save_dialog":
        return requestBrowserTarget?.bundleID
    default:
        return nil
    }
}

/// Authorization for the kinds that change which application is frontmost.
///
/// They are only reachable in `focus`/`unrestricted`, but focus is a real
/// effect on the person's session, so the target application must be one the
/// policy authorizes for control. A request that names nothing recognizable
/// matches no grant and is refused.
func actionAuthorizationRefusal(
    kind: String, params: [String: Any]
) -> BridgePolicyRefusal? {
    switch kind {
    case "app.open", "app.activate":
        let request = (params["app"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else {
            return BridgePolicyRefusal(
                code: "ACTION_FAILED",
                message: "The action names no application.",
                detail: "auth=app_missing;kind=\(kind)")
        }
        return authorization.decision(
            bundleID: request, name: request, windowTitle: nil, scope: .control,
            client: currentClient
        ).refusal
    case "window.focus":
        let request = (params["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else {
            return BridgePolicyRefusal(
                code: "ACTION_FAILED",
                message: "The action names no window.",
                detail: "auth=window_missing;kind=window.focus")
        }
        for candidate in NSWorkspace.shared.runningApplications {
            let appElement = AXUIElementCreateApplication(candidate.processIdentifier)
            guard let windows = axAttr(appElement, kAXWindowsAttribute) as? [AXUIElement] else { continue }
            for window in windows {
                let title = (axAttr(window, kAXTitleAttribute) as? String) ?? ""
                guard bridgeWindowTitleMatches(windowTitle: title, request: request) else { continue }
                let owner = bridgeTargetApp(candidate)
                return authorization.decision(
                    bundleID: owner.bundleID, name: owner.name,
                    windowTitle: title, scope: .control, client: currentClient
                ).refusal
            }
        }
        return nil  // no match: the action itself reports "window not found"
    default:
        return nil
    }
}

/// Refuse a press on a window control in a no-interference mode, before
/// anything runs (see `bridgeWindowChromeRefusal`).
func elementChromeRefusal(
    kind: String, params: [String: Any], mode: BridgeInteractionMode
) -> BridgePolicyRefusal? {
    guard kind == "ui.press", let id = (params["element_id"] as? NSNumber)?.intValue else { return nil }
    var subrole = requestHandle(id)?.subrole
    if subrole == nil, let element = requestHandle(id)?.element {
        subrole = axAttr(element, kAXSubroleAttribute) as? String
    }
    return bridgeWindowChromeRefusal(kind: kind, subrole: subrole, mode: mode)
}

/// The cached-frame read, factored out of `dispatch`.
///
/// The socket path serves this WITHOUT the global dispatch lock. It touches no
/// AppKit, AX or window-server resource — only the stream registry's and the
/// sink's own locks — and the global lock is held for a capture or an action
/// for hundreds of milliseconds. Queueing the mirror behind those would freeze
/// the viewer exactly while something is happening, which is the one moment it
/// must be live. `principal` is resolved from the connection's verified peer:
/// a frame is served only to the principal that opened the stream.
func streamFrameResponse(_ arguments: [String: Any], principal: BridgePrincipal) -> (Bool, Any?, [String: Any?]?) {
    var streamID: String?
    if let raw = arguments["stream_id"] {
        guard let text = raw as? String, bridgeValidOpaqueID(text, prefix: "str") else {
            return (false, nil, bridgeError(code: "STREAM_UNKNOWN", message: "No such stream for this client.",
                                            detail: "reason=stream_unknown"))
        }
        streamID = text
    }
    let (frame, failure) = windowStreamFrame(principal: principal, id: streamID)
    guard let frame else {
        // `stream_warming` is the normal first instant of a stream and
        // `stream_not_active` means the host must fall back to capture;
        // the detail says which, instead of one indistinguishable failure.
        if failure == "stream_unknown" {
            return (false, nil, bridgeError(code: "STREAM_UNKNOWN", message: "No such stream for this client.",
                                            detail: "reason=stream_unknown"))
        }
        return (false, nil, bridgeError(
            code: "ACTION_FAILED",
            message: "No live frame is available.",
            detail: failure ?? ""))
    }
    return (true, [
        "screenshot_base64": frame.jpeg.base64EncodedString(),
        "screenshot_scope": "window",
        "media_type": "image/jpeg",
        "stream_id": frame.streamID,
        "key": frame.key as Any,
        "frame_index": frame.frameIndex,
        "frame_age_ms": frame.ageMilliseconds,
        // Never "live" over an old picture: the phase is the stream's health,
        // not the presence of an image.
        "phase": frame.health.phase.rawValue,
        "phase_reason": frame.health.reason as Any,
        "unchanged": frame.health.unchanged,
        "stale": frame.health.phase != .live,
        "view_identity": [
            "bundle": frame.bundleID,
            "pid": frame.pid,
            "window": frame.windowTitle,
            "window_id": frame.windowID,
        ],
    ], nil)
}

// MARK: - Workspace operations (0.3.3)

/// The workspace contract this helper implements, for hosts and adapters.
let workspaceContractName = "cmm-computer-use/workspace"
let workspaceContractVersion = 1

/// A request field that must be an opaque context id when present.
/// `.success(nil)`: absent (the 0.3.2 default context).
func contextIDArgument(_ arguments: [String: Any], _ key: String = "context_id") -> Result<String?, BridgePolicyRefusal> {
    guard let raw = arguments[key], !(raw is NSNull) else { return .success(nil) }
    guard let text = raw as? String, bridgeValidContextID(text) else { return .failure(bridgeUnknownContextRefusal()) }
    return .success(text)
}

/// Contexts nobody used for `idleSeconds` are dropped with their handles and
/// their streams. Run before every workspace operation; cheap.
func reapIdleContexts() {
    for record in workspace.reap(now: Date().timeIntervalSince1970) {
        if let streamID = record.streamID { stopWindowStreamInternal(id: streamID, reason: "context_reaped") }
        // An expired context's download expectations end with it, exactly as
        // on an explicit close (audit R1).
        let forgotten = downloadMonitor.forget(principal: record.principal, contextID: record.id)
        log("CONTEXT_REAPED context=\(record.id) label=\(record.label) handles=\(record.handles.count) downloads=\(forgotten)")
    }
}

func principalSummary() -> [String: Any] {
    [
        "strength": currentPrincipal.strength.rawValue,
        "client_id": currentClient?.clientID ?? "",
    ]
}

func workspaceLimits() -> [String: Any] {
    [
        "max_contexts_per_client": workspace.limits.maxContextsPerPrincipal,
        "max_contexts": workspace.limits.maxContextsTotal,
        "max_streams": 2,
        "context_idle_seconds": Int(workspace.limits.idleSeconds),
    ]
}

func contextDescription(_ record: BridgeContextRecord<BridgeLiveHandle>, mode: BridgeInteractionMode) -> [String: Any] {
    var summary = bridgeContextSummary(record, now: Date().timeIntervalSince1970, mode: mode)
    if let streamID = record.streamID { summary["stream"] = streamDescription(id: streamID) }
    return summary
}

func workspaceStatus() -> (Bool, Any?, [String: Any?]?) {
    reapIdleContexts()
    let streams: Any
    switch windowStreamStatus(id: nil) {
    case .success(let status): streams = status["streams"] ?? []
    case .failure: streams = []
    }
    return (true, [
        "contract": workspaceContractName,
        "contract_version": workspaceContractVersion,
        "instance_id": helperInstanceID,
        "principal": principalSummary(),
        "limits": workspaceLimits(),
        "contexts": workspace.list(principal: currentPrincipal).map { contextDescription($0, mode: deploymentMode) },
        "streams": streams,
    ], nil)
}

/// Open an explicit context, optionally bound to one application. The app
/// must be running and authorized for `observe` FOR THIS CLIENT: a context is
/// never a way to reach an application the policy does not grant.
func contextCreate(_ arguments: [String: Any]) -> (Bool, Any?, [String: Any?]?) {
    reapIdleContexts()
    if let refusal = clientRequiredRefusal(operation: "workspace.context_create") {
        return (false, nil, refusalFrame(refusal))
    }
    var bound: String?
    let request = ((arguments["app"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if !request.isEmpty {
        guard let running = runningApp(named: request) else {
            return (false, nil, refusalFrame(BridgePolicyRefusal(
                code: "COMPUTER_TARGET_UNAVAILABLE", message: "application not running: \(request)",
                detail: "target=app")))
        }
        let owner = bridgeTargetApp(running)
        if let refusal = authorization.decision(
            bundleID: owner.bundleID, name: owner.name, windowTitle: nil, scope: .observe, client: currentClient
        ).refusal {
            return (false, nil, refusalFrame(refusal))
        }
        bound = owner.bundleID
    }
    switch workspace.create(principal: currentPrincipal, target: bound, now: Date().timeIntervalSince1970) {
    case .failure(let refusal):
        return (false, nil, refusalFrame(refusal))
    case .success(let record):
        log("CONTEXT_CREATED context=\(record.id) label=\(record.label) bound=\(bound ?? "-")")
        var result = contextDescription(record, mode: deploymentMode)
        result["instance_id"] = helperInstanceID
        return (true, result, nil)
    }
}

func contextStatus(_ arguments: [String: Any]) -> (Bool, Any?, [String: Any?]?) {
    reapIdleContexts()
    let requested: String?
    switch contextIDArgument(arguments) {
    case .failure(let refusal): return (false, nil, refusalFrame(refusal))
    case .success(let id): requested = id
    }
    switch workspace.context(principal: currentPrincipal, id: requested, now: Date().timeIntervalSince1970) {
    case .failure(let refusal): return (false, nil, refusalFrame(refusal))
    case .success(let record):
        var result = contextDescription(record, mode: deploymentMode)
        result["instance_id"] = helperInstanceID
        return (true, result, nil)
    }
}

/// Close a context: its handles are dropped and its stream is stopped.
/// Idempotent for the owner.
func contextClose(_ arguments: [String: Any]) -> (Bool, Any?, [String: Any?]?) {
    guard case .success(let requested) = contextIDArgument(arguments), let id = requested else {
        return (false, nil, refusalFrame(bridgeUnknownContextRefusal()))
    }
    switch workspace.close(principal: currentPrincipal, id: id) {
    case .failure(let refusal):
        return (false, nil, refusalFrame(refusal))
    case .success(let closed):
        if let streamID = closed.streamID { stopWindowStreamInternal(id: streamID, reason: "context_closed") }
        // A closed context's download expectations end with it (idempotent).
        let forgotten = downloadMonitor.forget(principal: currentPrincipal, contextID: id)
        if closed.closed { log("CONTEXT_CLOSED context=\(id) handles=\(closed.releasedHandles)") }
        return (true, [
            "context_id": id, "closed": closed.closed, "already_closed": closed.alreadyClosed,
            "released_handles": closed.releasedHandles, "stream_stopped": closed.streamID != nil,
            "downloads_forgotten": forgotten,
        ], nil)
    }
}

// MARK: - Operation ledger (0.3.3 Reliability Engine)

/// Operation ids received but not yet answered, across connections. A resend
/// of an id that is still in flight is refused (`OPERATION_IN_PROGRESS`)
/// instead of executing beside the first.
private let pendingOperationsLock = NSLock()
nonisolated(unsafe) private var pendingOperations: Set<String> = []

func beginPendingOperation(_ opID: String) -> Bool {
    pendingOperationsLock.lock()
    defer { pendingOperationsLock.unlock() }
    return pendingOperations.insert(opID).inserted
}

func endPendingOperation(_ opID: String) {
    pendingOperationsLock.lock()
    pendingOperations.remove(opID)
    pendingOperationsLock.unlock()
}

func operationIsPending(_ opID: String) -> Bool {
    pendingOperationsLock.lock()
    defer { pendingOperationsLock.unlock() }
    return pendingOperations.contains(opID)
}

/// Attach the execution facts to a response frame, success or failure.
func annotated(_ frame: (Bool, Any?, [String: Any?]?), execution: [String: Any])
    -> (Bool, Any?, [String: Any?]?)
{
    var (ok, result, error) = frame
    if ok {
        var payload = (result as? [String: Any]) ?? [:]
        payload["execution"] = execution
        result = payload
    } else {
        var failure = error ?? bridgeError(code: "ACTION_FAILED", message: "The computer action could not be executed.")
        failure["execution"] = execution
        error = failure
    }
    return (ok, result, error)
}

/// `action.execute` with the operation ledger around it.
///
/// * A response always says whether the action was handed to the machine
///   (`execution.executed`) and its outcome: `not_executed` (refused before
///   anything ran — safe to send again), `succeeded` or `failed`.
/// * With an `op_id`, an executed outcome is recorded; resending the SAME id
///   for the SAME action replays it (`replayed: true`) and never runs it
///   again; the same id for a different action is refused.
func executeActionWithLedger(arguments: [String: Any]) -> (Bool, Any?, [String: Any?]?) {
    var opID: String?
    if let raw = arguments["op_id"], !(raw is NSNull) {
        guard let text = raw as? String, bridgeValidOperationID(text) else {
            return annotated((false, nil, bridgeError(
                code: "CAPABILITY_UNSUPPORTED", message: "op_id must be 8-80 characters of [A-Za-z0-9_-].",
                detail: "reason=invalid_op_id")),
                execution: ["executed": false, "outcome": BridgeExecutionOutcome.notExecuted.rawValue,
                            "instance_id": helperInstanceID, "replayed": false])
        }
        opID = text
    }
    let kind = (arguments["kind"] as? String) ?? ""
    var params = (arguments["params"] as? [String: Any]) ?? [:]
    if params["context_id"] == nil, let contextID = arguments["context_id"] as? String { params["context_id"] = contextID }
    let fingerprint = bridgeActionFingerprint(kind: kind, contextID: params["context_id"] as? String, params: params)
    if let opID {
        switch operationLedger.lookup(principal: currentPrincipal, opID: opID, fingerprint: fingerprint) {
        case .replay(let outcome, let frame):
            log("OPERATION_REPLAYED op=\(opID) kind=\(kind) outcome=\(outcome.rawValue)")
            return annotated((frame.ok, frame.result, frame.error), execution: [
                "executed": true, "outcome": outcome.rawValue, "op_id": opID,
                "instance_id": helperInstanceID, "replayed": true])
        case .conflict:
            return annotated((false, nil, bridgeError(
                code: "OPERATION_ID_CONFLICT",
                message: "This op_id was already used for a different action; nothing was executed.",
                detail: "reason=op_id_conflict")),
                execution: ["executed": false, "outcome": BridgeExecutionOutcome.notExecuted.rawValue,
                            "op_id": opID, "instance_id": helperInstanceID, "replayed": false])
        case .new:
            break
        }
    }
    var executed = false
    let frame = executeActionRequest(arguments: arguments, executed: &executed)
    let outcome = bridgeExecutionOutcome(executed: executed, ok: frame.0)
    var execution: [String: Any] = [
        "executed": executed, "outcome": outcome.rawValue,
        "instance_id": helperInstanceID, "replayed": false,
    ]
    if let opID { execution["op_id"] = opID }
    if let contextID = requestContext?.id { execution["context_id"] = contextID }
    let answer = annotated(frame, execution: execution)
    if executed, let opID {
        operationLedger.record(
            principal: currentPrincipal, opID: opID, fingerprint: fingerprint, outcome: outcome,
            payload: BridgeLedgerFrame(ok: answer.0, result: answer.1, error: answer.2),
            at: Date().timeIntervalSince1970)
    }
    return answer
}

/// What happened to one operation id of the caller. `unknown` is a real
/// answer: an id the ledger never recorded may still have run (the helper
/// restarted, or the request is still queued), so it is never `not_executed`.
func actionOutcome(_ arguments: [String: Any]) -> (Bool, Any?, [String: Any?]?) {
    guard let opID = arguments["op_id"] as? String, bridgeValidOperationID(opID) else {
        return (false, nil, bridgeError(code: "CAPABILITY_UNSUPPORTED", message: "action.outcome needs a valid op_id.",
                                        detail: "reason=invalid_op_id"))
    }
    if let record = operationLedger.outcome(principal: currentPrincipal, opID: opID) {
        return (true, [
            "op_id": opID, "known": true, "outcome": record.outcome.rawValue,
            "ok": record.payload.ok, "at": record.at, "instance_id": helperInstanceID,
        ], nil)
    }
    let inFlight = operationIsPending(opID)
    return (true, [
        "op_id": opID, "known": false,
        "outcome": inFlight ? "in_progress" : BridgeExecutionOutcome.unknown.rawValue,
        "instance_id": helperInstanceID,
        "reason": inFlight ? "in_progress" : "not_recorded_by_this_instance",
    ], nil)
}

// MARK: - Observation operations with contexts

func captureScreenRequest(_ arguments: [String: Any]) -> (Bool, Any?, [String: Any?]?) {
    let app = (arguments["app"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let title = (arguments["window_title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasWindowTarget = !(title ?? "").isEmpty
    let resolved = effectiveMode(arguments)
    if let refusal = resolved.refusal {
        return (false, nil, refusalFrame(refusal))
    }
    // One authorized window at a time. Under per-app authorization a
    // display capture would include windows this deployment never granted,
    // so it is refused rather than special-cased.
    if let refusal = bridgeAuthorizedCaptureDecision(
        mode: resolved.mode, hasWindowTarget: hasWindowTarget,
        authorizationLoaded: authorization.loaded).refusal {
        return (false, nil, refusalFrame(refusal))
    }
    // The capture is tied to the caller's context generation (its own; a
    // foreign context id is refused like an unknown one).
    let context: BridgeContextRecord<BridgeLiveHandle>
    switch contextIDArgument(arguments).flatMap({
        workspace.context(principal: currentPrincipal, id: $0, now: Date().timeIntervalSince1970)
    }) {
    case .failure(let refusal): return (false, nil, refusalFrame(refusal))
    case .success(let found): context = found
    }
    let outcome = captureWindowBase64(
        app: (app?.isEmpty ?? true) ? nil : app, title: title ?? "", snapshot: context.generation)
    if let refusal = outcome.refusal {
        return (false, nil, refusalFrame(refusal))
    }
    guard let b64 = outcome.image else {
        return (false, nil, bridgeError(
            code: "ACTION_FAILED",
            message: "The window could not be captured.",
            detail: outcome.failure ?? ""))
    }
    var result: [String: Any] = ["screenshot_base64": b64, "screenshot_scope": "window"]
    if var identity = outcome.identity {
        if !context.legacy {
            identity["context_id"] = context.id
            identity["context_label"] = context.label
        }
        result["view_identity"] = identity
    }
    return (true, result, nil)
}

func streamStartRequest(_ arguments: [String: Any]) -> (Bool, Any?, [String: Any?]?) {
    reapIdleContexts()
    var app = (arguments["app"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let title = ((arguments["window_title"] as? String) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    // `window_id` is preferred when the client has it: a title follows the
    // active tab and a stream keyed on it dies on the next navigation.
    var requestedWindowID = (arguments["window_id"] as? Int)
        ?? (arguments["window_id"] as? NSNumber)?.intValue
    var expectedBundle = (arguments["expected_bundle"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    var expectedPID = (arguments["expected_pid"] as? NSNumber)?.int32Value
    let resolved = effectiveMode(arguments)
    if let refusal = resolved.refusal {
        return (false, nil, refusalFrame(refusal))
    }
    // The slot: a context the caller owns (bound to it: its identity is the
    // expectation), a client label, or nothing (the 0.3.2 single stream).
    var key: String?
    var context: BridgeContextRecord<BridgeLiveHandle>?
    switch contextIDArgument(arguments) {
    case .failure(let refusal): return (false, nil, refusalFrame(refusal))
    case .success(let contextID?):
        switch workspace.context(principal: currentPrincipal, id: contextID, now: Date().timeIntervalSince1970) {
        case .failure(let refusal): return (false, nil, refusalFrame(refusal))
        case .success(let found): context = found
        }
        key = contextID
        if let identity = context?.identity {
            expectedBundle = expectedBundle ?? identity.bundleID
            expectedPID = expectedPID ?? identity.pid
            if requestedWindowID == nil, title.isEmpty { requestedWindowID = identity.windowID }
            if (app ?? "").isEmpty { app = identity.bundleID }
        } else if let bound = context?.boundBundle {
            expectedBundle = expectedBundle ?? bound
            if (app ?? "").isEmpty { app = bound }
        }
    case .success(nil):
        if let label = arguments["stream_key"] as? String {
            guard bridgeValidStreamKey(label) else {
                return (false, nil, bridgeError(code: "CAPABILITY_UNSUPPORTED",
                                                message: "stream_key must be 1-80 characters of [A-Za-z0-9_-].",
                                                detail: "reason=invalid_stream_key"))
            }
            key = "key:" + label
        }
    }
    // A stream is a capture that keeps happening: the same
    // one-authorized-window rule and the same `.observe` grant apply, and
    // they are decided before any surface is opened.
    if let refusal = bridgeAuthorizedCaptureDecision(
        mode: resolved.mode,
        hasWindowTarget: !title.isEmpty || requestedWindowID != nil,
        authorizationLoaded: authorization.loaded).refusal {
        return (false, nil, refusalFrame(refusal))
    }
    let started = startWindowStream(
        app: (app?.isEmpty ?? true) ? nil : app, title: title, windowID: requestedWindowID,
        key: key, expectedBundle: expectedBundle, expectedPID: expectedPID)
    if let refusal = started.refusal {
        return (false, nil, refusalFrame(refusal))
    }
    guard var result = started.result else {
        return (false, nil, bridgeError(
            code: "ACTION_FAILED",
            message: "The window stream could not be started.",
            detail: started.failure ?? ""))
    }
    if let context {
        workspace.bindStream(id: context.id, streamID: result["stream_id"] as? String)
        result["context_id"] = context.id
        result["context_label"] = context.label
    }
    return (true, result, nil)
}

/// The stream an operation names: `stream_id`, else the stream bound to
/// `context_id`, else (neither) the caller's 0.3.2 stream.
func streamIDArgument(_ arguments: [String: Any]) -> Result<String?, BridgePolicyRefusal> {
    if let raw = arguments["stream_id"], !(raw is NSNull) {
        guard let text = raw as? String, bridgeValidOpaqueID(text, prefix: "str") else {
            return .failure(BridgePolicyRefusal(code: "STREAM_UNKNOWN", message: "No such stream for this client.",
                                                detail: "reason=stream_unknown"))
        }
        return .success(text)
    }
    switch contextIDArgument(arguments) {
    case .failure(let refusal): return .failure(refusal)
    case .success(nil): return .success(nil)
    case .success(let contextID?):
        switch workspace.context(principal: currentPrincipal, id: contextID, now: Date().timeIntervalSince1970) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let record):
            guard let streamID = record.streamID else {
                return .failure(BridgePolicyRefusal(code: "STREAM_UNKNOWN", message: "This context has no stream.",
                                                    detail: "reason=context_has_no_stream"))
            }
            return .success(streamID)
        }
    }
}

/// One `action.execute`, unchanged in its checks and their order since 0.3.2,
/// now resolving element handles inside the caller's context. `executed`
/// becomes true exactly when the action is handed to the machine, so the
/// caller can name the outcome (`not_executed` vs `succeeded`/`failed`).
func executeActionRequest(
    arguments: [String: Any], executed: inout Bool
) -> (Bool, Any?, [String: Any?]?) {
    guard let kind = arguments["kind"] as? String, !kind.isEmpty else {
        return (false, nil, bridgeError(code: "CAPABILITY_UNSUPPORTED", message: "The action has no kind."))
    }
    let rawParams = arguments["params"]
    guard rawParams == nil || rawParams is [String: Any] else {
        return (false, nil, bridgeError(code: "CAPABILITY_UNSUPPORTED", message: "The action params are invalid."))
    }
    var params = (rawParams as? [String: Any]) ?? [:]
    // The context may travel beside the params (as `observe` takes it) or
    // inside them (beside the snapshot and element id it qualifies).
    if params["context_id"] == nil, let contextID = arguments["context_id"] as? String {
        params["context_id"] = contextID
    }
    guard allowedActions.contains(kind) else {
        return (false, nil, bridgeError(code: "CAPABILITY_UNSUPPORTED", message: "Unsupported action: \(kind)"))
    }
    // Policy BEFORE anything touches the machine: a refused action must
    // leave no trace on the person's session, not even a click that is
    // then reported as forbidden.
    let resolved = effectiveMode(arguments)
    if let refusal = resolved.refusal {
        log("refused \(kind) invalid policy")
        return (false, nil, refusalFrame(refusal))
    }
    let mode = resolved.mode
    if let refusal = bridgeGlobalInputDecision(
        kind: kind, mode: mode, authorizationLoaded: authorization.loaded).refusal {
        log("refused \(kind) policy=\(mode.rawValue)")
        return (false, nil, refusalFrame(refusal))
    }
    // Authorization is decided BEFORE the action: a refused target must not
    // be touched, and the refusal must say which grant was missing.
    if let refusal = actionAuthorizationRefusal(kind: kind, params: params) {
        log("refused \(kind) authorization: \(refusal.detail)")
        return (false, nil, refusalFrame(refusal))
    }
    if let refusal = elementPreconditions(kind: kind, params: params, mode: mode) {
        log("refused \(kind) stale-or-expired observation")
        return (false, nil, refusalFrame(refusal))
    }
    if let refusal = browserPreconditions(kind: kind, params: params, mode: mode) {
        log("refused \(kind) browser precondition: \(refusal.detail)")
        return (false, nil, refusalFrame(refusal))
    }
    // Measure the invariant around EVERY executed action, success or
    // failure, and sample DURING it: a before/after pair cannot see a
    // window that raises itself and drops back.
    let targetBundle = actionTargetBundle(kind: kind, params: params)
    if let refusal = elementChromeRefusal(kind: kind, params: params, mode: mode) {
        log("refused \(kind) window chrome")
        return (false, nil, refusalFrame(refusal))
    }
    // The latch is persistent and independent of the mode a request asks
    // for: a target that breached stays suspended until CMM Console rearms
    // it. A latch file that cannot be trusted suspends ALL control.
    let isControl = bridgeActionClass(kind: kind) == .accessibility
        && kind != "wait" && kind != "finish"
    if let refusal = bridgeLatchRefusal(
        load: breachLatch, targetBundle: targetBundle, isControl: isControl, mode: mode) {
        log("refused \(kind) breach latch: \(refusal.detail)")
        return (false, nil, refusalFrame(refusal))
    }
    let actionClass = bridgeActionClass(kind: kind) ?? .accessibility
    let origin = ProcessInfo.processInfo.systemUptime
    let before = currentEnvironment(origin: origin)
    let sampler = InterferenceSampler(origin: origin)
    sampler.start()
    // From here on the action has been handed to the machine: whatever the
    // answer, its outcome is `succeeded` or `failed`, never `not_executed`.
    executed = true
    let result = executeAction(kind: kind, params: params)
    // AXPerformAction returns before the window server has acted on what
    // it triggered. Keep measuring for a bounded settle window instead of
    // stopping at return — stopping at return is how a press that made
    // the target frontmost was recorded as `untouched`.
    if kind != "wait" && kind != "finish" {
        let window = bridgeSettleWindow(actionClass: actionClass)
        let returnedAt = ProcessInfo.processInfo.systemUptime
        while bridgeShouldKeepSettling(
            window: window,
            elapsed: ProcessInfo.processInfo.systemUptime - returnedAt,
            sinceLastChange: sampler.sinceLastChange) {
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
    let samples = sampler.stop()
    let after = currentEnvironment(origin: origin)
    let report = bridgeInterferenceReport(
        before: before, after: after, samples: samples,
        actionClass: actionClass, mode: mode,
        targetBundle: targetBundle)
    if report.breach {
        // The action ran; the promise did not hold. FAIL CLOSED and STOP:
        // the call is a failure (never success with a footnote) and the
        // target is latched, durably and audited. Nothing is activated to
        // "undo" it: re-activating the person's previous application would
        // be a second interference caused by Computer Use.
        log("INTERFERENCE_BREACH kind=\(kind) verdict=\(report.verdict.rawValue) transient=\(report.transientFocusChanges) restored=\(report.restored) before=\(report.frontmostBefore) after=\(report.frontmostAfter) target_front_at_ms=\(report.targetFrontAtMs.map { String($0) } ?? "-") observed_for_ms=\(report.observedForMs)")
        var breachID = ""
        if let targetBundle {
            let record = BridgeBreachRecord(
                id: UUID().uuidString.lowercased(), targetBundle: targetBundle,
                targetName: (params["element_id"] as? NSNumber)
                    .flatMap { requestHandle($0.intValue)?.context.appName }
                    ?? requestBrowserTarget?.appName ?? "",
                clientID: currentClient?.clientID ?? "", kind: kind, policy: mode.rawValue,
                at: Date().timeIntervalSince1970, verdict: report.verdict.rawValue,
                focusBecameTarget: report.focusBecameTarget,
                windowRaisedOverPerson: report.windowRaisedOverPerson,
                targetFrontAtMs: report.targetFrontAtMs)
            breachID = record.id
            // An invalid latch already suspends everything; keep it invalid.
            if var state = breachLatch.state {
                state.latch(record)
                breachLatch = .loaded(state)
                let durable = saveBreachLatch(state)
                appendBreachAudit(bridgeBreachAuditEntry(
                    event: durable ? "latched" : "latch_write_failed",
                    at: record.at, record: record, actorClientID: record.clientID,
                    actorSigningID: currentPeer?.identifier, reason: nil))
            }
        }
        var error = bridgeError(
            code: "INTERFERENCE_BREACH",
            message: "The action brought the target application in front of the person's work in a mode that promised no interference. Control of it is suspended until CMM Console rearms it.",
            detail: "policy=\(mode.rawValue);reason=breach;kind=\(kind);action_ok=\(result["ok"] as? Bool == true)" + (breachID.isEmpty ? "" : ";breach_id=\(breachID)"))
        error["interference"] = report.dictionary()
        return (false, nil, error)
    }
    if report.requiresReobserve {
        // The PERSON brought the target in front while this action ran:
        // not a breach, nothing is latched. But the screen is no longer
        // what the element handles described, so the generation is retired
        // exactly as `observation.release` does: the next action on an old
        // handle is refused (`reason=released`, no age) before any UI is
        // touched, until the client observes again. Never retried here.
        // Only the AFFECTED context: the one whose handle the action used,
        // or — for an action without a handle — the caller's contexts on
        // the target application plus its 0.3.2 default.
        let affected = requestContext.map { [$0.id] }
            ?? workspace.list(principal: currentPrincipal)
                .filter { $0.legacy || $0.identity?.bundleID == targetBundle }.map { $0.id }
        for contextID in affected {
            invalidateObservation(contextID: contextID, reason: "user_takeover")
        }
        log("USER_TAKEOVER kind=\(kind) attribution=\(report.focusChangeAttribution.rawValue) input=\(report.humanInputKind?.rawValue ?? "-") age_ms=\(report.humanInputAgeMs.map { String($0) } ?? "-") target_front_at_ms=\(report.targetFrontAtMs.map { String($0) } ?? "-")")
    }
    if result["unsupported"] as? Bool == true {
        var error = bridgeError(
            code: "CAPABILITY_UNSUPPORTED",
            message: result["message"] as? String ?? "The action is not supported for this element.",
            detail: "policy=\(mode.rawValue);kind=\(kind);" + (result["detail"] as? String ?? ""))
        error["interference"] = report.dictionary()
        if let scroll = result["scroll"] { error["scroll"] = scroll }
        if let setValue = result["set_value"] { error["set_value"] = setValue }
        return (false, nil, error)
    }
    if result["ok"] as? Bool == true {
        var payload = result
        payload["interference"] = report.dictionary()
        return (true, payload, nil)
    }
    // A failed action still reports what it did to the session: the ledger
    // is evidence, not a decoration on success.
    var error = bridgeError(
        code: kind == "app.open" ? "COMPUTER_TARGET_UNAVAILABLE" : "ACTION_FAILED",
        message: result["message"] as? String ?? "The computer action could not be executed.",
        detail: (result["detail"] as? String).map { "policy=\(mode.rawValue);kind=\(kind);" + $0 } ?? "")
    error["interference"] = report.dictionary()
    if let scroll = result["scroll"] { error["scroll"] = scroll }
    if let setValue = result["set_value"] { error["set_value"] = setValue }
    return (false, nil, error)
}

func dispatch(operation: String, arguments: [String: Any]) -> (Bool, Any?, [String: Any?]?) {
    switch operation {
    case "bridge.ping":
        return (true, [
            "bridge": bridgeName,
            "protocol": bridgeVersion,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "bundle_id": Bundle.main.bundleIdentifier ?? "",
            "policy": deploymentMode.rawValue,
            "authorization": [
                "loaded": authorization.loaded,
                "apps": authorization.grants.count,
                "default": "deny",
                "client_authorization": authorization.clientAuthorization.rawValue,
        // Who the helper believes is asking on THIS connection. Diagnostics for
        // an administrator, never an authorization input.
        "client": [
            "authenticated": currentClient != nil,
            "client_id": currentClient?.clientID ?? "",
        ],
                "clients": authorization.clients.count,
            ],
            // Who the helper believes it is talking to, for THIS connection.
            "client": [
                "authenticated": currentClient != nil,
                "client_id": currentClient?.clientID ?? "",
            ],
            "capabilities": [
                "background_actions": true,
                "window_capture": true,
                "observation_targets_app": true,
                "snapshot_generations": true,
                "interference_report": true,
                "app_authorization": true,
                "scoped_observation": true,
                "failure_interference_report": true,
                "transient_sampling": true,
                // The ledger keeps sampling after the action returns
                // (bridgeSettleWindow) and reads the AX focused app and the
                // window order, not only the cached frontmost.
                "post_action_settle": true,
                "breach_fail_closed": true,
                "window_chrome_guard": true,
                "ax_scroll": true,
                "ax_tree_enrichment": true,
                // Breaches latch durably (survive restart) and are cleared only
                // by an audited `breach.rearm` from an admin client.
                "breach_latch": "persistent",
                "breach_rearm": true,
                // A live window stream (ScreenCaptureKit SCStream). The host
                // uses this to decide between the mirror and the per-request
                // capture fallback instead of discovering it by failing.
                "window_stream": true,
                // The v2 client dimension exists in THIS build. Without this
                // flag a host can only infer it from a loaded policy, which is
                // absent exactly when the answer matters most: "no policy yet"
                // must never read as "this helper cannot identify clients".
                "client_authentication": true,
                // Requirements can be compiled and evaluated on demand, so a
                // host validates before writing instead of after failing.
                "requirement_validation": true,
                // 0.3.3 Multi-App Workspace: per-client contexts with their
                // own generations and handles, up to two concurrent streams,
                // per-stream health/recovery, and the operation ledger.
                "workspace": [
                    "contract": workspaceContractName,
                    "contract_version": workspaceContractVersion,
                    "max_contexts_per_client": workspace.limits.maxContextsPerPrincipal,
                    "max_streams": 2,
                    "document_identity": true,
                    "operation_ledger": true,
                    "stream_recovery": true,
                ] as [String: Any],
                // F-09: browser windows/tabs/page lifecycle and verified
                // downloads (contract cmm-computer-use/browser v1).
                "browser": [
                    "contract": "cmm-computer-use/browser",
                    "contract_version": 1,
                    "tabs": true, "page_lifecycle": true, "select_tab": true,
                    "save_dialog": true, "window_targeting": true,
                ] as [String: Any],
                "downloads": [
                    "verified": true, "expectations": true, "partial_formats": ["webkit_bundle", "crdownload", "part"],
                    "checksum_on_request": true,
                ] as [String: Any],
            ],
            "requirement_contract": bridgeRequirementContractVersion,
            // Random per process: a change means the helper restarted and
            // every context, stream and recorded outcome is gone.
            "instance_id": helperInstanceID,
            // Live-stream diagnostics (no frame, no pixels): counts for every
            // client, details only for the caller's own 0.3.2 stream.
            "window_stream": windowStreamSummary(),
        ], nil)
    case "policy.status":
        return (true, authorizationStatus(), nil)
    case "breach.status":
        // Diagnostics, like policy.status: which targets are suspended and why.
        return (true, breachStatus(), nil)
    case "breach.rearm":
        return breachRearm(arguments: arguments)
    case "policy.requirements.check":
        // Read-only: compiles requirement strings and evaluates them against
        // code objects. It cannot write, reload or grant anything, which is why
        // it is reachable without a client identity — the moment it is needed,
        // no client is authorized yet.
        return requirementsCheck(arguments: arguments)
    case "policy.reload":
        // Re-read the user-owned allowlist. It can only re-apply
        // min(launch flag, file mode), so a reload never widens what the
        // process was launched with.
        let reloaded = loadAuthorizationPolicy()
        authorizationLock.lock()
        authorization = reloaded
        authorizationLock.unlock()
        applyDeploymentModes()
        reloadBreachLatch()
        // A stream is a capture that keeps happening: one whose window the new
        // policy no longer grants to its owner stops now, not at its next frame.
        revalidateWindowStreams { principal in
            reloaded.clients.first { "client:" + $0.clientID == principal.key }
        }
        return (true, authorizationStatus(), nil)
    case "permissions.status":
        return (true, permissionStatus(), nil)
    case "permissions.request_accessibility":
        return (true, requestAccessibility(), nil)
    case "permissions.request_screen_recording":
        return (true, requestScreenRecording(), nil)
    case "apps.list":
        if let refusal = clientRequiredRefusal(operation: "apps.list") {
            return (false, nil, refusalFrame(refusal))
        }
        return (true, appsList(), nil)
    case "observation.describe":
        let include = (arguments["include_screenshot"] as? Bool) ?? false
        let target = arguments["app"] as? String
        let resolved = effectiveMode(arguments)
        if let refusal = resolved.refusal {
            return (false, nil, refusalFrame(refusal))
        }
        reapIdleContexts()
        let contextID: String?
        switch contextIDArgument(arguments) {
        case .failure(let refusal): return (false, nil, refusalFrame(refusal))
        case .success(let id): contextID = id
        }
        let (result, refusal) = describe(
            includeScreenshot: include, targetApp: target, mode: resolved.mode,
            includeDiagnostics: (arguments["include_ax_diagnostics"] as? Bool) ?? false,
            elementFilter: (arguments["element_filter"] as? String) ?? "",
            contextID: contextID,
            windowID: (arguments["window_id"] as? NSNumber)?.intValue)
        if let refusal {
            return (false, nil, refusalFrame(refusal))
        }
        guard let result else {
            return (false, nil, bridgeError(code: "ACTION_FAILED", message: "The observation could not be completed."))
        }
        return (true, result, nil)
    case "observation.release":
        let released: (result: [String: Any]?, refusal: BridgePolicyRefusal?)
        switch contextIDArgument(arguments) {
        case .failure(let refusal): released = (nil, refusal)
        case .success(let id): released = releaseObservation(contextID: id)
        }
        if let refusal = released.refusal { return (false, nil, refusalFrame(refusal)) }
        return (true, released.result ?? [:], nil)
    case "observation.capture_screen":
        return captureScreenRequest(arguments)
    case "observation.stream_start":
        return streamStartRequest(arguments)
    case "observation.stream_stop":
        // Idempotent: stopping nothing (or something already stopped) is a
        // success, so a client can tear down on every exit path. Only the
        // caller's own streams can be named.
        switch streamIDArgument(arguments).flatMap({ stopWindowStream(id: $0) }) {
        case .failure(let refusal): return (false, nil, refusalFrame(refusal))
        case .success(let result):
            if let streamID = result["stream_id"] as? String,
               let bound = workspace.list(principal: currentPrincipal).first(where: { $0.streamID == streamID }) {
                workspace.bindStream(id: bound.id, streamID: nil)
            }
            return (true, result, nil)
        }
    case "observation.stream_frame":
        return streamFrameResponse(arguments, principal: currentPrincipal)
    case "observation.stream_status":
        switch streamIDArgument(arguments).flatMap({ windowStreamStatus(id: $0) }) {
        case .failure(let refusal): return (false, nil, refusalFrame(refusal))
        case .success(let result): return (true, result, nil)
        }
    case "observation.stream_recover":
        switch streamIDArgument(arguments) {
        case .failure(let refusal): return (false, nil, refusalFrame(refusal))
        case .success(nil):
            return (false, nil, bridgeError(code: "STREAM_UNKNOWN", message: "stream_recover names one stream.",
                                            detail: "reason=stream_unknown"))
        case .success(let streamID?):
            switch recoverWindowStream(id: streamID) {
            case .failure(let refusal): return (false, nil, refusalFrame(refusal))
            case .success(let result): return (true, result, nil)
            }
        }
    case "workspace.status":
        return workspaceStatus()
    case "workspace.context_create":
        return contextCreate(arguments)
    case "workspace.context_list":
        reapIdleContexts()
        return (true, [
            "contexts": workspace.list(principal: currentPrincipal).map { contextDescription($0, mode: deploymentMode) },
            "limits": workspaceLimits(),
            "instance_id": helperInstanceID,
        ], nil)
    case "workspace.context_status":
        return contextStatus(arguments)
    case "workspace.context_close":
        return contextClose(arguments)
    case "browser.state":
        return browserStateRequest(arguments)
    case "download.expect":
        return downloadExpectRequest(arguments)
    case "download.status":
        return downloadStatusRequest(arguments)
    case "download.list":
        return downloadListRequest()
    case "download.forget":
        return downloadForgetRequest(arguments)
    case "action.outcome":
        return actionOutcome(arguments)
    case "action.execute":
        return executeActionWithLedger(arguments: arguments)
    default:
        return (false, nil, bridgeError(code: "CAPABILITY_UNSUPPORTED", message: "Unknown operation: \(operation)"))
    }
}

// MARK: - Main loop

func send(_ object: [String: Any?], id: Any) {
    // Strip nil optionals for a clean frame.
    var clean: [String: Any] = ["version": bridgeVersion, "id": id, "ok": object["ok"] as Any]
    if let r = object["result"] { clean["result"] = r }
    if let e = object["error"] { clean["error"] = e }
    if let data = try? JSONSerialization.data(withJSONObject: clean, options: []),
       let line = String(data: data, encoding: .utf8)
    {
        print(line)
        fflush(stdout)
    } else {
        log("FATAL: could not encode response for id \(id)")
    }
}

// NOTE: stdin is read one byte at a time with getchar(), NOT with
// FileHandle.read(upToCount:) — the latter blocks until its count is met or
// EOF, which deadlocks a long-lived pipe where EOF never comes. A byte-wise
// reader blocks only for the next byte and enforces the bound incrementally.

enum LineRead {
    case line(String)
    case eof
    case tooLong
}

func readRequestLine() -> LineRead {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(1024)
    var drained = 0
    var overCap = false
    while true {
        let c = getchar()
        if c == EOF {
            if overCap { return .tooLong }
            if bytes.isEmpty { return .eof }
            break
        }
        if c == 0x0A { break }
        if overCap {
            drained += 1
            if drained > maxRequestBytes * 4 {
                // Absurd line without a newline: drop the connection rather
                // than buffer forever.
                return .tooLong
            }
            continue
        }
        if bytes.count >= maxRequestBytes {
            overCap = true
            bytes.removeAll(keepingCapacity: false)
            continue
        }
        bytes.append(UInt8(truncatingIfNeeded: c))
    }
    if overCap { return .tooLong }
    return .line(String(bytes: bytes, encoding: .utf8) ?? "")
}

func handleLine(_ text: String, sendTo fd: Int32?, peer: BridgePeerCode? = nil) {
    // sendTo == nil writes the response to stdout (stdio mode); otherwise to
    // the serving socket connection.
    func respond(_ object: [String: Any?], id rid: Any) {
        if let fd = fd {
            sendSocket(object, id: rid, fd: fd)
        } else {
            send(object, id: rid)
        }
    }
    if text.isEmpty { return }
    guard let data = text.data(using: .utf8) else {
        respond(["ok": false, "result": nil,
              "error": ["code": "CAPABILITY_UNSUPPORTED", "message": "Malformed request: not a JSON object."]],
             id: NSNull())
        return
    }
    guard let json = try? JSONSerialization.jsonObject(with: data, options: []),
          let req = json as? [String: Any]
    else {
        respond(["ok": false, "result": nil,
              "error": ["code": "CAPABILITY_UNSUPPORTED", "message": "Malformed request: not a JSON object."]],
             id: NSNull())
        return
    }
    let rid: Any = req["id"] ?? NSNull()
    guard (req["version"] as? Int) == bridgeVersion,
          let operation = req["operation"] as? String, !operation.isEmpty
    else {
        respond(["ok": false, "result": nil,
              "error": ["code": "CAPABILITY_UNSUPPORTED", "message": "Malformed request: version must be 1 with a named operation."]],
             id: rid)
        return
    }
    let rawArgs = req["arguments"]
    if rawArgs != nil, !(rawArgs is [String: Any]) {
        respond(["ok": false, "result": nil,
              "error": ["code": "CAPABILITY_UNSUPPORTED", "message": "Malformed request: arguments must be an object."]],
             id: rid)
        return
    }
    let args = (rawArgs as? [String: Any]) ?? [:]
    // Frame reads are served outside the dispatch lock on purpose: the sink
    // owns its own lock and a capture or an action can hold the global one for
    // hundreds of milliseconds, which would freeze the mirror precisely while
    // the machine is doing something worth watching. The frame still belongs
    // to one principal: resolved here from the verified peer, against a policy
    // read under its own lock.
    if operation == "observation.stream_frame" {
        authorizationLock.lock()
        let policy = authorization
        authorizationLock.unlock()
        let principal = requestPrincipal(peer: peer, client: bridgeMatchingClient(peer, policy: policy))
        let (ok, result, error) = streamFrameResponse(args, principal: principal)
        respond(["ok": ok, "result": result, "error": error], id: rid)
        return
    }
    // An operation id still in flight (its first send is queued behind the
    // lock on another connection) is refused, never executed beside it.
    var pendingOpID: String?
    if operation == "action.execute", let opID = args["op_id"] as? String, bridgeValidOperationID(opID) {
        guard beginPendingOperation(opID) else {
            respond(["ok": false, "result": nil, "error": [
                "code": "OPERATION_IN_PROGRESS",
                "message": "This op_id is still being executed; ask action.outcome instead of resending.",
                "detail": "reason=op_in_progress",
                "execution": ["executed": false, "outcome": BridgeExecutionOutcome.notExecuted.rawValue,
                              "op_id": opID, "instance_id": helperInstanceID, "replayed": false],
            ] as [String: Any]], id: rid)
            return
        }
        pendingOpID = opID
    }
    // Waits poll a read-only status, one locked sample at a time (F-09).
    if operation == "download.wait" || operation == "browser.wait" {
        let (ok, result, error) = waitLoop(operation: operation, arguments: args, peer: peer)
        respond(["ok": ok, "result": result, "error": error], id: rid)
        return
    }
    let (ok, result, error) = withRequestState(peer: peer) {
        dispatch(operation: operation, arguments: args)
    }
    if let pendingOpID { endPendingOperation(pendingOpID) }
    respond(["ok": ok, "result": result, "error": error], id: rid)
}

/// Run `body` as ONE request: under `dispatchLock`, with the client, peer and
/// principal of `peer` published for its authorization decisions, and every
/// per-request global cleared afterwards.
///
/// Resolve the client for this request under the lock, then dispatch. Every
/// authorization decision reads `currentClient`, so the two must not be
/// separated: the whole operation runs inside this critical section. The peer
/// is published beside it for the same reason: `policy.status` reports the
/// caller of THIS request, never another connection's. The principal (who
/// owns contexts and streams) is derived from the same two facts.
func withRequestState<T>(peer: BridgePeerCode?, _ body: () -> T) -> T {
    dispatchLock.lock()
    defer { dispatchLock.unlock() }
    currentPeer = peer
    currentClient = bridgeMatchingClient(peer, policy: authorization)
    currentPrincipal = requestPrincipal(peer: peer, client: currentClient)
    let value = body()
    requestContext = nil
    requestBrowserTarget = nil
    currentPrincipal = BridgePrincipal(key: "local", strength: .local)
    currentClient = nil
    currentPeer = nil
    return value
}

// MARK: - Socket serve mode (product transport)
//
// A helper spawned by an unbundled interpreter inherits an unusable TCC
// ancestry (the decision subject becomes the bare interpreter, never the helper
// identity). The PRODUCT path is therefore: a bundled app launches this helper
// with --serve-socket <path>, and clients connect to that Unix socket. Same
// NDJSON protocol, same dispatch, same allowlist — only the rendezvous
// differs. No TCP, no `open`, no FIFOs.

/// The address for `path`, or nil when the path does not fit COMPLETELY in
/// `sun_path` (Shared: `bridgeUnixSocketPathBytes`). Never truncated: a
/// truncated address would bind/connect somewhere other than `path`.
func unixAddr(_ path: String) -> sockaddr_un? {
    guard let bytes = bridgeUnixSocketPathBytes(path) else { return nil }
    var addr = sockaddr_un()
    memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
    addr.sun_family = sa_family_t(AF_UNIX)
    let off = MemoryLayout<sockaddr_un>.offset(of: \.sun_path)!
    guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    bytes.withUnsafeBytes { src in
        withUnsafeMutableBytes(of: &addr) { dst in
            dst.baseAddress!.advanced(by: off).copyMemory(
                from: src.baseAddress!, byteCount: bytes.count)
        }
    }
    return addr
}

func withSockAddr(_ addr: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
    withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saddr in
            body(saddr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

func serveSocket(at path: String) -> Never {
    // Before the probe, the unlink and the bind: a path that does not fit is
    // refused outright; nothing is removed and no truncated socket is created.
    guard var addr = unixAddr(path) else {
        log("FATAL: socket path does not fit in sockaddr_un (\(path.utf8.count) bytes; max \(bridgeUnixSocketPathMaxBytes)): \(path)")
        exit(2)
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        log("FATAL: socket() failed"); exit(2)
    }
    // Single instance per path: if something answers there, it owns it.
    if probeSocket(at: path) {
        log("another helper already serves \(path); exiting")
        exit(0)
    }
    unlink(path)
    let bound = withSockAddr(&addr) { saddr, len in bind(fd, saddr, len) }
    guard bound == 0 else {
        log("FATAL: bind(\(path)) failed: \(String(cString: strerror(errno)))"); exit(2)
    }
    guard listen(fd, 5) == 0 else {
        log("FATAL: listen() failed"); exit(2)
    }
    log("\(bridgeName) protocol v\(bridgeVersion) serving pid=\(ProcessInfo.processInfo.processIdentifier) bundle=\(Bundle.main.bundleIdentifier ?? "?") socket=\(path)")
    while true {
        let client = accept(fd, nil, nil)
        if client < 0 {
            if errno == EINTR { continue }
            log("accept() failed: \(String(cString: strerror(errno)))")
            continue
        }
        // One thread per connection: a long-lived client (the Hub keeps its
        // connection open) must never starve another one. Operations
        // themselves stay serialized by `dispatchLock` so the element table
        // and the window server see one request at a time.
        let thread = Thread { serveConnection(client); close(client) }
        thread.stackSize = 1 << 20
        thread.start()
    }
}

//: Serializes request handling across connection threads. The workspace
//: and every AppKit/AX/Quartz call are single-threaded by contract.
let dispatchLock = NSLock()
//: Guards replacing `authorization` against the frame path, which reads it
//: outside `dispatchLock` to resolve the caller's principal.
let authorizationLock = NSLock()

/// The principal of one request (Shared: ``bridgePrincipal``): the verified
/// client, else the peer's validly signed code identity, else its process;
/// stdio (no peer) is `local`.
func requestPrincipal(peer: BridgePeerCode?, client: BridgeClientGrant?) -> BridgePrincipal {
    bridgePrincipal(
        clientID: client?.clientID, peerIdentifier: peer?.identifier, peerTeamID: peer?.teamID,
        peerValidSignature: peer?.validSignature ?? false, peerPID: peer?.pid)
}

func probeSocket(at path: String) -> Bool {
    // Same validation as serveSocket: never connect to a truncated address.
    guard var addr = unixAddr(path) else { return false }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    let rc = withSockAddr(&addr) { saddr, len in connect(fd, saddr, len) }
    return rc == 0
}

func serveConnection(_ fd: Int32) {
    // Resolve WHO is on this socket exactly once, from the kernel's view of the
    // peer (audit token + code signature), never from anything it sends.
    let peer = bridgePeerCode(fd: fd)
    if let peer {
        log("client peer pid=\(peer.pid) signed=\(peer.validSignature) id=\(peer.identifier ?? "-")")
    } else {
        log("client peer could not be identified; application operations will be refused"
            + " when the policy requires clients")
    }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(1024)
    var overCap = false
    var drained = 0
    var one: UInt8 = 0
    while true {
        let n = recv(fd, &one, 1, 0)
        if n <= 0 { return } // EOF or error ends this connection
        if one == 0x0A {
            if overCap {
                sendSocket(["ok": false, "result": nil,
                      "error": ["code": "CAPABILITY_UNSUPPORTED", "message": "Request exceeds the bounded size."]],
                     id: NSNull(), fd: fd)
            } else {
                handleLine(String(bytes: bytes, encoding: .utf8) ?? "", sendTo: fd, peer: peer)
            }
            bytes.removeAll(keepingCapacity: true)
            overCap = false
            drained = 0
            continue
        }
        if overCap {
            drained += 1
            if drained > maxRequestBytes * 4 { return } // drop abusive connection
            continue
        }
        if bytes.count >= maxRequestBytes {
            overCap = true
            bytes.removeAll(keepingCapacity: false)
            continue
        }
        bytes.append(one)
    }
}

func sendSocket(_ object: [String: Any?], id: Any, fd: Int32) {
    var clean: [String: Any] = ["version": bridgeVersion, "id": id, "ok": object["ok"] as Any]
    if let r = object["result"] { clean["result"] = r }
    if let e = object["error"] { clean["error"] = e }
    guard let data = try? JSONSerialization.data(withJSONObject: clean, options: []),
          var line = String(data: data, encoding: .utf8)?.data(using: .utf8) else {
        log("FATAL: could not encode response for id \(id)")
        return
    }
    line.append(0x0A)
    line.withUnsafeBytes { ptr in
        var sent = 0
        while sent < line.count {
            let n = send(fd, ptr.baseAddress!.advanced(by: sent), line.count - sent, 0)
            if n <= 0 { return }
            sent += n
        }
    }
}

func warmWindowServerConnection() {
    // First window-server touch happens on the main thread, before any
    // connection thread exists. Hygiene only: two supervised instances have
    // been observed frozen on their launch-moment snapshot (frontmost +
    // window order never updating, so every later activate/focus fails
    // honestly-but-wrongly). The watchdog in ComputerBridgeSupervisor is the
    // real mitigation (it relaunches a helper whose view disagrees with the
    // app's live view); this just gives the connection its best start.
    _ = NSWorkspace.shared.frontmostApplication?.localizedName
    _ = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
}

// A client that disconnects mid-response (timeout, cancelled run) must
// never kill the server: without this, writing the reply raises SIGPIPE
// and the helper dies (termination status 13), churning the supervised
// helper and opening unavailable windows for in-flight runs. Ignored, the
// write fails EPIPE instead and sendSocket's `n <= 0` guard ends it cleanly.
signal(SIGPIPE, SIG_IGN)

// Activation policy, declared explicitly. This process runs a C main loop and
// never starts an NSApplication, so AppKit leaves its policy at the default
// for an unmanaged process: `.prohibited`. A prohibited process cannot
// activate ANY other application: NSRunningApplication.activate() returns
// true, AXSetAttributeValue(kAXFrontmost) returns success, and neither ever
// takes effect — the exact defect that made every app.activate and
// window.focus fail. `.accessory` is the policy for an agent that drives
// other apps: it may activate them, and it stays out of the Dock itself.
NSApplication.shared.setActivationPolicy(.accessory)

// MARK: - Launch arguments

/// Parse the launch line.
///
/// `--policy <background|focus|unrestricted>` declares what this process may
/// do to the machine; unknown flags and unknown modes are FATAL rather than
/// ignored, because a typo must never leave a helper running with a policy
/// nobody chose. Absent `--policy` means `background`: the safe default for a
/// new client, declared explicitly by the product's LaunchAgent when it wants
/// the legacy planner surface.
func parseLaunchArguments() -> (
    serveSocket: String?, mode: BridgeInteractionMode, preflightOnly: Bool,
    skipPermissionBootstrap: Bool
) {
    var preflightOnly = false
    var skipPermissionBootstrap = false
    var mode = BridgeInteractionMode.background
    var socketPath: String?
    var index = 1
    let arguments = CommandLine.arguments
    while index < arguments.count {
        switch arguments[index] {
        case "--no-permission-bootstrap":
            // Isolated verification lane. Serving a policy on a temporary socket
            // must not touch TCC, and bootstrapPermissions() can present the
            // system's Accessibility/Screen Recording prompts. This flag skips
            // ONLY that bootstrap: it grants nothing, and every observation or
            // action still fails normally if TCC was never granted.
            guard !skipPermissionBootstrap else {
                log("FATAL: duplicate --no-permission-bootstrap")
                exit(2)
            }
            skipPermissionBootstrap = true
            index += 1
        case "--preflight-only":
            guard !preflightOnly else {
                log("FATAL: duplicate --preflight-only")
                exit(2)
            }
            preflightOnly = true
            index += 1
        case "--policy":
            guard index + 1 < arguments.count,
                  let parsed = BridgeInteractionMode(flag: arguments[index + 1])
            else {
                log("FATAL: --policy needs background|focus|unrestricted")
                exit(2)
            }
            mode = parsed
            index += 2
        case "--policy-file":
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                log("FATAL: --policy-file needs a path")
                exit(2)
            }
            policyFileOverride = arguments[index + 1]
            index += 2
        case "--log-file":
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                log("FATAL: --log-file needs a path")
                exit(2)
            }
            helperLogFile = arguments[index + 1]
            index += 2
        case "--serve-socket":
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                log("FATAL: --serve-socket needs a path")
                exit(2)
            }
            socketPath = arguments[index + 1]
            index += 2
        default:
            log("FATAL: unknown argument")
            exit(2)
        }
    }
    guard !preflightOnly || socketPath == nil else {
        log("FATAL: --preflight-only cannot serve a socket")
        exit(2)
    }
    return (socketPath, mode, preflightOnly, skipPermissionBootstrap)
}

launchMode = launchArguments.mode
authorization = loadAuthorizationPolicy()
applyDeploymentModes()
reloadBreachLatch()
log("policy=\(deploymentMode.rawValue) launch=\(launchMode.rawValue) authorization_apps=\(authorization.grants.count) loaded=\(authorization.loaded)")

warmWindowServerConnection()

let app = NSApplication.shared

if let socketPath = launchArguments.serveSocket {
    // The socket server must NOT own the main thread: AppKit's run loop has
    // to be running on it for this process to be a real window-server
    // participant. Serving from a background queue and giving the main
    // thread to NSApplication is what lets activation requests issued from
    // here actually take effect.
    DispatchQueue.global(qos: .userInitiated).async {
        serveSocket(at: socketPath)
    }
    // Give the listener a moment to bind before announcing readiness, so a
    // client that sees the log can connect without racing the socket.
    Thread.sleep(forTimeInterval: 0.3)
    log("\(bridgeName) protocol v\(bridgeVersion) ready pid=\(ProcessInfo.processInfo.processIdentifier) bundle=\(Bundle.main.bundleIdentifier ?? "?") policy=\(deploymentMode.rawValue)")
    // Register with the window server, then run AppKit's loop. Without this
    // the process is never finished launching and every activation request
    // (ours and AX's) is accepted and silently dropped.
    app.finishLaunching()
    if launchArguments.skipPermissionBootstrap {
        log("permission bootstrap skipped (--no-permission-bootstrap)")
    } else {
        bootstrapPermissions()
    }
    app.run()
    exit(0)
}

log("\(bridgeName) protocol v\(bridgeVersion) ready pid=\(ProcessInfo.processInfo.processIdentifier) bundle=\(Bundle.main.bundleIdentifier ?? "?") policy=\(deploymentMode.rawValue)")

app.finishLaunching()
if launchArguments.skipPermissionBootstrap {
    log("permission bootstrap skipped (--no-permission-bootstrap)")
} else {
    bootstrapPermissions()
}
while true {
    switch readRequestLine() {
    case .eof:
        log("stdin closed; exiting")
        exit(0)
    case .tooLong:
        log("request exceeded the bounded size; rejected")
        send(["ok": false, "result": nil,
              "error": ["code": "CAPABILITY_UNSUPPORTED", "message": "Request exceeds the bounded size."]],
             id: NSNull())
    case .line(let text):
        handleLine(text, sendTo: nil)
    }
}
