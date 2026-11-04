import XCTest

/// F-09 verified downloads (Shared/ComputerUseDownloads.swift). Every case is a
/// directory trace the way each engine writes it; a download is complete only
/// when the finished file is there, non-empty and stable — never because a
/// button was pressed.
final class DownloadTests: XCTestCase {

    private let dsh = BridgePrincipal(key: "client:dsh", strength: .verifiedClient)
    private let other = BridgePrincipal(key: "client:other", strength: .verifiedClient)
    private let root = "/Users/someone/Downloads"
    private let timings = BridgeDownloadTimings(settleSeconds: 1, stallSeconds: 10, renameGraceSeconds: 2)

    private func file(_ name: String, _ size: Int64, inode: UInt64, at modified: Double = 0) -> BridgeDirectoryEntry {
        BridgeDirectoryEntry(name: name, isDirectory: false, size: size, inode: inode, modified: modified)
    }

    private func bundle(_ name: String, _ size: Int64, inode: UInt64) -> BridgeDirectoryEntry {
        BridgeDirectoryEntry(name: name, isDirectory: true, size: size, inode: inode, modified: 0)
    }

    private func monitor() -> BridgeDownloadMonitor {
        var next = 0
        return BridgeDownloadMonitor(timings: timings, makeID: { next += 1; return "dl_\(next)" })
    }

    private func expect(_ m: BridgeDownloadMonitor, _ entries: [BridgeDirectoryEntry], hint: String? = nil,
                        op: String? = nil, at now: Double, principal: BridgePrincipal? = nil) -> String {
        guard case .success(let id) = m.expect(
            principal: principal ?? dsh, contextID: "ctx_a", bundleID: "com.google.Chrome", root: root,
            entries: entries, opID: op, nameHint: hint, now: now) else { XCTFail("expect refused"); return "" }
        return id
    }

    private func state(_ m: BridgeDownloadMonitor, _ id: String, _ entries: [BridgeDirectoryEntry]?,
                       at now: Double) -> BridgeDownloadStatus {
        guard case .success(let status) = m.status(principal: dsh, id: id, entries: entries, now: now) else {
            XCTFail("status refused"); fatalError()
        }
        return status
    }

    // MARK: partial names

    func testPartialNamesOfEachEngine() {
        XCTAssertEqual(bridgePartialDownload(name: "a.pdf.download", isDirectory: true),
                       BridgePartialName(format: .webkitBundle, finalName: "a.pdf"))
        XCTAssertNil(bridgePartialDownload(name: "a.pdf.download", isDirectory: false))
        XCTAssertEqual(bridgePartialDownload(name: "a.zip.crdownload", isDirectory: false),
                       BridgePartialName(format: .chromium, finalName: "a.zip"))
        XCTAssertEqual(bridgePartialDownload(name: "Unconfirmed 123456.crdownload", isDirectory: false),
                       BridgePartialName(format: .chromium, finalName: nil))
        XCTAssertEqual(bridgePartialDownload(name: "a.zip.part", isDirectory: false),
                       BridgePartialName(format: .gecko, finalName: "a.zip"))
        XCTAssertNil(bridgePartialDownload(name: "a.zip", isDirectory: false))
        XCTAssertTrue(bridgeIgnoredDownloadEntry(".DS_Store"))
    }

    // MARK: 4. direct download (Chromium: renamed in place)

    func testChromiumDirectDownloadCompletesOnlyWhenTheFileIsStable() {
        let m = monitor()
        let old = file("old.txt", 10, inode: 1)
        let id = expect(m, [old], hint: "report.csv", at: 0)
        XCTAssertEqual(state(m, id, [old], at: 0.5).state, .notStarted, "pressing proves nothing")
        let growing = [old, file("Unconfirmed 42.crdownload", 1000, inode: 9)]
        var s = state(m, id, growing, at: 1)
        XCTAssertEqual(s.state, .inProgress)
        XCTAssertEqual(s.partialFormat, .chromium)
        XCTAssertNil(s.fileName, "the name is not known yet")
        s = state(m, id, [old, file("Unconfirmed 42.crdownload", 5000, inode: 9)], at: 2)
        XCTAssertEqual(s.bytes, 5000)
        // Renamed in place: same inode.
        let done = [old, file("report.csv", 8000, inode: 9, at: 3)]
        s = state(m, id, done, at: 3)
        XCTAssertEqual(s.state, .inProgress, "a file that just appeared is still settling")
        XCTAssertEqual(s.reason, "settling")
        s = state(m, id, done, at: 4.2)
        XCTAssertEqual(s.state, .complete)
        XCTAssertEqual(s.fileName, "report.csv")
        XCTAssertEqual(s.path, root + "/report.csv")
        XCTAssertEqual(s.bytes, 8000)
        XCTAssertFalse(s.renamed)
        XCTAssertFalse(s.replacedExisting)
        XCTAssertEqual(s.dictionary["terminal"] as? Bool, true)
    }

    // MARK: 5. PDF (WebKit bundle → file)

    func testWebKitBundleBecomesTheFinishedPDF() {
        let m = monitor()
        let id = expect(m, [], hint: "paper.pdf", at: 0)
        var s = state(m, id, [bundle("paper.pdf.download", 300, inode: 20)], at: 1)
        XCTAssertEqual(s.state, .inProgress)
        XCTAssertEqual(s.partialFormat, .webkitBundle)
        XCTAssertEqual(s.fileName, "paper.pdf")
        // Safari moves the data out of the bundle and removes the bundle.
        let done = [file("paper.pdf", 4096, inode: 21, at: 2)]
        _ = state(m, id, done, at: 2)
        s = state(m, id, done, at: 3.5)
        XCTAssertEqual(s.state, .complete)
        XCTAssertEqual(s.bytes, 4096)
    }

    // MARK: 6. ZIP (Gecko: part file + empty placeholder)

    func testGeckoPlaceholderIsNotAResultAndIsNotAnOverwrite() {
        let m = monitor()
        let id = expect(m, [], hint: "archive.zip", at: 0)
        let started = [file("archive.zip", 0, inode: 30), file("archive.zip.part", 2048, inode: 31)]
        var s = state(m, id, started, at: 1)
        XCTAssertEqual(s.state, .inProgress)
        XCTAssertEqual(s.partialFormat, .gecko)
        s = state(m, id, [file("archive.zip", 0, inode: 30), file("archive.zip.part", 9000, inode: 31)], at: 2)
        XCTAssertEqual(s.state, .inProgress, "the empty placeholder is not the download")
        let done = [file("archive.zip", 12000, inode: 31, at: 3)]
        _ = state(m, id, done, at: 3)
        s = state(m, id, done, at: 4.5)
        XCTAssertEqual(s.state, .complete)
        XCTAssertFalse(s.replacedExisting, "replacing its own placeholder is not an overwrite")
    }

    // MARK: 7. redirect / generated link: the name is only known at the end

    func testADownloadWhoseNameArrivesLateIsStillAttributed() {
        let m = monitor()
        let id = expect(m, [], at: 0)
        _ = state(m, id, [file("Unconfirmed 7.crdownload", 10, inode: 40)], at: 1)
        let done = [file("export-2026-11-04.csv", 64, inode: 40, at: 2)]
        _ = state(m, id, done, at: 2)
        let s = state(m, id, done, at: 3.1)
        XCTAssertEqual(s.state, .complete)
        XCTAssertEqual(s.fileName, "export-2026-11-04.csv")
    }

    func testAFastDownloadThatFinishedBetweenScansIsStillVerified() {
        let m = monitor()
        let id = expect(m, [], hint: "tiny.txt", at: 0)
        let done = [file("tiny.txt", 5, inode: 50, at: 1)]
        XCTAssertEqual(state(m, id, done, at: 1).state, .inProgress)
        XCTAssertEqual(state(m, id, done, at: 2.5).state, .complete)
    }

    func testAnEmptyFileIsNeverComplete() {
        let m = monitor()
        let id = expect(m, [], at: 0)
        let empty = [file("blank.bin", 0, inode: 51)]
        _ = state(m, id, empty, at: 1)
        XCTAssertNotEqual(state(m, id, empty, at: 5).state, .complete)
    }

    // MARK: name conflicts and overwrites

    func testAConflictRenameIsReportedAndStillMatchesTheHint() {
        let m = monitor()
        let existing = file("invoice.pdf", 100, inode: 60)
        let id = expect(m, [existing], hint: "invoice.pdf", at: 0)
        let done = [existing, file("invoice (1).pdf", 900, inode: 61)]
        _ = state(m, id, done, at: 1)
        let s = state(m, id, done, at: 2.5)
        XCTAssertEqual(s.state, .complete)
        XCTAssertEqual(s.fileName, "invoice (1).pdf")
        XCTAssertTrue(s.renamed)
        XCTAssertFalse(s.replacedExisting)
        XCTAssertTrue(bridgeNameMatchesHint("invoice-2.pdf", hint: "invoice.pdf"))
        XCTAssertTrue(bridgeNameMatchesHint("invoice(3).pdf", hint: "invoice.pdf"))
        XCTAssertFalse(bridgeNameMatchesHint("invoices.pdf", hint: "invoice.pdf"))
        XCTAssertFalse(bridgeNameMatchesHint("invoice (1).zip", hint: "invoice.pdf"))
    }

    func testAnOverwriteIsReportedAsSuch() {
        let m = monitor()
        let existing = file("data.csv", 100, inode: 70, at: 0)
        let id = expect(m, [existing], hint: "data.csv", at: 0)
        _ = state(m, id, [existing, file("data.csv.crdownload", 50, inode: 71)], at: 1)
        let done = [file("data.csv", 400, inode: 71, at: 2)]
        _ = state(m, id, done, at: 2)
        let s = state(m, id, done, at: 3.5)
        XCTAssertEqual(s.state, .complete)
        XCTAssertTrue(s.replacedExisting)
    }

    // MARK: 9. interruption and recovery

    func testAStalledPartialIsInterruptedAndResumesWhenItGrows() {
        let m = monitor()
        let id = expect(m, [], hint: "big.iso", at: 0)
        _ = state(m, id, [file("big.iso.crdownload", 100, inode: 80)], at: 1)
        var s = state(m, id, [file("big.iso.crdownload", 100, inode: 80)], at: 12)
        XCTAssertEqual(s.state, .interrupted)
        XCTAssertTrue(s.resumable, "the partial is still there")
        XCTAssertEqual(s.reason, "no_growth")
        XCTAssertFalse(s.state.terminal, "an interruption is not the end")
        s = state(m, id, [file("big.iso.crdownload", 500, inode: 80)], at: 13)
        XCTAssertEqual(s.state, .inProgress)
        let done = [file("big.iso", 900, inode: 80, at: 14)]
        _ = state(m, id, done, at: 14)
        s = state(m, id, done, at: 15.5)
        XCTAssertEqual(s.state, .complete)
        XCTAssertTrue(s.resumed)
    }

    func testAVanishedPartialWithNoResultFails() {
        let m = monitor()
        let id = expect(m, [], at: 0)
        _ = state(m, id, [file("x.bin.crdownload", 100, inode: 90)], at: 1)
        XCTAssertEqual(state(m, id, [], at: 1.5).state, .inProgress, "a rename may still be in flight")
        let s = state(m, id, [], at: 4)
        XCTAssertEqual(s.state, .failed)
        XCTAssertEqual(s.reason, "partial_removed")
        XCTAssertTrue(s.state.terminal)
    }

    // MARK: 10. two simultaneous downloads in one directory

    func testTwoSimultaneousDownloadsAreNeverConfused() {
        let m = monitor()
        let first = expect(m, [], hint: "a.zip", at: 0)
        _ = state(m, first, [file("a.zip.crdownload", 10, inode: 100)], at: 1)
        // The second expectation is declared while the first is in flight: the
        // first's partial is in its baseline and can never be its download.
        let second = expect(m, [file("a.zip.crdownload", 20, inode: 100)], hint: "b.pdf", at: 2)
        let both = [file("a.zip.crdownload", 30, inode: 100), file("b.pdf.crdownload", 5, inode: 101)]
        XCTAssertEqual(state(m, second, both, at: 3).fileName, "b.pdf")
        // B finishes first.
        let bDone = [file("a.zip.crdownload", 40, inode: 100), file("b.pdf", 70, inode: 101)]
        _ = state(m, second, bDone, at: 4)
        XCTAssertEqual(state(m, second, bDone, at: 5.5).state, .complete)
        XCTAssertEqual(state(m, first, bDone, at: 5.5).state, .inProgress)
        XCTAssertEqual(state(m, first, nil, at: 5.5).fileName, "a.zip")
        let allDone = [file("a.zip", 99, inode: 100), file("b.pdf", 70, inode: 101)]
        _ = state(m, first, allDone, at: 6)
        let a = state(m, first, allDone, at: 7.5)
        XCTAssertEqual(a.state, .complete)
        XCTAssertEqual(a.fileName, "a.zip")
        XCTAssertEqual(state(m, second, nil, at: 7.5).fileName, "b.pdf")
    }

    func testWithoutHintsTheOlderExpectationGetsTheFirstDownload() {
        let m = monitor()
        let first = expect(m, [], at: 0)
        let second = expect(m, [], at: 0.5)
        _ = state(m, first, [file("one.bin.crdownload", 1, inode: 110)], at: 1)
        XCTAssertEqual(state(m, first, nil, at: 1).fileName, "one.bin")
        XCTAssertEqual(state(m, second, nil, at: 1).state, .notStarted)
    }

    func testADownloadAlreadyInProgressBeforeTheExpectationIsNotCredited() {
        let m = monitor()
        let partial = file("earlier.zip.crdownload", 10, inode: 120)
        let id = expect(m, [partial], at: 0)
        let done = [file("earlier.zip", 50, inode: 120)]
        _ = state(m, id, done, at: 1)
        XCTAssertEqual(state(m, id, done, at: 3).state, .notStarted)
    }

    // MARK: lost answers: the expectation answers instead of a second press

    func testAResentExpectWithTheSameOperationIdIsTheSameExpectation() {
        let m = monitor()
        let a = expect(m, [], op: "op_download_0001", at: 0)
        let b = expect(m, [file("unrelated.txt", 1, inode: 130)], op: "op_download_0001", at: 1)
        XCTAssertEqual(a, b)
        XCTAssertEqual(m.count, 1)
    }

    func testExpectationsAreOwnedAndBounded() {
        let m = monitor()
        let id = expect(m, [], at: 0)
        if case .success = m.status(principal: other, id: id, entries: [], now: 1) {
            XCTFail("another client must not read this expectation")
        }
        XCTAssertFalse(m.forget(principal: other, id: id))
        XCTAssertTrue(m.forget(principal: dsh, id: id))
        XCTAssertFalse(m.forget(principal: dsh, id: id))
        let limited = BridgeDownloadMonitor(limits: BridgeDownloadLimits(maxPerPrincipal: 1))
        _ = limited.expect(principal: dsh, contextID: nil, bundleID: "b", root: root, entries: [], opID: nil,
                           nameHint: nil, now: 0)
        guard case .failure(let refusal) = limited.expect(
            principal: dsh, contextID: nil, bundleID: "b", root: root, entries: [], opID: nil, nameHint: nil, now: 0)
        else { return XCTFail("limit not enforced") }
        XCTAssertEqual(refusal.code, "DOWNLOAD_LIMIT")
    }

    // MARK: roots

    func testDownloadRootsAreNormalizedAndExact() {
        XCTAssertEqual(bridgeNormalizedDownloadRoot("~/Downloads", home: "/Users/someone"), "/Users/someone/Downloads")
        XCTAssertEqual(bridgeNormalizedDownloadRoot("/tmp/lane/", home: "/h"), "/tmp/lane")
        XCTAssertNil(bridgeNormalizedDownloadRoot("/", home: "/h"))
        XCTAssertNil(bridgeNormalizedDownloadRoot("Downloads", home: "/h"))
        XCTAssertNil(bridgeNormalizedDownloadRoot("~/Downloads/../.ssh", home: "/h"))
        XCTAssertNil(bridgeNormalizedDownloadRoot("", home: "/h"))
        XCTAssertTrue(bridgeDownloadRootAllowed("/h/Downloads", roots: ["/h/Downloads"]))
        XCTAssertFalse(bridgeDownloadRootAllowed("/h/Downloads/sub", roots: ["/h/Downloads"]))
    }

    func testThePolicyDeclaresDownloadRootsPerApplicationAndRefusesTypos() {
        let good = #"{"version":1,"mode":"background","apps":[{"bundle_id":"com.google.Chrome","scopes":["observe","control"],"downloads":{"roots":["/tmp/lane-downloads"]}}]}"#
        let policy = BridgeAuthorizationPolicy.parse(Data(good.utf8), source: "t")
        XCTAssertEqual(policy?.grants.first?.downloadRoots, ["/tmp/lane-downloads"])
        let none = #"{"version":1,"mode":"background","apps":[{"bundle_id":"com.google.Chrome","scopes":["observe"]}]}"#
        XCTAssertEqual(BridgeAuthorizationPolicy.parse(Data(none.utf8), source: "t")?.grants.first?.downloadRoots, [],
                       "no roots declared: no directory may be watched")
        let typo = #"{"version":1,"mode":"background","apps":[{"bundle_id":"com.google.Chrome","downloads":["/tmp"]}]}"#
        XCTAssertNil(BridgeAuthorizationPolicy.parse(Data(typo.utf8), source: "t"))
        let escape = #"{"version":1,"mode":"background","apps":[{"bundle_id":"x","downloads":{"roots":["relative/dir"]}}]}"#
        XCTAssertNil(BridgeAuthorizationPolicy.parse(Data(escape.utf8), source: "t"))
    }
}
