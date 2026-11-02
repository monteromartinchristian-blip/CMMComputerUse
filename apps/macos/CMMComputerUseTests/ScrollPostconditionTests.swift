import XCTest

/// `ui.scroll` is judged by an observable postcondition, not by the AX return
/// code (Shared/ComputerUsePolicy.swift, "Scroll postcondition").
///
/// Live finding 2026-11-02: `AXScrollDownByPage failed (-25205)` was reported
/// while the content had moved (AXTextArea y 622 -> 498).
final class ScrollPostconditionTests: XCTestCase {

    // MARK: - Effect measurement

    func testTheObservedLiveCaseIsAMoveDown() {
        // Content origin went up on screen: scrolled DOWN.
        let effect = bridgeScrollEffect(
            direction: .down,
            before: BridgeScrollProbe(contentOrigin: 622),
            after: BridgeScrollProbe(contentOrigin: 498))
        XCTAssertEqual(effect, .moved)
    }

    func testScrollBarValueDecidesWhenBothSidesHaveIt() {
        // Bar says down; content origin would say otherwise — the bar wins.
        let effect = bridgeScrollEffect(
            direction: .down,
            before: BridgeScrollProbe(barValue: 0.10, contentOrigin: 100),
            after: BridgeScrollProbe(barValue: 0.30, contentOrigin: 140))
        XCTAssertEqual(effect, .moved)
        XCTAssertEqual(bridgeScrollEffect(
            direction: .up,
            before: BridgeScrollProbe(barValue: 0.30),
            after: BridgeScrollProbe(barValue: 0.10)), .moved)
    }

    func testWrongDirectionUnchangedAndUnmeasurable() {
        XCTAssertEqual(bridgeScrollEffect(
            direction: .down, before: BridgeScrollProbe(barValue: 0.5),
            after: BridgeScrollProbe(barValue: 0.3)), .wrongDirection)
        XCTAssertEqual(bridgeScrollEffect(
            direction: .down, before: BridgeScrollProbe(contentOrigin: 300),
            after: BridgeScrollProbe(contentOrigin: 300.4)), .unchanged, "sub-point noise is not a scroll")
        XCTAssertEqual(bridgeScrollEffect(
            direction: .right, before: BridgeScrollProbe(contentOrigin: 10),
            after: BridgeScrollProbe(contentOrigin: -90)), .moved)
        XCTAssertEqual(bridgeScrollEffect(
            direction: .down, before: BridgeScrollProbe(), after: BridgeScrollProbe(barValue: 0.4)),
            .unmeasurable, "a one-sided reading proves nothing")
        XCTAssertFalse(BridgeScrollProbe().isMeasurable)
    }

    // MARK: - Decision after the page action

    func testPageActionErrorWithObservedEffectIsDoneAndKeepsTheError() {
        XCTAssertEqual(
            bridgeScrollAfterPageAction(effect: .moved, axError: -25205, scrollBarAvailable: true),
            .done(route: "page_action", axError: -25205))
        XCTAssertEqual(
            bridgeScrollAfterPageAction(effect: .moved, axError: nil, scrollBarAvailable: false),
            .done(route: "page_action", axError: nil))
    }

    func testNoEffectFallsBackToTheScrollBarWhenThereIsOne() {
        for effect in [BridgeScrollEffect.unchanged, .wrongDirection, .unmeasurable] {
            XCTAssertEqual(
                bridgeScrollAfterPageAction(effect: effect, axError: -25205, scrollBarAvailable: true),
                .tryScrollBar, "\(effect)")
        }
    }

    func testNoEffectAndNoScrollBarFailsWithTheReason() {
        XCTAssertEqual(bridgeScrollAfterPageAction(effect: .unchanged, axError: nil, scrollBarAvailable: false),
                       .failed(reason: "no_effect"))
        XCTAssertEqual(bridgeScrollAfterPageAction(effect: .unmeasurable, axError: nil, scrollBarAvailable: false),
                       .failed(reason: "scroll_unverifiable"))
        XCTAssertEqual(bridgeScrollAfterPageAction(effect: .wrongDirection, axError: nil, scrollBarAvailable: false),
                       .failed(reason: "wrong_direction"))
    }

    // MARK: - Decision after the scroll bar

    func testScrollBarRouteIsVerifiedToo() {
        XCTAssertEqual(bridgeScrollAfterScrollBar(effect: .moved, axError: nil), .done(route: "scroll_bar", axError: nil))
        XCTAssertEqual(bridgeScrollAfterScrollBar(effect: .unchanged, axError: -25200), .failed(reason: "no_effect"))
        XCTAssertEqual(bridgeScrollAfterScrollBar(effect: .unmeasurable, axError: nil), .failed(reason: "scroll_unverifiable"))
    }

    // MARK: - No route at all stays CAPABILITY_UNSUPPORTED (decided before any AX call)

    func testNoAXRouteIsUnsupportedBeforeAnythingRuns() {
        XCTAssertEqual(
            bridgeScrollPlan(direction: .down, actions: [], role: "AXScrollArea", hasScrollBar: false, scrollBarSettable: false),
            .unsupported(reason: "scroll_area_without_scrollbar"))
    }
}
