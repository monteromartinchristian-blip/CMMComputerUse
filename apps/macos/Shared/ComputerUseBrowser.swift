// ComputerUseBrowser.swift — browser windows, tabs and page lifecycle (F-09).
//
// 0.3.3 knew one fact about a browser: the digest of the document a window
// showed. Everything else was inferred by the caller from a refused action —
// a tab switch, a navigation, a closed window and a dead helper all arrived as
// "observe again", and clients read that as a lost connection.
//
// This file names those situations instead:
//
//   * WINDOWS and TABS get stable opaque ids that survive reordering and title
//     changes (matched by accessibility element identity first, never by
//     position alone);
//   * a PAGE STATE is what one window shows at one instant (selected tab,
//     document digest, web-area identity, loading evidence);
//   * a TRANSITION between two page states is classified: tab switched,
//     navigated, reloaded, tab closed, window closed, application closed or
//     relaunched — so only the handles of the document that changed are
//     retired and the context survives;
//   * a SAVE PANEL is recognized from generic accessibility facts (the
//     sheet's default/cancel buttons, its text field), so a download that asks
//     for a destination can be completed without a product integration.
//
// Pure: the helper feeds it what the accessibility API reports and the tests
// feed it literals. Nothing here talks to a browser, reads a profile, a cookie
// or a page's content. URLs are reported REDACTED (no query, no fragment, no
// credentials) and identities are digests.

import Foundation

// MARK: - Browser families

/// The engine family a bundle belongs to. It only selects which partial
/// download names to expect and how the tab strip is usually exposed; it is
/// never an authorization and never required (an unknown browser still works
/// through the generic accessibility path).
public enum BridgeBrowserFamily: String, Sendable, CaseIterable {
    case webkit
    case chromium
    case gecko
    case unknown
}

public func bridgeBrowserFamily(bundleID: String) -> BridgeBrowserFamily {
    let id = bundleID.lowercased()
    if id == "com.apple.safari" || id.hasPrefix("com.apple.safaritechnologypreview") { return .webkit }
    if id.hasPrefix("com.google.chrome") || id == "org.chromium.chromium" || id == "com.microsoft.edgemac"
        || id.hasPrefix("com.microsoft.edgemac.") || id == "com.brave.browser" || id == "com.vivaldi.vivaldi"
        || id.hasPrefix("company.thebrowser.") {
        return .chromium
    }
    if id.hasPrefix("org.mozilla.firefox") || id == "org.mozilla.nightly" { return .gecko }
    return .unknown
}

/// Whether a bundle is a browser this bridge has a profile for.
public func bridgeIsKnownBrowser(bundleID: String) -> Bool {
    bridgeBrowserFamily(bundleID: bundleID) != .unknown
}

// MARK: - URL redaction

/// A URL as it may leave the helper: scheme, host, port and path only.
///
/// Query strings and fragments routinely carry session tokens, e-mail
/// addresses and search terms; user-info carries credentials. None of them is
/// needed to know WHICH page a tab shows, so none of them is ever reported.
/// Opaque schemes (`blob:`, `data:`, `javascript:`) report the scheme alone.
/// `file:` reports only the last path component. Bounded to 300 characters.
public func bridgeRedactedURL(_ raw: String?) -> String? {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
    guard let components = URLComponents(string: raw), let scheme = components.scheme?.lowercased() else {
        return nil
    }
    switch scheme {
    case "http", "https":
        guard let host = components.host, !host.isEmpty else { return scheme + ":" }
        var out = scheme + "://" + host.lowercased()
        if let port = components.port { out += ":\(port)" }
        let path = components.percentEncodedPath
        out += path.isEmpty ? "/" : path
        return String(out.prefix(300))
    case "file":
        let last = (components.path as NSString).lastPathComponent
        return String(("file://…/" + last).prefix(300))
    case "about", "chrome", "edge", "brave", "vivaldi", "safari-resource", "favorites", "topsites":
        // Browser-internal pages: the page name is public, nothing else.
        let page = components.path.isEmpty ? (components.host ?? "") : components.path
        return String((scheme + ":" + page).prefix(300))
    default:
        return scheme + ":"
    }
}

// MARK: - Windows and tabs

/// One tab as the accessibility API reports it at one instant.
public struct BridgeTabSample: Equatable, Sendable {
    /// Identity of the live accessibility element (CFHash of an element that
    /// was CFEqual-checked by the caller), or nil when the element is unknown.
    /// Two samples with the same key ARE the same tab.
    public let elementKey: Int?
    public let title: String
    public let selected: Bool

    public init(elementKey: Int?, title: String, selected: Bool) {
        self.elementKey = elementKey
        self.title = title
        self.selected = selected
    }
}

/// How a tab id was carried from the previous sample to this one.
public enum BridgeTabMatch: String, Sendable {
    /// Same accessibility element: the tab is the same, whatever its title.
    case element
    /// Same unique title, no element evidence: probably the same tab.
    case title
    /// Seen for the first time.
    case new
}

public struct BridgeTrackedTab: Equatable, Sendable {
    public let id: String
    public let index: Int
    public let title: String
    public let selected: Bool
    public let match: BridgeTabMatch

    public var dictionary: [String: Any] {
        ["tab_id": id, "index": index, "title": String(title.prefix(200)), "selected": selected,
         "identity": match.rawValue]
    }
}

/// What changed in one window's tab strip between two samples.
public struct BridgeTabDelta: Equatable, Sendable {
    public let tabs: [BridgeTrackedTab]
    public let opened: [String]
    public let closed: [String]
    /// (previous, current) selected tab ids when the selection moved.
    public let selectionChanged: Bool
    public let previousSelected: String?
    public let selected: String?
    /// Same set of tabs in another order.
    public let reordered: Bool
    /// False when the window exposes no tab strip (one implicit tab).
    public let exposed: Bool
}

/// Stable tab ids per window. A tab keeps its id while its accessibility
/// element lives — a title change or a move in the strip does not create a new
/// tab, and a closed tab's id is never reused.
///
/// Not thread-safe; the helper uses it under `dispatchLock`.
public final class BridgeTabTracker {
    private struct Known {
        var id: String
        var elementKey: Int?
        var title: String
    }

    private var windows: [String: [Known]] = [:]
    private let makeID: () -> String

    public init(makeID: @escaping () -> String = { bridgeRandomID(prefix: "tab") }) {
        self.makeID = makeID
    }

    /// Fold one sample of a window's tab strip. `windowKey` is the caller's
    /// stable window identity (see ``BridgeWindowTracker``).
    public func update(windowKey: String, samples: [BridgeTabSample]) -> BridgeTabDelta {
        let previous = windows[windowKey] ?? []
        let previousSelected = lastSelected[windowKey]
        var unmatched = previous
        var assigned: [(Known, BridgeTabMatch)?] = Array(repeating: nil, count: samples.count)

        // 1. Element identity: conclusive.
        for (index, sample) in samples.enumerated() {
            guard let key = sample.elementKey,
                  let found = unmatched.firstIndex(where: { $0.elementKey == key }) else { continue }
            var known = unmatched.remove(at: found)
            known.title = sample.title
            assigned[index] = (known, .element)
        }
        // 2. A unique title among what is left on BOTH sides, only for samples
        //    without element evidence or whose element is new: never steals a
        //    tab that an element already claimed.
        for (index, sample) in samples.enumerated() where assigned[index] == nil {
            let sameTitleSamples = samples.indices.filter { assigned[$0] == nil && samples[$0].title == sample.title }
            let candidates = unmatched.indices.filter { unmatched[$0].title == sample.title }
            guard !sample.title.isEmpty, sameTitleSamples.count == 1, candidates.count == 1 else { continue }
            var known = unmatched.remove(at: candidates[0])
            known.elementKey = sample.elementKey ?? known.elementKey
            assigned[index] = (known, .title)
        }
        // 3. Everything else is a new tab.
        var tabs: [BridgeTrackedTab] = []
        var opened: [String] = []
        var current: [Known] = []
        for (index, sample) in samples.enumerated() {
            let (known, match) = assigned[index]
                ?? (Known(id: makeID(), elementKey: sample.elementKey, title: sample.title), .new)
            // The first sample of a window establishes it; only later ones open tabs.
            if match == .new && windows[windowKey] != nil { opened.append(known.id) }
            current.append(known)
            tabs.append(BridgeTrackedTab(id: known.id, index: index, title: sample.title,
                                         selected: sample.selected, match: match))
        }
        let closed = unmatched.map { $0.id }
        let selected = tabs.first(where: { $0.selected })?.id
        let previousOrder = previous.map { $0.id }.filter { id in current.contains { $0.id == id } }
        let currentOrder = current.map { $0.id }.filter { id in previous.contains { $0.id == id } }
        windows[windowKey] = current
        lastSelected[windowKey] = selected
        return BridgeTabDelta(
            tabs: tabs, opened: opened, closed: closed,
            selectionChanged: previousSelected != nil && selected != nil && previousSelected != selected,
            previousSelected: previousSelected, selected: selected,
            reordered: previousOrder != currentOrder, exposed: !samples.isEmpty)
    }

    private var lastSelected: [String: String] = [:]

    /// The tab id currently tracked under `elementKey` in a window.
    public func tabID(windowKey: String, elementKey: Int) -> String? {
        windows[windowKey]?.first { $0.elementKey == elementKey }?.id
    }

    /// The element key a tab id was last seen with.
    public func elementKey(windowKey: String, tabID: String) -> Int? {
        windows[windowKey]?.first { $0.id == tabID }?.elementKey
    }

    /// Which window holds a tab id.
    public func window(ofTab tabID: String) -> String? {
        windows.first { $0.value.contains { $0.id == tabID } }?.key
    }

    /// A window is gone: its tabs are forgotten (their ids are never reused).
    @discardableResult
    public func forget(windowKey: String) -> [String] {
        lastSelected.removeValue(forKey: windowKey)
        return (windows.removeValue(forKey: windowKey) ?? []).map { $0.id }
    }

    public var windowKeys: [String] { Array(windows.keys) }
}

/// One browser window as reported at one instant.
public struct BridgeWindowSample: Equatable, Sendable {
    /// CGWindowID when it could be matched unambiguously, else nil.
    public let windowID: Int?
    /// Identity of the live accessibility window element (see BridgeTabSample).
    public let elementKey: Int?
    public let title: String

    public init(windowID: Int?, elementKey: Int?, title: String) {
        self.windowID = windowID
        self.elementKey = elementKey
        self.title = title
    }
}

public struct BridgeTrackedWindow: Equatable, Sendable {
    public let key: String
    public let windowID: Int?
    public let title: String
    public let match: BridgeTabMatch
}

public struct BridgeWindowDelta: Equatable, Sendable {
    public let windows: [BridgeTrackedWindow]
    public let opened: [String]
    public let closed: [String]
}

/// Stable window keys for one application process: a CGWindowID or a live
/// element identity carries the key; a title never does on its own (two
/// windows routinely share a title, and a tab switch renames a window).
public final class BridgeWindowTracker {
    private struct Known {
        var key: String
        var windowID: Int?
        var elementKey: Int?
    }

    private var known: [Known] = []
    private var sampled = false
    private let makeID: () -> String

    public init(makeID: @escaping () -> String = { bridgeRandomID(prefix: "win") }) {
        self.makeID = makeID
    }

    public func update(samples: [BridgeWindowSample]) -> BridgeWindowDelta {
        var unmatched = known
        var result: [BridgeTrackedWindow] = []
        var current: [Known] = []
        var opened: [String] = []
        for sample in samples {
            var match: BridgeTabMatch = .new
            var found: Known?
            if let key = sample.elementKey, let index = unmatched.firstIndex(where: { $0.elementKey == key }) {
                found = unmatched.remove(at: index)
                match = .element
            } else if let id = sample.windowID, let index = unmatched.firstIndex(where: { $0.windowID == id }) {
                found = unmatched.remove(at: index)
                match = .element
            }
            var entry = found ?? Known(key: makeID(), windowID: sample.windowID, elementKey: sample.elementKey)
            entry.windowID = sample.windowID ?? entry.windowID
            entry.elementKey = sample.elementKey ?? entry.elementKey
            if found == nil && sampled { opened.append(entry.key) }
            current.append(entry)
            result.append(BridgeTrackedWindow(key: entry.key, windowID: entry.windowID, title: sample.title, match: match))
        }
        known = current
        sampled = true
        return BridgeWindowDelta(windows: result, opened: opened, closed: unmatched.map { $0.key })
    }

    public func windowID(forKey key: String) -> Int? { known.first { $0.key == key }?.windowID }
    public func key(forWindowID id: Int) -> String? { known.first { $0.windowID == id }?.key }
}

// MARK: - Page state and transitions

/// Loading evidence a web area exposes, folded into one of three words.
///
/// WebKit exposes `AXLoaded`/`AXLoadingProgress`; WebKit and Chromium expose
/// `AXElementBusy` while a document is loading. None of these is guaranteed,
/// so "unknown" is a real answer and never reported as "loaded".
public enum BridgeLoadState: String, Sendable {
    case loading
    case loaded
    case unknown
}

public func bridgeLoadState(busy: Bool?, loaded: Bool?, progress: Double?) -> BridgeLoadState {
    if busy == true { return .loading }
    if let progress, progress < 1 { return .loading }
    if loaded == false { return .loading }
    if loaded == true || busy == false || progress.map({ $0 >= 1 }) == true { return .loaded }
    return .unknown
}

/// What one browser window shows at one instant.
public struct BridgePageState: Equatable, Sendable {
    /// The application process is running.
    public let appRunning: Bool
    public let pid: Int32
    /// Stable window key (``BridgeWindowTracker``); nil when the window is gone.
    public let windowKey: String?
    public let selectedTab: String?
    /// Digest of the document URL/`AXDocument` (never the value), "" if none.
    public let documentDigest: String
    /// Identity of the live web-area element (CFHash), nil when not found.
    public let webAreaKey: Int?
    public let load: BridgeLoadState
    public let title: String

    public init(appRunning: Bool, pid: Int32, windowKey: String?, selectedTab: String?,
                documentDigest: String, webAreaKey: Int?, load: BridgeLoadState, title: String) {
        self.appRunning = appRunning
        self.pid = pid
        self.windowKey = windowKey
        self.selectedTab = selectedTab
        self.documentDigest = documentDigest
        self.webAreaKey = webAreaKey
        self.load = load
        self.title = title
    }
}

/// What happened between two page states, most significant first.
///
/// The order matters: a closed application also closed its windows and tabs;
/// a switched tab also shows another document. Each case says how much of the
/// caller's state survives — this is what stops a tab switch from being
/// reported (and handled) as a disconnection.
public enum BridgeBrowserTransition: String, Sendable {
    /// The process is gone. The context's application must be opened again.
    case appClosed = "app_closed"
    /// Same bundle, another process: every handle and tab id is void.
    case appRelaunched = "app_relaunched"
    /// The observed window no longer exists; the application does.
    case windowClosed = "window_closed"
    /// The previously selected tab no longer exists in the window.
    case tabClosed = "tab_closed"
    /// Another tab of the same window is selected.
    case tabSwitched = "tab_switched"
    /// Same tab, another document.
    case navigated
    /// Same tab, same document, a new web area: the page was reloaded.
    case reloaded
    /// Same tab and document, still loading.
    case loading
    case unchanged

    /// Handles taken from the previous document are void.
    public var invalidatesDocumentHandles: Bool {
        switch self {
        case .unchanged, .loading: return false
        default: return true
        }
    }

    /// The context (its application binding, its stream, its other window)
    /// survives the transition.
    public var contextSurvives: Bool {
        switch self {
        case .appClosed, .appRelaunched: return false
        default: return true
        }
    }

    /// One phrase a client can show; never "disconnected" unless it is.
    public var meaning: String {
        switch self {
        case .appClosed: return "the browser was closed"
        case .appRelaunched: return "the browser was restarted"
        case .windowClosed: return "the observed browser window was closed"
        case .tabClosed: return "the observed tab was closed"
        case .tabSwitched: return "another tab was selected; the connection is intact"
        case .navigated: return "the tab navigated to another page; the connection is intact"
        case .reloaded: return "the page was reloaded; the connection is intact"
        case .loading: return "the page is loading"
        case .unchanged: return "nothing changed"
        }
    }
}

/// Classify the move from `before` to `after`. `closedTabs` are tab ids the
/// tab tracker reported closed in the same window between the two samples.
public func bridgeClassifyTransition(
    before: BridgePageState, after: BridgePageState, closedTabs: [String] = []
) -> BridgeBrowserTransition {
    if !after.appRunning { return .appClosed }
    if after.pid != before.pid { return .appRelaunched }
    if before.windowKey != nil && after.windowKey != before.windowKey { return .windowClosed }
    if let previous = before.selectedTab, closedTabs.contains(previous) { return .tabClosed }
    if let previous = before.selectedTab, let current = after.selectedTab, previous != current { return .tabSwitched }
    if before.documentDigest != after.documentDigest && !(before.documentDigest.isEmpty && after.documentDigest.isEmpty) {
        // A web area that appears for the first time (empty → digest) while
        // loading is still the same navigation, not a second one.
        return .navigated
    }
    if let a = before.webAreaKey, let b = after.webAreaKey, a != b { return .reloaded }
    if after.load == .loading { return .loading }
    return .unchanged
}

/// The outcome of watching one window for a while (``browser.wait``).
public struct BridgeNavigationSummary: Equatable, Sendable {
    /// The most significant transition across the whole watch.
    public let transition: BridgeBrowserTransition
    /// Distinct documents passed through before the final one (redirects and
    /// intermediate pages); 0 for a direct navigation.
    public let intermediateDocuments: Int
    public let finalLoad: BridgeLoadState
    /// The page stopped changing: same document and web area, not loading,
    /// across the last `stableSamples` samples.
    public let settled: Bool
}

/// Fold a sequence of samples (oldest first, the first being the baseline).
public func bridgeSummarizeNavigation(
    _ samples: [BridgePageState], closedTabs: [String] = [], stableSamples: Int = 3
) -> BridgeNavigationSummary {
    guard let first = samples.first, let last = samples.last else {
        return BridgeNavigationSummary(transition: .unchanged, intermediateDocuments: 0, finalLoad: .unknown, settled: false)
    }
    let order: [BridgeBrowserTransition] = [
        .appClosed, .appRelaunched, .windowClosed, .tabClosed, .tabSwitched, .navigated, .reloaded, .loading, .unchanged,
    ]
    var worst: BridgeBrowserTransition = .unchanged
    var previous = first
    var digests: [String] = []
    for sample in samples.dropFirst() {
        let step = bridgeClassifyTransition(before: previous, after: sample, closedTabs: closedTabs)
        if order.firstIndex(of: step)! < order.firstIndex(of: worst)! { worst = step }
        if !sample.documentDigest.isEmpty, digests.last != sample.documentDigest,
           sample.documentDigest != first.documentDigest {
            digests.append(sample.documentDigest)
        }
        previous = sample
    }
    // The overall move is judged baseline → final as well: a page that went
    // A → B → A navigated twice but shows the same document.
    let overall = bridgeClassifyTransition(before: first, after: last, closedTabs: closedTabs)
    if worst == .loading || worst == .unchanged { worst = overall == .unchanged ? worst : overall }
    let tail = samples.suffix(max(1, stableSamples))
    let settled = tail.count >= max(1, stableSamples) && last.load != .loading
        && tail.allSatisfy { $0.documentDigest == last.documentDigest && $0.webAreaKey == last.webAreaKey
            && $0.selectedTab == last.selectedTab && $0.appRunning }
    return BridgeNavigationSummary(
        transition: worst, intermediateDocuments: max(0, digests.count - 1),
        finalLoad: last.load, settled: settled)
}

// MARK: - Save panels

/// One accessibility element inside a sheet or dialog, reduced to the facts
/// the recognizer needs. Titles are compared, never reported.
public struct BridgeDialogElement: Equatable, Sendable {
    public let role: String
    public let subrole: String?
    public let title: String
    public let identifier: String
    /// The sheet's `AXDefaultButton` / `AXCancelButton` (language-independent).
    public let isDefault: Bool
    public let isCancel: Bool
    /// Nesting: 0 for the outer sheet, 1 for an alert sheet on top of it.
    public let depth: Int

    public init(role: String, subrole: String? = nil, title: String = "", identifier: String = "",
                isDefault: Bool = false, isCancel: Bool = false, depth: Int = 0) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.identifier = identifier
        self.isDefault = isDefault
        self.isCancel = isCancel
        self.depth = depth
    }
}

/// What a save sheet currently asks for.
public enum BridgeSavePanelKind: String, Sendable {
    /// The file name / destination sheet.
    case save
    /// "A file with this name already exists. Replace it?"
    case replaceConfirmation = "replace_confirmation"
}

public struct BridgeSavePanel: Equatable, Sendable {
    public let kind: BridgeSavePanelKind
    /// Indices into the element list the recognizer was given.
    public let nameField: Int?
    public let confirm: Int?
    public let cancel: Int?
    /// Only for `.replaceConfirmation`, and only when positively identified.
    public let replace: Int?
}

/// Localized titles of the overwrite button, lower-cased. Only used to find
/// the destructive button positively: an unidentified button is never
/// pressed to overwrite anything.
public let bridgeReplaceTitles: Set<String> = [
    "replace", "reemplazar", "sustituir", "remplacer", "ersetzen", "sostituisci", "substituir", "vervangen",
]

/// Recognize a save sheet from generic facts:
///   * the file-name field is the sheet's text field (NSSavePanel's carries the
///     identifier `saveAsNameTextField`, preferred when present);
///   * confirm / cancel are the sheet's AXDefaultButton / AXCancelButton;
///   * a nested alert (depth 1) without a name field is the overwrite
///     confirmation; its replace button must be positively identified by
///     title, otherwise `replace` is nil and the caller refuses to overwrite.
public func bridgeRecognizeSavePanel(_ elements: [BridgeDialogElement]) -> BridgeSavePanel? {
    let nested = elements.indices.filter { elements[$0].depth >= 1 }
    if !nested.isEmpty {
        let alert = nested
        let cancel = alert.first { elements[$0].isCancel && elements[$0].role == "AXButton" }
        let replace = alert.first {
            elements[$0].role == "AXButton" && !elements[$0].isCancel
                && bridgeReplaceTitles.contains(elements[$0].title.trimmingCharacters(in: .whitespaces).lowercased())
        }
        let hasField = alert.contains { elements[$0].role == "AXTextField" }
        if !hasField && (replace != nil || cancel != nil) {
            return BridgeSavePanel(kind: .replaceConfirmation, nameField: nil, confirm: nil, cancel: cancel, replace: replace)
        }
    }
    let outer = elements.indices.filter { elements[$0].depth == 0 }
    let fields = outer.filter { elements[$0].role == "AXTextField" && elements[$0].subrole != "AXSearchField" }
    let named = fields.first { elements[$0].identifier == "saveAsNameTextField" }
    let nameField = named ?? (fields.count == 1 ? fields[0] : nil)
    let confirm = outer.first { elements[$0].isDefault && elements[$0].role == "AXButton" }
    let cancel = outer.first { elements[$0].isCancel && elements[$0].role == "AXButton" }
    guard nameField != nil, confirm != nil else { return nil }
    return BridgeSavePanel(kind: .save, nameField: nameField, confirm: confirm, cancel: cancel, replace: nil)
}

/// A file name a caller may type into a save sheet: one path component, no
/// separators, no control characters, no leading dot, bounded.
public func bridgeValidSaveName(_ name: String) -> Bool {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 255, trimmed == name else { return false }
    guard !trimmed.hasPrefix("."), !trimmed.contains("/"), !trimmed.contains(":") else { return false }
    return !trimmed.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
}
