import XCTest

/// Regression tests for the Computer Use interaction policy
/// (apps/macos/Shared/ComputerUsePolicy.swift) — the exact rules the
/// CMMComputerUse helper applies before it touches the machine.
///
/// The product claim being pinned: in `background` mode this bridge offers
/// accessibility primitives only. It never activates another application,
/// never posts a pointer event (which would move the system cursor) and never
/// posts a global keystroke (which would reach whatever holds focus). Those
/// kinds are refused with a diagnostic that says which requirement is missing,
/// rather than silently degrading into them.
///
/// Nothing here touches the desktop: the module is pure Foundation, so these
/// are the same decisions the helper makes, minus the window server.
final class ComputerUsePolicyTests: XCTestCase {

    // MARK: - Modes

    func testModeParsingIsExactAndCaseInsensitive() {
        XCTAssertEqual(BridgeInteractionMode(flag: "background"), .background)
        XCTAssertEqual(BridgeInteractionMode(flag: " FOCUS "), .focus)
        XCTAssertEqual(BridgeInteractionMode(flag: "Unrestricted"), .unrestricted)
    }

    func testUnknownModeNeverFallsBackToAPermissiveOne() {
        // A typo in the LaunchAgent must be a startup failure, never a silent
        // "you got the permissive mode".
        XCTAssertNil(BridgeInteractionMode(flag: "backgroundd"))
        XCTAssertNil(BridgeInteractionMode(flag: ""))
        XCTAssertNil(BridgeInteractionMode(flag: "all"))
    }

    func testModeOrderingIsByStrictness() {
        XCTAssertTrue(BridgeInteractionMode.background < .focus)
        XCTAssertTrue(BridgeInteractionMode.focus < .unrestricted)
        XCTAssertFalse(BridgeInteractionMode.unrestricted < .background)
        XCTAssertTrue(BridgeInteractionMode.background.promisesNoInterference)
        XCTAssertTrue(BridgeInteractionMode.focus.promisesNoInterference)
        XCTAssertFalse(BridgeInteractionMode.unrestricted.promisesNoInterference)
    }

    // MARK: - Effective mode: narrow, never widen

    func testRequestCanNarrowTheDeploymentMode() {
        XCTAssertEqual(
            bridgeEffectiveMode(requested: .background, deployment: .unrestricted),
            .background)
    }

    func testRequestCanNeverWidenTheDeploymentMode() {
        // The guarantee is the deployment's, not the caller's: a client that
        // asks for more than the helper was launched with gets the helper's
        // mode, not its own.
        XCTAssertEqual(
            bridgeEffectiveMode(requested: .unrestricted, deployment: .background),
            .background)
        XCTAssertEqual(
            bridgeEffectiveMode(requested: .focus, deployment: .background),
            .background)
    }

    func testAbsentRequestKeepsTheDeploymentMode() {
        XCTAssertEqual(bridgeEffectiveMode(requested: nil, deployment: .focus), .focus)
    }

    // MARK: - A malformed request value is refused, never ignored

    func testAbsentPolicyValueMeansTheDeploymentMode() {
        let resolved = bridgeResolveMode(requestedValue: nil, deployment: .unrestricted)
        XCTAssertEqual(resolved.mode, .unrestricted)
        XCTAssertNil(resolved.refusal)
    }

    func testValidPolicyValueNarrows() {
        let resolved = bridgeResolveMode(requestedValue: "background", deployment: .unrestricted)
        XCTAssertEqual(resolved.mode, .background)
        XCTAssertNil(resolved.refusal)
        let wide = bridgeResolveMode(requestedValue: "unrestricted", deployment: .background)
        XCTAssertEqual(wide.mode, .background, "a request can never widen the deployment")
    }

    func testMisspelledPolicyValueIsRefusedInsteadOfFallingBack() {
        // The dangerous shape: a client asks for a strict mode, misspells it,
        // and would otherwise silently get a more permissive deployment mode.
        let resolved = bridgeResolveMode(requestedValue: "backgroud", deployment: .unrestricted)
        XCTAssertEqual(resolved.mode, .unrestricted)
        XCTAssertEqual(resolved.refusal?.code, "CAPABILITY_UNSUPPORTED")
        XCTAssertEqual(resolved.refusal?.detail.contains("policy=invalid"), true)
        XCTAssertEqual(resolved.refusal?.detail.contains("unrestricted"), true)
    }

    func testNonStringPolicyValueIsRefused() {
        let resolved = bridgeResolveMode(requestedValue: 1, deployment: .background)
        XCTAssertEqual(resolved.refusal?.code, "CAPABILITY_UNSUPPORTED")
        XCTAssertEqual(resolved.mode, .background)
    }

    // MARK: - Action classes

    func testEveryAllowlistedKindHasAClass() {
        let kinds = [
            "app.open", "app.activate", "window.focus",
            "ui.press", "ui.set_value",
            "keyboard.type", "keyboard.shortcut",
            "pointer.click", "pointer.scroll", "wait", "finish",
        ]
        for kind in kinds {
            XCTAssertNotNil(bridgeActionClass(kind: kind), "\(kind) must be classified")
        }
        XCTAssertEqual(bridgeActionClass(kind: "ui.press"), .accessibility)
        XCTAssertEqual(bridgeActionClass(kind: "window.focus"), .focus)
        XCTAssertEqual(bridgeActionClass(kind: "pointer.click"), .pointer)
        XCTAssertEqual(bridgeActionClass(kind: "keyboard.type"), .globalKeyboard)
    }

    func testUnknownKindHasNoClass() {
        XCTAssertNil(bridgeActionClass(kind: "shell.exec"))
        XCTAssertNil(bridgeActionClass(kind: ""))
    }

    func testSideEffectsNameThePhysicalConsequence() {
        // The diagnostic a person reads must say what would happen, not
        // "not permitted".
        XCTAssertTrue(bridgeActionSideEffect(kind: "pointer.click").contains("cursor"))
        XCTAssertTrue(bridgeActionSideEffect(kind: "keyboard.type").contains("focus"))
        XCTAssertTrue(bridgeActionSideEffect(kind: "app.activate").contains("frontmost"))
    }

    // MARK: - background: the no-interference mode

    func testBackgroundAllowsAccessibilityPrimitivesOnly() {
        for kind in ["ui.press", "ui.set_value", "wait", "finish"] {
            XCTAssertEqual(
                bridgePolicyDecision(kind: kind, mode: .background), .allowed,
                "\(kind) is an accessibility-only primitive")
        }
    }

    func testBackgroundRefusesActivation() {
        for kind in ["app.open", "app.activate", "window.focus"] {
            let decision = bridgePolicyDecision(kind: kind, mode: .background)
            XCTAssertFalse(decision.isAllowed, "\(kind) must be refused in background mode")
            let refusal = decision.refusal
            XCTAssertEqual(refusal?.code, "CAPABILITY_UNSUPPORTED")
            XCTAssertEqual(refusal?.detail.contains("policy=background"), true)
            XCTAssertEqual(refusal?.detail.contains("requirement=activation"), true)
        }
    }

    func testBackgroundRefusesPointerAndSaysWhy() {
        for kind in ["pointer.click", "pointer.scroll"] {
            let refusal = bridgePolicyDecision(kind: kind, mode: .background).refusal
            XCTAssertEqual(refusal?.code, "CAPABILITY_UNSUPPORTED")
            XCTAssertEqual(refusal?.detail.contains("requirement=global_pointer"), true)
            XCTAssertEqual(refusal?.message.contains("cursor"), true)
        }
    }

    func testBackgroundRefusesGlobalKeyboardAndSaysWhy() {
        for kind in ["keyboard.type", "keyboard.shortcut"] {
            let refusal = bridgePolicyDecision(kind: kind, mode: .background).refusal
            XCTAssertEqual(refusal?.code, "CAPABILITY_UNSUPPORTED")
            XCTAssertEqual(refusal?.detail.contains("requirement=global_keyboard"), true)
            XCTAssertEqual(refusal?.message.contains("focus"), true)
        }
    }

    // MARK: - focus: announced activation, still no global input

    func testFocusModeAllowsActivationOnly() {
        for kind in ["app.open", "app.activate", "window.focus", "ui.press", "wait"] {
            XCTAssertEqual(bridgePolicyDecision(kind: kind, mode: .focus), .allowed)
        }
        for kind in ["pointer.click", "pointer.scroll", "keyboard.type", "keyboard.shortcut"] {
            XCTAssertFalse(
                bridgePolicyDecision(kind: kind, mode: .focus).isAllowed,
                "\(kind) must stay refused: focus mode allows activation, not global input")
        }
    }

    // MARK: - unrestricted: legacy planner surface

    func testUnrestrictedAllowsEveryAllowlistedKind() {
        for kind in [
            "app.open", "app.activate", "window.focus", "ui.press", "ui.set_value",
            "keyboard.type", "keyboard.shortcut", "pointer.click", "pointer.scroll",
            "wait", "finish",
        ] {
            XCTAssertEqual(bridgePolicyDecision(kind: kind, mode: .unrestricted), .allowed)
        }
    }

    func testUnrestrictedStillRefusesAnUnknownKind() {
        let refusal = bridgePolicyDecision(kind: "shell.exec", mode: .unrestricted).refusal
        XCTAssertEqual(refusal?.code, "CAPABILITY_UNSUPPORTED")
        XCTAssertEqual(refusal?.detail.contains("requirement=unknown_kind"), true)
    }

    // MARK: - Global input cannot escape the allowlist

    func testGlobalInputIsRefusedUnderAuthorizationEvenWhenUnrestricted() {
        // Coordinates and keystrokes reach whatever is topmost, not the app the
        // person authorized. `unrestricted` must not turn that into a bypass.
        for kind in ["pointer.click", "pointer.scroll", "keyboard.type", "keyboard.shortcut"] {
            let refusal = bridgeGlobalInputDecision(
                kind: kind, mode: .unrestricted, authorizationLoaded: true).refusal
            XCTAssertEqual(refusal?.code, "APPROVAL_REJECTED", kind)
            XCTAssertEqual(refusal?.detail.contains("global_input_not_scoped"), true, kind)
        }
    }

    func testGlobalInputStillFollowsTheModeWithoutAnAllowlist() {
        // Legacy deployments (no policy file) keep the old surface; the
        // scoped path never does.
        XCTAssertEqual(
            bridgeGlobalInputDecision(kind: "pointer.click", mode: .unrestricted,
                                      authorizationLoaded: false), .allowed)
        XCTAssertEqual(
            bridgeGlobalInputDecision(kind: "pointer.click", mode: .background,
                                      authorizationLoaded: false).refusal?.code,
            "CAPABILITY_UNSUPPORTED")
    }

    func testScopedKindsAreUnaffectedByTheGlobalInputRule() {
        XCTAssertEqual(
            bridgeGlobalInputDecision(kind: "ui.press", mode: .background,
                                      authorizationLoaded: true), .allowed)
    }

    // MARK: - Capture scope

    func testBackgroundCaptureRequiresOneWindow() {
        // A display capture includes every other window the person has open.
        let refusal = bridgeCaptureDecision(mode: .background, hasWindowTarget: false).refusal
        XCTAssertEqual(refusal?.code, "CAPABILITY_UNSUPPORTED")
        XCTAssertEqual(refusal?.detail.contains("capture=display"), true)
        XCTAssertEqual(
            bridgeCaptureDecision(mode: .background, hasWindowTarget: true), .allowed)
    }

    func testLegacyModesMayCaptureTheDisplay() {
        for mode in [BridgeInteractionMode.focus, .unrestricted] {
            XCTAssertEqual(
                bridgeCaptureDecision(mode: mode, hasWindowTarget: false), .allowed)
        }
    }

    // MARK: - Observation lifetime

    func testObservationExpiresInRestrictedModes() {
        XCTAssertEqual(bridgeObservationTimeout(.background), 30)
        XCTAssertEqual(bridgeObservationTimeout(.focus), 30)
        XCTAssertNil(bridgeObservationTimeout(.unrestricted))
    }

    func testObservationExpiryBoundary() {
        let captured = 1_000.0
        XCTAssertFalse(bridgeObservationExpired(capturedAt: captured, now: captured + 29, mode: .background))
        XCTAssertTrue(bridgeObservationExpired(capturedAt: captured, now: captured + 31, mode: .background))
        // A missing observation is not a fresh one.
        XCTAssertTrue(bridgeObservationExpired(capturedAt: 0, now: captured, mode: .background))
        XCTAssertFalse(bridgeObservationExpired(capturedAt: 0, now: captured, mode: .unrestricted))
    }

    func testHandleFromASupersededObservationIsRefused() {
        let refusal = bridgeSnapshotRefusal(current: 7, requested: 6, mode: .background)
        XCTAssertEqual(refusal?.code, "ACTION_FAILED")
        XCTAssertEqual(refusal?.detail.contains("snapshot=6"), true)
        XCTAssertEqual(refusal?.detail.contains("current=7"), true)
        XCTAssertNil(bridgeSnapshotRefusal(current: 7, requested: 7, mode: .background))
    }

    func testRestrictedModesRequireAGenerationAndLegacyDoesNot() {
        // Restricted callers must say which observation they acted on; the
        // legacy planner never sent one and must keep working unchanged.
        XCTAssertEqual(bridgeSnapshotRefusal(current: 3, requested: nil, mode: .background)?.code, "ACTION_FAILED")
        XCTAssertNil(bridgeSnapshotRefusal(current: 3, requested: nil, mode: .unrestricted))
    }

    // MARK: - Interference accounting

    private func environment(
        app: String = "Finder", bundle: String = "com.apple.finder",
        x: Double = 500, y: Double = 400
    ) -> BridgeEnvironment {
        BridgeEnvironment(frontmostApp: app, frontmostBundle: bundle, cursorX: x, cursorY: y)
    }

    func testUnchangedEnvironmentIsUntouched() {
        let report = bridgeInterferenceReport(
            before: environment(), after: environment(),
            actionClass: .accessibility, mode: .background)
        XCTAssertEqual(report.verdict, .untouched)
        XCTAssertFalse(report.breach)
        XCTAssertFalse(report.cursorMoved)
    }

    func testFocusChangeToAnUnrelatedAppIsExternalActivityNotABreach() {
        // The person switched windows while the action ran. That is their
        // business, not the bridge's: nothing here posted an activation.
        let report = bridgeInterferenceReport(
            before: environment(), after: environment(app: "Terminal", bundle: "com.apple.Terminal"),
            actionClass: .accessibility, mode: .background)
        XCTAssertEqual(report.verdict, .focusChanged)
        XCTAssertFalse(report.breach)
        XCTAssertTrue(report.externalActivity)
        XCTAssertFalse(report.focusBecameTarget)
        XCTAssertEqual(report.frontmostBefore, "Finder")
        XCTAssertEqual(report.frontmostAfter, "Terminal")
    }

    func testFocusChangeOntoTheActionsOwnTargetIsABreach() {
        // This is the one focus change an AX press can plausibly cause: the
        // application raising its own window when its control is pressed.
        let report = bridgeInterferenceReport(
            before: environment(),
            after: environment(app: "CMM CU Fixture", bundle: "com.cmm.cu.fixture"),
            actionClass: .accessibility, mode: .background,
            targetBundle: "com.cmm.cu.fixture")
        XCTAssertEqual(report.verdict, .focusChanged)
        XCTAssertTrue(report.focusBecameTarget)
        XCTAssertTrue(report.breach)
        XCTAssertFalse(report.externalActivity)
    }

    func testAccessibilityActionsPostNoCursorEventsSoMovementIsExternal() {
        // The whole point: `ui.press` calls AXPress and posts no HID event. A
        // pointer delta measured around it cannot be attributed to the bridge,
        // whatever the person is doing with the mouse.
        let report = bridgeInterferenceReport(
            before: environment(x: 500, y: 400), after: environment(x: 501, y: 400),
            actionClass: .accessibility, mode: .background)
        XCTAssertEqual(report.verdict, .cursorMoved)
        XCTAssertTrue(report.cursorMoved)
        XCTAssertFalse(report.cursorEventsPosted)
        XCTAssertFalse(report.cursorMovedByAction)
        XCTAssertFalse(report.breach)
        XCTAssertTrue(report.externalActivity)
        XCTAssertEqual(report.cursorDx, 1)
    }

    func testPointerActionsCanMoveTheCursorByConstruction() {
        let report = bridgeInterferenceReport(
            before: environment(x: 10, y: 10), after: environment(x: 410, y: 10),
            actionClass: .pointer, mode: .unrestricted)
        XCTAssertTrue(report.cursorEventsPosted)
        XCTAssertTrue(report.cursorMovedByAction)
        XCTAssertFalse(report.breach, "the permissive mode never promised otherwise")
    }

    func testToleranceAbsorbsJitterButNotRealMovement() {
        let jitter = bridgeInterferenceReport(
            before: environment(x: 500, y: 400), after: environment(x: 500.4, y: 400.2),
            actionClass: .accessibility, mode: .background, tolerance: 1.0)
        XCTAssertEqual(jitter.verdict, .untouched)
        let real = bridgeInterferenceReport(
            before: environment(x: 500, y: 400), after: environment(x: 530, y: 400),
            actionClass: .accessibility, mode: .background, tolerance: 1.0)
        XCTAssertEqual(real.verdict, .cursorMoved)
        XCTAssertFalse(real.breach)
    }

    func testBothChangedIsOneVerdictAndStaysExternalWithoutATarget() {
        let report = bridgeInterferenceReport(
            before: environment(),
            after: environment(app: "Safari", bundle: "com.apple.Safari", x: 10, y: 10),
            actionClass: .accessibility, mode: .background)
        XCTAssertEqual(report.verdict, .focusAndCursorChanged)
        XCTAssertTrue(report.externalActivity)
        XCTAssertFalse(report.breach)
    }

    func testFocusActionsInBackgroundModeDoNotBreachTheAccessibilityContract() {
        // A focus action is refused before it runs there; if it ever ran, the
        // change would be its job, not a broken accessibility promise.
        let report = bridgeInterferenceReport(
            before: environment(), after: environment(app: "Terminal", bundle: "com.apple.Terminal"),
            actionClass: .focus, mode: .background)
        XCTAssertEqual(report.verdict, .focusChanged)
        XCTAssertFalse(report.breach)
    }

    func testReportDictionaryHasTheStableWireShape() {
        let report = bridgeInterferenceReport(
            before: environment(), after: environment(x: 505, y: 400),
            actionClass: .accessibility, mode: .background)
        let wire = report.dictionary()
        XCTAssertEqual(wire["verdict"] as? String, "cursor_moved")
        XCTAssertEqual(wire["policy"] as? String, "background")
        XCTAssertEqual(wire["action_class"] as? String, "accessibility")
        XCTAssertEqual(wire["cursor_moved"] as? Bool, true)
        XCTAssertEqual(wire["cursor_dx"] as? Int, 5)
        XCTAssertEqual(wire["attributed"] as? Bool, false,
                       "a delta between two samples is evidence, never attribution")
        XCTAssertEqual(wire["breach"] as? Bool, false)
        XCTAssertEqual(wire["cursor_events_posted"] as? Bool, false)
        XCTAssertEqual(wire["cursor_moved_by_action"] as? Bool, false)
        XCTAssertEqual(wire["external_activity"] as? Bool, true)
        XCTAssertEqual(wire["focus_became_target"] as? Bool, false)
        XCTAssertEqual(wire["frontmost_before"] as? String, "Finder")
    }

    // MARK: - Transient interference (sampled during the action)

    func testTransientRaiseOfTheTargetIsABreachEvenWhenItDropsBack() {
        // The shape a before/after pair cannot see: the fixture raises itself
        // for a moment and drops back, so both endpoints say Finder.
        let report = bridgeInterferenceReport(
            before: environment(),
            after: environment(),
            samples: [environment(app: "CMM CU Fixture", bundle: "com.cmm.cu.fixture")],
            actionClass: .accessibility, mode: .background,
            targetBundle: "com.cmm.cu.fixture")
        XCTAssertEqual(report.verdict, .focusChanged)
        XCTAssertEqual(report.sampled, 1)
        XCTAssertEqual(report.transientFocusChanges, 2,
                       "Finder → Fixture → Finder is two transitions")
        XCTAssertTrue(report.restored, "the endpoints agree; only the samples saw it")
        XCTAssertTrue(report.focusBecameTarget)
        XCTAssertTrue(report.breach)
    }

    func testTransientSwitchToAnotherAppIsExternal() {
        let report = bridgeInterferenceReport(
            before: environment(),
            after: environment(),
            samples: [environment(app: "Terminal", bundle: "com.apple.Terminal")],
            actionClass: .accessibility, mode: .background,
            targetBundle: "com.cmm.cu.fixture")
        XCTAssertEqual(report.verdict, .focusChanged)
        XCTAssertFalse(report.breach)
        XCTAssertFalse(report.focusBecameTarget)
        XCTAssertTrue(report.externalActivity)
    }

    func testTransientCursorMoveIsReported() {
        let report = bridgeInterferenceReport(
            before: environment(x: 500, y: 400),
            after: environment(x: 500, y: 400),
            samples: [environment(x: 540, y: 400)],
            actionClass: .accessibility, mode: .background)
        XCTAssertEqual(report.verdict, .cursorMoved)
        XCTAssertEqual(report.transientCursorMaxDelta, 40)
        XCTAssertEqual(report.cursorDx, 40)
        XCTAssertTrue(report.restored)
        XCTAssertFalse(report.cursorMovedByAction)
        XCTAssertTrue(report.externalActivity)
    }

    func testCleanSamplesKeepTheResultUntouched() {
        let report = bridgeInterferenceReport(
            before: environment(),
            after: environment(),
            samples: [environment(), environment(), environment()],
            actionClass: .accessibility, mode: .background)
        XCTAssertEqual(report.verdict, .untouched)
        XCTAssertEqual(report.sampled, 3)
        XCTAssertEqual(report.transientFocusChanges, 0)
        XCTAssertFalse(report.restored)
        XCTAssertFalse(report.breach)
    }

    func testSampledReportKeepsTheWireShape() {
        let report = bridgeInterferenceReport(
            before: environment(),
            after: environment(),
            samples: [environment(app: "Terminal", bundle: "com.apple.Terminal")],
            actionClass: .accessibility, mode: .background)
        let wire = report.dictionary()
        XCTAssertEqual(wire["sampled"] as? Int, 1)
        XCTAssertEqual(wire["transient_focus_changes"] as? Int, 2)
        XCTAssertEqual(wire["restored"] as? Bool, true)
        XCTAssertEqual(wire["breach"] as? Bool, false,
                       "a switch to an unrelated app is not this action's doing")
    }

    // MARK: - Window selection (capture target)

    private var windows: [BridgeWindowCandidate] {
        [
            BridgeWindowCandidate(windowID: 1, title: "Notes — Recordatorios", app: "Notes", width: 1200, height: 800),
            BridgeWindowCandidate(windowID: 2, title: "Notes — Ajustes", app: "Notes", width: 800, height: 600),
            BridgeWindowCandidate(windowID: 3, title: "Notas", app: "Notes", width: 900, height: 700),
        ]
    }

    func testExactTitleSelectsOneWindow() {
        guard case .selected(let window) = bridgeSelectWindow(
            request: "Notas", app: nil, candidates: windows) else {
            return XCTFail("exactly one window matches")
        }
        XCTAssertEqual(window.windowID, 3)
    }

    func testFragmentIsCaseInsensitiveAndScopedToTheApp() {
        guard case .selected(let window) = bridgeSelectWindow(
            request: "ajustes", app: "notes", candidates: windows) else {
            return XCTFail("fragment must match inside the named app")
        }
        XCTAssertEqual(window.windowID, 2)
    }

    func testSeveralMatchesAreRefusedInsteadOfGuessed() {
        // Two Notes windows match "Notes": picking one would be an
        // arbitrary choice about which of the person's windows gets captured.
        switch bridgeSelectWindow(request: "Notes", app: nil, candidates: windows) {
        case .ambiguous(let matches):
            XCTAssertEqual(matches.count, 2)
        default:
            XCTFail("an ambiguous request must not select a window")
        }
    }

    func testEmptyTitleNeverMatches() {
        XCTAssertEqual(bridgeSelectWindow(request: "  ", app: nil, candidates: windows), .notFound)
    }

    func testUnknownAppIsNotFound() {
        XCTAssertEqual(
            bridgeSelectWindow(request: "Notas", app: "Safari", candidates: windows), .notFound)
    }

    func testAppFilterIsAnExactNameOrBundleID() {
        // The app filter uses the same "exact name or exact bundle id" rule
        // the activation path uses: a fragment of a name is not a target.
        XCTAssertEqual(
            bridgeSelectWindow(request: "Notas", app: "note", candidates: windows), .notFound)
        XCTAssertEqual(
            bridgeSelectWindow(request: "Notas", app: "com.apple.Notes", candidates: windows), .notFound,
            "these fixtures carry no bundle id; an unknown id must not match by name")
        let withBundle = windows.map {
            BridgeWindowCandidate(
                windowID: $0.windowID, title: $0.title, app: $0.app,
                bundleID: $0.app == "Notes" ? "com.apple.Notes" : "com.apple.finder",
                width: $0.width, height: $0.height)
        }
        guard case .selected(let window) = bridgeSelectWindow(
            request: "Notas", app: "com.apple.notes", candidates: withBundle) else {
            return XCTFail("an exact bundle id must select the window")
        }
        XCTAssertEqual(window.windowID, 3)
    }

    // MARK: - Window identity (the live stream's target)

    /// The live mirror is bound to a window id, not to a title: the title
    /// follows the active tab, so a mirror keyed on it dies the moment the
    /// person navigates. The id resolver must therefore work even when the
    /// title has already changed underneath the caller.
    func testWindowIDSelectsEvenWhenTheTitleMoved() {
        let moved = windows.map {
            BridgeWindowCandidate(
                windowID: $0.windowID, title: $0.windowID == 3 ? "Otra pestaña" : $0.title,
                app: $0.app, width: $0.width, height: $0.height)
        }
        guard case .selected(let window) = bridgeResolveWindowById(
            windowID: 3, app: nil, candidates: moved) else {
            return XCTFail("the window id must resolve after a title change")
        }
        XCTAssertEqual(window.windowID, 3)
        // And the stale title no longer resolves: proof the id is what held.
        XCTAssertEqual(
            bridgeSelectWindow(request: "Notas", app: nil, candidates: moved), .notFound)
    }

    func testUnknownWindowIDIsNotFound() {
        XCTAssertEqual(
            bridgeResolveWindowById(windowID: 99, app: nil, candidates: windows), .notFound)
    }

    /// An id must not reach a window of another application: a client that
    /// names the app it may observe cannot use a guessed number to escape it.
    func testWindowIDIsScopedToTheNamedApp() {
        XCTAssertEqual(
            bridgeResolveWindowById(windowID: 3, app: "Safari", candidates: windows), .notFound)
        guard case .selected(let window) = bridgeResolveWindowById(
            windowID: 3, app: "notes", candidates: windows) else {
            return XCTFail("the owning app must accept its own window id")
        }
        XCTAssertEqual(window.windowID, 3)
    }
}
