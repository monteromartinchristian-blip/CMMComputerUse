import XCTest

/// Two concurrent window streams (0.3.3). 0.3.2 kept ONE SCStream per helper
/// and a second `stream_start` — from any client — replaced the first. These
/// tests pin the bounded registry (Shared/ComputerUseStreams.swift): slots,
/// ownership, idempotency, the limit, per-stream health and recovery.
final class StreamRegistryTests: XCTestCase {

    private let dsh = BridgePrincipal(key: "client:dsh", strength: .verifiedClient)
    private let other = BridgePrincipal(key: "client:other", strength: .verifiedClient)

    private func identity(_ window: Int, pid: Int32 = 501, bundle: String = "com.apple.Safari") -> BridgeStreamIdentity {
        BridgeStreamIdentity(bundleID: bundle, pid: pid, windowID: window, windowTitle: "W\(window)", appName: "App")
    }

    private func registry(_ limits: BridgeStreamLimits = BridgeStreamLimits()) -> BridgeStreamRegistry<String> {
        var counter = 0
        return BridgeStreamRegistry<String>(limits: limits) {
            counter += 1
            return "str_test\(counter)"
        }
    }

    /// Reserve + activate, as the helper does once SCStream.startCapture succeeded.
    @discardableResult
    private func start(_ r: BridgeStreamRegistry<String>, _ principal: BridgePrincipal, key: String?,
                       _ identity: BridgeStreamIdentity, now: Double = 100) -> String {
        guard case .success(let reservation) = r.reserve(principal: principal, key: key, identity: identity) else {
            XCTFail("reserve refused"); fatalError()
        }
        switch reservation {
        case .existing(let id):
            return id
        case .start(let id, let replacing):
            if let replacing { _ = r.remove(id: replacing, now: now) }
            r.activate(id: id, principal: principal, key: key, identity: identity, resource: "scstream-\(id)", now: now)
            return id
        }
    }

    // MARK: 3/4. two live streams, independent

    func testTwoStreamsCoexistAndStoppingOneLeavesTheOther() {
        let r = registry()
        let a = start(r, dsh, key: "A", identity(11))
        let b = start(r, dsh, key: "B", identity(12, pid: 502, bundle: "com.apple.Notes"))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(r.entries(principal: dsh).count, 2, "starting B did not stop A")
        guard case .success(let stopped) = r.stop(principal: dsh, id: a, now: 101) else { return XCTFail() }
        XCTAssertTrue(stopped.stopped)
        XCTAssertEqual(stopped.resource, "scstream-\(a)", "the caller tears down exactly A's resource")
        XCTAssertEqual(r.entries(principal: dsh).map { $0.id }, [b])
    }

    func testFrameIndicesAreIndependentPerStream() {
        let r = registry()
        let a = start(r, dsh, key: "A", identity(11))
        let b = start(r, dsh, key: "B", identity(12))
        for _ in 0..<5 { r.recordFrame(id: a, at: 100.5) }
        r.recordFrame(id: b, at: 100.5)
        XCTAssertEqual(r.entry(principal: dsh, id: a).map { $0.frameIndex }, .success(5))
        XCTAssertEqual(r.entry(principal: dsh, id: b).map { $0.frameIndex }, .success(1))
    }

    func testStartIsIdempotentForTheSameSlotAndWindow() {
        let r = registry()
        let a = start(r, dsh, key: "A", identity(11))
        guard case .success(.existing(let again)) = r.reserve(principal: dsh, key: "A", identity: identity(11)) else {
            return XCTFail("re-starting the same slot on the same window is a no-op")
        }
        XCTAssertEqual(again, a)
        // Same slot, another window: the slot's own stream is replaced, never B's.
        let b = start(r, dsh, key: "B", identity(12))
        guard case .success(.start(_, let replacing)) = r.reserve(principal: dsh, key: "A", identity: identity(13)) else {
            return XCTFail()
        }
        XCTAssertEqual(replacing, a)
        XCTAssertNotEqual(replacing, b)
    }

    // MARK: 11. the third stream is refused safely

    func testThirdStreamIsRefusedWithoutTouchingTheOthers() {
        let r = registry()
        start(r, dsh, key: "A", identity(11))
        start(r, dsh, key: "B", identity(12))
        guard case .failure(let refusal) = r.reserve(principal: dsh, key: "C", identity: identity(13)) else {
            return XCTFail("a third concurrent stream must be refused")
        }
        XCTAssertEqual(refusal.code, "STREAM_LIMIT")
        XCTAssertTrue(refusal.detail.contains("max=2"), refusal.detail)
        XCTAssertEqual(r.entries(principal: dsh).count, 2)
    }

    func testHelperWideLimitAlsoBindsOtherClients() {
        let r = registry()
        start(r, dsh, key: "A", identity(11))
        start(r, dsh, key: "B", identity(12))
        guard case .failure(let refusal) = r.reserve(principal: other, key: "A", identity: identity(13)) else {
            return XCTFail()
        }
        XCTAssertEqual(refusal.code, "STREAM_LIMIT")
        XCTAssertTrue(refusal.detail.contains("scope=helper"), refusal.detail)
    }

    // MARK: 10. ownership

    func testAnotherClientCannotReadStopOrRecoverAStream() {
        let r = registry()
        let a = start(r, dsh, key: "A", identity(11))
        r.recordFrame(id: a, at: 100.2)
        for result in [r.entry(principal: other, id: a).map { _ in () },
                       r.stop(principal: other, id: a, now: 101).map { _ in () },
                       r.beginRecovery(principal: other, id: a, now: 101).map { _ in () }] {
            guard case .failure(let refusal) = result else { return XCTFail("cross-client access") }
            XCTAssertEqual(refusal.code, "STREAM_UNKNOWN")
        }
        XCTAssertEqual(r.entries(principal: other).count, 0)
        XCTAssertEqual(r.entries(principal: dsh).count, 1)
    }

    func testLegacyStartReplacesOnlyTheCallersOwnLegacyStream() {
        let r = registry()
        let mine = start(r, dsh, key: nil, identity(11))
        let theirs = start(r, other, key: nil, identity(21))
        guard case .success(.start(_, let replacing)) = r.reserve(principal: dsh, key: nil, identity: identity(12)) else {
            return XCTFail()
        }
        XCTAssertEqual(replacing, mine, "0.3.2 semantics for the caller")
        XCTAssertNotEqual(replacing, theirs, "but never another client's stream")
        XCTAssertEqual(r.legacyStream(principal: other)?.id, theirs)
    }

    // MARK: 18. repeated stop

    func testStopIsIdempotent() {
        let r = registry()
        let a = start(r, dsh, key: "A", identity(11))
        guard case .success(let first) = r.stop(principal: dsh, id: a, now: 101),
              case .success(let second) = r.stop(principal: dsh, id: a, now: 102)
        else { return XCTFail() }
        XCTAssertTrue(first.stopped)
        XCTAssertFalse(second.stopped)
        XCTAssertTrue(second.alreadyStopped)
        XCTAssertNil(second.resource, "nothing to tear down twice")
    }

    // MARK: 13. health: live, unchanged, frozen, warming, error

    func testHealthNeverCallsAnOldFrameLive() {
        let limits = BridgeStreamLimits()
        func health(frames: Int, lastFrame: Double, heartbeat: Double = 0, failure: String? = nil,
                    recovering: Bool = false, now: Double) -> BridgeStreamHealth {
            bridgeStreamHealth(startedAt: 100, frames: frames, lastFrameAt: lastFrame, lastHeartbeatAt: heartbeat,
                               failure: failure, recovering: recovering, stopped: false, now: now, limits: limits)
        }
        XCTAssertEqual(health(frames: 0, lastFrame: 0, now: 101).phase, .warming)
        XCTAssertEqual(health(frames: 0, lastFrame: 0, now: 110).phase, .stale)
        XCTAssertEqual(health(frames: 0, lastFrame: 0, now: 110).reason, "no_first_frame")
        XCTAssertEqual(health(frames: 3, lastFrame: 105, now: 105.5).phase, .live)
        // No new pixels, but the stream reports idle buffers: alive, unchanged.
        let unchanged = health(frames: 3, lastFrame: 105, heartbeat: 109.8, now: 110)
        XCTAssertEqual(unchanged.phase, .live)
        XCTAssertTrue(unchanged.unchanged)
        // Neither pixels nor heartbeats: frozen, never "live".
        let frozen = health(frames: 3, lastFrame: 105, heartbeat: 105, now: 110)
        XCTAssertEqual(frozen.phase, .stale)
        XCTAssertEqual(frozen.reason, "frozen")
        XCTAssertEqual(health(frames: 3, lastFrame: 105, failure: "window_closed", now: 106).phase, .error)
        XCTAssertEqual(health(frames: 3, lastFrame: 105, failure: "window_closed", recovering: true, now: 106).phase,
                       .recovering)
        XCTAssertEqual(bridgeStreamHealth(startedAt: 100, frames: 3, lastFrameAt: 105, lastHeartbeatAt: 0,
                                          failure: nil, recovering: false, stopped: true, now: 106,
                                          limits: limits).phase, .closed)
    }

    func testFailureOfOneStreamIsRecordedOnlyOnThatStream() {
        let r = registry()
        let a = start(r, dsh, key: "A", identity(11))
        let b = start(r, dsh, key: "B", identity(12))
        r.markFailure(id: a, reason: "stopped_by_system")
        XCTAssertEqual(try r.entry(principal: dsh, id: a).get().failure, "stopped_by_system")
        XCTAssertNil(try r.entry(principal: dsh, id: b).get().failure)
    }

    // MARK: recovery without touching the sibling

    func testRecoveryKeepsTheIdAndFrameIndexAndIsBounded() {
        let r = registry(BridgeStreamLimits(maxRecoveries: 2))
        let a = start(r, dsh, key: "A", identity(11))
        let b = start(r, dsh, key: "B", identity(12))
        for _ in 0..<4 { r.recordFrame(id: a, at: 101) }
        r.markFailure(id: a, reason: "stopped_by_system")
        guard case .success(let plan) = r.beginRecovery(principal: dsh, id: a, now: 102) else { return XCTFail() }
        XCTAssertEqual(plan.attempt, 1)
        XCTAssertEqual(plan.delay, 0.5, accuracy: 0.0001)
        XCTAssertEqual(plan.previousResource, "scstream-\(a)")
        r.finishRecovery(id: a, resource: "scstream-\(a)-r1", now: 103)
        r.recordFrame(id: a, at: 103.1)
        let recovered = try! r.entry(principal: dsh, id: a).get()
        XCTAssertEqual(recovered.id, a, "a panel keeps its stream id across recovery")
        XCTAssertEqual(recovered.frameIndex, 5, "the index never goes backwards")
        XCTAssertNil(recovered.failure)
        XCTAssertEqual(recovered.restarts, 1)
        XCTAssertEqual(try r.entry(principal: dsh, id: b).get().restarts, 0, "B was never restarted")
        // Bounded: the third attempt is refused, the stream stays in error.
        _ = r.beginRecovery(principal: dsh, id: a, now: 104)
        guard case .failure(let exhausted) = r.beginRecovery(principal: dsh, id: a, now: 105) else {
            return XCTFail()
        }
        XCTAssertEqual(exhausted.code, "STREAM_RECOVERY_EXHAUSTED")
    }

    func testRecoveryBackoffIsExponentialAndCapped() {
        XCTAssertEqual(bridgeRecoveryDelay(attempt: 1), 0.5)
        XCTAssertEqual(bridgeRecoveryDelay(attempt: 2), 1.0)
        XCTAssertEqual(bridgeRecoveryDelay(attempt: 3), 2.0)
        XCTAssertEqual(bridgeRecoveryDelay(attempt: 4), 4.0)
        XCTAssertEqual(bridgeRecoveryDelay(attempt: 9), 8.0)
        XCTAssertEqual(bridgeRecoveryDelay(attempt: 0), 0.5)
    }

    // MARK: identity validation during the life of the stream

    func testIdentityDriftIsDetected() {
        let started = identity(11, pid: 501)
        XCTAssertNil(bridgeStreamIdentityDrift(started: started, current: identity(11, pid: 501)))
        XCTAssertEqual(bridgeStreamIdentityDrift(started: started, current: identity(11, pid: 777)), "pid_changed")
        XCTAssertEqual(bridgeStreamIdentityDrift(started: started, current: nil), "window_gone")
        XCTAssertEqual(bridgeStreamIdentityDrift(
            started: started, current: identity(11, pid: 501, bundle: "com.evil")), "bundle_changed")
        // A title follows the active tab: never a reason to drop a window stream.
        let retitled = BridgeStreamIdentity(bundleID: started.bundleID, pid: 501, windowID: 11,
                                            windowTitle: "Other tab", appName: "App")
        XCTAssertNil(bridgeStreamIdentityDrift(started: started, current: retitled))
    }

    func testExpectedIdentityMustMatchBeforeAStreamOpens() {
        let live = identity(11, pid: 501)
        XCTAssertNil(bridgeStreamExpectationRefusal(expectedBundle: "com.apple.Safari", expectedPID: 501,
                                                    selected: live))
        XCTAssertNil(bridgeStreamExpectationRefusal(expectedBundle: nil, expectedPID: nil, selected: live))
        let pid = bridgeStreamExpectationRefusal(expectedBundle: "com.apple.Safari", expectedPID: 9, selected: live)
        XCTAssertEqual(pid?.code, "STREAM_IDENTITY_MISMATCH")
        XCTAssertTrue(pid!.detail.contains("reason=pid_changed"), pid!.detail)
        let bundle = bridgeStreamExpectationRefusal(expectedBundle: "com.apple.Notes", expectedPID: nil, selected: live)
        XCTAssertTrue(bundle!.detail.contains("reason=bundle_changed"), bundle!.detail)
    }

    func testRemoveAllReturnsEveryResourceForTeardown() {
        let r = registry()
        start(r, dsh, key: "A", identity(11))
        start(r, other, key: "A", identity(21))
        let removed = r.removeAll()
        XCTAssertEqual(Set(removed.compactMap { $0.resource }).count, 2)
        XCTAssertTrue(r.entries(principal: dsh).isEmpty)
    }

    func testStreamKeyShapeIsBounded() {
        XCTAssertTrue(bridgeValidStreamKey("A"))
        XCTAssertTrue(bridgeValidStreamKey("ctx_0123abcd"))
        XCTAssertFalse(bridgeValidStreamKey(""))
        XCTAssertFalse(bridgeValidStreamKey(String(repeating: "x", count: 81)))
        XCTAssertFalse(bridgeValidStreamKey("a/b"))
    }

    // MARK: a stream is judged again on the window's CURRENT title (audit X-05)

    private func windowGrantPolicy() -> BridgeAuthorizationPolicy {
        let text = #"{"version":1,"mode":"background","apps":[{"bundle_id":"com.apple.Safari","scopes":["observe"],"windows":["CMM"]}]}"#
        return BridgeAuthorizationPolicy.parse(Data(text.utf8), source: "t")!
    }

    private let docs = BridgeStreamIdentity(bundleID: "com.apple.Safari", pid: 7, windowID: 90,
                                            windowTitle: "CMM – Docs", appName: "Safari")

    /// The stream was granted while the window was titled "CMM – Docs". After a
    /// tab switch the window is titled like the person's bank: its frames must
    /// stop, however the grant was satisfied at the start.
    func testAStreamWhoseWindowChangedToAnUncoveredTitleIsRevoked() {
        let verdict = bridgeStreamRecheck(policy: windowGrantPolicy(), client: nil, identity: docs, currentTitle: "Banco – Cuentas")
        XCTAssertNotNil(verdict.refusal)
        XCTAssertEqual(verdict.refusal?.code, "APPROVAL_REJECTED")
        XCTAssertTrue(verdict.refusal?.detail.contains("window_not_granted") ?? false)
    }

    func testACoveredNewTitleKeepsTheStreamAndMakesItsIdentityHonest() {
        let verdict = bridgeStreamRecheck(policy: windowGrantPolicy(), client: nil, identity: docs, currentTitle: "CMM – Otra pestaña")
        XCTAssertNil(verdict.refusal)
        XCTAssertEqual(verdict.identity.windowTitle, "CMM – Otra pestaña", "view_identity no longer reports a stale title")
        XCTAssertEqual(verdict.identity.windowID, 90)
        XCTAssertEqual(verdict.identity.bundleID, "com.apple.Safari")
    }

    func testAnUnreadableTitleDoesNotInventAVerdict() {
        let verdict = bridgeStreamRecheck(policy: windowGrantPolicy(), client: nil, identity: docs, currentTitle: nil)
        XCTAssertNil(verdict.refusal, "the window is gone or unreadable: the stream's own health reports that")
        XCTAssertEqual(verdict.identity, docs)
    }

    func testAnEmptyTitleUnderAWindowGrantIsNotCovered() {
        XCTAssertNotNil(bridgeStreamRecheck(policy: windowGrantPolicy(), client: nil, identity: docs, currentTitle: "").refusal)
    }

    func testAGrantWithoutWindowPatternsCoversAnyTitle() {
        let text = #"{"version":1,"mode":"background","apps":[{"bundle_id":"com.apple.Safari","scopes":["observe"]}]}"#
        let open = BridgeAuthorizationPolicy.parse(Data(text.utf8), source: "t")!
        XCTAssertNil(bridgeStreamRecheck(policy: open, client: nil, identity: docs, currentTitle: "Banco – Cuentas").refusal)
    }

    func testTheRecheckIsRateLimitedPerStream() {
        XCTAssertTrue(bridgeStreamRecheckDue(lastCheckedAt: nil, now: 100))
        XCTAssertFalse(bridgeStreamRecheckDue(lastCheckedAt: 100, now: 100.2))
        XCTAssertTrue(bridgeStreamRecheckDue(lastCheckedAt: 100, now: 100.6))
    }
}
