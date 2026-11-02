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
    case "ui.press", "ui.set_value", "ui.scroll", "wait", "finish":
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
///
/// Three independent readings of "who is in front", because one of them was
/// observed to lie (2026-11-02: `ui.press` on Claude's zoom button, Claude
/// became frontmost, every sample still said DeepSeek Harness):
///
/// - `frontmostBundle`: `NSWorkspace.frontmostApplication`. A CACHED property
///   that AppKit refreshes from a workspace notification; it can trail the
///   window server, and a sampler that stops before the notification lands
///   records nothing.
/// - `focusedBundle`: the system-wide accessibility element's
///   `AXFocusedApplication`, read synchronously from the accessibility server
///   on every sample. Empty when it could not be read (never guessed).
/// - `topWindowBundle`: owner of the front-most on-screen layer-0 window per
///   `CGWindowListCopyWindowInfo`. Catches a window ordered in front of the
///   person's work even when activation itself did not happen.
///
/// `t` is seconds since the first sample of this measurement (0 when unknown),
/// so a report can say WHEN the target came to the front.
public struct BridgeEnvironment: Equatable, Sendable {
    public var frontmostApp: String
    public var frontmostBundle: String
    public var cursorX: Double
    public var cursorY: Double
    public var focusedBundle: String
    public var topWindowBundle: String
    public var t: Double

    public init(
        frontmostApp: String, frontmostBundle: String, cursorX: Double, cursorY: Double,
        focusedBundle: String = "", topWindowBundle: String = "", t: Double = 0
    ) {
        self.frontmostApp = frontmostApp
        self.frontmostBundle = frontmostBundle
        self.cursorX = cursorX
        self.cursorY = cursorY
        self.focusedBundle = focusedBundle
        self.topWindowBundle = topWindowBundle
        self.t = t
    }

    /// Does any activation reading (cached frontmost or live AX focus) name
    /// this bundle?
    func isActive(_ bundle: String) -> Bool {
        let target = bundle.lowercased()
        guard !target.isEmpty else { return false }
        return frontmostBundle.lowercased() == target || focusedBundle.lowercased() == target
    }

    /// Is this bundle's window the front-most normal window on screen?
    func isOnTop(_ bundle: String) -> Bool {
        let target = bundle.lowercased()
        return !target.isEmpty && topWindowBundle.lowercased() == target
    }
}

// MARK: - Post-action observation window

/// How long the ledger keeps sampling AFTER an action returns, in seconds.
///
/// `AXUIElementPerformAction` returns when the target application has accepted
/// the action, not when the window server has finished acting on it: an
/// activation the press triggers can materialize hundreds of milliseconds
/// later. Stopping the sampler at return was the root cause of the
/// `verdict=untouched` / frontmost=target contradiction. The window is
/// bounded: `minimum` always, extended while readings are still changing,
/// never past `maximum`.
public struct BridgeSettleWindow: Equatable, Sendable {
    public let minimum: Double
    public let quiet: Double
    public let maximum: Double

    public init(minimum: Double, quiet: Double, maximum: Double) {
        self.minimum = minimum
        self.quiet = quiet
        self.maximum = maximum
    }
}

public func bridgeSettleWindow(actionClass: BridgeActionClass) -> BridgeSettleWindow {
    switch actionClass {
    case .accessibility, .focus:
        return BridgeSettleWindow(minimum: 0.8, quiet: 0.25, maximum: 2.0)
    case .pointer, .globalKeyboard:
        return BridgeSettleWindow(minimum: 0.4, quiet: 0.2, maximum: 1.0)
    }
}

/// Keep sampling? `elapsed` since the action returned, `sinceLastChange`
/// since the last reading that differed from the one before it.
public func bridgeShouldKeepSettling(
    window: BridgeSettleWindow, elapsed: Double, sinceLastChange: Double
) -> Bool {
    if elapsed >= window.maximum { return false }
    if elapsed < window.minimum { return true }
    return sinceLastChange < window.quiet
}

// MARK: - Background-unsafe accessibility targets

/// Window-management buttons in a window's title bar.
///
/// They are accessibility elements like any other, but pressing them is not
/// "the application acting on its own content": zoom and full screen order
/// the window front (full screen moves it to its own Space), and close and
/// minimize change what the person sees on their desktop. The observed press
/// of an Electron window's zoom button activated the application. In a mode
/// that promises no interference they are refused BEFORE anything runs.
public let bridgeWindowChromeSubroles: Set<String> = [
    "AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton",
]

public func bridgeIsWindowChrome(subrole: String?) -> Bool {
    guard let subrole else { return false }
    return bridgeWindowChromeSubroles.contains(subrole)
}

public func bridgeWindowChromeRefusal(
    kind: String, subrole: String?, mode: BridgeInteractionMode
) -> BridgePolicyRefusal? {
    guard kind == "ui.press", mode.promisesNoInterference,
          bridgeIsWindowChrome(subrole: subrole), let subrole
    else { return nil }
    return BridgePolicyRefusal(
        code: "CAPABILITY_UNSUPPORTED",
        message: "Window controls (close, minimize, zoom, full screen) can bring the application to the front; \(mode.rawValue) mode does not press them.",
        detail: "policy=\(mode.rawValue);kind=ui.press;reason=window_chrome;subrole=\(subrole)")
}

// MARK: - What an observation offers

/// What an observed window offers through accessibility, kept apart:
///
/// - `actionable`: at least one non-window-control element that can be acted
///   on (pressable, a text input, or a verified-scrollable area);
/// - `readable`: no such control, but there is readable content (or
///   non-control elements) — enough to OBSERVE, not to operate;
/// - `unavailable`: nothing but window controls, or nothing at all.
///
/// A live Claude (Electron) observation exposed AXWindow, AXGroup, AXWebArea
/// and AXHeading and no control: that is `readable`, not `unavailable`, and
/// not evidence that the application can be controlled.
public enum BridgeAXAccess: String, Sendable {
    case actionable
    case readable
    case unavailable
}

public struct BridgeObservedElement: Equatable, Sendable {
    public var windowChrome: Bool
    public var actionable: Bool

    public init(windowChrome: Bool, actionable: Bool) {
        self.windowChrome = windowChrome
        self.actionable = actionable
    }
}

/// Roles whose value `ui.set_value` may set (secure fields are refused by the
/// action itself).
public let bridgeTextInputRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

/// A text input counts only when its AXValue is SETTABLE: a read-only field
/// is content, not a control (2026-11-02: no optimistic `actionable`).
public func bridgeElementIsActionable(
    role: String, pressable: Bool, scrollable: Bool, windowChrome: Bool,
    valueSettable: Bool = false
) -> Bool {
    guard !windowChrome else { return false }
    return pressable || scrollable || (bridgeTextInputRoles.contains(role) && valueSettable)
}

// MARK: - When to ask Electron/Chromium for its full tree

/// Why the helper asks the application to materialize its accessibility tree
/// (`AXManualAccessibility`), decided AFTER a first walk:
///
/// - `sparse`: fewer nodes than the threshold (the original rule);
/// - `unavailable`: only window controls, or nothing;
/// - `readableNotActionable`: content is readable but no control is — the
///   live Claude Desktop state (AXWebArea + headings, 0 actionable). The old
///   node-count rule never fired there, so the tree was never requested.
///
/// nil when the window already offers a control: nothing is touched.
public enum BridgeEnrichmentTrigger: String, Sendable {
    case sparse
    case unavailable
    case readableNotActionable = "readable_not_actionable"
}

public func bridgeEnrichmentTrigger(
    nodeCount: Int, access: BridgeAXAccess, sparseThreshold: Int
) -> BridgeEnrichmentTrigger? {
    if access == .actionable { return nil }
    if nodeCount < sparseThreshold { return .sparse }
    return access == .unavailable ? .unavailable : .readableNotActionable
}

// MARK: - set_value postcondition

/// Did `ui.set_value` actually take? Judged on the value read back through
/// AX, never on the return code. Whitespace at the ends and non-breaking
/// spaces are normalized (editors add them); anything else must match.
public enum BridgeSetValueCheck: String, Sendable {
    case verified
    case notApplied = "not_applied"
    case unreadable
}

public func bridgeSetValueCheck(requested: String, readBack: String?) -> BridgeSetValueCheck {
    guard let readBack else { return .unreadable }
    func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return normalized(readBack) == normalized(requested) ? .verified : .notApplied
}

public func bridgeAXAccess(contentCount: Int, elements: [BridgeObservedElement]) -> BridgeAXAccess {
    if elements.contains(where: { $0.actionable && !$0.windowChrome }) { return .actionable }
    let nonChrome = elements.filter { !$0.windowChrome }.count
    if contentCount > 0 || nonChrome > 0 { return .readable }
    return .unavailable
}

// MARK: - Accessibility-only scrolling

public enum BridgeScrollDirection: String, CaseIterable, Sendable {
    case up, down, left, right

    /// The AX page action an element may advertise for this direction.
    public var pageAction: String {
        switch self {
        case .up: return "AXScrollUpByPage"
        case .down: return "AXScrollDownByPage"
        case .left: return "AXScrollLeftByPage"
        case .right: return "AXScrollRightByPage"
        }
    }

    public var isVertical: Bool { self == .up || self == .down }
}

/// How `ui.scroll` will move one observed element, or why it cannot.
///
/// Only accessibility primitives: an action the element advertises, or the
/// value of its own scroll bar. NEVER a scroll-wheel event: that is global
/// input, lands under the cursor and (to aim it) needs the cursor moved —
/// exactly what background mode forbids.
public enum BridgeScrollPlan: Equatable, Sendable {
    case pageAction(String)
    case scrollBarValue
    case unsupported(reason: String)
}

public func bridgeScrollPlan(
    direction: BridgeScrollDirection, actions: [String], role: String,
    hasScrollBar: Bool, scrollBarSettable: Bool
) -> BridgeScrollPlan {
    if actions.contains(direction.pageAction) { return .pageAction(direction.pageAction) }
    if hasScrollBar && scrollBarSettable { return .scrollBarValue }
    if hasScrollBar { return .unsupported(reason: "scrollbar_not_settable") }
    if role == "AXScrollArea" { return .unsupported(reason: "scroll_area_without_scrollbar") }
    return .unsupported(reason: "not_scrollable")
}

/// New scroll-bar value for `pages` pages in `direction`, clamped to 0...1.
/// A page is approximated by `pageFraction` of the range when the element
/// cannot report its visible fraction.
public func bridgeScrollBarTarget(
    current: Double, direction: BridgeScrollDirection, pages: Int, pageFraction: Double = 0.2
) -> Double {
    let step = Double(max(1, min(pages, 10))) * max(0.01, min(pageFraction, 1.0))
    let sign: Double = (direction == .down || direction == .right) ? 1 : -1
    return max(0, min(1, current + sign * step))
}

// MARK: - Scroll postcondition

/// What can be measured about a scroll position through accessibility only,
/// along the axis of the requested direction.
///
/// - `barValue`: the scroll bar's AXValue (0…1, grows downward/rightward);
///   the preferred indicator when the element has one.
/// - `contentOrigin`: screen position (AX, top-left origin) of the scrolled
///   content's first non-scroll-bar child; it moves the OPPOSITE way to the
///   scroll (scrolling down moves content up, so y decreases).
public struct BridgeScrollProbe: Equatable, Sendable {
    public var barValue: Double?
    public var contentOrigin: Double?

    public init(barValue: Double? = nil, contentOrigin: Double? = nil) {
        self.barValue = barValue
        self.contentOrigin = contentOrigin
    }

    public var isMeasurable: Bool { barValue != nil || contentOrigin != nil }
}

public enum BridgeScrollEffect: String, Sendable {
    case moved
    case unchanged
    case wrongDirection = "wrong_direction"
    case unmeasurable
}

/// Did the scroll actually happen, in the requested direction?
///
/// The scroll bar value decides when both samples have it; otherwise the
/// content position does. `barEpsilon` is in value units, `pointEpsilon` in
/// points: sub-pixel noise is not a scroll.
public func bridgeScrollEffect(
    direction: BridgeScrollDirection, before: BridgeScrollProbe, after: BridgeScrollProbe,
    barEpsilon: Double = 0.001, pointEpsilon: Double = 1.0
) -> BridgeScrollEffect {
    let forward = direction == .down || direction == .right
    if let b = before.barValue, let a = after.barValue {
        let delta = a - b
        if abs(delta) <= barEpsilon { return .unchanged }
        return (delta > 0) == forward ? .moved : .wrongDirection
    }
    if let b = before.contentOrigin, let a = after.contentOrigin {
        let delta = a - b
        if abs(delta) <= pointEpsilon { return .unchanged }
        return (delta < 0) == forward ? .moved : .wrongDirection
    }
    return .unmeasurable
}

/// The next step of `ui.scroll`, decided from the measured effect.
public enum BridgeScrollStep: Equatable, Sendable {
    /// The scroll happened. `axError` is kept as a diagnostic when the AX
    /// call reported an error although the effect is observable.
    case done(route: String, axError: Int32?)
    /// The page action had no verifiable effect; try the scroll bar value.
    case tryScrollBar
    /// No route produced a verifiable effect.
    case failed(reason: String)
}

/// After the element's own page action: done when the effect is observable
/// in the requested direction, whatever the AX return code said; otherwise
/// the AX-only scroll bar fallback when there is one.
public func bridgeScrollAfterPageAction(
    effect: BridgeScrollEffect, axError: Int32?, scrollBarAvailable: Bool
) -> BridgeScrollStep {
    if effect == .moved { return .done(route: "page_action", axError: axError) }
    if scrollBarAvailable { return .tryScrollBar }
    return .failed(reason: bridgeScrollFailureReason(effect))
}

/// After setting the scroll bar value: done only when observable.
public func bridgeScrollAfterScrollBar(
    effect: BridgeScrollEffect, axError: Int32?
) -> BridgeScrollStep {
    if effect == .moved { return .done(route: "scroll_bar", axError: axError) }
    return .failed(reason: bridgeScrollFailureReason(effect))
}

func bridgeScrollFailureReason(_ effect: BridgeScrollEffect) -> String {
    switch effect {
    case .moved: return "none"
    case .unchanged: return "no_effect"
    case .wrongDirection: return "wrong_direction"
    case .unmeasurable: return "scroll_unverifiable"
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
    /// The target's window became the front-most normal window over the
    /// person's application, with or without activation.
    public let windowRaisedOverPerson: Bool
    /// Milliseconds after the first sample at which the target was first seen
    /// in front; nil when it never was.
    public let targetFrontAtMs: Int?
    /// How long the measurement actually covered, in milliseconds.
    public let observedForMs: Int

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
        restored: Bool = false,
        windowRaisedOverPerson: Bool = false,
        targetFrontAtMs: Int? = nil,
        observedForMs: Int = 0
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
        self.windowRaisedOverPerson = windowRaisedOverPerson
        self.targetFrontAtMs = targetFrontAtMs
        self.observedForMs = observedForMs
    }

    /// Wire shape. Stable keys, no user content beyond application names.
    public func dictionary() -> [String: Any] {
        var wire: [String: Any] = [
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
            "window_raised_over_person": windowRaisedOverPerson,
            "observed_for_ms": observedForMs,
        ]
        if let targetFrontAtMs { wire["target_front_at_ms"] = targetFrontAtMs }
        return wire
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

    // Activation and window order are judged on every reading the sample
    // carries (see BridgeEnvironment), not on the cached frontmost alone.
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
    var windowRaisedOverPerson = false
    var targetFrontAt: Double? = nil
    if let targetBundle, !targetBundle.isEmpty {
        let beforeWasTarget = sequence[0].isActive(targetBundle)
        let beforeWasOnTop = sequence[0].isOnTop(targetBundle)
        for sample in sequence.dropFirst() {
            if !beforeWasTarget && sample.isActive(targetBundle) {
                focusBecameTarget = true
                if targetFrontAt == nil { targetFrontAt = sample.t }
            }
            if !beforeWasOnTop && !beforeWasTarget && sample.isOnTop(targetBundle) {
                windowRaisedOverPerson = true
                if targetFrontAt == nil { targetFrontAt = sample.t }
            }
        }
    }

    // Attribution. The cursor cannot be ours without a posted event; a focus
    // change is ours only when it lands on our own target.
    let cursorMovedByAction = postsInput && cursorMoved
    let externalActivity = (cursorMoved && !postsInput)
        || (focusChanged && !focusBecameTarget && !windowRaisedOverPerson)

    // A breach is a promise broken by THIS action: an accessibility action in a
    // no-interference mode that raised the application it acted on. Pointer or
    // keyboard input is never permitted in those modes, so it cannot be the
    // cause of a breach there.
    let breach = mode.promisesNoInterference
        && actionClass == .accessibility
        && (focusBecameTarget || windowRaisedOverPerson)

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
        restored: sawSomething && endpointsAgree,
        windowRaisedOverPerson: windowRaisedOverPerson,
        targetFrontAtMs: targetFrontAt.map { Int(($0 * 1000).rounded()) },
        observedForMs: Int(((sequence.last?.t ?? 0) - (sequence.first?.t ?? 0)) * 1000)
    )
}

/// Do two samples describe the same frontmost application?
///
/// Bundle id when both have one, display name otherwise: an app without a
/// bundle id still counts as a distinct frontmost application.
func bridgeSameApplication(_ lhs: BridgeEnvironment, _ rhs: BridgeEnvironment) -> Bool {
    let left = lhs.frontmostBundle.isEmpty ? lhs.frontmostApp : lhs.frontmostBundle
    let right = rhs.frontmostBundle.isEmpty ? rhs.frontmostApp : rhs.frontmostBundle
    guard left == right else { return false }
    // The live readings count only when both samples have them: a reading that
    // failed once is "unknown", never a transition.
    if !lhs.focusedBundle.isEmpty, !rhs.focusedBundle.isEmpty,
       lhs.focusedBundle != rhs.focusedBundle { return false }
    if !lhs.topWindowBundle.isEmpty, !rhs.topWindowBundle.isEmpty,
       lhs.topWindowBundle != rhs.topWindowBundle { return false }
    return true
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
