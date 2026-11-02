import XCTest

/// After a `USER_TAKEOVER` (the person brought the target in front while an
/// action ran) the element handles are invalidated with the SAME rule as
/// `observation.release` (Shared: `bridgeRetireObservation`).
///
/// Bug: the takeover path zeroed the observation time, so the next action on
/// an old handle was refused with `reason=expired;age=<seconds since 1970>`.
/// Now the generation is retired: the old handle is refused with
/// `reason=released`, without an age, before any UI is touched, and a fresh
/// observation works as usual.
final class UserTakeoverInvalidationTests: XCTestCase {

    private let harness = "com.apple.Terminal"
    private let claude = "com.anthropic.claudefordesktop"
    private let idle = BridgeHumanInputSample(mouseDownAge: 600, keyDownAge: 600, flagsChangedAge: 600)

    private func env(_ t: Double, front: String, input: BridgeHumanInputSample) -> BridgeEnvironment {
        BridgeEnvironment(
            frontmostApp: front == claude ? "Claude" : "Terminal", frontmostBundle: front,
            cursorX: 100, cursorY: 100, focusedBundle: front, topWindowBundle: front,
            t: t, humanInput: input)
    }

    private func clickAt(_ t: Double, mouseDownAt: Double) -> BridgeHumanInputSample {
        BridgeHumanInputSample(mouseDownAge: t - mouseDownAt, keyDownAge: 600, flagsChangedAge: 600)
    }

    /// The person clicks Claude at 0.50 s; Claude is seen in front at 0.55 s.
    private var userTakeover: BridgeInterferenceReport {
        let sequence = [
            env(0, front: harness, input: idle),
            env(0.45, front: harness, input: idle),
            env(0.50, front: harness, input: clickAt(0.50, mouseDownAt: 0.50)),
            env(0.55, front: claude, input: clickAt(0.55, mouseDownAt: 0.50)),
            env(1.0, front: claude, input: clickAt(1.0, mouseDownAt: 0.50)),
        ]
        return bridgeInterferenceReport(
            before: sequence.first!, after: sequence.last!, samples: Array(sequence.dropFirst().dropLast()),
            actionClass: .accessibility, mode: .background, targetBundle: claude)
    }

    /// Mirror of the helper's element preconditions, in their order: released
    /// first, then expiry (the only place an `age` is computed), then staleness.
    private func refusal(requested: Int, generation: Int, capturedAt: Double, released: Set<Int>,
                         now: Double, mode: BridgeInteractionMode = .background) -> BridgePolicyRefusal? {
        if let r = bridgeReleasedSnapshotRefusal(
            requested: requested, releasedSnapshots: released, current: generation, mode: mode) { return r }
        if bridgeObservationExpired(capturedAt: capturedAt, now: now, mode: mode) {
            return BridgePolicyRefusal(code: "ACTION_FAILED", message: "expired",
                                       detail: "policy=\(mode.rawValue);reason=expired;age=\(Int(now - capturedAt))s")
        }
        return bridgeSnapshotRefusal(current: generation, requested: requested, mode: mode)
    }

    func testTakeoverRetiresTheGenerationAndTheOldHandleIsRefusedAsReleasedWithoutAge() {
        let observedAt = 1_793_600_000.0
        let n = 7
        // Snapshot N is valid before the takeover.
        XCTAssertNil(refusal(requested: n, generation: n, capturedAt: observedAt, released: [], now: observedAt + 1))

        let report = userTakeover
        XCTAssertTrue(report.requiresReobserve, "precondition: a user takeover")
        XCTAssertFalse(report.breach, "a takeover is not a breach")

        let now = observedAt + 2
        let after = bridgeRetireObservation(generation: n, releasedSnapshots: [], now: now)
        XCTAssertEqual(after.retired, n)
        XCTAssertEqual(after.generation, n + 1)
        XCTAssertEqual(after.capturedAt, now, "the observation time is now, never 0")
        XCTAssertGreaterThan(after.capturedAt, 0)
        XCTAssertTrue(after.releasedSnapshots.contains(n))

        let old = refusal(requested: n, generation: after.generation, capturedAt: after.capturedAt,
                          released: after.releasedSnapshots, now: now + 0.5)
        XCTAssertEqual(old?.code, "ACTION_FAILED")
        XCTAssertTrue(old?.detail.contains("reason=released") ?? false)
        XCTAssertTrue(old?.detail.contains("snapshot=\(n);current=\(n + 1)") ?? false)
        XCTAssertFalse(old?.detail.contains("age=") ?? true, "no epoch-sized age")
        XCTAssertFalse(old?.detail.contains("reason=expired") ?? true)
    }

    func testTheZeroedTimestampWouldHaveProducedAnEpochAge() {
        // The old behaviour, pinned so the regression is visible: capturedAt=0
        // is "expired" and its age is the seconds since 1970.
        let now = 1_793_600_002.0
        let old = refusal(requested: 7, generation: 7, capturedAt: 0, released: [], now: now)
        XCTAssertTrue(old?.detail.contains("age=\(Int(now))s") ?? false)
        XCTAssertFalse(bridgeObservationExpired(
            capturedAt: bridgeRetireObservation(generation: 7, releasedSnapshots: [], now: now).capturedAt,
            now: now + 1, mode: .background))
    }

    func testANewObservationAfterTheTakeoverWorks() {
        let now = 1_793_600_002.0
        let after = bridgeRetireObservation(generation: 7, releasedSnapshots: [], now: now)
        // `observation.describe` advances the generation and stamps the time.
        let fresh = after.generation + 1
        XCTAssertNil(refusal(requested: fresh, generation: fresh, capturedAt: now + 1,
                             released: after.releasedSnapshots, now: now + 1.5))
        // The retired one stays refused as released, not as stale.
        let old = refusal(requested: 7, generation: fresh, capturedAt: now + 1,
                          released: after.releasedSnapshots, now: now + 1.5)
        XCTAssertTrue(old?.detail.contains("reason=released") ?? false)
    }

    func testReleaseAndTakeoverShareOneRuleAndRepeatedRetirementsAreBounded() {
        var released: Set<Int> = []
        var generation = 1
        for _ in 0..<(bridgeReleasedSnapshotsLimit + 10) {
            let r = bridgeRetireObservation(generation: generation, releasedSnapshots: released, now: 10)
            XCTAssertEqual(r.generation, generation + 1)
            released = r.releasedSnapshots
            generation = r.generation
        }
        XCTAssertEqual(released.count, bridgeReleasedSnapshotsLimit)
        XCTAssertFalse(released.contains(1), "the oldest is dropped first")
        XCTAssertTrue(released.contains(generation - 1))
        // A dropped generation is still older than current: refused as stale, never resolved.
        let dropped = bridgeSnapshotRefusal(current: generation, requested: 1, mode: .background)
        XCTAssertTrue(dropped?.detail.contains("reason=stale_snapshot") ?? false)
    }
}
