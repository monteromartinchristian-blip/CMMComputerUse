import XCTest

/// The breach latch (apps/macos/Shared/ComputerUseBreachLatch.swift).
///
/// Product decisions pinned here (2026-11-02):
/// - a breach is latched durably; a helper restart is NOT an unlock;
/// - the only unlock is `breach.rearm` from a v2 client whose policy entry
///   grants `admin: ["breach.rearm"]`, with a reason, audited;
/// - the client whose action caused the breach cannot rearm it;
/// - a latch file that cannot be trusted suspends all control (fail closed);
/// - nothing re-activates the person's previous application after a breach.
final class BreachLatchTests: XCTestCase {

    private let claude = "com.anthropic.claudefordesktop"

    private func record(id: String = "b-1", client: String = "dsh-agent") -> BridgeBreachRecord {
        BridgeBreachRecord(
            id: id, targetBundle: "Com.Anthropic.ClaudeForDesktop", targetName: "Claude",
            clientID: client, kind: "ui.press", policy: "background", at: 1_793_600_000,
            verdict: "focus_changed", focusBecameTarget: true, windowRaisedOverPerson: false,
            targetFrontAtMs: 620)
    }

    private func console(admin: Set<String> = ["breach.rearm"]) -> BridgeClientGrant {
        BridgeClientGrant(clientID: "cmm-console", requirement: "identifier \"com.cmm.console\"",
                          apps: [], scopes: [], adminOperations: admin)
    }

    private func latched() -> BridgeBreachLatchLoad {
        var state = BridgeBreachLatchState()
        state.latch(record())
        return .loaded(state)
    }

    // MARK: - Persistence

    func testRoundTripSurvivesARestart() {
        var state = BridgeBreachLatchState()
        state.latch(record())
        // What a restarted helper reads back is the same latch.
        let reloaded = bridgeLoadBreachLatch(data: state.encoded())
        XCTAssertEqual(reloaded, .loaded(state))
        XCTAssertEqual(reloaded.state?.record(forTarget: claude)?.targetFrontAtMs, 620)
        XCTAssertEqual(reloaded.state?.record(forTarget: claude)?.targetBundle, claude)
    }

    func testNoFileMeansNothingLatched() {
        XCTAssertEqual(bridgeLoadBreachLatch(data: nil), .loaded(BridgeBreachLatchState()))
    }

    func testCorruptFileIsInvalidNotEmpty() {
        XCTAssertEqual(bridgeLoadBreachLatch(data: Data("{".utf8)), .invalid(reason: "not_json"))
        XCTAssertEqual(bridgeLoadBreachLatch(data: Data(#"{"version":9,"breaches":[]}"#.utf8)),
                       .invalid(reason: "unknown_version"))
        XCTAssertEqual(bridgeLoadBreachLatch(data: Data(#"{"version":1,"breaches":[{"id":""}]}"#.utf8)),
                       .invalid(reason: "malformed_record"))
    }

    // MARK: - Enforcement

    func testLatchedTargetRefusesControlInEveryMode() {
        for mode in BridgeInteractionMode.allCases {
            let refusal = bridgeLatchRefusal(load: latched(), targetBundle: claude, isControl: true, mode: mode)
            XCTAssertEqual(refusal?.code, "ACTION_FAILED")
            XCTAssertTrue(refusal?.detail.contains("reason=breach;target=\(claude);breach_id=b-1") ?? false)
            XCTAssertTrue(refusal?.message.contains("CMM Console") ?? false,
                          "the refusal names the unlock path, not a restart")
            XCTAssertFalse(refusal?.message.lowercased().contains("restart") ?? true)
        }
    }

    func testOtherTargetsAndNonControlAreUnaffected() {
        XCTAssertNil(bridgeLatchRefusal(load: latched(), targetBundle: "com.apple.notes", isControl: true, mode: .background))
        XCTAssertNil(bridgeLatchRefusal(load: latched(), targetBundle: claude, isControl: false, mode: .background))
    }

    func testInvalidLatchSuspendsAllControl() {
        let refusal = bridgeLatchRefusal(load: .invalid(reason: "not_json"), targetBundle: "com.apple.notes",
                                         isControl: true, mode: .background)
        XCTAssertTrue(refusal?.detail.contains("reason=breach_latch_invalid") ?? false)
    }

    // MARK: - Rearm authority

    func testConsoleWithAdminGrantRearmsWithAReason() {
        let decision = bridgeRearmDecision(
            arguments: ["breach_id": "b-1", "reason": "  revisado: zoom pulsado por el agente\n"],
            client: console(), clientAuthorization: .required, load: latched())
        XCTAssertEqual(decision, .rearm(record(), reason: "revisado: zoom pulsado por el agente"))
    }

    func testLegacyDeploymentCannotRearm() {
        guard case .refused(let refusal) = bridgeRearmDecision(
            arguments: ["breach_id": "b-1", "reason": "x"], client: nil,
            clientAuthorization: .legacyNone, load: latched()) else { return XCTFail() }
        XCTAssertTrue(refusal.detail.contains("auth=rearm_requires_client_identity"))
    }

    func testUnidentifiedOrUngrantedClientsCannotRearm() {
        guard case .refused(let none) = bridgeRearmDecision(
            arguments: ["breach_id": "b-1", "reason": "x"], client: nil,
            clientAuthorization: .required, load: latched()) else { return XCTFail() }
        XCTAssertTrue(none.detail.contains("auth=client_not_authorized"))
        guard case .refused(let plain) = bridgeRearmDecision(
            arguments: ["breach_id": "b-1", "reason": "x"], client: console(admin: []),
            clientAuthorization: .required, load: latched()) else { return XCTFail() }
        XCTAssertTrue(plain.detail.contains("auth=rearm_not_granted"))
    }

    func testTheClientThatCausedTheBreachCannotClearIt() {
        let agent = BridgeClientGrant(clientID: "DSH-Agent", requirement: "r", adminOperations: ["breach.rearm"])
        guard case .refused(let refusal) = bridgeRearmDecision(
            arguments: ["breach_id": "b-1", "reason": "x"], client: agent,
            clientAuthorization: .required, load: latched()) else { return XCTFail() }
        XCTAssertTrue(refusal.detail.contains("auth=self_rearm_not_permitted"))
    }

    func testReasonAndIdAreRequired() {
        for args: [String: Any] in [["breach_id": "b-1"], ["breach_id": "b-1", "reason": "  \n "]] {
            guard case .refused(let r) = bridgeRearmDecision(
                arguments: args, client: console(), clientAuthorization: .required, load: latched())
            else { return XCTFail() }
            XCTAssertTrue(r.detail.contains("reason=rearm_reason_missing"))
        }
        guard case .refused(let missing) = bridgeRearmDecision(
            arguments: ["reason": "x"], client: console(), clientAuthorization: .required, load: latched())
        else { return XCTFail() }
        XCTAssertTrue(missing.detail.contains("reason=breach_id_missing"))
        guard case .refused(let unknown) = bridgeRearmDecision(
            arguments: ["breach_id": "nope", "reason": "x"], client: console(),
            clientAuthorization: .required, load: latched()) else { return XCTFail() }
        XCTAssertTrue(unknown.detail.contains("reason=unknown_breach"))
    }

    func testInvalidStateIsResetOnlyExplicitly() {
        let invalid = BridgeBreachLatchLoad.invalid(reason: "not_json")
        guard case .refused(let byID) = bridgeRearmDecision(
            arguments: ["breach_id": "b-1", "reason": "x"], client: console(),
            clientAuthorization: .required, load: invalid) else { return XCTFail() }
        XCTAssertTrue(byID.detail.contains("reason=breach_latch_invalid"))
        XCTAssertEqual(bridgeRearmDecision(
            arguments: ["reset_invalid_state": true, "reason": "archivo corrupto"], client: console(),
            clientAuthorization: .required, load: invalid), .resetInvalid(reason: "archivo corrupto"))
        guard case .refused(let valid) = bridgeRearmDecision(
            arguments: ["reset_invalid_state": true, "reason": "x"], client: console(),
            clientAuthorization: .required, load: latched()) else { return XCTFail() }
        XCTAssertTrue(valid.detail.contains("reason=latch_state_valid"))
    }

    func testReasonIsSanitizedAndBounded() {
        XCTAssertEqual(bridgeSanitizedReason("a\u{0007}b\nc"), "a b c")
        XCTAssertEqual(bridgeSanitizedReason(String(repeating: "x", count: 900))?.count, bridgeRearmReasonMaxChars)
        XCTAssertNil(bridgeSanitizedReason(42))
    }

    // MARK: - Audit

    func testAuditEntryCarriesActorReasonAndBreach() {
        let entry = bridgeBreachAuditEntry(
            event: "rearmed", at: 5, record: record(), actorClientID: "cmm-console",
            actorSigningID: "com.cmm.console", reason: "ok")
        XCTAssertEqual(entry["event"] as? String, "rearmed")
        XCTAssertEqual(entry["actor_client_id"] as? String, "cmm-console")
        XCTAssertEqual(entry["actor_signing_id"] as? String, "com.cmm.console")
        XCTAssertEqual((entry["breach"] as? [String: Any])?["id"] as? String, "b-1")
        XCTAssertNotNil(try? JSONSerialization.data(withJSONObject: entry))
    }

    func testBreachesRemovedOutsideRearmAreDetected() {
        var before = BridgeBreachLatchState()
        before.latch(record(id: "a"))
        before.latch(record(id: "b"))
        var after = before
        after.remove(id: "a")
        XCTAssertEqual(bridgeBreachesClearedOutside(before: before, after: after).map { $0.id }, ["a"])
    }

    // MARK: - Policy grant

    func testAdminGrantParsesAndUnknownOperationRefusesTheDocument() {
        let ok = #"{"version":2,"mode":"background","default":"deny","clients":[{"client_id":"cmm-console","requirement":"identifier \"com.cmm.console\"","admin":["breach.rearm"]}],"apps":[]}"#
        let policy = BridgeAuthorizationPolicy.parse(Data(ok.utf8), source: "test")
        XCTAssertEqual(policy?.clients.first?.adminOperations, ["breach.rearm"])
        let typo = ok.replacingOccurrences(of: "breach.rearm", with: "breach.rearmm")
        XCTAssertNil(BridgeAuthorizationPolicy.parse(Data(typo.utf8), source: "test"))
        let none = ok.replacingOccurrences(of: #","admin":["breach.rearm"]"#, with: "")
        XCTAssertEqual(BridgeAuthorizationPolicy.parse(Data(none.utf8), source: "test")?
            .clients.first?.adminOperations, [])
    }
}
