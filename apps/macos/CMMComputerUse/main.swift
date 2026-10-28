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
let maxDepth = 12
/// Hard ceiling on nodes visited, so a pathological tree costs bounded time
/// and memory no matter how deep or wide it is.
let maxVisitedNodes = 6_000
/// Fan-out cap per node. 40 truncated real content areas mid-way.
let maxChildrenPerNode = 200
let maxScreenshotBytes = 24_000_000 // ~24MB base64 ceiling for one PNG frame.

let interactiveRoles: Set<String> = [
    "AXButton", "AXTextField", "AXTextArea", "AXSecureTextField",
    "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuItem",
    "AXLink", "AXTab", "AXSlider", "AXSwitch",
]

let allowedActions: Set<String> = [
    "app.open", "app.activate", "window.focus",
    "ui.press", "ui.set_value",
    "keyboard.type", "keyboard.shortcut",
    "pointer.click", "pointer.scroll",
    "wait", "finish",
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

// MARK: - Element table (live AX refs stay in-process across requests)

// Single-threaded by construction (one synchronous dispatch loop); the only
// concurrent scope (screenshot Task) touches only its Sendable box.
nonisolated(unsafe) var elementTable: [Int: AXUIElement] = [:]
nonisolated(unsafe) var elementRoles: [Int: String] = [:]
/// What each handle is bound to (application, process, window). Cleared with
/// the element table; re-validated before every action.
nonisolated(unsafe) var elementContexts: [Int: BridgeElementContext] = [:]

// MARK: - Interaction policy (shared rules in ../Shared/ComputerUsePolicy.swift)

/// The mode this helper was LAUNCHED with. A request may narrow it, never
/// widen it (``bridgeEffectiveMode``). Declared by ``--policy``, reported by
/// `bridge.ping`, and printed on stderr at start so `launchctl print` and the
/// log agree about what this process is allowed to do.
nonisolated(unsafe) var deploymentMode: BridgeInteractionMode = .background

/// Generation of the element table. Every `observation.describe` produces a
/// new one, so a handle from an older observation is refused instead of being
/// resolved against a newer one (``bridgeSnapshotRefusal``).
nonisolated(unsafe) var observationGeneration = 0
nonisolated(unsafe) var observationCapturedAt: Double = 0

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

/// What the machine looks like right now, as far as interference cares.
func currentEnvironment() -> BridgeEnvironment {
    let front = NSWorkspace.shared.frontmostApplication
    let cursor = cursorLocation()
    return BridgeEnvironment(
        frontmostApp: front?.localizedName ?? "",
        frontmostBundle: front?.bundleIdentifier ?? "",
        cursorX: Double(cursor.x),
        cursorY: Double(cursor.y))
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

/// The loaded allowlist. `denyAll` until a valid file is read: a missing or
/// malformed policy denies every target instead of falling back to TCC's
/// process-wide grant.
nonisolated(unsafe) var authorization: BridgeAuthorizationPolicy =
    .denyAll(source: "")

func loadAuthorizationPolicy() -> BridgeAuthorizationPolicy {
    let path = policyFilePath()
    guard let data = FileManager.default.contents(atPath: path) else {
        log("AUTHORIZATION: no policy at \(path); every application is denied")
        return .denyAll(source: path)
    }
    guard let policy = BridgeAuthorizationPolicy.parse(data, source: path) else {
        log("AUTHORIZATION: policy at \(path) is malformed; every application is denied")
        return .denyAll(source: path)
    }
    log("AUTHORIZATION: \(policy.grants.count) grant(s) from \(path) mode=\(policy.mode.rawValue)")
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
    /// 2000 samples at ~2 ms covers four seconds; `wait` is capped at 5 s and
    /// no AX primitive takes that long.
    private let maxSamples = 2000

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
                let sample = currentEnvironment()
                self.lock.lock()
                if self.samples.count < self.maxSamples {
                    self.samples.append(sample)
                }
                self.lock.unlock()
                Thread.sleep(forTimeInterval: 0.002)
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

func walk(
    _ element: AXUIElement, into traversal: Traversal, depth: Int,
    owner: BridgeTargetApp, window: AXUIElement?, windowTitle: String
) {
    if depth > maxDepth { return }
    if traversal.visited >= maxVisitedNodes { return }
    // Budgets are per list: running out of controls must not stop content
    // collection, and running out of content must not stop control collection.
    if traversal.elements.count >= maxElements && traversal.content.count >= maxContentNodes {
        return
    }
    traversal.visited += 1

    let role = (axAttr(element, kAXRoleAttribute) as? String) ?? "AXUnknown"
    if interactiveRoles.contains(role), traversal.elements.count < maxElements {
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
        elementTable[elementID] = element
        elementRoles[elementID] = role
        // What this handle is allowed to touch, captured now and re-checked
        // before any action: the application, its process, and the window the
        // element was found in.
        elementContexts[elementID] = BridgeElementContext(
            pid: owner.pid, bundleID: owner.bundleID, appName: owner.name,
            windowTitle: windowTitle, window: window)
        traversal.elements.append([
            "element_id": elementID,
            "role": role,
            "title": String(label.prefix(120)),
            "value": String(value.prefix(120)),
            "x": x, "y": y, "width": w, "height": h,
            "pressable": actions.contains("AXPress"),
        ])
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
                scope: .observe
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
    includeScreenshot: Bool, targetApp: String?, mode: BridgeInteractionMode
) -> (result: [String: Any]?, refusal: BridgePolicyRefusal?) {
    let workspace = NSWorkspace.shared
    let frontmost = workspace.frontmostApplication

    var target: NSRunningApplication? = frontmost
    if let request = targetApp?.trimmingCharacters(in: .whitespacesAndNewlines), !request.isEmpty {
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
    let appElement = AXUIElementCreateApplication(owner.pid)
    if AXIsProcessTrusted() {
        windowElement = axElement(appElement, kAXFocusedWindowAttribute)
            ?? axElement(appElement, kAXMainWindowAttribute)
            ?? (axAttr(appElement, kAXWindowsAttribute) as? [AXUIElement])?.first
        if let windowElement {
            captureTitle = (axAttr(windowElement, kAXTitleAttribute) as? String) ?? ""
        }
    }

    // DENY BY DEFAULT: an application the deployment did not authorize is
    // refused here, before a single AX attribute is read from it.
    if let refusal = authorization.decision(
        bundleID: owner.bundleID, name: owner.name,
        windowTitle: captureTitle, scope: .observe
    ).refusal {
        log("observation refused: \(refusal.detail)")
        return (nil, refusal)
    }

    elementTable.removeAll()
    elementRoles.removeAll()
    elementContexts.removeAll()
    observationGeneration += 1
    observationCapturedAt = Date().timeIntervalSince1970

    let traversal = Traversal()
    if AXIsProcessTrusted() {
        // Scope to the window the person is actually looking at. Walking the
        // whole application spends the element budget on a menu bar and on
        // every other open window, so the content of the target window arrived
        // only after its budget was already gone. This is generic: it asks the
        // system which window is focused, whatever the app.
        if let windowElement {
            walk(windowElement, into: traversal, depth: 0,
                 owner: owner, window: windowElement, windowTitle: captureTitle)
        } else {
            walk(appElement, into: traversal, depth: 0,
                 owner: owner, window: nil, windowTitle: captureTitle)
        }
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
            return (buildDescription(
                frontmostName: frontmostName, frontmost: frontmost, target: target,
                traversal: traversal, windowTitle: captureTitle, screenshot: nil, scope: "none",
                error: screenshotError), nil)
        }
        let outcome = captureWindowBase64(app: owner.name, title: captureTitle)
        screenshotB64 = outcome.image
        screenshotScope = outcome.image == nil ? "none" : "window"
        if let refusal = outcome.refusal { screenshotError = refusal.detail }
        else { screenshotError = outcome.failure }
    }

    return (buildDescription(
        frontmostName: frontmostName, frontmost: frontmost, target: target,
        traversal: traversal, windowTitle: captureTitle, screenshot: screenshotB64, scope: screenshotScope,
        error: screenshotError), nil)
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
    screenshot: String?,
    scope: String,
    error: String?
) -> [String: Any] {
    let windows = visibleWindows(frontmostApp: frontmostName, targetPID: target?.processIdentifier)
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
        "snapshot": observationGeneration,
        "captured_at": observationCapturedAt,
    ]
    if matches.count == 1 { result["target_window_id"] = matches[0]["window_id"] }
    if let error { result["screenshot_error"] = error }
    return result
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
    app: String?, title: String
) -> (image: String?, failure: String?, refusal: BridgePolicyRefusal?, identity: [String: Any]?) {
    guard CGPreflightScreenCaptureAccess() else {
        return (nil, "screen_recording_denied", nil, nil)
    }
    let box = WindowCaptureBox()
    let sema = DispatchSemaphore(value: 0)
    let captureSnapshot = observationGeneration
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
                    windowTitle: pair.0.title, scope: .observe
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
func appsList() -> [String: Any] {
    var apps: [[String: Any]] = []
    for candidate in NSWorkspace.shared.runningApplications {
        let name = candidate.localizedName ?? ""
        let bundle = candidate.bundleIdentifier ?? ""
        guard !name.isEmpty || !bundle.isEmpty else { continue }
        guard let grant = authorization.grant(bundleID: bundle, name: name) else { continue }
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
func releaseObservation() -> [String: Any] {
    let released = elementTable.count
    elementTable.removeAll()
    elementRoles.removeAll()
    elementContexts.removeAll()
    observationCapturedAt = 0
    return ["released": released, "snapshot": observationGeneration]
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
    guard let el = elementTable[elementID] else { return nil }
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
            var launched: NSRunningApplication?
            workspace.openApplication(at: appURL, configuration: config) { app, err in
                launched = app
                if err != nil { log("open failed: \(err!)") }
                sema.signal()
            }
            _ = sema.wait(timeout: .now() + 15)
            target = launched
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

func uiSetValue(_ params: [String: Any]) -> [String: Any] {
    guard let (elementID, el) = resolveElement(params: params) else {
        return ["ok": false, "message": "The referenced UI element is no longer on screen."]
    }
    if elementRoles[elementID] == "AXSecureTextField" {
        return ["ok": false, "message": "secure fields are never modified automatically"]
    }
    let text = String((params["text"] as? String ?? "").prefix(maxTextChars))
    let setErr = AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFTypeRef)
    if setErr != .success {
        return ["ok": false, "message": "AXSetValue failed (\(setErr.rawValue))"]
    }
    return ["ok": true, "message": "value set"]
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
    case "ui.set_value": return uiSetValue(params)
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
    guard kind == "ui.press" || kind == "ui.set_value" else { return nil }
    let now = Date().timeIntervalSince1970
    if bridgeObservationExpired(capturedAt: observationCapturedAt, now: now, mode: mode) {
        return BridgePolicyRefusal(
            code: "ACTION_FAILED",
            message: "The observation this element belongs to has expired; observe again.",
            detail: "policy=\(mode.rawValue);reason=expired;age=\(Int(now - observationCapturedAt))s;snapshot=\(observationGeneration)")
    }
    let requested = (params["snapshot"] as? NSNumber)?.intValue
    if let refusal = bridgeSnapshotRefusal(
        current: observationGeneration, requested: requested, mode: mode) {
        return refusal
    }
    guard let rawID = params["element_id"] as? NSNumber,
          let context = elementContexts[rawID.intValue]
    else {
        return BridgePolicyRefusal(
            code: "ACTION_FAILED",
            message: "The referenced UI element is no longer on screen.",
            detail: "policy=\(mode.rawValue);reason=unknown_element")
    }
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
    if let element = elementTable[rawID.intValue] {
        if let stored = context.window, let current = axElement(element, kAXWindowAttribute),
           !CFEqual(current, stored) {
            return BridgePolicyRefusal(
                code: "ACTION_FAILED",
                message: "The window this element belongs to has been replaced.",
                detail: "policy=\(mode.rawValue);reason=window_changed;pid=\(context.pid)")
        }
        if let window = axElement(element, kAXWindowAttribute),
           let title = axAttr(window, kAXTitleAttribute) as? String {
            currentTitle = title
        }
    }
    // Authorization is re-evaluated with the CURRENT window title: a window
    // renamed out of the authorized set must stop being controllable.
    if let refusal = authorization.decision(
        bundleID: context.bundleID, name: context.appName,
        windowTitle: currentTitle, scope: .control
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
    case "ui.press", "ui.set_value":
        guard let id = (params["element_id"] as? NSNumber)?.intValue,
              let context = elementContexts[id]
        else { return nil }
        return context.bundleID
    case "app.activate", "app.open":
        let request = (params["app"] as? String) ?? ""
        return runningApp(named: request)?.bundleIdentifier
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
            bundleID: request, name: request, windowTitle: nil, scope: .control
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
                    windowTitle: title, scope: .control
                ).refusal
            }
        }
        return nil  // no match: the action itself reports "window not found"
    default:
        return nil
    }
}

/// The cached-frame read, factored out of `dispatch`.
///
/// The socket path serves this WITHOUT the global dispatch lock. It touches no
/// AppKit, AX or window-server resource — only the stream sink's own lock — and
/// that lock is held for a capture or an action for hundreds of milliseconds.
/// Queueing the mirror behind those would freeze the viewer exactly while
/// something is happening, which is the one moment it must be live.
func streamFrameResponse(_ arguments: [String: Any]) -> (Bool, Any?, [String: Any?]?) {
    let (frame, failure) = windowStreamFrame()
    guard let frame else {
        // `stream_warming` is the normal first instant of a stream and
        // `stream_not_active` means the host must fall back to capture;
        // the detail says which, instead of one indistinguishable failure.
        return (false, nil, bridgeError(
            code: "ACTION_FAILED",
            message: "No live frame is available.",
            detail: failure ?? ""))
    }
    return (true, [
        "screenshot_base64": frame.jpeg.base64EncodedString(),
        "screenshot_scope": "window",
        "media_type": "image/jpeg",
        "frame_index": frame.frameIndex,
        "frame_age_ms": frame.ageMilliseconds,
        "stale": frame.stale,
        "view_identity": [
            "bundle": frame.bundleID,
            "pid": frame.pid,
            "window": frame.windowTitle,
            "window_id": frame.windowID,
        ],
    ], nil)
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
                // A live window stream (ScreenCaptureKit SCStream). The host
                // uses this to decide between the mirror and the per-request
                // capture fallback instead of discovering it by failing.
                "window_stream": true,
            ],
            // Live-stream diagnostics (no frame, no pixels): whether a stream
            // is open, on which window, and how healthy its delivery is.
            "window_stream": windowStreamStatus(),
        ], nil)
    case "policy.status":
        return (true, authorizationStatus(), nil)
    case "policy.reload":
        // Re-read the user-owned allowlist. It can only re-apply
        // min(launch flag, file mode), so a reload never widens what the
        // process was launched with.
        authorization = loadAuthorizationPolicy()
        applyDeploymentModes()
        return (true, authorizationStatus(), nil)
    case "permissions.status":
        return (true, permissionStatus(), nil)
    case "permissions.request_accessibility":
        return (true, requestAccessibility(), nil)
    case "permissions.request_screen_recording":
        return (true, requestScreenRecording(), nil)
    case "apps.list":
        return (true, appsList(), nil)
    case "observation.describe":
        let include = (arguments["include_screenshot"] as? Bool) ?? false
        let target = arguments["app"] as? String
        let resolved = effectiveMode(arguments)
        if let refusal = resolved.refusal {
            return (false, nil, refusalFrame(refusal))
        }
        let (result, refusal) = describe(
            includeScreenshot: include, targetApp: target, mode: resolved.mode)
        if let refusal {
            return (false, nil, refusalFrame(refusal))
        }
        guard let result else {
            return (false, nil, bridgeError(code: "ACTION_FAILED", message: "The observation could not be completed."))
        }
        return (true, result, nil)
    case "observation.release":
        return (true, releaseObservation(), nil)
    case "observation.capture_screen":
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
        let outcome = captureWindowBase64(
            app: (app?.isEmpty ?? true) ? nil : app, title: title ?? "")
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
        if let identity = outcome.identity { result["view_identity"] = identity }
        return (true, result, nil)
    case "observation.stream_start":
        let app = (arguments["app"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = ((arguments["window_title"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // `window_id` is preferred when the client has it: a title follows the
        // active tab and a stream keyed on it dies on the next navigation.
        let requestedWindowID = (arguments["window_id"] as? Int)
            ?? (arguments["window_id"] as? NSNumber)?.intValue
        let resolved = effectiveMode(arguments)
        if let refusal = resolved.refusal {
            return (false, nil, refusalFrame(refusal))
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
            app: (app?.isEmpty ?? true) ? nil : app, title: title,
            windowID: requestedWindowID)
        if let refusal = started.refusal {
            return (false, nil, refusalFrame(refusal))
        }
        guard let identity = started.identity else {
            return (false, nil, bridgeError(
                code: "ACTION_FAILED",
                message: "The window stream could not be started.",
                detail: started.failure ?? ""))
        }
        return (true, ["stream": "started", "view_identity": identity], nil)
    case "observation.stream_stop":
        // Idempotent: stopping nothing is a success, so a client can tear down
        // on every exit path without tracking whether it started one.
        return (true, stopWindowStream(), nil)
    case "observation.stream_frame":
        return streamFrameResponse(arguments)
    case "action.execute":
        guard let kind = arguments["kind"] as? String, !kind.isEmpty else {
            return (false, nil, bridgeError(code: "CAPABILITY_UNSUPPORTED", message: "The action has no kind."))
        }
        let rawParams = arguments["params"]
        guard rawParams == nil || rawParams is [String: Any] else {
            return (false, nil, bridgeError(code: "CAPABILITY_UNSUPPORTED", message: "The action params are invalid."))
        }
        let params = (rawParams as? [String: Any]) ?? [:]
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
        // Measure the invariant around EVERY executed action, success or
        // failure, and sample DURING it: a before/after pair cannot see a
        // window that raises itself and drops back.
        let actionClass = bridgeActionClass(kind: kind) ?? .accessibility
        let before = currentEnvironment()
        let sampler = InterferenceSampler()
        sampler.start()
        let result = executeAction(kind: kind, params: params)
        let after = currentEnvironment()
        let samples = sampler.stop()
        let report = bridgeInterferenceReport(
            before: before, after: after, samples: samples,
            actionClass: actionClass, mode: mode,
            targetBundle: actionTargetBundle(kind: kind, params: params))
        if report.breach {
            // The action ran; the promise did not hold. Say so loudly instead
            // of reporting an unqualified success.
            log("INTERFERENCE_BREACH kind=\(kind) verdict=\(report.verdict.rawValue) transient=\(report.transientFocusChanges) restored=\(report.restored) before=\(report.frontmostBefore) after=\(report.frontmostAfter)")
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
            message: result["message"] as? String ?? "The computer action could not be executed.")
        error["interference"] = report.dictionary()
        return (false, nil, error)
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

func handleLine(_ text: String, sendTo fd: Int32?) {
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
    // the machine is doing something worth watching.
    if operation == "observation.stream_frame" {
        let (ok, result, error) = streamFrameResponse(args)
        respond(["ok": ok, "result": result, "error": error], id: rid)
        return
    }
    dispatchLock.lock()
    let (ok, result, error) = dispatch(operation: operation, arguments: args)
    dispatchLock.unlock()
    respond(["ok": ok, "result": result, "error": error], id: rid)
}

// MARK: - Socket serve mode (product transport)
//
// A helper spawned by an unbundled interpreter inherits an unusable TCC
// ancestry (the decision subject becomes the bare interpreter, never the helper
// identity). The PRODUCT path is therefore: a bundled app launches this helper
// with --serve-socket <path>, and clients connect to that Unix socket. Same
// NDJSON protocol, same dispatch, same allowlist — only the rendezvous
// differs. No TCP, no `open`, no FIFOs.

func unixAddr(_ path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8.prefix(103)) + [0]
    let off = MemoryLayout<sockaddr_un>.offset(of: \.sun_path)!
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
    var addr = unixAddr(path)
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

//: Serializes request handling across connection threads. The element table
//: and every AppKit/AX/Quartz call are single-threaded by contract.
let dispatchLock = NSLock()

func probeSocket(at path: String) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var addr = unixAddr(path)
    let rc = withSockAddr(&addr) { saddr, len in connect(fd, saddr, len) }
    return rc == 0
}

func serveConnection(_ fd: Int32) {
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
                handleLine(String(bytes: bytes, encoding: .utf8) ?? "", sendTo: fd)
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
func parseLaunchArguments() -> (serveSocket: String?, mode: BridgeInteractionMode, preflightOnly: Bool) {
    var preflightOnly = false
    var mode = BridgeInteractionMode.background
    var socketPath: String?
    var index = 1
    let arguments = CommandLine.arguments
    while index < arguments.count {
        switch arguments[index] {
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
    return (socketPath, mode, preflightOnly)
}

launchMode = launchArguments.mode
authorization = loadAuthorizationPolicy()
applyDeploymentModes()
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
    bootstrapPermissions()
    app.run()
    exit(0)
}

log("\(bridgeName) protocol v\(bridgeVersion) ready pid=\(ProcessInfo.processInfo.processIdentifier) bundle=\(Bundle.main.bundleIdentifier ?? "?") policy=\(deploymentMode.rawValue)")

app.finishLaunching()
bootstrapPermissions()
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
