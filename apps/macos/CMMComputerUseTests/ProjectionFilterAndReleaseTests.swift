import XCTest

/// Two defects from the production acceptance (Shared/ComputerUsePolicy.swift):
///
/// 1. The adapter's `filter` could not find a control the helper had already
///    cut off by its element budget (Claude "Inicio": 61 returned,
///    budget_skipped_controls=24, `filter="Configuración"` -> 0). The filter
///    is now pushed down: non-matching controls consume no budget.
/// 2. `observation.release` zeroed the timestamp, so an old handle was refused
///    with `age=<seconds since 1970>`. The generation is now retired and an
///    old handle is refused with `reason=released`.
final class ProjectionFilterAndReleaseTests: XCTestCase {

    private typealias Candidate = (role: String, title: String, value: String, isText: Bool)

    /// Drive the SAME budget `walk()` uses over a list of interactive controls.
    private func project(_ candidates: [Candidate], filter: String = "",
                         maxRegular: Int = 60, maxText: Int = 20) -> (titles: [String], budget: BridgeProjectionBudget) {
        var budget = BridgeProjectionBudget(filter: filter, maxRegular: maxRegular, maxTextInputs: maxText)
        var admitted: [String] = []
        for c in candidates {
            var read = false
            let decision = budget.consider(isTextInput: c.isText) {
                read = true
                return [c.role, c.title, c.value]
            }
            if filter.trimmingCharacters(in: .whitespaces).isEmpty {
                XCTAssertFalse(read, "an unfiltered walk reads no extra attribute")
            }
            if decision == .admit { admitted.append(c.title) }
        }
        return (admitted, budget)
    }

    /// 85 unrelated buttons, then the gear — past the 60-control budget.
    private var claudeHome: [Candidate] {
        (1...85).map { (role: "AXButton", title: "Chat \($0)", value: "", isText: false) }
            + [(role: "AXButton", title: "Configuración de Code", value: "", isText: false)]
    }

    // MARK: - Filter pushdown

    func testUnfilteredProjectionKeepsTheOldBoundedBehaviour() {
        let (titles, budget) = project(claudeHome)
        XCTAssertEqual(titles.count, 60)
        XCTAssertFalse(titles.contains("Configuración de Code"), "past the budget, as in production")
        XCTAssertEqual(budget.budgetSkipped, 26)
        XCTAssertEqual(budget.filterSkipped, 0)
    }

    func testFilterFindsTheLateControl() {
        let (titles, budget) = project(claudeHome, filter: "Configuración")
        XCTAssertEqual(titles, ["Configuración de Code"])
        XCTAssertEqual(budget.filterSkipped, 85, "non-matching controls consumed no budget")
        XCTAssertEqual(budget.budgetSkipped, 0)
        XCTAssertEqual(budget.regular, 1)
    }

    func testFilterIsCaseInsensitiveAndMatchesPrefixesValueAndRole() {
        XCTAssertEqual(project(claudeHome, filter: "configuraci").titles, ["Configuración de Code"])
        XCTAssertEqual(project(claudeHome, filter: "  CONFIGURACIÓN  ").titles, ["Configuración de Code"])
        let withValue: [Candidate] = (1...70).map { (role: "AXButton", title: "B\($0)", value: "", isText: false) }
            + [(role: "AXTextField", title: "", value: "buscar proyectos", isText: true)]
        XCTAssertEqual(project(withValue, filter: "proyectos").titles, [""])
        let roles: [Candidate] = (1...70).map { (role: "AXButton", title: "B\($0)", value: "", isText: false) }
            + [(role: "AXPopUpButton", title: "Modelo", value: "", isText: false)]
        XCTAssertEqual(project(roles, filter: "popup").titles, ["Modelo"])
    }

    func testFilteredMatchesAreStillBounded() {
        let many: [Candidate] = (1...100).map { (role: "AXButton", title: "Ajustes \($0)", value: "", isText: false) }
        let (titles, budget) = project(many, filter: "ajustes")
        XCTAssertEqual(titles.count, 60, "the budget bounds the MATCHES returned")
        XCTAssertEqual(budget.budgetSkipped, 40)
        XCTAssertTrue(budget.isFull == false, "text-input budget unused")
    }

    func testEmptyFilterIsExactlyTheUnfilteredRule() {
        let a = project(claudeHome, filter: "")
        let b = project(claudeHome, filter: "   ")
        let c = project(claudeHome)
        XCTAssertEqual(a.titles, c.titles)
        XCTAssertEqual(b.titles, c.titles)
        XCTAssertEqual(a.budget, c.budget)
        XCTAssertFalse(BridgeProjectionBudget(filter: " ", maxRegular: 1, maxTextInputs: 1).isFiltering)
    }

    func testTextInputsKeepTheirOwnBudgetUnderAFilter() {
        let mixed: [Candidate] = (1...30).map { (role: "AXTextField", title: "campo \($0)", value: "", isText: true) }
        XCTAssertEqual(project(mixed, filter: "campo", maxText: 20).titles.count, 20)
    }

    func testFilterIsBoundedInLength() {
        let long = String(repeating: "x", count: 5_000)
        XCTAssertEqual(BridgeProjectionBudget(filter: long, maxRegular: 1, maxTextInputs: 1).filter.count,
                       bridgeElementFilterMaxChars)
    }

    func testMatcher() {
        XCTAssertTrue(bridgeElementMatchesFilter("", fields: []))
        XCTAssertTrue(bridgeElementMatchesFilter("code", fields: ["AXButton", "Configuración de Code"]))
        XCTAssertFalse(bridgeElementMatchesFilter("ajustes", fields: ["AXButton", "Configuración"]))
    }

    // MARK: - Release retires the generation

    func testAHandleFromAReleasedSnapshotIsRefusedAsReleasedWithoutAnAge() {
        let refusal = bridgeReleasedSnapshotRefusal(
            requested: 21, releasedSnapshots: [21], current: 22, mode: .background)
        XCTAssertEqual(refusal?.code, "ACTION_FAILED")
        XCTAssertTrue(refusal?.detail.contains("reason=released") ?? false)
        XCTAssertTrue(refusal?.detail.contains("snapshot=21;current=22") ?? false)
        XCTAssertFalse(refusal?.detail.contains("age=") ?? true, "a released observation has no age")
    }

    func testOtherSnapshotsAreNotReportedAsReleased() {
        XCTAssertNil(bridgeReleasedSnapshotRefusal(requested: 22, releasedSnapshots: [21], current: 22, mode: .background))
        XCTAssertNil(bridgeReleasedSnapshotRefusal(requested: nil, releasedSnapshots: [21], current: 22, mode: .background))
    }

    func testAStaleSnapshotSaysSo() {
        let refusal = bridgeSnapshotRefusal(current: 23, requested: 20, mode: .background)
        XCTAssertTrue(refusal?.detail.contains("reason=stale_snapshot") ?? false)
        XCTAssertTrue(refusal?.detail.contains("current=23") ?? false)
    }
}
