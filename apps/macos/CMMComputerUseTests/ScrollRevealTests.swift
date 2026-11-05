import XCTest

/// Acceptance finding D5: Firefox's document area is an AXScrollArea with no
/// accessible scroll bar and no AXScroll<Dir>ByPage, so `ui.scroll` refused
/// it although its content can be read. Its content nodes advertise
/// AXScrollToVisible: scrolling = revealing the descendant just beyond the
/// visible edge, verified by that descendant's own position.
final class ScrollRevealTests: XCTestCase {

    private let viewport = BridgeRevealRect(minX: 0, minY: 100, maxX: 800, maxY: 500)

    private func line(_ top: Double, height: Double = 20) -> BridgeRevealRect {
        BridgeRevealRect(minX: 10, minY: top, maxX: 400, maxY: top + height)
    }

    // MARK: plan

    func testAScrollAreaWithoutScrollBarRevealsWhenItsContentCan() {
        XCTAssertEqual(
            bridgeScrollPlan(direction: .down, actions: [], role: "AXScrollArea",
                             hasScrollBar: false, scrollBarSettable: false, canReveal: true),
            .revealDescendant)
        XCTAssertEqual(
            bridgeScrollPlan(direction: .down, actions: [], role: "AXScrollArea",
                             hasScrollBar: false, scrollBarSettable: false, canReveal: false),
            .unsupported(reason: "scroll_area_without_scrollbar"),
            "nothing to reveal: the explicit refusal stays")
    }

    /// No degradation: elements that already scrolled keep their route.
    func testExistingRoutesStayPreferred() {
        XCTAssertEqual(
            bridgeScrollPlan(direction: .down, actions: ["AXScrollDownByPage"], role: "AXScrollArea",
                             hasScrollBar: true, scrollBarSettable: true, canReveal: true),
            .pageAction("AXScrollDownByPage"))
        XCTAssertEqual(
            bridgeScrollPlan(direction: .up, actions: [], role: "AXScrollArea",
                             hasScrollBar: true, scrollBarSettable: true, canReveal: true),
            .scrollBarValue)
        XCTAssertEqual(
            bridgeScrollPlan(direction: .up, actions: [], role: "AXScrollArea",
                             hasScrollBar: true, scrollBarSettable: false, canReveal: true),
            .revealDescendant, "a read-only scroll bar no longer blocks a revealable document")
        XCTAssertEqual(
            bridgeScrollPlan(direction: .down, actions: ["AXPress"], role: "AXButton",
                             hasScrollBar: false, scrollBarSettable: false, canReveal: false),
            .unsupported(reason: "not_scrollable"))
    }

    // MARK: target (nearest first, then by the measured landing; never skip content)

    private func next(_ direction: BridgeScrollDirection, _ candidates: [BridgeRevealRect], landing: Double?,
                      remaining: Double, room: Double = 400) -> Int? {
        bridgeRevealNext(direction: direction, viewport: viewport, candidates: candidates, landing: landing,
                         remaining: remaining, room: room)
    }

    func testTheFirstStepIsTheNearestContentBeyondTheEdge() {
        XCTAssertEqual(next(.down, [line(120), line(520), line(600), line(1300)], landing: nil, remaining: 360), 1)
        XCTAssertEqual(next(.up, [line(-700), line(-20), line(150)], landing: nil, remaining: 360), 1)
    }

    /// Viewport 100…500. A centring browser (landing 200): candidate centres
    /// 530/630/810/1310 would move the content 230/330/510/1010.
    func testLaterStepsUseTheMeasuredLanding() {
        let candidates = [line(520), line(620), line(800), line(1300)]
        XCTAssertEqual(next(.down, candidates, landing: 200, remaining: 360), 1, "farthest within 360")
        XCTAssertEqual(next(.down, candidates, landing: 200, remaining: 160, room: 400), 0,
                       "none within 160: the nearest, still inside the cap")
        // Edge-aligned browser (landing 390): moves 40/140/320/820; capped at one viewport.
        XCTAssertEqual(next(.down, candidates, landing: 390, remaining: 2000), 2)
    }

    /// Live finding: a centring browser overshot one page by ~25 pt when a
    /// second half-page step was forced. Content is never skipped: a step that
    /// would exceed the cap is not taken.
    func testNoStepExceedsTheCap() {
        let candidates = [line(520), line(620), line(800)]
        XCTAssertNil(next(.down, candidates, landing: 200, remaining: 160, room: 200))
    }

    func testUpUsesTheSameRuleMirrored() {
        let candidates = [line(-700), line(-300), line(-20), line(150)]
        // Centre landing 200: moves 990/590/310 -> the -20 line.
        XCTAssertEqual(next(.up, candidates, landing: 200, remaining: 360), 2)
        // Top-aligned (landing 10): moves 800/400/120 -> the -300 line, exactly one viewport.
        XCTAssertEqual(next(.up, candidates, landing: 10, remaining: 2000), 1)
    }

    func testNothingBeyondTheEdgeIsNoTarget() {
        XCTAssertNil(next(.down, [line(120), line(470)], landing: nil, remaining: 360))
        XCTAssertNil(next(.up, [line(120), line(470)], landing: 200, remaining: 360))
    }

    func testAnElementStraddlingTheEdgeIsNotAStep() {
        XCTAssertEqual(next(.down, [line(490, height: 40), line(700)], landing: nil, remaining: 360), 1)
    }

    func testHorizontalTargets() {
        let right = BridgeRevealRect(minX: 900, minY: 200, maxX: 960, maxY: 220)
        let left = BridgeRevealRect(minX: -300, minY: 200, maxX: -240, maxY: 220)
        XCTAssertEqual(next(.right, [left, right], landing: nil, remaining: 700), 1)
        XCTAssertEqual(next(.left, [left, right], landing: nil, remaining: 700), 0)
    }

    // MARK: effect (a call that merely returned no error is not a scroll)

    func testTheEffectIsTheTargetsOwnMovement() {
        XCTAssertEqual(bridgeRevealEffect(direction: .down, before: line(800), after: line(480)), .moved)
        XCTAssertEqual(bridgeRevealEffect(direction: .down, before: line(800), after: line(800.4)), .unchanged)
        XCTAssertEqual(bridgeRevealEffect(direction: .down, before: line(800), after: line(900)), .wrongDirection)
        XCTAssertEqual(bridgeRevealEffect(direction: .up, before: line(-20), after: line(110)), .moved)
        XCTAssertEqual(bridgeRevealEffect(direction: .up, before: line(-20), after: nil), .unmeasurable)
    }

    // MARK: nested scroll containers (live finding: the document scroll moved the inner container)

    /// Firefox reports the content of an inner `overflow:auto` box at its
    /// unclipped positions: its lines look like they lie below the fold of the
    /// document. A container whose children extend beyond its own frame is a
    /// scroller of its own; its content is never a target for its ancestor.
    func testAContainerWhoseChildrenOverflowItIsANestedScroller() {
        let box = BridgeRevealRect(minX: 10, minY: 250, maxX: 430, maxY: 470)
        XCTAssertTrue(bridgeOverflows(container: box, children: [line(260), line(1300)]))
        XCTAssertTrue(bridgeOverflows(container: box, children: [line(100)]), "content scrolled out above")
        XCTAssertFalse(bridgeOverflows(container: box, children: [line(260), line(440)]))
        XCTAssertFalse(bridgeOverflows(container: box, children: [line(469.5, height: 2)]), "sub-point overhang is not overflow")
        XCTAssertFalse(bridgeOverflows(container: box, children: []))
    }
}
