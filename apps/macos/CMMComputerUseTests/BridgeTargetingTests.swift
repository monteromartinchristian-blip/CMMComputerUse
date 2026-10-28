import XCTest

/// Regression tests for the Computer Bridge targeting rules
/// (apps/macos/Shared/BridgeTargeting.swift) — the exact rules the
/// CMMComputerUse helper executes for `app.activate` and `window.focus`.
///
/// These pin the A3 native-action fix: activating Finder by name AND bundle
/// id, focusing a background window by exact title, idempotent success for
/// already-active/already-focused targets, and truthful failure for unknown
/// apps and missing windows. Live side effects (actually stealing focus) are
/// never exercised here; they are proven through the production socket.
final class BridgeTargetingTests: XCTestCase {
    private var running: [BridgeAppCandidate] {
        [
            BridgeAppCandidate(name: "Notes", bundleID: "com.apple.Notes", isActive: true),
            BridgeAppCandidate(name: "Finder", bundleID: "com.apple.finder", isActive: false),
            BridgeAppCandidate(name: "Terminal", bundleID: "com.apple.Terminal", isActive: false),
        ]
    }

    // MARK: - app.activate: Finder by name

    func testActivateFinderByName() {
        let resolved = bridgeResolveApp(request: "Finder", candidates: running)
        XCTAssertEqual(resolved?.name, "Finder")
        XCTAssertEqual(resolved?.bundleID, "com.apple.finder")
    }

    func testActivateFinderByNameCaseInsensitive() {
        XCTAssertEqual(
            bridgeResolveApp(request: "finder", candidates: running)?.bundleID,
            "com.apple.finder")
    }

    // MARK: - app.activate: Finder by bundle id

    func testActivateFinderByBundleID() {
        // The pre-fix helper answered "application not running" here.
        let resolved = bridgeResolveApp(request: "com.apple.finder", candidates: running)
        XCTAssertEqual(resolved?.name, "Finder")
    }

    func testActivateUnknownAppResolvesToNil() {
        // Unknown stays unknown: the helper must report "not running",
        // never activate a guess.
        XCTAssertNil(bridgeResolveApp(request: "NoExiste", candidates: running))
        XCTAssertNil(bridgeResolveApp(request: "", candidates: running))
        XCTAssertNil(bridgeResolveApp(request: "   ", candidates: running))
    }

    // MARK: - already-active app: resolution is state-independent

    func testResolveAlreadyActiveApp() {
        // Idempotence: the already-frontmost app resolves exactly like a
        // background one; the helper returns ok instead of failing.
        let front = bridgeResolveApp(request: "Notes", candidates: running)
        XCTAssertEqual(front?.name, "Notes")
        XCTAssertTrue(front?.isActive ?? false)
        let back = bridgeResolveApp(request: "Finder", candidates: running)
        XCTAssertEqual(back?.name, "Finder")
        XCTAssertFalse(back?.isActive ?? true)
    }

    // MARK: - window.focus: exact title, fragment, background window

    func testFocusWindowByExactTitle() {
        XCTAssertTrue(bridgeWindowTitleMatches(
            windowTitle: "Fixture-E2E-Probe", request: "Fixture-E2E-Probe"))
    }

    func testFocusWindowByFragment() {
        // The planner contract is "<window title fragment>".
        XCTAssertTrue(bridgeWindowTitleMatches(
            windowTitle: "Fixture-E2E-Probe", request: "E2E-Probe"))
    }

    func testFocusWindowTitleCaseInsensitive() {
        XCTAssertTrue(bridgeWindowTitleMatches(
            windowTitle: "Fixture-E2E-Probe", request: "fixture-e2e-probe"))
    }

    func testFocusMissingWindowNeverMatches() {
        // Truthful failure basis: no title matches, so the helper reports
        // "window not found" instead of raising an arbitrary window.
        XCTAssertFalse(bridgeWindowTitleMatches(
            windowTitle: "Capturas", request: "Fixture-E2E-Probe"))
        XCTAssertFalse(bridgeWindowTitleMatches(windowTitle: "", request: "Capturas"))
    }

    func testFocusEmptyRequestNeverMatches() {
        // An empty fragment must not match everything.
        XCTAssertFalse(bridgeWindowTitleMatches(windowTitle: "Capturas", request: ""))
        XCTAssertFalse(bridgeWindowTitleMatches(windowTitle: "Capturas", request: "   "))
    }
}

// MARK: - Activation and focus decisions (A3 native defect)
//
// Production evidence: `window.focus` failed for every app because the helper
// process was not a window-server participant (no LSUIElement, no AppKit
// lifecycle). With that fixed, these rules are what decide the outcome, so
// they are pinned here rather than only observed live.

final class BridgeActivationTests: XCTestCase {

    // MARK: target app inactive → activate

    func testInactiveAppIsActivated() {
        XCTAssertEqual(
            bridgeActivationOutcome(wasActive: false, activateAccepted: true,
                                    becameActive: true, name: "Finder"),
            .activated)
    }

    func testAlreadyActiveAppNeedsNoActivation() {
        XCTAssertEqual(
            bridgeActivationOutcome(wasActive: true, activateAccepted: false,
                                    becameActive: true, name: "Finder"),
            .activated)
    }

    // MARK: the refusal the production defect produced

    func testAcceptedButNotFrontmostIsNotReportedAsSuccess() {
        // activate() returning true proves nothing: the system can accept the
        // request and drop it. Reporting this as success is how the original
        // defect hid.
        XCTAssertEqual(
            bridgeActivationOutcome(wasActive: false, activateAccepted: true,
                                    becameActive: false, name: "Finder"),
            .acceptedButNotFrontmost)
    }

    func testRefusedActivationIsDistinctFromIgnoredOne() {
        let refused = bridgeActivationOutcome(
            wasActive: false, activateAccepted: false,
            becameActive: false, name: "Safari")
        XCTAssertEqual(refused, .refused(reason: "activation was refused for Safari"))
        if case .acceptedButNotFrontmost = refused {
            XCTFail("a refusal must not be reported as an ignored activation")
        }
    }

    // MARK: focus ordering

    func testTitledWindowInInactiveAppActivatesBeforeRaising() {
        // Raising a background window has no visible effect, so the order is
        // part of the contract.
        XCTAssertEqual(bridgeFocusPlan(ownerIsActive: false), .activateThenRaise)
    }

    func testTitledWindowInActiveAppOnlyRaises() {
        XCTAssertEqual(bridgeFocusPlan(ownerIsActive: true), .raiseOnly)
    }

    func testAlreadyFocusedWindowStillMatchesTruthfully() {
        // Idempotent success: the title still matches when already focused.
        XCTAssertTrue(bridgeWindowTitleMatches(
            windowTitle: "Fixture-E2E-Probe", request: "Fixture-E2E-Probe"))
        XCTAssertEqual(bridgeFocusPlan(ownerIsActive: true), .raiseOnly)
    }

    func testMissingWindowNeverMatches() {
        XCTAssertFalse(bridgeWindowTitleMatches(
            windowTitle: "Fixture-E2E-Probe", request: "NoSuchWindow"))
        XCTAssertFalse(bridgeWindowTitleMatches(
            windowTitle: "Fixture-E2E-Probe", request: ""))
    }

    // MARK: readable content rule

    func testReadableLabelsAreContent() {
        for label in ["objeto-1.txt", "informe.pdf", "7 bytes", "Hoy, 1:58"] {
            XCTAssertTrue(
                bridgeIsReadableContent(label: label, role: "AXStaticText",
                                        roleDescription: "texto estático"),
                "\(label) is content a person can read")
        }
    }

    func testLabelsThatOnlyRestateTheRoleAreNotContent() {
        // These describe the widget, not what it shows; emitting them wastes
        // the content budget that file names need.
        XCTAssertFalse(bridgeIsReadableContent(
            label: "celda", role: "AXCell", roleDescription: "celda"))
        XCTAssertFalse(bridgeIsReadableContent(
            label: "file row", role: "AXRow", roleDescription: "file row"))
        XCTAssertFalse(bridgeIsReadableContent(
            label: "AXCell", role: "AXCell", roleDescription: "celda"))
    }

    func testEmptyAndOversizedLabelsAreNotContent() {
        XCTAssertFalse(bridgeIsReadableContent(label: nil, role: "AXCell", roleDescription: nil))
        XCTAssertFalse(bridgeIsReadableContent(label: "   ", role: "AXCell", roleDescription: nil))
        XCTAssertFalse(bridgeIsReadableContent(
            label: String(repeating: "x", count: 401), role: "AXCell", roleDescription: nil))
    }
}
