import XCTest

/// Audit X-06: a window is SELECTED only among the windows the caller may
/// observe. Before, the selection ran over every window of every application
/// and an ambiguous title answered with `App / Title` labels BEFORE any
/// authorization — a process with no identity could enumerate the title of
/// every window on the screen through the helper's Screen Recording permission.
final class WindowSelectionAuthorizationTests: XCTestCase {

    private let pages = BridgeWindowCandidate(windowID: 11, title: "Informe Q3", app: "Pages", bundleID: "com.apple.iWork.Pages", width: 800, height: 600)
    private let pagesTwo = BridgeWindowCandidate(windowID: 12, title: "Informe Q4", app: "Pages", bundleID: "com.apple.iWork.Pages", width: 800, height: 600)
    private let mail = BridgeWindowCandidate(windowID: 21, title: "Informe confidencial: despido", app: "Mail", bundleID: "com.apple.mail", width: 800, height: 600)
    private let bank = BridgeWindowCandidate(windowID: 31, title: "Informe de la cuenta ES91…", app: "Safari", bundleID: "com.apple.Safari", width: 800, height: 600)

    private var onlyPages: (BridgeWindowCandidate) -> Bool { { $0.bundleID == "com.apple.iWork.Pages" } }

    func testAnUnauthorizedWindowNeverTakesPartInTheSelection() {
        let all = [pages, mail, bank]
        // Unfiltered, "Informe" is ambiguous and the answer would list Mail and Safari.
        guard case .ambiguous(let leaked) = bridgeSelectWindow(request: "Informe", app: nil, candidates: all) else {
            return XCTFail("setup: the unfiltered selection is ambiguous")
        }
        XCTAssertTrue(leaked.contains { $0.contains("Mail") })
        // Filtered by authorization first: one authorized match, nothing else exists.
        XCTAssertEqual(bridgeSelectAuthorizedWindow(request: "Informe", app: nil, candidates: all, isAuthorized: onlyPages),
                       .selected(pages))
    }

    func testAnAmbiguousAnswerListsOnlyAuthorizedWindows() {
        let all = [pages, pagesTwo, mail, bank]
        guard case .ambiguous(let labels) = bridgeSelectAuthorizedWindow(
            request: "Informe", app: nil, candidates: all, isAuthorized: onlyPages) else { return XCTFail() }
        XCTAssertEqual(labels, ["Pages / Informe Q3", "Pages / Informe Q4"])
        XCTAssertFalse(labels.joined().contains("Mail"))
        XCTAssertFalse(labels.joined().contains("cuenta"))
    }

    /// No existence oracle: an unauthorized window and a window that does not
    /// exist give the SAME answer.
    func testAnUnauthorizedWindowLooksExactlyLikeOneThatDoesNotExist() {
        let all = [pages, mail]
        XCTAssertEqual(bridgeSelectAuthorizedWindow(request: "despido", app: nil, candidates: all, isAuthorized: onlyPages),
                       bridgeSelectAuthorizedWindow(request: "no-such-title", app: nil, candidates: all, isAuthorized: onlyPages))
        XCTAssertEqual(bridgeSelectAuthorizedWindow(request: "despido", app: nil, candidates: all, isAuthorized: onlyPages), .notFound)
        XCTAssertEqual(bridgeResolveAuthorizedWindowById(windowID: mail.windowID, app: nil, candidates: all, isAuthorized: onlyPages),
                       bridgeResolveAuthorizedWindowById(windowID: 99999, app: nil, candidates: all, isAuthorized: onlyPages))
        XCTAssertEqual(bridgeResolveAuthorizedWindowById(windowID: pages.windowID, app: nil, candidates: all, isAuthorized: onlyPages),
                       .selected(pages))
    }

    func testNothingAuthorizedAnswersNotFound() {
        XCTAssertEqual(bridgeSelectAuthorizedWindow(request: "Informe", app: nil, candidates: [mail, bank], isAuthorized: { _ in false }),
                       .notFound)
        XCTAssertEqual(bridgeSelectAuthorizedWindow(request: "Informe", app: "Mail", candidates: [mail, bank], isAuthorized: { _ in false }),
                       .notFound)
    }
}
