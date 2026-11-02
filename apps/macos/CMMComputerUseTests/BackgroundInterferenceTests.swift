import XCTest

/// Regression tests for the 2026-11-02 background breach that the ledger
/// missed: `ui.press` on an Electron window's zoom button made the target
/// (Claude) frontmost while the report said `verdict=untouched`,
/// `focus_became_target=false`, `transient_focus_changes=0`, `breach=false`.
///
/// Root causes pinned here (pure rules in Shared/ComputerUsePolicy.swift):
///
/// 1. The sampler stopped when `AXUIElementPerformAction` returned; the
///    activation it triggered materialized later. → bounded settle window.
/// 2. Only the CACHED `NSWorkspace.frontmostApplication` was read. → each
///    sample also carries the live AX focused application and the window
///    server's front-most window owner, and any of them naming the target
///    counts.
/// 3. Window controls are intrinsically activating. → refused up front in
///    no-interference modes.
final class BackgroundInterferenceTests: XCTestCase {

    private let harness = "com.deepseek.harness"
    private let claude = "com.anthropic.claudefordesktop"

    private func env(
        front: String, focused: String = "", top: String = "", t: Double = 0,
        x: Double = 100, y: Double = 100
    ) -> BridgeEnvironment {
        BridgeEnvironment(
            frontmostApp: front == claude ? "Claude" : "DeepSeek Harness",
            frontmostBundle: front, cursorX: x, cursorY: y,
            focusedBundle: focused, topWindowBundle: top, t: t)
    }

    // MARK: - The observed defect, reproduced

    func testLateActivationCaughtInSettleSamplesIsABreach() {
        // Before and the samples taken while AXPress ran show the harness; the
        // samples from the settle window (after return) show Claude.
        let before = env(front: harness, focused: harness, top: harness, t: 0)
        let samples = [
            env(front: harness, focused: harness, top: harness, t: 0.05),
            env(front: harness, focused: harness, top: harness, t: 0.30),
            env(front: claude, focused: claude, top: claude, t: 0.62),
            env(front: claude, focused: claude, top: claude, t: 0.90),
        ]
        let after = env(front: claude, focused: claude, top: claude, t: 1.1)
        let report = bridgeInterferenceReport(
            before: before, after: after, samples: samples,
            actionClass: .accessibility, mode: .background, targetBundle: claude)
        XCTAssertTrue(report.focusBecameTarget)
        XCTAssertTrue(report.breach)
        XCTAssertNotEqual(report.verdict, .untouched)
        XCTAssertGreaterThan(report.transientFocusChanges, 0)
        XCTAssertEqual(report.targetFrontAtMs, 620)
        XCTAssertEqual(report.observedForMs, 1100)
        XCTAssertFalse(report.externalActivity)
        let wire = report.dictionary()
        XCTAssertEqual(wire["breach"] as? Bool, true)
        XCTAssertEqual(wire["focus_became_target"] as? Bool, true)
        XCTAssertEqual(wire["target_front_at_ms"] as? Int, 620)
    }

    func testStaleWorkspaceCacheDoesNotHideALiveAXFocusChange() {
        // NSWorkspace still says the harness for every sample (stale cache),
        // the accessibility server already says Claude.
        let before = env(front: harness, focused: harness, t: 0)
        let samples = [env(front: harness, focused: claude, t: 0.4)]
        let after = env(front: harness, focused: claude, t: 0.9)
        let report = bridgeInterferenceReport(
            before: before, after: after, samples: samples,
            actionClass: .accessibility, mode: .background, targetBundle: claude)
        XCTAssertTrue(report.focusBecameTarget)
        XCTAssertTrue(report.breach)
        XCTAssertGreaterThan(report.transientFocusChanges, 0)
    }

    func testWindowOrderedOverThePersonWithoutActivationIsABreach() {
        let before = env(front: harness, focused: harness, top: harness)
        let samples = [env(front: harness, focused: harness, top: claude, t: 0.2)]
        let after = env(front: harness, focused: harness, top: claude, t: 0.8)
        let report = bridgeInterferenceReport(
            before: before, after: after, samples: samples,
            actionClass: .accessibility, mode: .background, targetBundle: claude)
        XCTAssertFalse(report.focusBecameTarget)
        XCTAssertTrue(report.windowRaisedOverPerson)
        XCTAssertTrue(report.breach)
        XCTAssertEqual(report.dictionary()["window_raised_over_person"] as? Bool, true)
    }

    func testUnreadableLiveReadingIsUnknownNotATransition() {
        // An AX read that failed once ("") must not count as a focus change.
        let before = env(front: harness, focused: harness, top: harness)
        let samples = [
            env(front: harness, focused: "", top: harness, t: 0.1),
            env(front: harness, focused: harness, top: "", t: 0.2),
        ]
        let after = env(front: harness, focused: harness, top: harness, t: 0.9)
        let report = bridgeInterferenceReport(
            before: before, after: after, samples: samples,
            actionClass: .accessibility, mode: .background, targetBundle: claude)
        XCTAssertEqual(report.verdict, .untouched)
        XCTAssertEqual(report.transientFocusChanges, 0)
        XCTAssertFalse(report.breach)
    }

    func testTargetAlreadyInFrontIsNotABreach() {
        let before = env(front: claude, focused: claude, top: claude)
        let after = env(front: claude, focused: claude, top: claude, t: 0.8)
        let report = bridgeInterferenceReport(
            before: before, after: after, actionClass: .accessibility,
            mode: .background, targetBundle: claude)
        XCTAssertFalse(report.breach)
    }

    func testUnrelatedSwitchStaysExternalActivity() {
        let before = env(front: harness, focused: harness, top: harness)
        let mail = "com.apple.mail"
        let after = BridgeEnvironment(
            frontmostApp: "Mail", frontmostBundle: mail, cursorX: 100, cursorY: 100,
            focusedBundle: mail, topWindowBundle: mail, t: 0.8)
        let report = bridgeInterferenceReport(
            before: before, after: after, actionClass: .accessibility,
            mode: .background, targetBundle: claude)
        XCTAssertFalse(report.breach)
        XCTAssertTrue(report.externalActivity)
    }

    func testUnrestrictedNeverReportsABreach() {
        let before = env(front: harness, focused: harness)
        let after = env(front: claude, focused: claude, t: 0.8)
        let report = bridgeInterferenceReport(
            before: before, after: after, actionClass: .accessibility,
            mode: .unrestricted, targetBundle: claude)
        XCTAssertTrue(report.focusBecameTarget)
        XCTAssertFalse(report.breach)
    }

    func testLegacyInitializerStillWorks() {
        // Callers that only know the cached reading keep compiling and keep
        // the old semantics.
        let a = BridgeEnvironment(frontmostApp: "A", frontmostBundle: "a", cursorX: 0, cursorY: 0)
        XCTAssertEqual(a.focusedBundle, "")
        XCTAssertEqual(a.topWindowBundle, "")
        XCTAssertEqual(a.t, 0)
    }

    // MARK: - Settle window

    func testSettleWindowCoversTheObservedLatency() {
        let window = bridgeSettleWindow(actionClass: .accessibility)
        // The observed activation needs to land inside the window; 300 ms
        // (the old implicit window) was not enough.
        XCTAssertGreaterThanOrEqual(window.minimum, 0.8)
        XCTAssertLessThanOrEqual(window.maximum, 2.0)
        XCTAssertLessThan(window.minimum, window.maximum)
    }

    func testSettleKeepsGoingUntilMinimumThenUntilQuiet() {
        let window = BridgeSettleWindow(minimum: 0.8, quiet: 0.25, maximum: 2.0)
        XCTAssertTrue(bridgeShouldKeepSettling(window: window, elapsed: 0.1, sinceLastChange: 5))
        XCTAssertFalse(bridgeShouldKeepSettling(window: window, elapsed: 0.9, sinceLastChange: 0.5))
        XCTAssertTrue(bridgeShouldKeepSettling(window: window, elapsed: 0.9, sinceLastChange: 0.1))
        // Bounded: still changing at the ceiling stops anyway.
        XCTAssertFalse(bridgeShouldKeepSettling(window: window, elapsed: 2.0, sinceLastChange: 0))
    }

    // MARK: - Window chrome

    func testWindowControlsAreRefusedInNoInterferenceModes() {
        for subrole in ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"] {
            for mode in [BridgeInteractionMode.background, .focus] {
                let refusal = bridgeWindowChromeRefusal(kind: "ui.press", subrole: subrole, mode: mode)
                XCTAssertEqual(refusal?.code, "CAPABILITY_UNSUPPORTED", "\(subrole) in \(mode)")
                XCTAssertTrue(refusal?.detail.contains("reason=window_chrome") ?? false)
                XCTAssertTrue(refusal?.detail.contains("subrole=\(subrole)") ?? false)
            }
            XCTAssertNil(bridgeWindowChromeRefusal(kind: "ui.press", subrole: subrole, mode: .unrestricted))
        }
    }

    func testOrdinaryButtonsAndOtherKindsAreNotChrome() {
        XCTAssertNil(bridgeWindowChromeRefusal(kind: "ui.press", subrole: nil, mode: .background))
        XCTAssertNil(bridgeWindowChromeRefusal(kind: "ui.press", subrole: "AXToolbarButton", mode: .background))
        XCTAssertNil(bridgeWindowChromeRefusal(kind: "ui.set_value", subrole: "AXZoomButton", mode: .background))
        XCTAssertFalse(bridgeIsWindowChrome(subrole: "AXSearchField"))
    }

    // MARK: - Accessibility-only scroll

    func testScrollIsAnAccessibilityPrimitiveAllowedInBackground() {
        XCTAssertEqual(bridgeActionClass(kind: "ui.scroll"), .accessibility)
        XCTAssertEqual(bridgePolicyDecision(kind: "ui.scroll", mode: .background), .allowed)
        // The global wheel stays global input: refused in background and
        // under any allowlist.
        XCTAssertNotNil(bridgePolicyDecision(kind: "pointer.scroll", mode: .background).refusal)
        XCTAssertNotNil(bridgeGlobalInputDecision(
            kind: "pointer.scroll", mode: .unrestricted, authorizationLoaded: true).refusal)
    }

    func testScrollPrefersTheElementsOwnPageAction() {
        XCTAssertEqual(
            bridgeScrollPlan(direction: .down, actions: ["AXScrollDownByPage"], role: "AXScrollArea",
                             hasScrollBar: true, scrollBarSettable: true),
            .pageAction("AXScrollDownByPage"))
        XCTAssertEqual(
            bridgeScrollPlan(direction: .up, actions: [], role: "AXScrollArea",
                             hasScrollBar: true, scrollBarSettable: true),
            .scrollBarValue)
    }

    func testElectronScrollAreaWithoutScrollBarIsUnsupported() {
        XCTAssertEqual(
            bridgeScrollPlan(direction: .down, actions: ["AXShowMenu"], role: "AXScrollArea",
                             hasScrollBar: false, scrollBarSettable: false),
            .unsupported(reason: "scroll_area_without_scrollbar"))
        XCTAssertEqual(
            bridgeScrollPlan(direction: .down, actions: [], role: "AXScrollArea",
                             hasScrollBar: true, scrollBarSettable: false),
            .unsupported(reason: "scrollbar_not_settable"))
        XCTAssertEqual(
            bridgeScrollPlan(direction: .down, actions: ["AXPress"], role: "AXButton",
                             hasScrollBar: false, scrollBarSettable: false),
            .unsupported(reason: "not_scrollable"))
    }

    func testScrollBarTargetIsClampedAndDirectional() {
        XCTAssertEqual(bridgeScrollBarTarget(current: 0.5, direction: .down, pages: 1), 0.7, accuracy: 1e-9)
        XCTAssertEqual(bridgeScrollBarTarget(current: 0.5, direction: .up, pages: 1), 0.3, accuracy: 1e-9)
        XCTAssertEqual(bridgeScrollBarTarget(current: 0.9, direction: .down, pages: 3), 1.0)
        XCTAssertEqual(bridgeScrollBarTarget(current: 0.1, direction: .up, pages: 3), 0.0)
        XCTAssertEqual(bridgeScrollBarTarget(current: 0.0, direction: .down, pages: 99), 1.0)
    }
}

/// Readable is not actionable (Shared/ComputerUsePolicy.swift, "What an
/// observation offers").
final class AXAccessTests: XCTestCase {
    func testLiveClaudeShapeIsReadable() {
        // AXWindow / AXGroup / AXWebArea / AXHeading as content, no control.
        XCTAssertEqual(bridgeAXAccess(contentCount: 4, elements: []), .readable)
    }

    func testWindowControlsOnlyIsUnavailable() {
        let chrome = Array(repeating: BridgeObservedElement(windowChrome: true, actionable: false), count: 3)
        XCTAssertEqual(bridgeAXAccess(contentCount: 0, elements: chrome), .unavailable)
        XCTAssertEqual(bridgeAXAccess(contentCount: 0, elements: []), .unavailable)
    }

    func testAnyRealControlIsActionable() {
        XCTAssertEqual(bridgeAXAccess(contentCount: 0, elements: [
            BridgeObservedElement(windowChrome: true, actionable: false),
            BridgeObservedElement(windowChrome: false, actionable: true),
        ]), .actionable)
        XCTAssertEqual(bridgeAXAccess(contentCount: 0, elements: [
            BridgeObservedElement(windowChrome: false, actionable: false),
        ]), .readable, "a non-control element is readable, not actionable")
    }

    func testElementActionability() {
        XCTAssertTrue(bridgeElementIsActionable(role: "AXButton", pressable: true, scrollable: false, windowChrome: false))
        XCTAssertTrue(bridgeElementIsActionable(role: "AXTextField", pressable: false, scrollable: false, windowChrome: false))
        XCTAssertTrue(bridgeElementIsActionable(role: "AXScrollArea", pressable: false, scrollable: true, windowChrome: false))
        XCTAssertFalse(bridgeElementIsActionable(role: "AXButton", pressable: true, scrollable: false, windowChrome: true))
        XCTAssertFalse(bridgeElementIsActionable(role: "AXScrollArea", pressable: false, scrollable: false, windowChrome: false))
    }
}
