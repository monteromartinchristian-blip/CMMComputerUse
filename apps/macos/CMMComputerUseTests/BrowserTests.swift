import XCTest

/// F-09 browser model (Shared/ComputerUseBrowser.swift): stable window and tab
/// ids, transitions that tell a tab switch from a navigation from a closed
/// application, redacted URLs, and save-panel recognition.
final class BrowserTests: XCTestCase {

    private func counter(_ prefix: String) -> () -> String {
        var next = 0
        return { next += 1; return "\(prefix)_\(next)" }
    }

    private func page(_ tab: String?, _ digest: String, web: Int? = 1, load: BridgeLoadState = .loaded,
                      window: String? = "w", pid: Int32 = 500, running: Bool = true) -> BridgePageState {
        BridgePageState(appRunning: running, pid: pid, windowKey: window, selectedTab: tab,
                        documentDigest: digest, webAreaKey: web, load: load, title: "")
    }

    // MARK: families and URLs

    func testBrowserFamiliesAreDeclaredNotRequired() {
        XCTAssertEqual(bridgeBrowserFamily(bundleID: "com.apple.Safari"), .webkit)
        XCTAssertEqual(bridgeBrowserFamily(bundleID: "com.google.Chrome"), .chromium)
        XCTAssertEqual(bridgeBrowserFamily(bundleID: "com.google.Chrome.canary"), .chromium)
        XCTAssertEqual(bridgeBrowserFamily(bundleID: "org.mozilla.firefox"), .gecko)
        XCTAssertEqual(bridgeBrowserFamily(bundleID: "com.example.Editor"), .unknown)
        XCTAssertFalse(bridgeIsKnownBrowser(bundleID: "com.apple.TextEdit"))
    }

    func testURLsAreRedactedBeforeTheyLeaveTheHelper() {
        XCTAssertEqual(bridgeRedactedURL("https://user:pw@Example.com:8443/a/b?token=SECRET#frag"),
                       "https://example.com:8443/a/b")
        XCTAssertEqual(bridgeRedactedURL("http://example.com"), "http://example.com/")
        XCTAssertEqual(bridgeRedactedURL("file:///Users/someone/Private/report.pdf"), "file://…/report.pdf")
        XCTAssertEqual(bridgeRedactedURL("blob:https://example.com/0f1e"), "blob:")
        XCTAssertEqual(bridgeRedactedURL("data:text/html;base64,AAAA"), "data:")
        XCTAssertEqual(bridgeRedactedURL("about:blank"), "about:blank")
        XCTAssertNil(bridgeRedactedURL(""))
        XCTAssertNil(bridgeRedactedURL(nil))
        let long = "https://example.com/" + String(repeating: "a", count: 1000)
        XCTAssertEqual(bridgeRedactedURL(long)?.count, 300)
    }

    // MARK: 1/3. tabs keep their ids; opening, closing, reordering

    func testTabIdsSurviveTitleChangesAndReordering() {
        let tracker = BridgeTabTracker(makeID: counter("tab"))
        let first = tracker.update(windowKey: "w", samples: [
            BridgeTabSample(elementKey: 10, title: "Inbox", selected: true),
            BridgeTabSample(elementKey: 11, title: "Docs", selected: false),
        ])
        XCTAssertEqual(first.tabs.map { $0.id }, ["tab_1", "tab_2"])
        XCTAssertEqual(first.opened, [], "the first sample establishes the window")
        // The page retitles itself and the tabs are dragged into another order.
        let second = tracker.update(windowKey: "w", samples: [
            BridgeTabSample(elementKey: 11, title: "Docs — edited", selected: false),
            BridgeTabSample(elementKey: 10, title: "Inbox (3)", selected: true),
        ])
        XCTAssertEqual(second.tabs.map { $0.id }, ["tab_2", "tab_1"])
        XCTAssertTrue(second.tabs.allSatisfy { $0.match == .element })
        XCTAssertTrue(second.reordered)
        XCTAssertFalse(second.selectionChanged)
        XCTAssertEqual(second.closed, [])
    }

    func testOpeningAndClosingTabsAreReportedAndIdsAreNeverReused() {
        let tracker = BridgeTabTracker(makeID: counter("tab"))
        _ = tracker.update(windowKey: "w", samples: [BridgeTabSample(elementKey: 1, title: "A", selected: true)])
        let opened = tracker.update(windowKey: "w", samples: [
            BridgeTabSample(elementKey: 1, title: "A", selected: false),
            BridgeTabSample(elementKey: 2, title: "B", selected: true),
        ])
        XCTAssertEqual(opened.opened, ["tab_2"])
        XCTAssertTrue(opened.selectionChanged)
        XCTAssertEqual(opened.previousSelected, "tab_1")
        XCTAssertEqual(opened.selected, "tab_2")
        let closed = tracker.update(windowKey: "w", samples: [BridgeTabSample(elementKey: 1, title: "A", selected: true)])
        XCTAssertEqual(closed.closed, ["tab_2"])
        // A new tab that happens to reuse the old title is a NEW tab when its
        // element is new: no id is resurrected.
        let again = tracker.update(windowKey: "w", samples: [
            BridgeTabSample(elementKey: 1, title: "A", selected: false),
            BridgeTabSample(elementKey: 3, title: "B", selected: true),
        ])
        XCTAssertEqual(again.opened, ["tab_3"])
    }

    func testTitleMatchingIsOnlyUsedWhenUniqueAndWithoutElementEvidence() {
        let tracker = BridgeTabTracker(makeID: counter("tab"))
        _ = tracker.update(windowKey: "w", samples: [
            BridgeTabSample(elementKey: nil, title: "Same", selected: true),
            BridgeTabSample(elementKey: nil, title: "Same", selected: false),
            BridgeTabSample(elementKey: nil, title: "Unique", selected: false),
        ])
        let next = tracker.update(windowKey: "w", samples: [
            BridgeTabSample(elementKey: nil, title: "Same", selected: true),
            BridgeTabSample(elementKey: nil, title: "Same", selected: false),
            BridgeTabSample(elementKey: nil, title: "Unique", selected: false),
        ])
        XCTAssertEqual(next.tabs[2].id, "tab_3")
        XCTAssertEqual(next.tabs[2].match, .title)
        XCTAssertEqual(next.tabs[0].match, .new, "two tabs with one title are never guessed")
        XCTAssertEqual(next.tabs[1].match, .new)
    }

    func testAWindowWithoutATabStripIsOneImplicitTab() {
        let tracker = BridgeTabTracker(makeID: counter("tab"))
        let delta = tracker.update(windowKey: "w", samples: [])
        XCTAssertFalse(delta.exposed)
        XCTAssertNil(delta.selected)
    }

    func testWindowsAreTrackedByElementOrWindowIdNeverByTitle() {
        let tracker = BridgeWindowTracker(makeID: counter("win"))
        let first = tracker.update(samples: [
            BridgeWindowSample(windowID: 100, elementKey: 7, title: "Inbox"),
            BridgeWindowSample(windowID: 101, elementKey: 8, title: "Inbox"),
        ])
        XCTAssertEqual(first.windows.map { $0.key }, ["win_1", "win_2"])
        // A tab switch renames the window; the key stays.
        let second = tracker.update(samples: [
            BridgeWindowSample(windowID: 100, elementKey: 7, title: "Other page"),
            BridgeWindowSample(windowID: 101, elementKey: 8, title: "Inbox"),
        ])
        XCTAssertEqual(second.windows.map { $0.key }, ["win_1", "win_2"])
        XCTAssertEqual(second.closed, [])
        let third = tracker.update(samples: [
            BridgeWindowSample(windowID: 101, elementKey: 8, title: "Inbox"),
            BridgeWindowSample(windowID: 102, elementKey: 9, title: "New window"),
        ])
        XCTAssertEqual(third.closed, ["win_1"])
        XCTAssertEqual(third.opened, ["win_3"])
        XCTAssertEqual(tracker.key(forWindowID: 102), "win_3")
    }

    // MARK: 1/2. transitions: a tab switch is not a disconnection

    func testTransitionsAreClassifiedMostSignificantFirst() {
        let base = page("t1", "aaaa")
        XCTAssertEqual(bridgeClassifyTransition(before: base, after: page("t1", "aaaa")), .unchanged)
        XCTAssertEqual(bridgeClassifyTransition(before: base, after: page("t2", "bbbb")), .tabSwitched)
        XCTAssertEqual(bridgeClassifyTransition(before: base, after: page("t1", "bbbb")), .navigated)
        XCTAssertEqual(bridgeClassifyTransition(before: base, after: page("t1", "aaaa", web: 2)), .reloaded)
        XCTAssertEqual(bridgeClassifyTransition(before: base, after: page("t1", "aaaa", load: .loading)), .loading)
        XCTAssertEqual(bridgeClassifyTransition(before: base, after: page("t2", "bbbb"), closedTabs: ["t1"]), .tabClosed)
        XCTAssertEqual(bridgeClassifyTransition(before: base, after: page(nil, "", window: "w2")), .windowClosed)
        XCTAssertEqual(bridgeClassifyTransition(before: base, after: page("t1", "aaaa", pid: 501)), .appRelaunched)
        XCTAssertEqual(bridgeClassifyTransition(before: base, after: page(nil, "", window: nil, running: false)), .appClosed)
    }

    func testOnlyApplicationLossEndsTheContext() {
        for transition in [BridgeBrowserTransition.tabSwitched, .navigated, .reloaded, .tabClosed, .windowClosed] {
            XCTAssertTrue(transition.contextSurvives, transition.rawValue)
            XCTAssertTrue(transition.invalidatesDocumentHandles, transition.rawValue)
            XCTAssertFalse(transition.meaning.contains("disconnect"), transition.rawValue)
        }
        XCTAssertFalse(BridgeBrowserTransition.appClosed.contextSurvives)
        XCTAssertFalse(BridgeBrowserTransition.appRelaunched.contextSurvives)
        XCTAssertFalse(BridgeBrowserTransition.unchanged.invalidatesDocumentHandles)
        XCTAssertFalse(BridgeBrowserTransition.loading.invalidatesDocumentHandles)
        XCTAssertTrue(BridgeBrowserTransition.tabSwitched.meaning.contains("connection is intact"))
    }

    func testRedirectChainsAreCountedAndSettlingIsRequired() {
        let samples = [
            page("t1", "a"),
            page("t1", "r1", load: .loading),
            page("t1", "r2", load: .loading),
            page("t1", "final", load: .loading),
            page("t1", "final"), page("t1", "final"), page("t1", "final"),
        ]
        let summary = bridgeSummarizeNavigation(samples)
        XCTAssertEqual(summary.transition, .navigated)
        XCTAssertEqual(summary.intermediateDocuments, 2, "two redirects before the final page")
        XCTAssertTrue(summary.settled)
        XCTAssertEqual(summary.finalLoad, .loaded)
        let stillLoading = bridgeSummarizeNavigation([page("t1", "a"), page("t1", "b", load: .loading)])
        XCTAssertFalse(stillLoading.settled)
    }

    func testAReloadIsAReloadEvenWhenItEndsOnTheSameDocument() {
        let summary = bridgeSummarizeNavigation([
            page("t1", "a", web: 1), page("t1", "a", web: 2, load: .loading),
            page("t1", "a", web: 2), page("t1", "a", web: 2), page("t1", "a", web: 2),
        ])
        XCTAssertEqual(summary.transition, .reloaded)
        XCTAssertEqual(summary.intermediateDocuments, 0)
        XCTAssertTrue(summary.settled)
    }

    func testLoadEvidenceNeverClaimsLoadedWithoutEvidence() {
        XCTAssertEqual(bridgeLoadState(busy: nil, loaded: nil, progress: nil), .unknown)
        XCTAssertEqual(bridgeLoadState(busy: true, loaded: true, progress: 1), .loading)
        XCTAssertEqual(bridgeLoadState(busy: nil, loaded: nil, progress: 0.4), .loading)
        XCTAssertEqual(bridgeLoadState(busy: nil, loaded: true, progress: nil), .loaded)
        XCTAssertEqual(bridgeLoadState(busy: false, loaded: nil, progress: nil), .loaded)
    }

    // MARK: 8. save panels

    func testASaveSheetIsRecognizedFromGenericFacts() {
        let sheet = [
            BridgeDialogElement(role: "AXStaticText", title: "Save As:"),
            BridgeDialogElement(role: "AXTextField", identifier: "saveAsNameTextField"),
            BridgeDialogElement(role: "AXTextField", subrole: "AXSearchField"),
            BridgeDialogElement(role: "AXButton", title: "Guardar", isDefault: true),
            BridgeDialogElement(role: "AXButton", title: "Cancelar", isCancel: true),
        ]
        let panel = bridgeRecognizeSavePanel(sheet)
        XCTAssertEqual(panel?.kind, .save)
        XCTAssertEqual(panel?.nameField, 1)
        XCTAssertEqual(panel?.confirm, 3)
        XCTAssertEqual(panel?.cancel, 4)
        XCTAssertNil(panel?.replace)
    }

    func testTheOverwriteButtonMustBePositivelyIdentified() {
        let confirm = [
            BridgeDialogElement(role: "AXTextField", identifier: "saveAsNameTextField"),
            BridgeDialogElement(role: "AXButton", title: "Save", isDefault: true),
            BridgeDialogElement(role: "AXStaticText", title: "“a.pdf” already exists.", depth: 1),
            BridgeDialogElement(role: "AXButton", title: "Cancel", isDefault: true, isCancel: true, depth: 1),
            BridgeDialogElement(role: "AXButton", title: "Reemplazar", depth: 1),
        ]
        let panel = bridgeRecognizeSavePanel(confirm)
        XCTAssertEqual(panel?.kind, .replaceConfirmation)
        XCTAssertEqual(panel?.replace, 4)
        XCTAssertEqual(panel?.cancel, 3)
        // An alert whose other button is not recognizably "Replace" is still a
        // confirmation, but nothing may be pressed to overwrite.
        let unknown = [
            BridgeDialogElement(role: "AXButton", title: "Cancel", isCancel: true, depth: 1),
            BridgeDialogElement(role: "AXButton", title: "Keep Both", depth: 1),
        ]
        XCTAssertEqual(bridgeRecognizeSavePanel(unknown)?.kind, .replaceConfirmation)
        XCTAssertNil(bridgeRecognizeSavePanel(unknown)?.replace)
    }

    func testSomethingThatIsNotASaveSheetIsNotRecognized() {
        XCTAssertNil(bridgeRecognizeSavePanel([
            BridgeDialogElement(role: "AXTextField"), BridgeDialogElement(role: "AXTextField"),
            BridgeDialogElement(role: "AXButton", title: "OK", isDefault: true),
        ]), "two anonymous fields: which one is the name is not known")
        XCTAssertNil(bridgeRecognizeSavePanel([BridgeDialogElement(role: "AXButton", title: "OK", isDefault: true)]))
    }

    func testSaveNamesAreOnePlainComponent() {
        XCTAssertTrue(bridgeValidSaveName("report 2026.pdf"))
        XCTAssertFalse(bridgeValidSaveName("../etc/passwd"))
        XCTAssertFalse(bridgeValidSaveName("a/b.pdf"))
        XCTAssertFalse(bridgeValidSaveName(".hidden"))
        XCTAssertFalse(bridgeValidSaveName(" padded.pdf "))
        XCTAssertFalse(bridgeValidSaveName("line\nbreak.pdf"))
        XCTAssertFalse(bridgeValidSaveName(String(repeating: "a", count: 256)))
    }

    // MARK: window resolution under load (acceptance finding D6)

    private func resolution(_ follow: String, _ title: String, _ error: Int32 = 0) -> BridgeWindowResolution {
        BridgeWindowResolution(follow: follow, title: title, titleError: error)
    }

    /// A bound window that is found with a readable title is decided at once.
    func testACertainResolutionIsNotRetried() {
        var pauses = 0
        let out = bridgeResolveWindow({ resolution("bound", "CMM-ACC-Destino.txt") }, pause: { pauses += 1 })
        XCTAssertEqual(out.attempts, 1)
        XCTAssertEqual(pauses, 0)
        XCTAssertEqual(out.resolution.follow, "bound")
    }

    /// Live finding D6: under load the bound window was momentarily not matched,
    /// or its title could not be read, and an authorized window was refused.
    /// One short second look decides on the real window instead.
    func testAnUncertainResolutionIsRetriedExactlyOnce() {
        for first in [resolution("bound_window_closed", "Otra"), resolution("bound", "", -25204),
                      resolution("bound", "")] {
            var answers = [first, resolution("bound", "CMM-ACC-Destino.txt")]
            var pauses = 0
            let out = bridgeResolveWindow({ answers.removeFirst() }, pause: { pauses += 1 })
            XCTAssertEqual(out.attempts, 2, "\(first)")
            XCTAssertEqual(pauses, 1)
            XCTAssertEqual(out.resolution.title, "CMM-ACC-Destino.txt")
            XCTAssertEqual(out.first, first, "the first attempt is kept for the diagnostics")
        }
    }

    func testTheRetryIsBoundedAndStillFailsClosed() {
        var calls = 0
        var pauses = 0
        let out = bridgeResolveWindow({ calls += 1; return resolution("bound_window_closed", "", -25204) },
                                      pause: { pauses += 1 })
        XCTAssertEqual(calls, 2, "never more than one retry")
        XCTAssertEqual(pauses, 1)
        XCTAssertTrue(out.resolution.uncertain, "still uncertain: the caller decides on it and refuses")
    }

    func testARefusalCarriesWhatWasDecided() {
        let r = resolution("bound_window_closed", "Abc", -25204)
        XCTAssertEqual(r.diagnostics, "follow=bound_window_closed;title_len=3;title_ax_error=-25204")
        XCTAssertFalse(resolution("focused", "x").uncertain)
        XCTAssertTrue(resolution("requested_missing", "").uncertain)
    }
}
