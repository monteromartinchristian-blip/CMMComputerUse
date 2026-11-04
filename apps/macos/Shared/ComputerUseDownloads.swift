// ComputerUseDownloads.swift — verified downloads (F-09).
//
// Pressing a "Download" button proves nothing: the browser may open the file
// in a viewer, ask for a destination, rename it, fail half-way or never start.
// A download is reported COMPLETE only when the file system shows it:
//
//   1. the caller declares an EXPECTATION before the press (`download.expect`)
//      — a baseline of a directory the policy allows, metadata only;
//   2. every scan folds the directory into ARTIFACTS: one per download,
//      followed across the browser's renames (inode first, then the partial
//      name's final name), through the partial formats each engine uses
//      (`X.download/` bundles, `X.crdownload`, `X.part` + placeholder);
//   3. each new artifact is CLAIMED by exactly one expectation, oldest first,
//      a name hint winning — so two simultaneous downloads in one directory
//      are never confused, and a download that started before an expectation
//      existed is never credited to it;
//   4. an artifact is `complete` only when its partial is gone, its final file
//      exists, is non-empty and has kept the same size and modification time
//      for the settle interval; a partial that stops growing is `interrupted`
//      (and `in_progress` again if it resumes); a partial that vanishes with
//      no final file is `failed`.
//
// The expectation is what makes a lost answer harmless: when the press that
// should have started a download has an UNKNOWN outcome, the caller asks the
// expectation instead of pressing again. Nothing here opens a file: names,
// sizes, inodes and dates only. Pure; the helper feeds it `lstat` results.

import CryptoKit
import Foundation

// MARK: - Directory entries

public struct BridgeDirectoryEntry: Equatable, Sendable {
    public let name: String
    public let isDirectory: Bool
    /// Bytes; for a WebKit `.download` bundle, the bytes of the data inside.
    public let size: Int64
    public let inode: UInt64
    public let modified: Double

    public init(name: String, isDirectory: Bool, size: Int64, inode: UInt64, modified: Double) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.inode = inode
        self.modified = modified
    }
}

/// How an engine marks a download that is not finished yet.
public enum BridgePartialFormat: String, Sendable {
    /// Safari/WebKit: a `Name.ext.download` bundle (directory) holding the data.
    case webkitBundle = "webkit_bundle"
    /// Chromium: `Name.ext.crdownload`, or `Unconfirmed N.crdownload` before
    /// the name is known; renamed in place (same inode) when done.
    case chromium = "crdownload"
    /// Firefox/Gecko: `Name.<8 random>.ext.part` (older releases:
    /// `Name.ext.part`) plus an empty placeholder `Name.ext`; the part file
    /// replaces the placeholder (same inode) when done.
    case gecko = "part"
}

public struct BridgePartialName: Equatable, Sendable {
    public let format: BridgePartialFormat
    /// The name the finished file will have, when the partial name says it.
    public let finalName: String?
}

public func bridgePartialDownload(name: String, isDirectory: Bool) -> BridgePartialName? {
    func base(_ suffix: String) -> String? {
        let stem = String(name.dropLast(suffix.count))
        return stem.isEmpty ? nil : stem
    }
    if isDirectory {
        guard name.hasSuffix(".download") else { return nil }
        return BridgePartialName(format: .webkitBundle, finalName: base(".download"))
    }
    if name.hasSuffix(".crdownload") {
        guard let stem = base(".crdownload") else { return BridgePartialName(format: .chromium, finalName: nil) }
        let unconfirmed = stem.hasPrefix("Unconfirmed ")
            && stem.dropFirst("Unconfirmed ".count).allSatisfy { $0.isNumber }
        return BridgePartialName(format: .chromium, finalName: unconfirmed ? nil : stem)
    }
    if name.hasSuffix(".part") {
        guard let stem = base(".part") else { return BridgePartialName(format: .gecko, finalName: nil) }
        // Current Firefox inserts an 8-character random token before the
        // extension (observed live: `slow.ap041uWi.bin.part` for `slow.bin`).
        let pattern = #"^(.+)\.[A-Za-z0-9_-]{8}(\.[^.]+)?$"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let found = regex.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)) {
            let head = Range(found.range(at: 1), in: stem).map { String(stem[$0]) } ?? stem
            let ext = Range(found.range(at: 2), in: stem).map { String(stem[$0]) } ?? ""
            return BridgePartialName(format: .gecko, finalName: head + ext)
        }
        return BridgePartialName(format: .gecko, finalName: stem)
    }
    return nil
}

/// Entries a scan ignores: the file system's own bookkeeping.
public func bridgeIgnoredDownloadEntry(_ name: String) -> Bool {
    name.hasPrefix(".") || name == "Icon\r"
}

// MARK: - States

public enum BridgeDownloadState: String, Sendable {
    /// Nothing attributable to this expectation has appeared yet.
    case notStarted = "not_started"
    case inProgress = "in_progress"
    /// The partial stopped growing for the stall interval. It may resume.
    case interrupted
    /// The partial disappeared and no finished file replaced it.
    case failed
    /// The finished file exists, is non-empty and is stable.
    case complete

    public var terminal: Bool { self == .complete || self == .failed }
}

public struct BridgeDownloadTimings: Equatable, Sendable {
    /// The final file must keep its size/mtime this long to be complete.
    public var settleSeconds: Double
    /// A partial that does not grow this long is interrupted.
    public var stallSeconds: Double
    /// A vanished partial gets this long for its final file to appear.
    public var renameGraceSeconds: Double

    public init(settleSeconds: Double = 1.0, stallSeconds: Double = 20, renameGraceSeconds: Double = 3) {
        self.settleSeconds = settleSeconds
        self.stallSeconds = stallSeconds
        self.renameGraceSeconds = renameGraceSeconds
    }
}

public struct BridgeDownloadLimits: Equatable, Sendable {
    public var maxPerPrincipal: Int
    public var maxTotal: Int
    /// A terminal expectation is forgotten this long after it ended.
    public var retainSeconds: Double
    /// An expectation that never ends is forgotten this long after creation.
    public var maxAgeSeconds: Double

    public init(maxPerPrincipal: Int = 8, maxTotal: Int = 32, retainSeconds: Double = 3600,
                maxAgeSeconds: Double = 7200) {
        self.maxPerPrincipal = maxPerPrincipal
        self.maxTotal = maxTotal
        self.retainSeconds = retainSeconds
        self.maxAgeSeconds = maxAgeSeconds
    }
}

// MARK: - Monitor

/// Public status of one expectation.
public struct BridgeDownloadStatus: Equatable, Sendable {
    public let downloadID: String
    public let state: BridgeDownloadState
    public let root: String
    /// The finished file's name (complete) or the name it will have.
    public let fileName: String?
    public let bytes: Int64
    public let partialFormat: BridgePartialFormat?
    /// The finished name differs from the caller's hint (browser renamed it,
    /// typically `name (1).ext` on a conflict).
    public let renamed: Bool
    /// The download replaced a file that existed before the expectation.
    public let replacedExisting: Bool
    /// A partial is still on disk, so the browser can usually resume it.
    public let resumable: Bool
    /// The download stalled at least once and then grew again.
    public let resumed: Bool
    public let reason: String?
    public let elapsed: Double
    /// The browser unpacked the archive into this folder and removed the
    /// archive (Safari's "Open safe files after downloading", observed live).
    public var extractedTo: String? = nil
    /// The inode of the finished file (or unpacked folder) when it was seen
    /// complete: every read checks the path still IS that file (audit A1).
    public var finalInode: UInt64? = nil

    public var path: String? {
        (extractedTo ?? fileName).map { (root as NSString).appendingPathComponent($0) }
    }

    public var dictionary: [String: Any] {
        var out: [String: Any] = [
            "download_id": downloadID, "state": state.rawValue, "terminal": state.terminal,
            "directory": root, "bytes": bytes, "renamed": renamed, "replaced_existing": replacedExisting,
            "resumable": resumable, "resumed": resumed, "elapsed_ms": Int(elapsed * 1000),
        ]
        if let fileName { out["file_name"] = fileName }
        if state == .complete, let path { out["path"] = path }
        if let partialFormat { out["partial_format"] = partialFormat.rawValue }
        if let reason { out["reason"] = reason }
        if let extractedTo {
            out["extracted_by_browser"] = true
            out["archive_name"] = fileName as Any
            out["extracted_to"] = extractedTo
        }
        return out
    }
}

public final class BridgeDownloadMonitor {
    private struct Expectation {
        let id: String
        let principal: BridgePrincipal
        let contextID: String?
        let bundleID: String
        /// The application's name at declaration: a grant may name it.
        let appName: String
        let root: String
        let opID: String?
        let nameHint: String?
        /// What the caller knows the file must be (e.g. the server's size):
        /// a browser can present a truncated transfer as finished (observed
        /// live with Firefox), which file metadata alone cannot see.
        let expectedBytes: Int64?
        let expectedSHA256: String?
        let createdAt: Double
        /// Folds up to and including the baseline: artifacts first seen in
        /// them predate the expectation and are never its download.
        let afterFold: Int
        var artifact: Int?
        var endedAt: Double?
    }

    private struct Artifact {
        let id: Int
        let root: String
        let firstSeenAt: Double
        let firstFold: Int
        var format: BridgePartialFormat?
        var partialName: String?
        var partialInode: UInt64?
        var finalName: String?
        var bytes: Int64 = 0
        var lastGrowthAt: Double
        var partialGoneAt: Double?
        var finalInode: UInt64?
        var finalSize: Int64?
        var finalModified: Double?
        var stableSince: Double?
        var replacedExisting = false
        var extractedTo: String?
        var extractedInode: UInt64?
        var stalled = false
        var resumed = false
        var state: BridgeDownloadState = .inProgress
        var reason: String?
    }

    public let timings: BridgeDownloadTimings
    public let limits: BridgeDownloadLimits
    private let makeID: () -> String
    private var expectations: [String: Expectation] = [:]
    private var order: [String] = []
    private var artifacts: [Int: Artifact] = [:]
    private var nextArtifact = 1
    private var folds = 0
    /// Per root: what the directory held when it was last scanned.
    private var known: [String: [String: BridgeDirectoryEntry]] = [:]

    public init(timings: BridgeDownloadTimings = BridgeDownloadTimings(),
                limits: BridgeDownloadLimits = BridgeDownloadLimits(),
                makeID: @escaping () -> String = { bridgeRandomID(prefix: "dl") }) {
        self.timings = timings
        self.limits = limits
        self.makeID = makeID
    }

    // MARK: expectations

    /// Declare that a download is about to be triggered into `root`.
    /// `entries` is the directory as it is NOW (the baseline). Idempotent per
    /// (principal, opID): a resent expect returns the same expectation.
    public func expect(
        principal: BridgePrincipal, contextID: String?, bundleID: String, root: String,
        entries: [BridgeDirectoryEntry], opID: String?, nameHint: String?, now: Double,
        expectedBytes: Int64? = nil, expectedSHA256: String? = nil, appName: String = ""
    ) -> Result<String, BridgePolicyRefusal> {
        reap(now: now)
        if let opID, let existing = order.first(where: {
            expectations[$0]?.principal == principal && expectations[$0]?.opID == opID
        }) {
            return .success(existing)
        }
        // Only OPEN expectations count against the limit: a finished one is a
        // record, evicted oldest-first (this principal's first) to make room.
        let mine = expectations.values.filter { $0.principal == principal && $0.endedAt == nil }.count
        while expectations.count >= limits.maxTotal {
            let ended = order.compactMap { expectations[$0] }.filter { $0.endedAt != nil }
            guard let victim = ended.first(where: { $0.principal == principal }) ?? ended.first else { break }
            forget(principal: victim.principal, id: victim.id)
        }
        guard mine < limits.maxPerPrincipal, expectations.count < limits.maxTotal else {
            return .failure(BridgePolicyRefusal(
                code: "DOWNLOAD_LIMIT",
                message: "Too many pending download expectations; wait for or forget one first.",
                detail: "reason=download_limit;active=\(mine);max=\(limits.maxPerPrincipal)"))
        }
        // Fold what is already there BEFORE the expectation exists: anything
        // seen now is older than it and can never be claimed by it.
        fold(root: root, entries: entries, now: now)
        var id = makeID()
        while expectations[id] != nil { id = makeID() }
        let hint = nameHint.flatMap { $0.isEmpty ? nil : $0 }
        expectations[id] = Expectation(
            id: id, principal: principal, contextID: contextID, bundleID: bundleID, appName: appName, root: root,
            opID: opID, nameHint: hint, expectedBytes: expectedBytes,
            expectedSHA256: expectedSHA256?.lowercased(), createdAt: now, afterFold: folds)
        order.append(id)
        return .success(id)
    }

    /// Fold a new scan of `root` and return the status of `id` for its owner.
    public func status(
        principal: BridgePrincipal, id: String, entries: [BridgeDirectoryEntry]?, now: Double
    ) -> Result<BridgeDownloadStatus, BridgePolicyRefusal> {
        reap(now: now)
        guard let expectation = expectations[id], expectation.principal == principal else {
            return .failure(BridgePolicyRefusal(
                code: "DOWNLOAD_UNKNOWN",
                message: "No such download expectation for this client.",
                detail: "reason=download_unknown"))
        }
        if let entries { fold(root: expectation.root, entries: entries, now: now) }
        return .success(describe(id: id, now: now))
    }

    public func root(of id: String, principal: BridgePrincipal) -> String? {
        guard let expectation = expectations[id], expectation.principal == principal else { return nil }
        return expectation.root
    }

    public func contextID(of id: String) -> String? { expectations[id]?.contextID }

    /// The checksum the caller declared, if any (the helper compares it once
    /// the file is complete; that is an explicit request to read it).
    public func expectedSHA256(of id: String, principal: BridgePrincipal) -> String? {
        guard let expectation = expectations[id], expectation.principal == principal else { return nil }
        return expectation.expectedSHA256
    }

    public func list(principal: BridgePrincipal, now: Double) -> [BridgeDownloadStatus] {
        reap(now: now)
        return order.filter { expectations[$0]?.principal == principal }.map { describe(id: $0, now: now) }
    }

    /// What `download.list` answers: every expectation of `principal` with the
    /// SAME integrity rule as `download.status` (`bridgeDownloadReport`). A
    /// declared checksum is read through `digestOf`; nothing else is read.
    public func listReports(principal: BridgePrincipal, now: Double, probe: (String) -> BridgeFileProbe?,
                            digestOf: (String, BridgeFileProbe) -> String?) -> [[String: Any]] {
        reap(now: now)
        return order.filter { expectations[$0]?.principal == principal }.map { id in
            bridgeDownloadReport(describe(id: id, now: now), expectedSHA256: expectations[id]?.expectedSHA256,
                                 requested: false, probe: probe, digestOf: digestOf)
        }
    }

    /// Forget an expectation. Idempotent; the file (if any) is untouched.
    @discardableResult
    public func forget(principal: BridgePrincipal, id: String) -> Bool {
        guard let expectation = expectations[id], expectation.principal == principal else { return false }
        expectations.removeValue(forKey: id)
        order.removeAll { $0 == id }
        if let artifact = expectation.artifact { artifacts.removeValue(forKey: artifact) }
        return true
    }

    /// Forget every expectation one context of `principal` declared (the
    /// context was closed). Returns how many were forgotten.
    @discardableResult
    public func forget(principal: BridgePrincipal, contextID: String) -> Int {
        let mine = order.filter { expectations[$0]?.principal == principal && expectations[$0]?.contextID == contextID }
        for id in mine { forget(principal: principal, id: id) }
        return mine.count
    }

    /// What an expectation watches — the application and the directory the
    /// policy must still grant at every read. Its owner only.
    public func subject(of id: String, principal: BridgePrincipal)
        -> (bundleID: String, appName: String, root: String)?
    {
        guard let expectation = expectations[id], expectation.principal == principal else { return nil }
        return (expectation.bundleID, expectation.appName, expectation.root)
    }

    /// The ids of `principal`'s expectations, oldest first.
    public func ids(principal: BridgePrincipal) -> [String] {
        order.filter { expectations[$0]?.principal == principal }
    }

    /// Roots that have open (non-terminal) expectations: the ones to scan.
    public func activeRoots() -> Set<String> {
        Set(expectations.values.filter { $0.endedAt == nil }.map { $0.root })
    }

    public var count: Int { expectations.count }

    private func reap(now: Double) {
        for id in order {
            guard let expectation = expectations[id] else { continue }
            let expired = (expectation.endedAt.map { now - $0 > limits.retainSeconds } ?? false)
                || now - expectation.createdAt > limits.maxAgeSeconds
            if expired { forget(principal: expectation.principal, id: id) }
        }
    }

    // MARK: folding

    private func fold(root: String, entries: [BridgeDirectoryEntry], now: Double) {
        folds += 1
        let earlier = known[root]
        let current = Dictionary(
            entries.filter { !bridgeIgnoredDownloadEntry($0.name) }.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first })
        known[root] = current
        // The first scan of a root is its baseline: no finished file in it is
        // new, and its partials are tracked (so a download already running is
        // followed) but belong to no expectation that exists yet.
        let previous = earlier ?? current

        let partials = current.values.compactMap { entry -> (BridgeDirectoryEntry, BridgePartialName)? in
            bridgePartialDownload(name: entry.name, isDirectory: entry.isDirectory).map { (entry, $0) }
        }
        var seenPartials: Set<Int> = []
        // 1. Partials: follow by inode, then by name; otherwise a new artifact.
        for (entry, partial) in partials {
            let id = artifactID(root: root, where: { $0.partialInode == entry.inode && $0.format == partial.format })
                ?? artifactID(root: root, where: { $0.partialName == entry.name && $0.partialGoneAt == nil })
                ?? newArtifact(root: root, now: now, replacing: false)
            guard var artifact = artifacts[id] else { continue }
            seenPartials.insert(id)
            artifact.format = partial.format
            artifact.partialName = entry.name
            artifact.partialInode = entry.inode
            artifact.finalName = partial.finalName ?? artifact.finalName
            artifact.partialGoneAt = nil
            if entry.size > artifact.bytes {
                if artifact.stalled { artifact.resumed = true }
                artifact.stalled = false
                artifact.lastGrowthAt = now
                artifact.bytes = entry.size
            }
            if now - artifact.lastGrowthAt >= timings.stallSeconds {
                artifact.stalled = true
                artifact.state = .interrupted
                artifact.reason = "no_growth"
            } else {
                artifact.state = .inProgress
                artifact.reason = nil
            }
            artifacts[id] = artifact
        }
        // 2. Partials that vanished.
        for (id, var artifact) in artifacts where artifact.root == root && artifact.partialName != nil
            && !seenPartials.contains(id) && artifact.finalInode == nil {
            if artifact.partialGoneAt == nil { artifact.partialGoneAt = now }
            artifacts[id] = artifact
        }
        // 3. Final (non-partial) files that are new or changed since the last scan.
        let livePartialFinals = Set(partials.compactMap { $0.1.finalName })
        // Names that were a Gecko-style placeholder in the previous scan: the
        // finished file replacing one is the same download, not an overwrite.
        let placeholders = Set(previous.values.compactMap {
            bridgePartialDownload(name: $0.name, isDirectory: $0.isDirectory)?.finalName
        })
        for entry in current.values where bridgePartialDownload(name: entry.name, isDirectory: entry.isDirectory) == nil {
            // A Gecko placeholder (or any file a live partial will become) is
            // not a result yet.
            if livePartialFinals.contains(entry.name) { continue }
            let old = previous[entry.name]
            let changed = old == nil || old!.inode != entry.inode || old!.size != entry.size
                || old!.modified != entry.modified
            if let id = artifactID(root: root, where: { $0.finalName == entry.name && $0.finalInode != nil }) {
                // An artifact already finished into this name: keep its clock honest.
                updateFinal(id: id, entry: entry, now: now)
                continue
            }
            if entry.isDirectory {
                if let id = artifactID(root: root, where: { $0.extractedTo == entry.name }) {
                    updateExtracted(id: id, entry: entry, now: now)
                } else if changed, let id = extractionSource(root: root, folder: entry.name) {
                    artifacts[id]?.extractedTo = entry.name
                    artifacts[id]?.finalInode = entry.inode
                    updateExtracted(id: id, entry: entry, now: now)
                }
                continue
            }
            // An EMPTY new file is not a download yet: Firefox creates its
            // 0-byte placeholder before (sometimes a scan before) the part
            // file that will replace it — observed live. It becomes an
            // artifact only once it has content.
            guard changed, !entry.isDirectory, entry.size > 0 else { continue }
            // Link to a vanished partial: same inode (renamed in place), else
            // the partial's announced final name, else the only vanished one.
            let vanished = artifacts.values.filter { $0.root == root && $0.partialGoneAt != nil && $0.finalInode == nil }
            let link = vanished.first { $0.partialInode == entry.inode }
                ?? vanished.first { $0.finalName == entry.name }
                ?? (vanished.count == 1 && vanished[0].finalName == nil ? vanished.first : nil)
            let overwrite = old != nil && !(placeholders.contains(entry.name) && old!.size == 0)
            let id = link?.id ?? newArtifact(root: root, now: now, replacing: overwrite)
            guard var artifact = artifacts[id] else { continue }
            if overwrite { artifact.replacedExisting = true }
            artifact.finalName = entry.name
            artifact.finalInode = entry.inode
            artifacts[id] = artifact
            updateFinal(id: id, entry: entry, now: now)
        }
        // 4. Vanished partials past the grace period with no final file.
        for (id, var artifact) in artifacts where artifact.root == root && artifact.finalInode == nil {
            if let gone = artifact.partialGoneAt, now - gone >= timings.renameGraceSeconds {
                artifact.state = .failed
                artifact.reason = "partial_removed"
                artifacts[id] = artifact
            }
        }
        claim(root: root)
        for id in order { markEnded(id, now: now) }
    }

    /// A vanished partial of an ARCHIVE whose stem is `folder` (or `stem N`):
    /// the browser unpacked it there and deleted the archive.
    private func extractionSource(root: String, folder: String) -> Int? {
        let archives: Set<String> = ["zip"]
        return artifacts.values.filter { artifact in
            guard artifact.root == root, artifact.partialGoneAt != nil, artifact.finalInode == nil,
                  let name = artifact.finalName, archives.contains((name as NSString).pathExtension.lowercased())
            else { return false }
            let stem = (name as NSString).deletingPathExtension
            return folder == stem || folder.range(of: "^" + NSRegularExpression.escapedPattern(for: stem) + #" \d+$"#,
                                                  options: .regularExpression) != nil
        }.map { $0.id }.min()
    }

    /// An extracted folder is complete once its modification time held still
    /// for the settle interval.
    private func updateExtracted(id: Int, entry: BridgeDirectoryEntry, now: Double) {
        guard var artifact = artifacts[id] else { return }
        if artifact.finalModified != entry.modified || artifact.extractedInode != entry.inode {
            artifact.finalModified = entry.modified
            artifact.extractedInode = entry.inode
            artifact.stableSince = now
        }
        artifact.partialName = nil
        if let since = artifact.stableSince, now - since >= timings.settleSeconds {
            artifact.state = .complete
            artifact.reason = nil
        } else {
            artifact.state = .inProgress
            artifact.reason = "settling"
        }
        artifacts[id] = artifact
    }

    private func updateFinal(id: Int, entry: BridgeDirectoryEntry, now: Double) {
        guard var artifact = artifacts[id] else { return }
        if artifact.finalSize != entry.size || artifact.finalModified != entry.modified
            || artifact.finalInode != entry.inode {
            artifact.finalSize = entry.size
            artifact.finalModified = entry.modified
            artifact.finalInode = entry.inode
            artifact.stableSince = now
        }
        artifact.bytes = entry.size
        artifact.partialName = nil
        if entry.size <= 0 {
            artifact.state = .inProgress
            artifact.reason = "empty_file"
        } else if let since = artifact.stableSince, now - since >= timings.settleSeconds {
            artifact.state = .complete
            artifact.reason = nil
        } else {
            artifact.state = .inProgress
            artifact.reason = "settling"
        }
        artifacts[id] = artifact
    }

    private func artifactID(root: String, where predicate: (Artifact) -> Bool) -> Int? {
        artifacts.values.filter { $0.root == root && predicate($0) }.map { $0.id }.min()
    }

    private func newArtifact(root: String, now: Double, replacing: Bool) -> Int {
        let id = nextArtifact
        nextArtifact += 1
        artifacts[id] = Artifact(id: id, root: root, firstSeenAt: now, firstFold: folds, lastGrowthAt: now,
                                 replacedExisting: replacing)
        return id
    }

    /// Give each unclaimed artifact to one open expectation of the same root
    /// whose baseline predates the artifact: a hint match first, else
    /// the oldest. An expectation claims one artifact.
    private func claim(root: String) {
        let claimed = Set(expectations.values.compactMap { $0.artifact })
        let free = artifacts.values.filter { $0.root == root && !claimed.contains($0.id) }
            .sorted { ($0.firstSeenAt, $0.id) < ($1.firstSeenAt, $1.id) }
        for artifact in free {
            let open = order.compactMap { expectations[$0] }
                .filter { $0.root == root && $0.artifact == nil && $0.afterFold < artifact.firstFold }
            let hinted = open.first { hint in
                guard let name = hint.nameHint else { return false }
                return artifact.finalName.map { bridgeNameMatchesHint($0, hint: name) } ?? false
            }
            // Without a final name yet, an artifact waits for one only when
            // several expectations are open and all of them are hinted.
            let unhinted = open.first { $0.nameHint == nil }
            // A NAMED artifact that matches no hint is never handed to a
            // hinted expectation while another one is open: that is how two
            // simultaneous downloads were swapped in the live lane. With one
            // open expectation it is that expectation's (a renamed download).
            let pick = hinted ?? unhinted ?? (open.count == 1 ? open.first : nil)
            guard let pick else { continue }
            expectations[pick.id]?.artifact = artifact.id
        }
    }

    private func markEnded(_ id: String, now: Double) {
        guard var expectation = expectations[id], expectation.endedAt == nil,
              let artifact = expectation.artifact.flatMap({ artifacts[$0] }), artifact.state.terminal else { return }
        expectation.endedAt = now
        expectations[id] = expectation
    }

    private func describe(id: String, now: Double) -> BridgeDownloadStatus {
        let expectation = expectations[id]!
        guard let artifact = expectation.artifact.flatMap({ artifacts[$0] }) else {
            return BridgeDownloadStatus(
                downloadID: id, state: .notStarted, root: expectation.root, fileName: nil, bytes: 0,
                partialFormat: nil, renamed: false, replacedExisting: false, resumable: false, resumed: false,
                reason: nil, elapsed: now - expectation.createdAt)
        }
        let renamed = expectation.nameHint.map { hint in
            artifact.finalName.map { $0 != hint } ?? false
        } ?? false
        var state = artifact.state
        var reason = artifact.reason
        if state == .complete, let expected = expectation.expectedBytes {
            if artifact.extractedTo != nil {
                // The archive is gone and a folder has no comparable size:
                // the declared size cannot be verified, so it is not.
                state = .failed
                reason = "size_unavailable;archive_unpacked_by_browser"
            } else if artifact.bytes != expected {
                state = .failed
                reason = "size_mismatch;expected=\(expected);got=\(artifact.bytes)"
            }
        }
        return BridgeDownloadStatus(
            downloadID: id, state: state, root: expectation.root, fileName: artifact.finalName,
            bytes: artifact.bytes, partialFormat: artifact.format, renamed: renamed,
            replacedExisting: artifact.replacedExisting,
            resumable: artifact.state == .interrupted && artifact.partialName != nil,
            resumed: artifact.resumed, reason: reason, elapsed: now - expectation.createdAt,
            extractedTo: artifact.extractedTo,
            finalInode: artifact.extractedTo != nil ? artifact.extractedInode : artifact.finalInode)
    }
}

/// A finished name matches a hint when it is the hint, or the hint with a
/// browser's conflict suffix: `name (1).ext`, `name-2.ext`, `name(1).ext`.
public func bridgeNameMatchesHint(_ name: String, hint: String) -> Bool {
    if name == hint { return true }
    let hintExt = (hint as NSString).pathExtension
    let nameExt = (name as NSString).pathExtension
    guard hintExt == nameExt else { return false }
    let hintStem = (hint as NSString).deletingPathExtension
    let nameStem = (name as NSString).deletingPathExtension
    guard nameStem.hasPrefix(hintStem) else { return false }
    let rest = nameStem.dropFirst(hintStem.count)
    let patterns = [#"^ \(\d+\)$"#, #"^\(\d+\)$"#, #"^-\d+$"#]
    return patterns.contains { String(rest).range(of: $0, options: .regularExpression) != nil }
}

// MARK: - Roots

/// Normalize a download root from the policy: absolute or `~/…`, no `..`
/// component, never `/` itself. Returns nil for anything else (fail closed).
public func bridgeNormalizedDownloadRoot(_ raw: String, home: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 1024 else { return nil }
    var path: String
    if trimmed == "~" { path = home }
    else if trimmed.hasPrefix("~/") { path = (home as NSString).appendingPathComponent(String(trimmed.dropFirst(2))) }
    else if trimmed.hasPrefix("/") { path = trimmed }
    else { return nil }
    let components = (path as NSString).pathComponents
    guard !components.contains(".."), !components.contains(".") || components.first == "/" else { return nil }
    path = (path as NSString).standardizingPath
    guard path != "/", path.hasPrefix("/") else { return nil }
    return path
}

/// Is `requested` one of `roots` (exact, after normalization)? Subdirectories
/// are not implied: the policy names every directory a download may land in.
public func bridgeDownloadRootAllowed(_ requested: String, roots: [String]) -> Bool {
    roots.contains(requested)
}

/// Is an existing expectation still covered by the policy NOW? Decided at
/// every read, not only at `download.expect`: a revoked application, a lost
/// `observe` scope or a root removed from the grant stops it answering
/// (nil = still covered).
public func bridgeDownloadAuthorizationRefusal(
    policy: BridgeAuthorizationPolicy, client: BridgeClientGrant?, bundleID: String, appName: String = "",
    root: String
) -> BridgePolicyRefusal? {
    if let refusal = policy.decision(bundleID: bundleID, name: appName, windowTitle: nil, scope: .observe,
                                     client: client).refusal {
        return refusal
    }
    guard let grant = policy.grant(bundleID: bundleID, name: appName),
          bridgeDownloadRootAllowed(root, roots: grant.downloadRoots) else {
        return BridgePolicyRefusal(
            code: "DOWNLOAD_ROOT_NOT_ALLOWED",
            message: "The policy no longer allows this download directory for this application.",
            detail: "reason=root_revoked")
    }
    return nil
}

// MARK: - Integrity

/// What `lstat` says about a path: its own type (a symbolic link is `.other`,
/// never what it points to), inode, size and modification time.
public struct BridgeFileProbe: Equatable, Sendable {
    public enum Kind: Sendable { case regular, directory, other }
    public let kind: Kind
    public let inode: UInt64
    public let size: Int64
    public let modified: Double

    public init(kind: Kind, inode: UInt64, size: Int64, modified: Double) {
        self.kind = kind
        self.inode = inode
        self.size = size
        self.modified = modified
    }
}

/// `lstat` of `path`, or nil when nothing is there. Never follows a link.
public func bridgeProbeFile(_ path: String) -> BridgeFileProbe? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return nil }
    let type = info.st_mode & S_IFMT
    let kind: BridgeFileProbe.Kind = type == S_IFREG ? .regular : type == S_IFDIR ? .directory : .other
    return BridgeFileProbe(kind: kind, inode: UInt64(info.st_ino), size: Int64(info.st_size),
                           modified: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
}

/// The largest file the helper hashes: the read runs inside one request, so
/// it is bounded instead of open-ended (audit A2).
public let bridgeChecksumMaxBytes: Int64 = 2 << 30

/// SHA-256 of the REGULAR file at `path`, or nil — never the digest of a
/// prefix and never of anything else:
/// * opened with `O_NOFOLLOW | O_NONBLOCK`: a symbolic link is refused, not
///   followed, and a FIFO or device cannot make the open wait;
/// * `fstat` of the opened descriptor must be a regular file (no device, FIFO,
///   socket or folder), with `expectedInode` when given (the file that was
///   checked is the file that is read) and at most `maxBytes`;
/// * exactly the size `fstat` reported is read; a read error, a short file or
///   a file still growing gives nil.
public func bridgeSHA256(ofFileAt path: String, expectedInode: UInt64? = nil,
                         maxBytes: Int64 = bridgeChecksumMaxBytes) -> String? {
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
          expectedInode.map({ UInt64(info.st_ino) == $0 }) ?? true,
          info.st_size >= 0, Int64(info.st_size) <= maxBytes else { return nil }
    let size = Int64(info.st_size)
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 1 << 20)
    var total: Int64 = 0
    while total < size {
        let wanted = Int(min(Int64(buffer.count), size - total))
        let got = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, wanted) }
        if got < 0 && errno == EINTR { continue }
        guard got > 0 else { return nil }
        hasher.update(data: buffer[0..<got])
        total += Int64(got)
    }
    var extra: UInt8 = 0
    guard read(fd, &extra, 1) == 0 else { return nil }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// The answer for one expectation — the one rule every read path
/// (`download.status`, `download.wait`, `download.list`) applies:
/// 1. a COMPLETE download is re-checked against the file system (`probe`, an
///    `lstat`): its path must still be the same regular file (inode and size)
///    or, for an archive the browser unpacked, the same folder. Otherwise it is
///    `failed` with `file_missing` / `file_changed`, without a path, and
///    nothing is read (audit A1);
/// 2. the file's bytes are read (`digestOf`) only for a declared checksum or
///    an explicit `checksum` request.
public func bridgeDownloadReport(
    _ status: BridgeDownloadStatus, expectedSHA256: String?, requested: Bool,
    probe: (String) -> BridgeFileProbe?, digestOf: (String, BridgeFileProbe) -> String?
) -> [String: Any] {
    var result = status.dictionary
    guard status.state == .complete, let path = status.path else { return result }
    let unpacked = status.extractedTo != nil
    guard let found = probe(path) else {
        withdraw(&result, reason: "file_missing")
        return result
    }
    let sameKind = unpacked ? found.kind == .directory : found.kind == .regular
    guard sameKind, found.inode == status.finalInode, unpacked || found.size == status.bytes else {
        withdraw(&result, reason: "file_changed")
        return result
    }
    if requested || expectedSHA256 != nil {
        let digest = unpacked ? nil : digestOf(path, found)
        bridgeApplyIntegrity(&result, expectedSHA256: expectedSHA256, digest: digest, requested: requested)
    }
    return result
}

/// A download that is no longer what was verified: failed, without its path.
private func withdraw(_ result: inout [String: Any], reason: String) {
    result["state"] = BridgeDownloadState.failed.rawValue
    result["terminal"] = true
    result["reason"] = reason
    result.removeValue(forKey: "path")
}

/// Fold a checksum into a COMPLETE status. `digest` is nil when the file could
/// not be hashed. A declared `expectedSHA256` is an explicit integrity
/// requirement: a mismatch AND an unavailable digest are both `failed`, and the
/// path is withheld — an unverified file is never handed out as the result.
/// A plain `checksum` request without a digest says so and invents nothing.
public func bridgeApplyIntegrity(
    _ result: inout [String: Any], expectedSHA256: String?, digest: String?, requested: Bool
) {
    if let digest { result["sha256"] = digest }
    guard let expected = expectedSHA256 else {
        if requested && digest == nil { result["checksum"] = "unavailable" }
        return
    }
    guard let digest, digest == expected.lowercased() else {
        result["state"] = BridgeDownloadState.failed.rawValue
        result["terminal"] = true
        result["reason"] = digest == nil ? "checksum_unavailable" : "checksum_mismatch"
        result.removeValue(forKey: "path")
        return
    }
    result["integrity"] = "sha256_verified"
}
