// ComputerUsePolicy.swift — interaction policy and interference accounting for
// the CMM Computer Use bridge.
//
// ONE source of truth, compiled into the CMMComputerUse helper (via
// scripts/build-helper.sh), the CMMComputerUseTests bundle (via project.yml)
// and any adapter that needs to state the same rules. Pure Foundation: no
// AppKit, no AX, no window server, so the policy is pinned by tests that never
// touch the desktop.
//
// WHAT THIS FILE DECIDES
//
// Not every operation in the wire allowlist has the same physical effect.
// `ui.press` asks an application's own accessibility layer to perform its
// press action; `pointer.click` posts a HID event at absolute screen
// coordinates, which moves the system cursor and lands on whatever is
// topmost at that point; `keyboard.type` posts Cmd+V to the session, which
// reaches whichever application currently holds the keyboard focus. A client
// that promised "I will not take your focus" could not keep that promise
// while those last two exist.
//
// So the mode is explicit and the helper enforces it:
//
//   background    — accessibility primitives only. No activation, no pointer,
//                   no global keyboard, screen captures only of a named
//                   window, element handles expire.
//   focus         — background plus app/window activation (an explicit,
//                   announced focus change). Still no pointer, no global
//                   keyboard.
//   unrestricted  — the legacy planner surface, unchanged. Declared, never
//                   inferred.
//
// A request may TIGHTEN the deployment mode (bridgeEffectiveMode); it can
// never loosen it. That is what lets one helper serve a cautious client and a
// legacy planner at the same time without a second engine.

import Foundation

// MARK: - Modes

/// What a bridge deployment is allowed to do to the machine.
///
/// Ordered by strictness: `background` < `focus` < `unrestricted`. Comparing
/// two modes answers "which one promises less".
public enum BridgeInteractionMode: String, CaseIterable, Comparable, Sendable {
    case background
    case focus
    case unrestricted

    /// Strictness rank. Higher means the mode permits more interference.
    public var rank: Int {
        switch self {
        case .background: return 0
        case .focus: return 1
        case .unrestricted: return 2
        }
    }

    public static func < (lhs: BridgeInteractionMode, rhs: BridgeInteractionMode) -> Bool {
        lhs.rank < rhs.rank
    }

    /// Parse a mode from a launch flag / request value. Unknown stays unknown:
    /// a typo must never silently select the permissive mode.
    public init?(flag: String) {
        let normalized = flag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let mode = BridgeInteractionMode(rawValue: normalized) else { return nil }
        self = mode
    }

    /// Whether this mode promises the person their frontmost application and
    /// cursor stay where they are.
    public var promisesNoInterference: Bool { self != .unrestricted }
}

/// The effective mode for one request: the stricter of the deployment's mode
/// and the caller's request. A client can only ever narrow what it may do.
public func bridgeEffectiveMode(
    requested: BridgeInteractionMode?, deployment: BridgeInteractionMode
) -> BridgeInteractionMode {
    guard let requested else { return deployment }
    return min(requested, deployment)
}

/// Resolve the `policy` a request carried.
///
/// Absent means "whatever the deployment allows". Present but unparseable is a
/// REFUSAL, not a fallback: a client that asks for a mode and misspells it must
/// not silently receive the deployment's (possibly more permissive) one.
public func bridgeResolveMode(
    requestedValue: Any?, deployment: BridgeInteractionMode
) -> (mode: BridgeInteractionMode, refusal: BridgePolicyRefusal?) {
    guard let requestedValue else { return (deployment, nil) }
    guard let text = requestedValue as? String,
          let requested = BridgeInteractionMode(flag: text)
    else {
        return (deployment, BridgePolicyRefusal(
            code: "CAPABILITY_UNSUPPORTED",
            message: "The requested policy is not background, focus or unrestricted.",
            detail: "policy=invalid;needs=background|focus|unrestricted"))
    }
    return (bridgeEffectiveMode(requested: requested, deployment: deployment), nil)
}

// MARK: - Action classes

/// The physical effect class of an action kind.
public enum BridgeActionClass: String, Sendable {
    /// An accessibility primitive on an element of an observed window. Safe in
    /// every mode; the preferred route.
    case accessibility
    /// Activation: changes which application is frontmost by design.
    case focus
    /// Global pointer events at absolute coordinates: move the system cursor.
    case pointer
    /// Global keyboard events: reach whichever application holds focus, and
    /// `keyboard.type` rewrites the pasteboard on the way.
    case globalKeyboard = "global_keyboard"
}

/// The class of a wire action kind, or nil for anything outside the allowlist.
///
/// `wait` and `finish` are control-plane only: they touch nothing, so they are
/// `accessibility` for accounting purposes (they must never register as a
/// breach).
public func bridgeActionClass(kind: String) -> BridgeActionClass? {
    switch kind {
    case "ui.press", "ui.set_value", "wait", "finish":
        return .accessibility
    case "app.open", "app.activate", "window.focus":
        return .focus
    case "pointer.click", "pointer.scroll":
        return .pointer
    case "keyboard.type", "keyboard.shortcut":
        return .globalKeyboard
    default:
        return nil
    }
}

/// One sentence a person can act on: what this kind does to their machine.
public func bridgeActionSideEffect(kind: String) -> String {
    switch bridgeActionClass(kind: kind) {
    case .accessibility:
        return "touches one accessibility element; no activation and no global input"
    case .focus:
        return "changes which application is frontmost"
    case .pointer:
        return "posts a global pointer event, which moves the system cursor"
    case .globalKeyboard:
        return "posts a global keyboard event into whichever application holds focus"
    case nil:
        return "is not an action kind this bridge knows"
    }
}

// MARK: - Refusals

/// A refusal with the machine-readable facts a client needs to explain it.
public struct BridgePolicyRefusal: Equatable, Sendable {
    /// Frozen product error grammar (`CAPABILITY_UNSUPPORTED` for a request the
    /// deployment's policy does not support). Never invented per call site.
    public let code: String
    public let message: String
    /// `key=value;…` facts, bounded: mode, kind, requirement. No window text,
    /// no user content.
    public let detail: String

    public init(code: String, message: String, detail: String) {
        self.code = code
        self.message = message
        self.detail = detail
    }
}

public enum BridgePolicyDecision: Equatable, Sendable {
    case allowed
    case refused(BridgePolicyRefusal)

    public var isAllowed: Bool { self == .allowed }

    public var refusal: BridgePolicyRefusal? {
        if case .refused(let refusal) = self { return refusal }
        return nil
    }
}

/// The requirement that makes a kind unacceptable in a mode, if any.
public func bridgeRequiredMode(kind: String) -> BridgeInteractionMode? {
    switch bridgeActionClass(kind: kind) {
    case .accessibility: return .background
    case .focus: return .focus
    case .pointer, .globalKeyboard: return .unrestricted
    case nil: return nil
    }
}

/// Decide one action kind against the effective mode.
///
/// An unknown kind is refused here as well as in the helper's allowlist: two
/// independent checks, because this function is also compiled into clients
/// that never see the helper's dispatch switch.
public func bridgePolicyDecision(kind: String, mode: BridgeInteractionMode) -> BridgePolicyDecision {
    guard let required = bridgeRequiredMode(kind: kind) else {
        return .refused(BridgePolicyRefusal(
            code: "CAPABILITY_UNSUPPORTED",
            message: "Unsupported action: \(kind)",
            detail: "policy=\(mode.rawValue);kind=\(kind);requirement=unknown_kind"
        ))
    }
    guard required <= mode else {
        let requirement: String
        switch bridgeActionClass(kind: kind) {
        case .focus: requirement = "activation"
        case .pointer: requirement = "global_pointer"
        case .globalKeyboard: requirement = "global_keyboard"
        default: requirement = "unknown"
        }
        return .refused(BridgePolicyRefusal(
            code: "CAPABILITY_UNSUPPORTED",
            message: "The bridge runs in \(mode.rawValue) mode: \(kind) \(bridgeActionSideEffect(kind: kind)).",
            detail: "policy=\(mode.rawValue);kind=\(kind);requirement=\(requirement);needs=\(required.rawValue)"
        ))
    }
    return .allowed
}

/// Global input under per-application authorization.
///
/// A pointer event at absolute coordinates lands on whatever is topmost, and a
/// keystroke goes to whatever holds focus: neither can be limited to the
/// application the person authorized. So when an allowlist is in force, global
/// input is refused WHATEVER the mode — `unrestricted` is not an escape hatch
/// from the allowlist, it is only the legacy surface of a deployment that has
/// no allowlist at all.
public func bridgeGlobalInputDecision(
    kind: String, mode: BridgeInteractionMode, authorizationLoaded: Bool
) -> BridgePolicyDecision {
    let globalInput = (bridgeActionClass(kind: kind) == .pointer
        || bridgeActionClass(kind: kind) == .globalKeyboard)
    guard globalInput, authorizationLoaded else {
        return bridgePolicyDecision(kind: kind, mode: mode)
    }
    return .refused(BridgePolicyRefusal(
        code: "APPROVAL_REJECTED",
        message: "Global input cannot be limited to an authorized application, so this deployment does not accept it.",
        detail: "auth=global_input_not_scoped;policy=\(mode.rawValue);kind=\(kind)"))
}

/// Whether a screen capture may run: `background` captures one named window
/// only, because a display capture includes every other window the person has
/// open.
public func bridgeCaptureDecision(
    mode: BridgeInteractionMode, hasWindowTarget: Bool
) -> BridgePolicyDecision {
    if mode == .background && !hasWindowTarget {
        return .refused(BridgePolicyRefusal(
            code: "CAPABILITY_UNSUPPORTED",
            message: "The bridge runs in background mode: a screen capture must name one window.",
            detail: "policy=background;capture=display;requirement=window_target"
        ))
    }
    return .allowed
}

/// Whether a screen capture may run under per-application authorization.
///
/// A display capture is every window the person has open, including the ones
/// this deployment never authorized, so it is refused outright: the authorized
/// route is a window capture, which is checked against the grant that covers
/// that window's owner.
public func bridgeAuthorizedCaptureDecision(
    mode: BridgeInteractionMode, hasWindowTarget: Bool, authorizationLoaded: Bool
) -> BridgePolicyDecision {
    guard hasWindowTarget else {
        return .refused(BridgePolicyRefusal(
            code: "APPROVAL_REJECTED",
            message: "This deployment captures one authorized window at a time, never the display.",
            detail: "auth=display_capture_not_permitted;policy=\(mode.rawValue);authorization_loaded=\(authorizationLoaded)"))
    }
    return bridgeCaptureDecision(mode: mode, hasWindowTarget: true)
}

// MARK: - Observation lifetime

/// Element handles are only meaningful for the observation that produced them:
/// a re-walk replaces the table, and a stale handle must never be resolved
/// against a newer one. Restricted modes additionally expire an observation on
/// a clock, because the window it described may be gone.
public func bridgeObservationTimeout(_ mode: BridgeInteractionMode) -> Double? {
    switch mode {
    case .background, .focus: return 30.0
    case .unrestricted: return nil
    }
}

/// Has this observation outlived its mode's window?
public func bridgeObservationExpired(
    capturedAt: Double, now: Double, mode: BridgeInteractionMode
) -> Bool {
    guard let timeout = bridgeObservationTimeout(mode) else { return false }
    guard capturedAt > 0 else { return true }
    return now - capturedAt > timeout
}

/// Refuse a handle that belongs to a superseded observation.
///
/// `requested == nil` is the legacy caller that never sent a generation; it is
/// only acceptable outside restricted modes, where the clock still bounds it.
public func bridgeSnapshotRefusal(
    current: Int, requested: Int?, mode: BridgeInteractionMode
) -> BridgePolicyRefusal? {
    guard let requested else {
        return mode.promisesNoInterference
            ? BridgePolicyRefusal(
                code: "ACTION_FAILED",
                message: "This bridge requires the observation snapshot that produced the element.",
                detail: "policy=\(mode.rawValue);requirement=snapshot")
            : nil
    }
    guard requested == current else {
        return BridgePolicyRefusal(
            code: "ACTION_FAILED",
            message: "The referenced UI element is no longer on screen.",
            detail: "policy=\(mode.rawValue);snapshot=\(requested);current=\(current)"
        )
    }
    return nil
}

// MARK: - Interference accounting

/// What the machine looked like at one instant, as far as interference cares.
public struct BridgeEnvironment: Equatable, Sendable {
    public var frontmostApp: String
    public var frontmostBundle: String
    public var cursorX: Double
    public var cursorY: Double

    public init(frontmostApp: String, frontmostBundle: String, cursorX: Double, cursorY: Double) {
        self.frontmostApp = frontmostApp
        self.frontmostBundle = frontmostBundle
        self.cursorX = cursorX
        self.cursorY = cursorY
    }
}

public enum BridgeInterferenceVerdict: String, Sendable {
    case untouched
    case focusChanged = "focus_changed"
    case cursorMoved = "cursor_moved"
    case focusAndCursorChanged = "focus_and_cursor_changed"
}

/// The measured answer to "did that action take the person's focus or move
/// their cursor?".
///
/// `attributed` is deliberately false: a change between two samples is
/// evidence, not proof. The person may have switched apps in the same
/// instant. What the report can say honestly is whether the invariant held,
/// and by how much it did not.
///
/// Sampling matters as much as the endpoints: an app that raises itself for
/// 40 ms and drops back is invisible to a before/after comparison, and that is
/// exactly the interference a person notices. When samples are supplied the
/// verdict covers the whole window, and `restored` says the endpoints alone
/// would have missed it.
public struct BridgeInterferenceReport: Equatable, Sendable {
    public let verdict: BridgeInterferenceVerdict
    public let frontmostBefore: String
    public let frontmostAfter: String
    public let cursorMoved: Bool
    public let cursorDx: Double
    public let cursorDy: Double
    public let actionClass: BridgeActionClass
    public let mode: BridgeInteractionMode
    /// A breach is something THIS action is responsible for, in a mode that
    /// promised no interference. It is not "the environment changed": the
    /// person may be using the machine while the action runs, and their
    /// pointer movement is not the bridge's fault.
    public let breach: Bool
    /// Did the code path of this action post global HID input at all?
    ///
    /// An accessibility action (AXPress / AXSetAttributeValue) posts no event:
    /// it asks the target application to act on one of its own elements. So
    /// any cursor movement measured around it is, by construction, not ours.
    public let cursorEventsPosted: Bool
    /// The measured cursor delta belongs to an input path that could have
    /// produced it. False for accessibility-only actions, always.
    public let cursorMovedByAction: Bool
    /// Did the frontmost application become the action's own target? That is
    /// the one focus change an accessibility action can plausibly cause (an app
    /// raising its window when pressed).
    public let focusBecameTarget: Bool
    /// Something in the environment changed that this action cannot explain:
    /// the person moved the pointer, or switched to an unrelated application.
    public let externalActivity: Bool
    /// Environment samples taken DURING the action.
    public let sampled: Int
    /// Frontmost transitions across before → samples → after.
    public let transientFocusChanges: Int
    /// Largest cursor displacement from the pre-action position, in points.
    public let transientCursorMaxDelta: Double
    /// A change was observed and the final state equals the initial one.
    public let restored: Bool

    public init(
        verdict: BridgeInterferenceVerdict,
        frontmostBefore: String,
        frontmostAfter: String,
        cursorMoved: Bool,
        cursorDx: Double,
        cursorDy: Double,
        actionClass: BridgeActionClass,
        mode: BridgeInteractionMode,
        breach: Bool,
        cursorEventsPosted: Bool = false,
        cursorMovedByAction: Bool = false,
        focusBecameTarget: Bool = false,
        externalActivity: Bool = false,
        sampled: Int = 0,
        transientFocusChanges: Int = 0,
        transientCursorMaxDelta: Double = 0,
        restored: Bool = false
    ) {
        self.verdict = verdict
        self.frontmostBefore = frontmostBefore
        self.frontmostAfter = frontmostAfter
        self.cursorMoved = cursorMoved
        self.cursorDx = cursorDx
        self.cursorDy = cursorDy
        self.actionClass = actionClass
        self.mode = mode
        self.breach = breach
        self.cursorEventsPosted = cursorEventsPosted
        self.cursorMovedByAction = cursorMovedByAction
        self.focusBecameTarget = focusBecameTarget
        self.externalActivity = externalActivity
        self.sampled = sampled
        self.transientFocusChanges = transientFocusChanges
        self.transientCursorMaxDelta = transientCursorMaxDelta
        self.restored = restored
    }

    /// Wire shape. Stable keys, no user content beyond application names.
    public func dictionary() -> [String: Any] {
        [
            "verdict": verdict.rawValue,
            "frontmost_before": frontmostBefore,
            "frontmost_after": frontmostAfter,
            "cursor_moved": cursorMoved,
            "cursor_dx": Int(cursorDx.rounded()),
            "cursor_dy": Int(cursorDy.rounded()),
            "action_class": actionClass.rawValue,
            "policy": mode.rawValue,
            "attributed": false,
            "breach": breach,
            "cursor_events_posted": cursorEventsPosted,
            "cursor_moved_by_action": cursorMovedByAction,
            "focus_became_target": focusBecameTarget,
            "external_activity": externalActivity,
            "sampled": sampled,
            "transient_focus_changes": transientFocusChanges,
            "transient_cursor_max_delta": transientCursorMaxDelta,
            "restored": restored,
        ]
    }
}

/// Compare the environment before, during (optional samples) and after one
/// action, and separate what the action is responsible for from what merely
/// happened while it ran.
///
/// `targetBundle` is the application the action acted on, when there is one:
/// it is what makes "the frontmost app became MY target" distinguishable from
/// "the person switched to another window".
///
/// `tolerance` is in points. Zero means "any movement is reported": the report
/// never hides a delta, and a client that wants to ignore sub-pixel jitter
/// decides that itself.
public func bridgeInterferenceReport(
    before: BridgeEnvironment,
    after: BridgeEnvironment,
    samples: [BridgeEnvironment] = [],
    actionClass: BridgeActionClass,
    mode: BridgeInteractionMode,
    targetBundle: String? = nil,
    tolerance: Double = 0
) -> BridgeInterferenceReport {
    // One chronological sequence: before, everything sampled while it ran, after.
    var sequence: [BridgeEnvironment] = [before]
    sequence.append(contentsOf: samples)
    sequence.append(after)

    var transitions = 0
    var previous = sequence[0]
    for sample in sequence.dropFirst() {
        if !bridgeSameApplication(previous, sample) { transitions += 1 }
        previous = sample
    }

    var maxCursorDelta = 0.0
    var maxDx = 0.0
    var maxDy = 0.0
    for sample in sequence {
        let dx = sample.cursorX - before.cursorX
        let dy = sample.cursorY - before.cursorY
        let distance = (dx * dx + dy * dy).squareRoot()
        if distance > maxCursorDelta {
            maxCursorDelta = distance
            maxDx = dx
            maxDy = dy
        }
    }

    let focusChanged = transitions > 0
    let cursorMoved = maxCursorDelta > tolerance

    let verdict: BridgeInterferenceVerdict
    switch (focusChanged, cursorMoved) {
    case (false, false): verdict = .untouched
    case (true, false): verdict = .focusChanged
    case (false, true): verdict = .cursorMoved
    case (true, true): verdict = .focusAndCursorChanged
    }

    // What this action's own code path can do. An accessibility action posts no
    // HID event and requests no activation; only pointer and keyboard events
    // can move the cursor, and only an activation request moves focus by design.
    let postsInput = (actionClass == .pointer || actionClass == .globalKeyboard)

    // Did the frontmost application become the one we acted on? Tracked across
    // the samples, so a window that raises itself for a moment still counts.
    var focusBecameTarget = false
    if let targetBundle, !targetBundle.isEmpty {
        let target = targetBundle.lowercased()
        let beforeWasTarget = sequence[0].frontmostBundle.lowercased() == target
        for sample in sequence.dropFirst() {
            if sample.frontmostBundle.lowercased() == target {
                if !beforeWasTarget { focusBecameTarget = true }
            }
        }
    }

    // Attribution. The cursor cannot be ours without a posted event; a focus
    // change is ours only when it lands on our own target.
    let cursorMovedByAction = postsInput && cursorMoved
    let externalActivity = (cursorMoved && !postsInput) || (focusChanged && !focusBecameTarget)

    // A breach is a promise broken by THIS action: an accessibility action in a
    // no-interference mode that raised the application it acted on. Pointer or
    // keyboard input is never permitted in those modes, so it cannot be the
    // cause of a breach there.
    let breach = mode.promisesNoInterference
        && actionClass == .accessibility
        && focusBecameTarget

    let endpointsAgree = bridgeSameApplication(before, after)
        && abs(after.cursorX - before.cursorX) <= tolerance
        && abs(after.cursorY - before.cursorY) <= tolerance
    let sawSomething = verdict != .untouched

    return BridgeInterferenceReport(
        verdict: verdict,
        frontmostBefore: before.frontmostApp,
        frontmostAfter: after.frontmostApp,
        cursorMoved: cursorMoved,
        cursorDx: maxDx,
        cursorDy: maxDy,
        actionClass: actionClass,
        mode: mode,
        breach: breach,
        cursorEventsPosted: postsInput,
        cursorMovedByAction: cursorMovedByAction,
        focusBecameTarget: focusBecameTarget,
        externalActivity: externalActivity,
        sampled: samples.count,
        transientFocusChanges: transitions,
        transientCursorMaxDelta: maxCursorDelta,
        restored: sawSomething && endpointsAgree
    )
}

/// Do two samples describe the same frontmost application?
///
/// Bundle id when both have one, display name otherwise: an app without a
/// bundle id still counts as a distinct frontmost application.
func bridgeSameApplication(_ lhs: BridgeEnvironment, _ rhs: BridgeEnvironment) -> Bool {
    let left = lhs.frontmostBundle.isEmpty ? lhs.frontmostApp : lhs.frontmostBundle
    let right = rhs.frontmostBundle.isEmpty ? rhs.frontmostApp : rhs.frontmostBundle
    return left == right
}

// MARK: - Window selection

/// One window as targeting sees it. Supplied by the caller (CoreGraphics on
/// the helper) so this file stays free of the window server.
public struct BridgeWindowCandidate: Equatable, Sendable {
    public var windowID: Int
    public var title: String
    public var app: String
    /// Bundle id of the owning application, when the caller knows it. The app
    /// filter accepts an exact display name OR an exact bundle id, the same
    /// rule `app.activate` uses; an empty bundle id simply never matches one.
    public var bundleID: String
    public var width: Int
    public var height: Int

    public init(
        windowID: Int, title: String, app: String,
        bundleID: String = "", width: Int, height: Int
    ) {
        self.windowID = windowID
        self.title = title
        self.app = app
        self.bundleID = bundleID
        self.width = width
        self.height = height
    }
}

public enum BridgeWindowSelection: Equatable, Sendable {
    case selected(BridgeWindowCandidate)
    /// More than one window matched: refuse rather than guess.
    case ambiguous(matches: [String])
    case notFound
}

/// Select exactly one window for a capture.
///
/// `app` is an exact name or bundle id (the same rule `app.activate` uses);
/// an empty app means "any application". A title request matches per
/// `bridgeWindowTitleMatches`. Exactly one match selects; several are
/// reported as ambiguous with their titles so the client can ask again.
public func bridgeSelectWindow(
    request: String, app: String?, candidates: [BridgeWindowCandidate]
) -> BridgeWindowSelection {
    var scoped = candidates
    if let app, !app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let query = app.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        scoped = candidates.filter {
            $0.app.lowercased() == query || $0.bundleID.lowercased() == query
        }
        if scoped.isEmpty { return .notFound }
    }
    let matching = scoped.filter {
        bridgeWindowTitleMatches(windowTitle: $0.title, request: request)
    }
    if matching.count == 1 { return .selected(matching[0]) }
    if matching.isEmpty { return .notFound }
    let labels = matching.map { "\($0.app) / \($0.title)" }.sorted()
    return .ambiguous(matches: Array(labels.prefix(6)))
}

/// Select one window by the identity the bridge itself published
/// (`view_identity.window_id`).
///
/// A title is a MOVING target: it follows the active tab, the open document
/// and the application's own rewrites, so a live mirror keyed on a title dies
/// the moment the person navigates. The window id does not move for the life
/// of the window. This resolver therefore takes precedence over the title
/// rules, and it is deliberately strict: the id must exist AND, when the
/// caller also names an app, must belong to that app — otherwise a client
/// could reach a window of another application by guessing a number.
public func bridgeResolveWindowById(
    windowID: Int, app: String?, candidates: [BridgeWindowCandidate]
) -> BridgeWindowSelection {
    guard let match = candidates.first(where: { $0.windowID == windowID }) else {
        return .notFound
    }
    if let app, !app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let query = app.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard match.app.lowercased() == query || match.bundleID.lowercased() == query else {
            return .notFound
        }
    }
    return .selected(match)
}
