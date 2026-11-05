import XCTest

/// Multi-App Workspace (0.3.3): two independent application/window contexts per
/// client, each with its own generation, its own element handles and its own
/// invalidation. Pins the rules in Shared/ComputerUseWorkspace.swift that the
/// helper executes; no window server, no TCC.
///
/// 0.3.2 kept ONE process-wide element table and ONE generation: observing app B
/// replaced app A's handles, and any client could act on handles another client
/// produced. These tests define the replacement contract.
final class WorkspaceContextTests: XCTestCase {

    private let dsh = bridgePrincipal(
        clientID: "dsh", peerIdentifier: "org.python.python", peerTeamID: nil,
        peerValidSignature: true, peerPID: 4100)
    private let other = bridgePrincipal(
        clientID: "other-agent", peerIdentifier: "com.example.agent", peerTeamID: "TEAM",
        peerValidSignature: true, peerPID: 4200)

    private let safari = BridgeContextIdentity(
        bundleID: "com.apple.Safari", pid: 501, appName: "Safari", windowID: 11, windowTitle: "Docs",
        document: BridgeDocumentIdentity(axDocument: nil, axURL: "https://example.com/a", title: "Docs"))
    private let notes = BridgeContextIdentity(
        bundleID: "com.apple.Notes", pid: 502, appName: "Notes", windowID: 12, windowTitle: "Docs",
        document: BridgeDocumentIdentity(axDocument: nil, axURL: nil, title: "Docs"))

    private func workspace(_ limits: BridgeWorkspaceLimits = BridgeWorkspaceLimits()) -> BridgeWorkspace<String> {
        var counter = 0
        return BridgeWorkspace<String>(limits: limits) {
            counter += 1
            return "ctx_test\(counter)"
        }
    }

    private func create(_ ws: BridgeWorkspace<String>, _ principal: BridgePrincipal, target: String? = nil,
                        now: Double = 100) -> BridgeContextRecord<String> {
        guard case .success(let context) = ws.create(principal: principal, target: target, now: now) else {
            XCTFail("context create refused"); fatalError()
        }
        return context
    }

    /// Observe `identity` into `id` and commit `handles` under the new generation.
    @discardableResult
    private func observe(_ ws: BridgeWorkspace<String>, _ id: String, _ identity: BridgeContextIdentity,
                         _ handles: [Int: String], now: Double = 100) -> Int {
        let started = ws.beginObservation(id: id, identity: identity, now: now)
        XCTAssertNotNil(started)
        ws.commit(id: id, generation: started!.generation, handles: handles)
        return started!.generation
    }

    // MARK: principals

    func testPrincipalPrefersVerifiedClientOverCodeAndProcess() {
        XCTAssertEqual(dsh.key, "client:dsh")
        XCTAssertEqual(dsh.strength, .verifiedClient)
        let code = bridgePrincipal(clientID: nil, peerIdentifier: "com.x", peerTeamID: "T",
                                   peerValidSignature: true, peerPID: 9)
        XCTAssertEqual(code.key, "code:com.x@T")
        XCTAssertEqual(code.strength, .codeIdentity)
        // An unsigned identifier is a claim, not an identity: only the process.
        let unsigned = bridgePrincipal(clientID: nil, peerIdentifier: "com.x", peerTeamID: nil,
                                       peerValidSignature: false, peerPID: 9)
        XCTAssertEqual(unsigned.key, "pid:9")
        XCTAssertEqual(unsigned.strength, .process)
        let stdio = bridgePrincipal(clientID: nil, peerIdentifier: nil, peerTeamID: nil,
                                    peerValidSignature: false, peerPID: nil)
        XCTAssertEqual(stdio.key, "local")
    }

    // MARK: ids

    func testRandomContextIDsAreOpaqueAndUnique() {
        var seen = Set<String>()
        for _ in 0..<500 {
            let id = bridgeRandomContextID()
            XCTAssertTrue(id.hasPrefix("ctx_"))
            XCTAssertEqual(id.count, 4 + 32, "128 random bits, hex")
            XCTAssertTrue(bridgeValidContextID(id))
            seen.insert(id)
        }
        XCTAssertEqual(seen.count, 500)
        XCTAssertFalse(bridgeValidContextID("ctx_../../etc"))
        XCTAssertFalse(bridgeValidContextID(""))
    }

    // MARK: 1. two apps observed at once; 7. observing B does not invalidate A

    func testTwoAppsObservedSimultaneouslyKeepIndependentGenerations() {
        let ws = workspace()
        let a = create(ws, dsh)
        let b = create(ws, dsh)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(a.label, "A")
        XCTAssertEqual(b.label, "B")
        let genA = observe(ws, a.id, safari, [1: "safari-button"])
        let genB = observe(ws, b.id, notes, [1: "notes-button"])
        XCTAssertEqual(genA, 1)
        XCTAssertNotEqual(genB, genA, "a snapshot number names ONE context (audit X-04)")
        // Observing B again moves only B.
        observe(ws, b.id, notes, [1: "notes-button-2"])
        guard case .success(let resolvedA) = ws.resolveHandle(
            principal: dsh, id: a.id, snapshot: genA, elementID: 1, mode: .background, now: 101)
        else { return XCTFail("A's handle must survive B's observation") }
        XCTAssertEqual(resolvedA.handle, "safari-button")
    }

    // MARK: 6. coinciding element ids never cross

    func testSameElementIDResolvesOnlyInsideItsOwnContext() {
        let ws = workspace()
        let a = create(ws, dsh)
        let b = create(ws, dsh)
        let genA = observe(ws, a.id, safari, [7: "A7"])
        let genB = observe(ws, b.id, notes, [7: "B7"])
        guard case .success(let inA) = ws.resolveHandle(
            principal: dsh, id: a.id, snapshot: genA, elementID: 7, mode: .background, now: 101),
              case .success(let inB) = ws.resolveHandle(
            principal: dsh, id: b.id, snapshot: genB, elementID: 7, mode: .background, now: 101)
        else { return XCTFail("both handles must resolve in their own context") }
        XCTAssertEqual(inA.handle, "A7")
        XCTAssertEqual(inB.handle, "B7")
        // B's element 8 does not exist; A's table is never consulted for it.
        observe(ws, a.id, safari, [7: "A7", 8: "A8"])
        guard case .failure(let refusal) = ws.resolveHandle(
            principal: dsh, id: b.id, snapshot: genB, elementID: 8, mode: .background, now: 101)
        else { return XCTFail("an id that exists only in A must not resolve in B") }
        XCTAssertTrue(refusal.detail.contains("reason=unknown_element"), refusal.detail)
    }

    // MARK: 5. same title in different windows

    func testSameWindowTitleInTwoAppsDoesNotShareIdentity() {
        let ws = workspace()
        let a = create(ws, dsh)
        let b = create(ws, dsh)
        observe(ws, a.id, safari, [1: "x"])
        observe(ws, b.id, notes, [1: "y"])
        let identities = ws.list(principal: dsh).compactMap { $0.identity }
        XCTAssertEqual(identities.count, 2)
        XCTAssertEqual(identities[0].windowTitle, identities[1].windowTitle)
        XCTAssertNotEqual(identities[0], identities[1], "identity is bundle+pid+window, never the title alone")
    }

    // MARK: 2. two windows of one app

    func testTwoWindowsOfTheSameAppAreTwoContexts() {
        let ws = workspace()
        let a = create(ws, dsh, target: "com.apple.Safari")
        let b = create(ws, dsh, target: "com.apple.Safari")
        let second = BridgeContextIdentity(
            bundleID: "com.apple.Safari", pid: 501, appName: "Safari", windowID: 99, windowTitle: "Other",
            document: BridgeDocumentIdentity(axDocument: nil, axURL: "https://example.com/b", title: "Other"))
        let genA = observe(ws, a.id, safari, [1: "w11"])
        let genB = observe(ws, b.id, second, [1: "w99"])
        guard case .success(let one) = ws.resolveHandle(
            principal: dsh, id: a.id, snapshot: genA, elementID: 1, mode: .background, now: 101),
              case .success(let two) = ws.resolveHandle(
            principal: dsh, id: b.id, snapshot: genB, elementID: 1, mode: .background, now: 101)
        else { return XCTFail() }
        XCTAssertEqual(one.handle, "w11")
        XCTAssertEqual(two.handle, "w99")
    }

    // MARK: 8. pid changed / window replaced / document changed

    func testReobservingAfterRelaunchReportsThePidChange() {
        let ws = workspace()
        let a = create(ws, dsh)
        let gen1 = observe(ws, a.id, safari, [1: "old"])
        let relaunched = BridgeContextIdentity(
            bundleID: safari.bundleID, pid: 777, appName: "Safari", windowID: 11, windowTitle: "Docs",
            document: safari.document)
        let started = ws.beginObservation(id: a.id, identity: relaunched, now: 102)!
        XCTAssertEqual(started.identityChanges, ["pid"])
        ws.commit(id: a.id, generation: started.generation, handles: [1: "new"])
        guard case .failure(let refusal) = ws.resolveHandle(
            principal: dsh, id: a.id, snapshot: gen1, elementID: 1, mode: .background, now: 102)
        else { return XCTFail("a handle from before the relaunch must be refused") }
        XCTAssertTrue(refusal.detail.contains("reason=stale_snapshot"), refusal.detail)
    }

    func testExplicitContextRefusesToSwitchApplication() {
        let ws = workspace()
        let a = create(ws, dsh)
        observe(ws, a.id, safari, [1: "x"])
        XCTAssertNotNil(ws.targetMismatch(id: a.id, bundleID: notes.bundleID),
                        "a context is ONE application; another app needs another context")
        XCTAssertNil(ws.targetMismatch(id: a.id, bundleID: safari.bundleID))
        let legacy = ws.legacyContext(principal: dsh, now: 100)
        _ = ws.beginObservation(id: legacy.id, identity: safari, now: 100)
        XCTAssertNil(ws.targetMismatch(id: legacy.id, bundleID: notes.bundleID),
                     "the 0.3.2 default context follows whatever app the caller names")
    }

    func testCreateWithTargetBindsBeforeTheFirstObservation() {
        let ws = workspace()
        let a = create(ws, dsh, target: "com.apple.Safari")
        XCTAssertNotNil(ws.targetMismatch(id: a.id, bundleID: "com.apple.Notes"))
        XCTAssertNil(ws.targetMismatch(id: a.id, bundleID: "com.apple.Safari"))
    }

    func testVerifiedDocumentChangeRefusesTheOldDocumentsHandles() {
        let observed = BridgeDocumentIdentity(axDocument: nil, axURL: "https://example.com/a", title: "A")
        let tabSwitched = BridgeDocumentIdentity(axDocument: nil, axURL: "https://example.com/b", title: "A")
        let same = BridgeDocumentIdentity(axDocument: nil, axURL: "https://example.com/a", title: "A (1)")
        XCTAssertTrue(observed.verified)
        XCTAssertNotEqual(observed.digest, tabSwitched.digest)
        XCTAssertFalse(observed.digest.contains("example"), "the digest never carries the URL")
        let refusal = bridgeDocumentRefusal(observed: observed, current: tabSwitched, strict: false, mode: .background)
        XCTAssertNotNil(refusal)
        XCTAssertTrue(refusal!.detail.contains("reason=document_changed"), refusal!.detail)
        XCTAssertNil(bridgeDocumentRefusal(observed: observed, current: same, strict: true, mode: .background),
                     "a verified identity outranks a title that changed")
    }

    func testUnverifiableDocumentIsConservativeOnlyForExplicitContexts() {
        let observed = BridgeDocumentIdentity(axDocument: nil, axURL: nil, title: "Inbox")
        let retitled = BridgeDocumentIdentity(axDocument: nil, axURL: nil, title: "Draft")
        XCTAssertFalse(observed.verified)
        let strict = bridgeDocumentRefusal(observed: observed, current: retitled, strict: true, mode: .background)
        XCTAssertNotNil(strict)
        XCTAssertTrue(strict!.detail.contains("reason=document_unverified"), strict!.detail)
        XCTAssertNil(bridgeDocumentRefusal(observed: observed, current: retitled, strict: false, mode: .background),
                     "the 0.3.2 default context keeps its semantics: a title is not an identity")
        // Losing a verified identity cannot prove it is the same document.
        let verified = BridgeDocumentIdentity(axDocument: "file:///a.txt", axURL: nil, title: "a.txt")
        XCTAssertNotNil(bridgeDocumentRefusal(observed: verified, current: retitled, strict: true, mode: .background))
    }

    // MARK: 10. no client reaches another client's context

    func testAnotherPrincipalCannotResolveCloseOrListAContext() {
        let ws = workspace()
        let a = create(ws, dsh)
        let gen = observe(ws, a.id, safari, [1: "x"])
        guard case .failure(let resolve) = ws.resolveHandle(
            principal: other, id: a.id, snapshot: gen, elementID: 1, mode: .background, now: 101)
        else { return XCTFail("knowing the id must not be enough") }
        XCTAssertEqual(resolve.code, "CONTEXT_UNKNOWN")
        guard case .failure(let close) = ws.close(principal: other, id: a.id) else {
            return XCTFail("another principal must not close it")
        }
        XCTAssertEqual(close.code, "CONTEXT_UNKNOWN")
        XCTAssertTrue(ws.list(principal: other).isEmpty)
        // The refusal is the same as for an id that never existed: no oracle.
        guard case .failure(let never) = ws.context(principal: other, id: "ctx_" + String(repeating: "0", count: 32), now: 101)
        else { return XCTFail() }
        XCTAssertEqual(never.code, close.code)
        XCTAssertEqual(never.message, close.message)
        // Still intact for its owner.
        guard case .success = ws.resolveHandle(
            principal: dsh, id: a.id, snapshot: gen, elementID: 1, mode: .background, now: 101)
        else { return XCTFail() }
    }

    func testLegacyDefaultContextIsPerPrincipal() {
        let ws = workspace()
        let mine = ws.legacyContext(principal: dsh, now: 100)
        let theirs = ws.legacyContext(principal: other, now: 100)
        XCTAssertNotEqual(mine.id, theirs.id)
        let gen = observe(ws, mine.id, safari, [1: "mine"])
        observe(ws, theirs.id, notes, [1: "theirs"])
        guard case .success(let resolved) = ws.resolveHandle(
            principal: dsh, id: nil, snapshot: gen, elementID: 1, mode: .background, now: 101)
        else { return XCTFail() }
        XCTAssertEqual(resolved.handle, "mine", "another client's observation never replaces my default table")
    }

    // MARK: limits

    func testThirdExplicitContextIsRefusedAndClosingFreesASlot() {
        let ws = workspace()
        let a = create(ws, dsh)
        _ = create(ws, dsh)
        guard case .failure(let refusal) = ws.create(principal: dsh, target: nil, now: 100) else {
            return XCTFail("the third context must be refused")
        }
        XCTAssertEqual(refusal.code, "CONTEXT_LIMIT")
        XCTAssertTrue(refusal.detail.contains("max=2"), refusal.detail)
        // The legacy default never counts against the explicit limit.
        _ = ws.legacyContext(principal: dsh, now: 100)
        guard case .success = ws.close(principal: dsh, id: a.id) else { return XCTFail() }
        guard case .success(let c) = ws.create(principal: dsh, target: nil, now: 101) else {
            return XCTFail("a closed slot is reusable")
        }
        XCTAssertEqual(c.label, "A", "the freed label is reused so panels stay A/B")
        // Another principal has its own two.
        _ = create(ws, other)
        _ = create(ws, other)
    }

    func testGlobalContextCapBoundsResources() {
        let ws = workspace(BridgeWorkspaceLimits(maxContextsPerPrincipal: 2, maxContextsTotal: 3))
        _ = create(ws, dsh)
        _ = create(ws, dsh)
        _ = create(ws, other)
        guard case .failure(let refusal) = ws.create(principal: other, target: nil, now: 100) else {
            return XCTFail()
        }
        XCTAssertEqual(refusal.code, "CONTEXT_LIMIT")
        XCTAssertTrue(refusal.detail.contains("scope=helper"), refusal.detail)
    }

    // MARK: 16. USER_TAKEOVER invalidates only the affected context

    func testInvalidatingOneContextLeavesTheOtherUsable() {
        let ws = workspace()
        let a = create(ws, dsh)
        let b = create(ws, dsh)
        let genA = observe(ws, a.id, safari, [1: "a"])
        let genB = observe(ws, b.id, notes, [1: "b"])
        let retired = ws.invalidate(id: a.id, reason: "user_takeover", now: 105)
        XCTAssertEqual(retired?.retired, genA)
        guard case .failure(let refusal) = ws.resolveHandle(
            principal: dsh, id: a.id, snapshot: genA, elementID: 1, mode: .background, now: 106)
        else { return XCTFail() }
        XCTAssertTrue(refusal.detail.contains("reason=released"), refusal.detail)
        XCTAssertFalse(refusal.detail.contains("age="), "a released generation has no age")
        guard case .success(let stillB) = ws.resolveHandle(
            principal: dsh, id: b.id, snapshot: genB, elementID: 1, mode: .background, now: 106)
        else { return XCTFail("B must be untouched by A's takeover") }
        XCTAssertEqual(stillB.handle, "b")
        XCTAssertEqual(ws.list(principal: dsh).first { $0.id == a.id }?.invalidation, "user_takeover")
    }

    func testExpiryIsPerContextClock() {
        let ws = workspace()
        let a = create(ws, dsh)
        let b = create(ws, dsh)
        let genA = observe(ws, a.id, safari, [1: "a"], now: 100)
        let genB = observe(ws, b.id, notes, [1: "b"], now: 125)
        guard case .failure(let expired) = ws.resolveHandle(
            principal: dsh, id: a.id, snapshot: genA, elementID: 1, mode: .background, now: 140)
        else { return XCTFail() }
        XCTAssertTrue(expired.detail.contains("reason=expired"), expired.detail)
        guard case .success = ws.resolveHandle(
            principal: dsh, id: b.id, snapshot: genB, elementID: 1, mode: .background, now: 140)
        else { return XCTFail("B was observed later; its clock is its own") }
    }

    func testLateCommitFromASupersededObservationIsDropped() {
        let ws = workspace()
        let a = create(ws, dsh)
        let first = ws.beginObservation(id: a.id, identity: safari, now: 100)!
        let second = ws.beginObservation(id: a.id, identity: safari, now: 101)!
        ws.commit(id: a.id, generation: second.generation, handles: [1: "new"])
        ws.commit(id: a.id, generation: first.generation, handles: [1: "old"])
        guard case .success(let resolved) = ws.resolveHandle(
            principal: dsh, id: a.id, snapshot: second.generation, elementID: 1, mode: .background, now: 102)
        else { return XCTFail() }
        XCTAssertEqual(resolved.handle, "new")
    }

    // MARK: 18. repeated close and cleanup

    func testCloseIsIdempotentAndReleasesHandlesAndStream() {
        let ws = workspace()
        let a = create(ws, dsh)
        observe(ws, a.id, safari, [1: "a", 2: "b"])
        ws.bindStream(id: a.id, streamID: "str_1")
        guard case .success(let first) = ws.close(principal: dsh, id: a.id) else { return XCTFail() }
        XCTAssertTrue(first.closed)
        XCTAssertFalse(first.alreadyClosed)
        XCTAssertEqual(first.releasedHandles, 2)
        XCTAssertEqual(first.streamID, "str_1", "the caller stops the bound stream")
        guard case .success(let again) = ws.close(principal: dsh, id: a.id) else {
            return XCTFail("closing twice is a successful no-op")
        }
        XCTAssertFalse(again.closed)
        XCTAssertTrue(again.alreadyClosed)
        XCTAssertNil(again.streamID)
        guard case .failure(let after) = ws.context(principal: dsh, id: a.id, now: 101) else { return XCTFail() }
        XCTAssertEqual(after.code, "CONTEXT_CLOSED")
    }

    func testIdleContextsAreReapedWithTheirStreams() {
        let ws = workspace(BridgeWorkspaceLimits(idleSeconds: 60))
        let a = create(ws, dsh, now: 100)
        let b = create(ws, dsh, now: 100)
        ws.bindStream(id: a.id, streamID: "str_a")
        _ = ws.context(principal: dsh, id: b.id, now: 150) // B used recently
        let reaped = ws.reap(now: 170)
        XCTAssertEqual(reaped.map { $0.id }, [a.id])
        XCTAssertEqual(reaped.first?.streamID, "str_a")
        guard case .success = ws.context(principal: dsh, id: b.id, now: 171) else { return XCTFail() }
    }

    func testResetDropsEveryContextForAHelperWideFailure() {
        let ws = workspace()
        _ = create(ws, dsh)
        _ = create(ws, other)
        let dropped = ws.removeAll()
        XCTAssertEqual(dropped.count, 2)
        XCTAssertTrue(ws.list(principal: dsh).isEmpty)
        XCTAssertTrue(ws.list(principal: other).isEmpty)
    }

    // MARK: 19. 0.3.2 callers

    func testLegacyCallerWithoutContextBehavesLikeOneProcessTable() {
        let ws = workspace()
        // 0.3.2: observe (no context) → snapshot N → press with snapshot N.
        let legacy = ws.legacyContext(principal: dsh, now: 100)
        let gen1 = observe(ws, legacy.id, safari, [3: "first"])
        let gen2 = observe(ws, legacy.id, notes, [3: "second"])
        XCTAssertEqual(gen2, gen1 + 1)
        guard case .failure(let stale) = ws.resolveHandle(
            principal: dsh, id: nil, snapshot: gen1, elementID: 3, mode: .background, now: 101)
        else { return XCTFail() }
        XCTAssertTrue(stale.detail.contains("reason=stale_snapshot;snapshot=1;current=2"), stale.detail)
        // Unrestricted legacy callers may omit the snapshot, exactly as before.
        guard case .success(let loose) = ws.resolveHandle(
            principal: dsh, id: nil, snapshot: nil, elementID: 3, mode: .unrestricted, now: 101)
        else { return XCTFail() }
        XCTAssertEqual(loose.handle, "second")
        guard case .failure(let strict) = ws.resolveHandle(
            principal: dsh, id: nil, snapshot: nil, elementID: 3, mode: .background, now: 101)
        else { return XCTFail() }
        XCTAssertTrue(strict.detail.contains("requirement=snapshot"), strict.detail)
    }

    /// Audit X-04 (regression of 0.3.3): with per-context numbering, context A
    /// and context B both had "snapshot 1, element 1"; an action that named
    /// the wrong context (or none) ran on the OTHER application. A snapshot
    /// number now identifies one context, so the mix-up is refused.
    func testASnapshotFromOneContextIsRefusedInAnother() {
        let ws = workspace()
        let a = create(ws, dsh)
        let b = create(ws, dsh)
        let genA = observe(ws, a.id, safari, [1: "safari-button"])
        let genB = observe(ws, b.id, notes, [1: "notes-button"])
        guard case .failure(let wrong) = ws.resolveHandle(
            principal: dsh, id: b.id, snapshot: genA, elementID: 1, mode: .background, now: 101)
        else { return XCTFail("A's snapshot must not resolve in B") }
        XCTAssertTrue(wrong.detail.contains("stale_snapshot") || wrong.detail.contains("superseded"), wrong.detail)
        let legacy = ws.legacyContext(principal: dsh, now: 100)
        let genL = observe(ws, legacy.id, notes, [1: "legacy-button"])
        XCTAssertNotEqual(genL, genA)
        guard case .failure = ws.resolveHandle(
            principal: dsh, id: nil, snapshot: genA, elementID: 1, mode: .background, now: 101)
        else { return XCTFail("A's snapshot must not resolve in the default context") }
        guard case .success(let right) = ws.resolveHandle(
            principal: dsh, id: b.id, snapshot: genB, elementID: 1, mode: .background, now: 101)
        else { return XCTFail() }
        XCTAssertEqual(right.handle, "notes-button")
    }

    /// What `release` / USER_TAKEOVER REPORT as the new current snapshot is the
    /// number the context really holds (the model cites it next).
    func testRetirementReportsTheGenerationTheContextReallyHolds() {
        let ws = workspace()
        let a = create(ws, dsh)
        let b = create(ws, dsh)
        let genA = observe(ws, a.id, safari, [1: "a"])
        _ = observe(ws, b.id, notes, [1: "b"])
        _ = observe(ws, b.id, notes, [1: "b2"])
        let retired = ws.invalidate(id: a.id, reason: "release", now: 101)!
        XCTAssertEqual(retired.retired, genA)
        guard case .failure(let refusal) = ws.resolveHandle(
            principal: dsh, id: a.id, snapshot: genA, elementID: 1, mode: .background, now: 102)
        else { return XCTFail() }
        XCTAssertTrue(refusal.detail.contains("current=\(retired.generation)"), refusal.detail)
        XCTAssertGreaterThan(retired.generation, genA + 1, "other contexts moved the shared counter")
    }

    /// Audit M-03 / E-01: waiting on a long download kept nothing alive, so the
    /// context expired under it and the expectation vanished (DOWNLOAD_UNKNOWN,
    /// and the risk of pressing Download again). A read of the download touches
    /// the context that owns it.
    func testTouchingAContextKeepsItAliveAndOnlyForItsOwner() {
        let ws = workspace()
        let a = create(ws, dsh)
        XCTAssertTrue(ws.touch(principal: dsh, id: a.id, now: 1700))
        XCTAssertTrue(ws.reap(now: 3400).isEmpty, "idle since 1700, not since 0")
        XCTAssertFalse(ws.touch(principal: BridgePrincipal(key: "client:other", strength: .verifiedClient), id: a.id, now: 3500),
                       "another client cannot keep it alive")
        XCTAssertFalse(ws.touch(principal: dsh, id: "ctx_" + String(repeating: "f", count: 32), now: 3500))
        XCTAssertEqual(ws.reap(now: 5300).count, 1, "and without further use it still expires")
    }

    func testLegacyReleaseKeepsTheReleasedReason() {
        let ws = workspace()
        let legacy = ws.legacyContext(principal: dsh, now: 100)
        let gen = observe(ws, legacy.id, safari, [1: "x"])
        let retired = ws.invalidate(id: legacy.id, reason: "release", now: 101)!
        XCTAssertEqual(retired.retired, gen)
        XCTAssertEqual(retired.generation, gen + 1)
        guard case .failure(let refusal) = ws.resolveHandle(
            principal: dsh, id: nil, snapshot: gen, elementID: 1, mode: .background, now: 102)
        else { return XCTFail() }
        XCTAssertEqual(refusal.detail, "policy=background;reason=released;snapshot=\(gen);current=\(gen + 1)")
    }
}
