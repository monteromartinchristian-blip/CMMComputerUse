import XCTest

/// Attribution of a focus change onto the target (Shared/ComputerUsePolicy.swift,
/// "Human input witness").
///
/// Bug (2026-11-02): the person clicked Claude while an AX action on Claude was
/// settling; the ledger saw Claude come to the front and latched a breach. The
/// facts (`focusBecameTarget`, `windowRaisedOverPerson`) stay; the BREACH now
/// requires the change to be attributable to the action: no correlated
/// focus-capable physical input, or no reliable witness (fail closed).
final class HumanTakeoverAttributionTests: XCTestCase {

    private let harness = "com.apple.Terminal"
    private let claude = "com.anthropic.claudefordesktop"
    /// "No recent input": ages far larger than any measurement.
    private let idle = BridgeHumanInputSample(mouseDownAge: 600, keyDownAge: 600, flagsChangedAge: 600)

    /// A sample at `t` whose witness says the last mouse-down / key-down /
    /// modifier change happened at the given ABSOLUTE times (nil = long ago).
    private func witness(at t: Double, mouseDownAt: Double? = nil, keyDownAt: Double? = nil,
                         flagsAt: Double? = nil, command: Bool = false) -> BridgeHumanInputSample {
        BridgeHumanInputSample(
            mouseDownAge: mouseDownAt.map { t - $0 } ?? 600,
            keyDownAge: keyDownAt.map { t - $0 } ?? 600,
            flagsChangedAge: flagsAt.map { t - $0 } ?? 600,
            commandHeld: command)
    }

    private func env(_ t: Double, front: String, focused: String? = nil, top: String? = nil,
                     x: Double = 100, input: BridgeHumanInputSample?) -> BridgeEnvironment {
        BridgeEnvironment(
            frontmostApp: front == claude ? "Claude" : "Terminal", frontmostBundle: front,
            cursorX: x, cursorY: 100, focusedBundle: focused ?? front, topWindowBundle: top ?? front,
            t: t, humanInput: input)
    }

    private func report(_ sequence: [BridgeEnvironment], mode: BridgeInteractionMode = .background)
        -> BridgeInterferenceReport {
        bridgeInterferenceReport(
            before: sequence.first!, after: sequence.last!, samples: Array(sequence.dropFirst().dropLast()),
            actionClass: .accessibility, mode: mode, targetBundle: claude)
    }

    // 1. Late target activation, no human input -> breach.
    func testLateActivationWithoutHumanInputIsABreach() {
        let r = report([
            env(0, front: harness, input: idle),
            env(0.3, front: harness, input: idle),
            env(0.62, front: claude, input: idle),
            env(1.1, front: claude, input: idle),
        ])
        XCTAssertTrue(r.focusBecameTarget)
        XCTAssertEqual(r.focusChangeAttribution, .action)
        XCTAssertTrue(r.humanWitnessAvailable)
        XCTAssertFalse(r.humanInputDetected)
        XCTAssertFalse(r.externalActivity)
        XCTAssertTrue(r.breach)
        XCTAssertFalse(r.requiresReobserve)
    }

    // 2. Stale NSWorkspace + live AX focus, no human input -> breach.
    func testStaleWorkspaceLiveAXFocusWithoutHumanInputIsABreach() {
        let r = report([
            env(0, front: harness, input: idle),
            env(0.4, front: harness, focused: claude, input: idle),
            env(0.9, front: harness, focused: claude, input: idle),
        ])
        XCTAssertTrue(r.focusBecameTarget)
        XCTAssertEqual(r.focusChangeAttribution, .action)
        XCTAssertTrue(r.breach)
    }

    // 3. Window raised over the person, no human input -> breach.
    func testWindowRaisedWithoutHumanInputIsABreach() {
        let r = report([
            env(0, front: harness, input: idle),
            env(0.2, front: harness, top: claude, input: idle),
            env(0.8, front: harness, top: claude, input: idle),
        ])
        XCTAssertFalse(r.focusBecameTarget)
        XCTAssertTrue(r.windowRaisedOverPerson)
        XCTAssertEqual(r.focusChangeAttribution, .action)
        XCTAssertTrue(r.breach)
    }

    // 4. Correlated mouse-down -> the person; no breach, external.
    func testCorrelatedMouseDownIsAUserTakeover() {
        // Click at 0.50, Claude seen in front at 0.55.
        let r = report([
            env(0, front: harness, input: idle),
            env(0.45, front: harness, input: idle),
            env(0.50, front: harness, input: witness(at: 0.50, mouseDownAt: 0.50)),
            env(0.55, front: claude, input: witness(at: 0.55, mouseDownAt: 0.50)),
            env(1.0, front: claude, input: witness(at: 1.0, mouseDownAt: 0.50)),
        ])
        XCTAssertTrue(r.focusBecameTarget, "the fact is still reported")
        XCTAssertEqual(r.focusChangeAttribution, .user)
        XCTAssertTrue(r.humanInputDetected)
        XCTAssertEqual(r.humanInputKind, .mouseDown)
        XCTAssertEqual(r.humanInputAgeMs, 50)
        XCTAssertTrue(r.externalActivity)
        XCTAssertFalse(r.breach)
        XCTAssertTrue(r.requiresReobserve)
    }

    // 5. Correlated ⌘-key down -> the person; no breach, external.
    func testCorrelatedCommandKeyDownIsAUserTakeover() {
        let r = report([
            env(0, front: harness, input: idle),
            env(0.40, front: harness, input: witness(at: 0.40, keyDownAt: 0.39, command: true)),
            env(0.60, front: claude, input: witness(at: 0.60, keyDownAt: 0.39, command: true)),
            env(1.0, front: claude, input: witness(at: 1.0, keyDownAt: 0.39)),
        ])
        XCTAssertEqual(r.focusChangeAttribution, .user)
        XCTAssertEqual(r.humanInputKind, .commandKeyDown)
        XCTAssertTrue(r.externalActivity)
        XCTAssertFalse(r.breach)
    }

    func testCommandTabReleaseLongAfterTabStillCounts() {
        // Tab pressed at 0.1 with ⌘ held (too old by itself), ⌘ released at 1.2,
        // Claude in front at 1.25.
        let r = report([
            env(0, front: harness, input: witness(at: 0, command: true)),
            env(0.2, front: harness, input: witness(at: 0.2, keyDownAt: 0.1, command: true)),
            env(1.2, front: harness, input: witness(at: 1.2, keyDownAt: 0.1, command: true)),
            env(1.22, front: harness, input: witness(at: 1.22, keyDownAt: 0.1, flagsAt: 1.21, command: false)),
            env(1.25, front: claude, input: witness(at: 1.25, keyDownAt: 0.1, flagsAt: 1.21)),
            env(1.6, front: claude, input: witness(at: 1.6, keyDownAt: 0.1, flagsAt: 1.21)),
        ])
        XCTAssertEqual(r.focusChangeAttribution, .user)
        XCTAssertEqual(r.humanInputKind, .commandRelease)
        XCTAssertFalse(r.breach)
    }

    func testPlainTypingIsNotAFocusInput() {
        // A key without ⌘ (the person typing in Terminal) right before the raise.
        let r = report([
            env(0, front: harness, input: idle),
            env(0.5, front: harness, input: witness(at: 0.5, keyDownAt: 0.48)),
            env(0.55, front: claude, input: witness(at: 0.55, keyDownAt: 0.48)),
            env(1.0, front: claude, input: witness(at: 1.0, keyDownAt: 0.48)),
        ])
        XCTAssertEqual(r.focusChangeAttribution, .action)
        XCTAssertTrue(r.breach)
    }

    // 6. Human input too old -> breach.
    func testHumanInputTooOldStillBreaches() {
        // Click 1.0 s before Claude came up: outside the 0.75 s window.
        let r = report([
            env(0, front: harness, input: witness(at: 0, mouseDownAt: -0.2)),
            env(0.5, front: harness, input: witness(at: 0.5, mouseDownAt: -0.2)),
            env(0.8, front: claude, input: witness(at: 0.8, mouseDownAt: -0.2)),
            env(1.2, front: claude, input: witness(at: 1.2, mouseDownAt: -0.2)),
        ])
        XCTAssertEqual(r.focusChangeAttribution, .action)
        XCTAssertFalse(r.humanInputDetected)
        XCTAssertTrue(r.breach)
    }

    func testInputAfterTheTransitionBeyondSkewDoesNotExcuseIt() {
        // Claude up at 0.55; the click comes 200 ms later (person reacting to it).
        let r = report([
            env(0, front: harness, input: idle),
            env(0.55, front: claude, input: idle),
            env(0.75, front: claude, input: witness(at: 0.75, mouseDownAt: 0.75)),
            env(1.2, front: claude, input: witness(at: 1.2, mouseDownAt: 0.75)),
        ])
        XCTAssertEqual(r.focusChangeAttribution, .action)
        XCTAssertTrue(r.breach)
    }

    func testInputWithinSkewAfterTheFirstSampleIsAmbiguousNoLatch() {
        let r = report([
            env(0, front: harness, input: idle),
            env(0.55, front: claude, input: idle),
            env(0.58, front: claude, input: witness(at: 0.58, mouseDownAt: 0.57)),
            env(1.0, front: claude, input: witness(at: 1.0, mouseDownAt: 0.57)),
        ])
        XCTAssertEqual(r.focusChangeAttribution, .ambiguousExternal)
        XCTAssertTrue(r.externalActivity)
        XCTAssertFalse(r.breach)
        XCTAssertTrue(r.requiresReobserve)
    }

    // 7. Mouse movement alone never hides a breach.
    func testCursorMovementWithoutAClickDoesNotHideABreach() {
        let r = report([
            env(0, front: harness, x: 100, input: idle),
            env(0.4, front: harness, x: 160, input: idle),
            env(0.55, front: claude, x: 220, input: idle),
            env(1.0, front: claude, x: 260, input: idle),
        ])
        XCTAssertTrue(r.cursorMoved)
        XCTAssertFalse(r.cursorMovedByAction)
        XCTAssertEqual(r.focusChangeAttribution, .action)
        XCTAssertTrue(r.breach)
    }

    // 8. Unrelated app switch stays external activity.
    func testUnrelatedSwitchStaysExternal() {
        let mail = "com.apple.mail"
        let r = report([
            env(0, front: harness, input: idle),
            env(0.5, front: mail, input: witness(at: 0.5, mouseDownAt: 0.48)),
            env(1.0, front: mail, input: witness(at: 1.0, mouseDownAt: 0.48)),
        ])
        XCTAssertEqual(r.focusChangeAttribution, .none)
        XCTAssertTrue(r.externalActivity)
        XCTAssertFalse(r.breach)
        XCTAssertFalse(r.requiresReobserve)
    }

    // 9. Target already in front before the action -> no breach.
    func testTargetAlreadyInFrontIsNoBreach() {
        let r = report([
            env(0, front: claude, input: idle),
            env(1.0, front: claude, input: idle),
        ])
        XCTAssertEqual(r.focusChangeAttribution, .none)
        XCTAssertFalse(r.breach)
    }

    // 10. No reliable witness -> fail closed.
    func testUnavailableWitnessFailsClosed() {
        let click = witness(at: 0.5, mouseDownAt: 0.5)
        for broken: BridgeHumanInputSample? in [nil, BridgeHumanInputSample(mouseDownAge: .nan),
                                                 BridgeHumanInputSample(keyDownAge: -1)] {
            let r = report([
                env(0, front: harness, input: idle),
                env(0.5, front: harness, input: broken),      // one bad reading is enough
                env(0.55, front: claude, input: click),
                env(1.0, front: claude, input: click),
            ])
            XCTAssertFalse(r.humanWitnessAvailable)
            XCTAssertEqual(r.focusChangeAttribution, .unknown)
            XCTAssertTrue(r.breach, "no telemetry is never a reason to excuse a raise")
        }
    }

    func testLegacySamplesWithoutAWitnessKeepTheStrictBehaviour() {
        let r = bridgeInterferenceReport(
            before: BridgeEnvironment(frontmostApp: "T", frontmostBundle: harness, cursorX: 0, cursorY: 0),
            after: BridgeEnvironment(frontmostApp: "C", frontmostBundle: claude, cursorX: 0, cursorY: 0, t: 0.8),
            actionClass: .accessibility, mode: .background, targetBundle: claude)
        XCTAssertEqual(r.focusChangeAttribution, .unknown)
        XCTAssertTrue(r.breach)
    }

    // 11. Wire keeps the old keys and adds the attribution.
    func testWireKeepsOldKeysAndAddsAttribution() {
        let r = report([
            env(0, front: harness, input: idle),
            env(0.50, front: harness, input: witness(at: 0.50, mouseDownAt: 0.50)),
            env(0.55, front: claude, input: witness(at: 0.55, mouseDownAt: 0.50)),
            env(1.0, front: claude, input: witness(at: 1.0, mouseDownAt: 0.50)),
        ])
        let wire = r.dictionary()
        for key in ["verdict", "breach", "focus_became_target", "window_raised_over_person",
                    "external_activity", "cursor_events_posted", "cursor_moved_by_action",
                    "target_front_at_ms", "observed_for_ms", "sampled", "transient_focus_changes"] {
            XCTAssertNotNil(wire[key], key)
        }
        XCTAssertEqual(wire["focus_change_attribution"] as? String, "user")
        XCTAssertEqual(wire["human_input_detected"] as? Bool, true)
        XCTAssertEqual(wire["human_input_kind"] as? String, "mouse_down")
        XCTAssertEqual(wire["human_input_age_ms"] as? Int, 50)
        XCTAssertEqual(wire["human_witness_available"] as? Bool, true)
        XCTAssertEqual(wire["requires_reobserve"] as? Bool, true)
        XCTAssertEqual(wire["breach"] as? Bool, false)
        XCTAssertNotNil(try? JSONSerialization.data(withJSONObject: wire))
    }

    func testUnrestrictedNeverBreachesEitherWay() {
        let r = report([
            env(0, front: harness, input: idle),
            env(0.6, front: claude, input: idle),
            env(1.0, front: claude, input: idle),
        ], mode: .unrestricted)
        XCTAssertEqual(r.focusChangeAttribution, .action)
        XCTAssertFalse(r.breach)
    }

    func testThresholdsArePinned() {
        XCTAssertEqual(bridgeHumanFocusWindow, 0.75)
        XCTAssertEqual(bridgeHumanFocusSkew, 0.06)
        // The settle window this attribution rides on is unchanged.
        XCTAssertEqual(bridgeSettleWindow(actionClass: .accessibility),
                       BridgeSettleWindow(minimum: 0.8, quiet: 0.25, maximum: 2.0))
    }
}
