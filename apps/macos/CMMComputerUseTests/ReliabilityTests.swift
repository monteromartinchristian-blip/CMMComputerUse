import XCTest

/// Reliability Engine rules (Shared/ComputerUseReliability.swift): which
/// operations may be retried automatically, how an action's outcome is named,
/// and the operation-id ledger that makes a resent mutating action replay its
/// recorded outcome instead of running twice.
final class ReliabilityTests: XCTestCase {

    private let dsh = BridgePrincipal(key: "client:dsh", strength: .verifiedClient)
    private let other = BridgePrincipal(key: "client:other", strength: .verifiedClient)

    // MARK: 15. a mutating action is never retried automatically

    func testOnlyReadsAndIdempotentHelperStateAreRetryable() {
        XCTAssertEqual(bridgeRetryClass(operation: "action.execute", kind: "ui.press"), .mutating)
        XCTAssertEqual(bridgeRetryClass(operation: "action.execute", kind: "ui.set_value"), .mutating)
        XCTAssertEqual(bridgeRetryClass(operation: "action.execute", kind: "ui.scroll"), .mutating)
        XCTAssertEqual(bridgeRetryClass(operation: "action.execute", kind: "keyboard.type"), .mutating)
        XCTAssertEqual(bridgeRetryClass(operation: "action.execute", kind: nil), .mutating,
                       "an action of unknown kind is treated as mutating")
        XCTAssertEqual(bridgeRetryClass(operation: "action.execute", kind: "wait"), .read)
        XCTAssertEqual(bridgeRetryClass(operation: "observation.describe", kind: nil), .read)
        XCTAssertEqual(bridgeRetryClass(operation: "observation.stream_frame", kind: nil), .read)
        XCTAssertEqual(bridgeRetryClass(operation: "workspace.context_close", kind: nil), .idempotent)
        XCTAssertEqual(bridgeRetryClass(operation: "observation.stream_stop", kind: nil), .idempotent)
        XCTAssertEqual(bridgeRetryClass(operation: "breach.rearm", kind: nil), .mutating)
        XCTAssertEqual(bridgeRetryClass(operation: "some.future_op", kind: nil), .mutating,
                       "unknown operations fail closed: no automatic retry")
        XCTAssertEqual(bridgeRetryDelays(.mutating), [])
        XCTAssertFalse(bridgeRetryDelays(.read).isEmpty)
    }

    func testOutcomeNamesDistinguishNotExecutedFromFailedFromUnknown() {
        XCTAssertEqual(bridgeExecutionOutcome(executed: false, ok: false), .notExecuted)
        XCTAssertEqual(bridgeExecutionOutcome(executed: true, ok: false), .failed)
        XCTAssertEqual(bridgeExecutionOutcome(executed: true, ok: true), .succeeded)
        XCTAssertEqual(BridgeExecutionOutcome.unknown.rawValue, "unknown")
    }

    func testOperationIDShape() {
        XCTAssertTrue(bridgeValidOperationID("op_0123456789abcdef"))
        XCTAssertTrue(bridgeValidOperationID("a1b2c3d4-e5f6"))
        XCTAssertFalse(bridgeValidOperationID("short"))
        XCTAssertFalse(bridgeValidOperationID("op with spaces 123"))
        XCTAssertFalse(bridgeValidOperationID(String(repeating: "a", count: 81)))
    }

    // MARK: ledger: replay, conflict, isolation, bound

    func testResentOperationReplaysTheRecordedOutcome() {
        let ledger = BridgeOperationLedger<String>()
        XCTAssertEqual(ledger.lookup(principal: dsh, opID: "op_aaaaaaaa", fingerprint: "ui.press|1|7"), .new)
        ledger.record(principal: dsh, opID: "op_aaaaaaaa", fingerprint: "ui.press|1|7",
                      outcome: .succeeded, payload: "pressed", at: 100)
        XCTAssertEqual(ledger.lookup(principal: dsh, opID: "op_aaaaaaaa", fingerprint: "ui.press|1|7"),
                       .replay(outcome: .succeeded, payload: "pressed"))
    }

    func testReusingAnOperationIDForAnotherActionIsRefused() {
        let ledger = BridgeOperationLedger<String>()
        ledger.record(principal: dsh, opID: "op_aaaaaaaa", fingerprint: "ui.press|1|7",
                      outcome: .succeeded, payload: "pressed", at: 100)
        XCTAssertEqual(ledger.lookup(principal: dsh, opID: "op_aaaaaaaa", fingerprint: "ui.press|1|8"), .conflict)
    }

    func testLedgerIsPerPrincipal() {
        let ledger = BridgeOperationLedger<String>()
        ledger.record(principal: dsh, opID: "op_aaaaaaaa", fingerprint: "f", outcome: .failed, payload: "x", at: 1)
        XCTAssertEqual(ledger.lookup(principal: other, opID: "op_aaaaaaaa", fingerprint: "f"), .new,
                       "another client never reads my outcomes")
        XCTAssertNil(ledger.outcome(principal: other, opID: "op_aaaaaaaa"))
        XCTAssertEqual(ledger.outcome(principal: dsh, opID: "op_aaaaaaaa")?.outcome, .failed)
    }

    func testLedgerIsBoundedOldestFirst() {
        let ledger = BridgeOperationLedger<Int>(capacity: 3)
        for index in 0..<5 {
            ledger.record(principal: dsh, opID: "op_0000000\(index)", fingerprint: "f",
                          outcome: .succeeded, payload: index, at: Double(index))
        }
        XCTAssertNil(ledger.outcome(principal: dsh, opID: "op_00000000"))
        XCTAssertNil(ledger.outcome(principal: dsh, opID: "op_00000001"))
        XCTAssertEqual(ledger.outcome(principal: dsh, opID: "op_00000004")?.payload, 4)
        XCTAssertEqual(ledger.count(principal: dsh), 3)
    }

    func testFingerprintIsStableAndIgnoresTheOperationIDItself() {
        let one = bridgeActionFingerprint(kind: "ui.press", contextID: "ctx_1",
                                          params: ["element_id": 7, "snapshot": 2, "op_id": "op_aaaaaaaa"])
        let two = bridgeActionFingerprint(kind: "ui.press", contextID: "ctx_1",
                                          params: ["snapshot": 2, "op_id": "op_bbbbbbbb", "element_id": 7])
        XCTAssertEqual(one, two)
        XCTAssertNotEqual(one, bridgeActionFingerprint(kind: "ui.press", contextID: "ctx_2",
                                                       params: ["element_id": 7, "snapshot": 2]))
        // Text never enters the fingerprint in clear.
        let typed = bridgeActionFingerprint(kind: "ui.set_value", contextID: nil,
                                            params: ["element_id": 1, "text": "secret value"])
        XCTAssertFalse(typed.contains("secret"))
    }
}
