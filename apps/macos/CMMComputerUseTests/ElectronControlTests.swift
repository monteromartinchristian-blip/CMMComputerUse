import XCTest

/// Claude Desktop (Electron) was `readable` but not `actionable`
/// (content=4, elements=3, actionable=0, window_controls=3). Pinned here:
/// when the helper asks for the full tree, and how `set_value` is verified.
final class ElectronControlTests: XCTestCase {

    // MARK: - Enrichment trigger (decided after a first walk)

    func testReadableButNotActionableNowTriggersEnrichment() {
        // The live Claude state: plenty of nodes, readable, no control.
        XCTAssertEqual(bridgeEnrichmentTrigger(nodeCount: 24, access: .readable, sparseThreshold: 24),
                       .readableNotActionable)
    }

    func testSparseAndUnavailableTrigger() {
        XCTAssertEqual(bridgeEnrichmentTrigger(nodeCount: 5, access: .readable, sparseThreshold: 24), .sparse)
        XCTAssertEqual(bridgeEnrichmentTrigger(nodeCount: 5, access: .unavailable, sparseThreshold: 24), .sparse)
        XCTAssertEqual(bridgeEnrichmentTrigger(nodeCount: 24, access: .unavailable, sparseThreshold: 24), .unavailable)
    }

    func testAnActionableWindowIsNeverTouched() {
        XCTAssertNil(bridgeEnrichmentTrigger(nodeCount: 3, access: .actionable, sparseThreshold: 24))
        XCTAssertNil(bridgeEnrichmentTrigger(nodeCount: 500, access: .actionable, sparseThreshold: 24))
    }

    // MARK: - set_value postcondition

    func testSetValueIsVerifiedByReadingBack() {
        XCTAssertEqual(bridgeSetValueCheck(requested: "CMM prueba", readBack: "CMM prueba"), .verified)
        // Editors pad and use NBSP; that is the same value.
        XCTAssertEqual(bridgeSetValueCheck(requested: "CMM prueba", readBack: "CMM\u{00A0}prueba\n"), .verified)
        XCTAssertEqual(bridgeSetValueCheck(requested: "", readBack: "\n"), .verified, "restoring to empty")
    }

    func testSetValueThatDidNotTakeIsNotVerified() {
        XCTAssertEqual(bridgeSetValueCheck(requested: "CMM prueba", readBack: ""), .notApplied)
        XCTAssertEqual(bridgeSetValueCheck(requested: "CMM prueba", readBack: "CMM pruebaX"), .notApplied)
        XCTAssertEqual(bridgeSetValueCheck(requested: "CMM prueba", readBack: nil), .unreadable)
    }

    // MARK: - readable is not actionable

    func testReadOnlyTextInputDoesNotMakeAWindowActionable() {
        let readOnlyField = BridgeObservedElement(windowChrome: false, actionable: bridgeElementIsActionable(
            role: "AXTextArea", pressable: false, scrollable: false, windowChrome: false, valueSettable: false))
        let chrome = BridgeObservedElement(windowChrome: true, actionable: false)
        XCTAssertEqual(bridgeAXAccess(contentCount: 4, elements: [chrome, chrome, chrome, readOnlyField]), .readable)
    }
}
