// BrowserSupport.swift — the helper's live side of F-09: browser windows, tabs,
// page lifecycle, save sheets and verified downloads.
//
// Everything here goes through the same doors as the rest of the helper:
// supported accessibility attributes, the policy's application grant (observe
// to read, control to act), the caller's own context, and — for the two new
// action kinds — the full `action.execute` pipeline (mode, latch, interference
// sampling, op-id ledger). No AppleScript, no browser automation protocol, no
// profile, cookie or history access, no global input. A download is verified
// from file-system metadata in a directory the policy names; no downloaded
// file is opened unless a checksum is explicitly requested.
//
// The pure rules live in Shared/ComputerUseBrowser.swift and
// Shared/ComputerUseDownloads.swift. State here is mutated only under
// `dispatchLock`; the two wait operations loop OUTSIDE it (see `waitLoop`).

import AppKit
import ApplicationServices
import Foundation

// MARK: - State (under dispatchLock)

/// Per (principal, process): stable window and tab ids. A tab id is not an
/// authorization; it only names what the caller saw.
nonisolated(unsafe) var browserWindowTrackers: [String: BridgeWindowTracker] = [:]
nonisolated(unsafe) var browserTabTrackers: [String: BridgeTabTracker] = [:]
/// The live tab elements of the last enumeration, by tab id (same key).
nonisolated(unsafe) var browserTabElements: [String: [String: AXUIElement]] = [:]
/// The page a context saw last (observation or browser.state), for transitions.
nonisolated(unsafe) var browserLastPage: [String: BridgePageState] = [:]
nonisolated(unsafe) var downloadMonitor = BridgeDownloadMonitor()
/// Digests already computed, by path, valid only for the exact file they
/// were computed from (inode, size, modification time): repeated `status` /
/// `list` reads do not re-read a large file under the lock (audit A2).
nonisolated(unsafe) var downloadDigestCache: [String: (probe: BridgeFileProbe, digest: String)] = [:]
/// The AX target a browser action resolved to, for THIS request only.
nonisolated(unsafe) var requestBrowserTarget: BrowserActionTarget?

struct BrowserActionTarget {
    let bundleID: String
    let appName: String
    let pid: pid_t
    /// browser.select_tab: the tab element.
    let tab: AXUIElement?
    let tabWindow: AXUIElement?
    /// browser.save_dialog: the sheet and the recognized elements.
    let sheetWindow: AXUIElement?
}

func trackerKey(_ principal: BridgePrincipal, _ pid: pid_t) -> String { "\(principal.key)|\(pid)" }

/// Forget trackers of processes that are gone (bounded bookkeeping).
func pruneBrowserTrackers() {
    let alive = Set(NSWorkspace.shared.runningApplications.map { $0.processIdentifier })
    for key in Array(browserWindowTrackers.keys) {
        guard let pid = key.split(separator: "|").last.flatMap({ Int32($0) }), !alive.contains(pid) else { continue }
        browserWindowTrackers.removeValue(forKey: key)
        browserTabTrackers.removeValue(forKey: key)
        browserTabElements.removeValue(forKey: key)
    }
}

// MARK: - Accessibility reads

func axString(_ element: AXUIElement, _ attribute: String) -> String? {
    axAttr(element, attribute) as? String
}

func axBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
    if let value = axAttr(element, attribute) as? Bool { return value }
    if let value = axAttr(element, attribute) as? NSNumber { return value.boolValue }
    return nil
}

func axKey(_ element: AXUIElement) -> Int { Int(bitPattern: UInt(CFHash(element))) }

func axFrame(_ element: AXUIElement) -> CGRect? {
    guard let rawPosition = axAttr(element, kAXPositionAttribute),
          let rawSize = axAttr(element, kAXSizeAttribute),
          CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID()
    else { return nil }
    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &point),
          AXValueGetValue(rawSize as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: point, size: size)
}

/// The CGWindowID of an AX window: same process, same bounds (±2 pt), and the
/// same title when several windows share the bounds. nil when ambiguous —
/// never a guess.
func cgWindowID(of window: AXUIElement, pid: pid_t) -> Int? {
    guard let frame = axFrame(window),
          let infos = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
    let title = axString(window, kAXTitleAttribute) ?? ""
    let candidates = infos.filter { info in
        guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              (info[kCGWindowLayer as String] as? Int) == 0,
              let bounds = info[kCGWindowBounds as String] as? [String: Any] else { return false }
        let x = (bounds["X"] as? CGFloat) ?? -1, y = (bounds["Y"] as? CGFloat) ?? -1
        let w = (bounds["Width"] as? CGFloat) ?? -1, h = (bounds["Height"] as? CGFloat) ?? -1
        return abs(x - frame.minX) <= 2 && abs(y - frame.minY) <= 2
            && abs(w - frame.width) <= 2 && abs(h - frame.height) <= 2
    }
    if candidates.count == 1 { return (candidates[0][kCGWindowNumber as String] as? NSNumber)?.intValue }
    let titled = candidates.filter { ($0[kCGWindowName as String] as? String) == title }
    if titled.count == 1 { return (titled[0][kCGWindowNumber as String] as? NSNumber)?.intValue }
    return nil
}

/// The tab strip of a window: the AXTabGroup with the most tab buttons, found
/// breadth-first without descending into web content (bounded, 800 nodes).
func tabStrip(of window: AXUIElement) -> [(BridgeTabSample, AXUIElement)] {
    var queue: [AXUIElement] = [window]
    var visited = 0
    var best: [(BridgeTabSample, AXUIElement)] = []
    while !queue.isEmpty, visited < 800 {
        let node = queue.removeFirst()
        visited += 1
        let role = axString(node, kAXRoleAttribute) ?? ""
        if role == "AXWebArea" { continue }
        let children = (axAttr(node, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        if role == "AXTabGroup" {
            let tabs: [(BridgeTabSample, AXUIElement)] = children.compactMap { child in
                let childRole = axString(child, kAXRoleAttribute) ?? ""
                let subrole = axString(child, kAXSubroleAttribute)
                guard childRole == "AXRadioButton" || childRole == "AXTab" || subrole == "AXTabButton" else {
                    return nil
                }
                let title = axString(child, kAXTitleAttribute) ?? axString(child, kAXDescriptionAttribute) ?? ""
                let selected = axBool(child, kAXValueAttribute) ?? axBool(child, kAXSelectedAttribute) ?? false
                return (BridgeTabSample(elementKey: axKey(child), title: title, selected: selected), child)
            }
            if tabs.count > best.count { best = tabs }
        }
        queue.append(contentsOf: children.prefix(maxChildrenPerNode))
    }
    return best
}

/// Loading evidence and document of a window's web area.
struct WebAreaReading {
    let element: AXUIElement?
    let url: String?
    let load: BridgeLoadState
}

func webAreaReading(of window: AXUIElement) -> WebAreaReading {
    guard let area = currentWebArea(of: window) else { return WebAreaReading(element: nil, url: nil, load: .unknown) }
    var url: String?
    if let raw = axAttr(area, kAXURLAttribute) {
        if let value = raw as? URL { url = value.absoluteString } else if let value = raw as? String { url = value }
    }
    let progress = (axAttr(area, "AXLoadingProgress") as? NSNumber)?.doubleValue
    let load = bridgeLoadState(busy: axBool(area, "AXElementBusy"), loaded: axBool(area, "AXLoaded"), progress: progress)
    return WebAreaReading(element: area, url: url, load: load)
}

// MARK: - Enumeration

struct BrowserWindowReading {
    let key: String
    let windowID: Int?
    let element: AXUIElement
    let title: String
    let authorized: Bool
    let delta: BridgeTabDelta?
    let web: WebAreaReading?
    let document: BridgeDocumentIdentity?
}

struct BrowserReading {
    let app: NSRunningApplication
    let bundleID: String
    let name: String
    let windows: [BrowserWindowReading]
    let windowDelta: BridgeWindowDelta
    let focusedKey: String?
}

/// Read every window of `app` the caller may observe: stable keys, tabs and
/// page state. Windows outside the grant are listed only as "not authorized".
func readBrowser(_ app: NSRunningApplication) -> BrowserReading {
    pruneBrowserTrackers()
    let owner = bridgeTargetApp(app)
    let key = trackerKey(currentPrincipal, owner.pid)
    let windowTracker = browserWindowTrackers[key] ?? BridgeWindowTracker()
    browserWindowTrackers[key] = windowTracker
    let tabTracker = browserTabTrackers[key] ?? BridgeTabTracker()
    browserTabTrackers[key] = tabTracker
    let appElement = AXUIElementCreateApplication(owner.pid)
    let elements = (axAttr(appElement, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    let standard = elements.filter { (axString($0, kAXRoleAttribute) ?? "") == "AXWindow" }
    let samples = standard.map {
        BridgeWindowSample(windowID: cgWindowID(of: $0, pid: owner.pid), elementKey: axKey($0),
                           title: axString($0, kAXTitleAttribute) ?? "")
    }
    let windowDelta = windowTracker.update(samples: samples)
    for closed in windowDelta.closed { tabTracker.forget(windowKey: closed) }
    let focused = axElement(appElement, kAXFocusedWindowAttribute)
    var focusedKey: String?
    var liveTabs: [String: AXUIElement] = [:]
    var readings: [BrowserWindowReading] = []
    for (index, element) in standard.enumerated() {
        let tracked = windowDelta.windows[index]
        if let focused, CFEqual(focused, element) { focusedKey = tracked.key }
        let authorized = authorization.decision(
            bundleID: owner.bundleID, name: owner.name, windowTitle: tracked.title,
            scope: .observe, client: currentClient).isAllowed
        guard authorized else {
            readings.append(BrowserWindowReading(key: tracked.key, windowID: tracked.windowID, element: element,
                                                 title: "", authorized: false, delta: nil, web: nil, document: nil))
            continue
        }
        let strip = tabStrip(of: element)
        let delta = tabTracker.update(windowKey: tracked.key, samples: strip.map { $0.0 })
        for (offset, tab) in delta.tabs.enumerated() { liveTabs[tab.id] = strip[offset].1 }
        let web = webAreaReading(of: element)
        let document = documentIdentity(window: element, webArea: web.element, title: tracked.title)
        readings.append(BrowserWindowReading(key: tracked.key, windowID: tracked.windowID, element: element,
                                             title: tracked.title, authorized: true, delta: delta, web: web,
                                             document: document))
    }
    browserTabElements[key] = liveTabs
    return BrowserReading(app: app, bundleID: owner.bundleID, name: owner.name, windows: readings,
                          windowDelta: windowDelta, focusedKey: focusedKey)
}

func pageState(_ reading: BrowserReading, window: BrowserWindowReading?) -> BridgePageState {
    BridgePageState(
        appRunning: !reading.app.isTerminated, pid: reading.app.processIdentifier, windowKey: window?.key,
        selectedTab: window?.delta?.selected, documentDigest: window?.document?.digest ?? "",
        webAreaKey: window?.web?.element.map { axKey($0) }, load: window?.web?.load ?? .unknown,
        title: window?.title ?? "")
}

/// The window a context follows: the one its last observation was bound to
/// (by CGWindowID), else the focused one.
func contextWindow(_ reading: BrowserReading, context: BridgeContextRecord<BridgeLiveHandle>) -> BrowserWindowReading? {
    let authorized = reading.windows.filter { $0.authorized }
    if let id = context.identity?.windowID, let bound = authorized.first(where: { $0.windowID == id }) { return bound }
    if let lastKey = browserLastPage[context.id]?.windowKey, let bound = authorized.first(where: { $0.key == lastKey }) {
        return bound
    }
    return authorized.first { $0.key == reading.focusedKey } ?? authorized.first
}

func transitionDictionary(_ transition: BridgeBrowserTransition) -> [String: Any] {
    ["kind": transition.rawValue, "meaning": transition.meaning,
     "context_survives": transition.contextSurvives,
     "handles_invalidated": transition.invalidatesDocumentHandles]
}

/// Record the page a context sees now and say what changed since last time.
func recordPage(contextID: String, page: BridgePageState, closedTabs: [String]) -> BridgeBrowserTransition? {
    defer { browserLastPage[contextID] = page }
    guard let before = browserLastPage[contextID] else { return nil }
    return bridgeClassifyTransition(before: before, after: page, closedTabs: closedTabs)
}

/// Called by `describe` after a commit: the observation is the new baseline
/// for this context's transitions.
func notePageObserved(contextID: String, app: NSRunningApplication) {
    guard bridgeIsKnownBrowser(bundleID: app.bundleIdentifier ?? ""), let context = workspace.record(id: contextID)
    else { return }
    let reading = readBrowser(app)
    _ = recordPage(contextID: contextID, page: pageState(reading, window: contextWindow(reading, context: context)),
                   closedTabs: [])
}

// MARK: - browser.state

/// The caller's context and its (still running, still authorized) application.
func browserContext(_ arguments: [String: Any], scope: BridgeScope)
    -> Result<(BridgeContextRecord<BridgeLiveHandle>, NSRunningApplication), BridgePolicyRefusal>
{
    let contextID: String?
    switch contextIDArgument(arguments) {
    case .failure(let refusal): return .failure(refusal)
    case .success(let id): contextID = id
    }
    let context: BridgeContextRecord<BridgeLiveHandle>
    switch workspace.context(principal: currentPrincipal, id: contextID, now: Date().timeIntervalSince1970) {
    case .failure(let refusal): return .failure(refusal)
    case .success(let found): context = found
    }
    guard let bundle = context.identity?.bundleID ?? context.boundBundle else {
        return .failure(BridgePolicyRefusal(
            code: "CONTEXT_UNOBSERVED",
            message: "Observe the browser in this context first.",
            detail: "reason=context_unobserved"))
    }
    let candidates = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundle && !$0.isTerminated }
    let app = candidates.first { $0.processIdentifier == context.identity?.pid } ?? candidates.first
    guard let app else {
        return .failure(BridgePolicyRefusal(
            code: "COMPUTER_TARGET_UNAVAILABLE",
            message: "The browser this context belongs to is not running.",
            detail: "reason=app_closed;transition=app_closed"))
    }
    let owner = bridgeTargetApp(app)
    // The application grant; each window is then decided on its own title.
    if let refusal = authorization.decision(
        bundleID: owner.bundleID, name: owner.name, windowTitle: nil, scope: scope, client: currentClient).refusal {
        return .failure(refusal)
    }
    return .success((context, app))
}

func browserStateRequest(_ arguments: [String: Any]) -> (Bool, Any?, [String: Any?]?) {
    guard AXIsProcessTrusted() else {
        return (false, nil, bridgeError(code: "COMPUTER_PERMISSION_DENIED", message: "Accessibility permission is required.",
                                        detail: "reason=accessibility_not_trusted"))
    }
    let context: BridgeContextRecord<BridgeLiveHandle>
    let app: NSRunningApplication
    switch browserContext(arguments, scope: .observe) {
    case .failure(let refusal): return (false, nil, refusalFrame(refusal))
    case .success(let pair): (context, app) = pair
    }
    let reading = readBrowser(app)
    let followed = contextWindow(reading, context: context)
    let closedTabs = reading.windows.flatMap { $0.delta?.closed ?? [] }
    let page = pageState(reading, window: followed)
    let transition = recordPage(contextID: context.id, page: page, closedTabs: closedTabs)
    let family = bridgeBrowserFamily(bundleID: reading.bundleID)
    let windows: [[String: Any]] = reading.windows.map { window in
        guard window.authorized else {
            return ["window_key": window.key, "window_id": window.windowID as Any, "authorized": false]
        }
        var entry: [String: Any] = [
            "window_key": window.key, "window_id": window.windowID as Any, "authorized": true,
            "title": String(window.title.prefix(200)), "focused": window.key == reading.focusedKey,
            "followed_by_context": window.key == followed?.key,
            "tabs_exposed": window.delta?.exposed ?? false,
            "tabs": (window.delta?.tabs ?? []).map { $0.dictionary },
            "selected_tab": window.delta?.selected as Any,
            "opened_tabs": window.delta?.opened ?? [], "closed_tabs": window.delta?.closed ?? [],
            "tab_selection_changed": window.delta?.selectionChanged ?? false,
            // A sheet on the window: usually a save/destination dialog.
            "dialog_open": sheet(of: window.element) != nil,
        ]
        let redacted = bridgeRedactedURL(window.web?.url)
        entry["page"] = [
            "url": redacted as Any,
            "document": window.document?.dictionary as Any,
            "load": window.web?.load.rawValue ?? BridgeLoadState.unknown.rawValue,
            "web_area": window.web?.element != nil,
            "pdf": redacted.map { $0.lowercased().hasSuffix(".pdf") } ?? false,
        ]
        return entry
    }
    var result: [String: Any] = [
        "browser": ["bundle": reading.bundleID, "app": reading.name, "family": family.rawValue,
                    "profile": family == .unknown ? "generic" : "known", "pid": Int(app.processIdentifier)],
        "context_id": context.id, "context_label": context.label,
        "windows": windows,
        "opened_windows": reading.windowDelta.opened, "closed_windows": reading.windowDelta.closed,
        "snapshot": context.generation,
    ]
    if let transition { result["transition"] = transitionDictionary(transition) }
    return (true, result, nil)
}

// MARK: - browser.select_tab / browser.save_dialog preconditions

/// Everything a browser action must prove before it runs: the caller's own
/// observed context, the same running application, a control grant for the
/// window it touches, and a target that exists NOW.
func browserPreconditions(kind: String, params: [String: Any], mode: BridgeInteractionMode) -> BridgePolicyRefusal? {
    guard kind == "browser.select_tab" || kind == "browser.save_dialog" else { return nil }
    requestBrowserTarget = nil
    guard AXIsProcessTrusted() else {
        return BridgePolicyRefusal(code: "COMPUTER_PERMISSION_DENIED", message: "Accessibility permission is required.",
                                   detail: "policy=\(mode.rawValue);reason=accessibility_not_trusted")
    }
    let context: BridgeContextRecord<BridgeLiveHandle>
    let app: NSRunningApplication
    switch browserContext(params, scope: .control) {
    case .failure(let refusal): return refusal
    case .success(let pair): (context, app) = pair
    }
    requestContext = context
    let owner = bridgeTargetApp(app)
    let reading = readBrowser(app)
    if kind == "browser.select_tab" {
        guard let tabID = params["tab_id"] as? String, bridgeValidOpaqueID(tabID, prefix: "tab") else {
            return BridgePolicyRefusal(code: "ACTION_FAILED", message: "The action names no valid tab.",
                                       detail: "policy=\(mode.rawValue);reason=tab_missing")
        }
        let key = trackerKey(currentPrincipal, owner.pid)
        guard let element = browserTabElements[key]?[tabID],
              let window = reading.windows.first(where: { $0.delta?.tabs.contains { $0.id == tabID } == true }) else {
            return BridgePolicyRefusal(code: "TAB_UNKNOWN",
                                       message: "That tab is not open in this browser any more; read the browser state again.",
                                       detail: "policy=\(mode.rawValue);reason=tab_unknown")
        }
        if let refusal = authorization.decision(
            bundleID: owner.bundleID, name: owner.name, windowTitle: window.title, scope: .control,
            client: currentClient).refusal {
            return refusal
        }
        requestBrowserTarget = BrowserActionTarget(bundleID: owner.bundleID, appName: owner.name, pid: owner.pid,
                                                   tab: element, tabWindow: window.element, sheetWindow: nil)
        return nil
    }
    // browser.save_dialog: the context's window must carry a sheet.
    guard let window = contextWindow(reading, context: context) ?? reading.windows.first(where: { $0.authorized }),
          sheet(of: window.element) != nil else {
        return BridgePolicyRefusal(code: "SAVE_DIALOG_NOT_FOUND",
                                   message: "No save dialog is open in this browser window.",
                                   detail: "policy=\(mode.rawValue);reason=no_sheet")
    }
    if let refusal = authorization.decision(
        bundleID: owner.bundleID, name: owner.name, windowTitle: window.title, scope: .control,
        client: currentClient).refusal {
        return refusal
    }
    if let name = params["filename"] as? String, !bridgeValidSaveName(name) {
        return BridgePolicyRefusal(code: "ACTION_FAILED", message: "The file name must be one plain path component.",
                                   detail: "policy=\(mode.rawValue);reason=invalid_filename")
    }
    requestBrowserTarget = BrowserActionTarget(bundleID: owner.bundleID, appName: owner.name, pid: owner.pid,
                                               tab: nil, tabWindow: nil, sheetWindow: window.element)
    return nil
}

// MARK: - browser.select_tab

func browserSelectTab(_ params: [String: Any]) -> [String: Any] {
    guard let target = requestBrowserTarget, let tab = target.tab else {
        return ["ok": false, "message": "The tab is no longer available.", "detail": "reason=tab_unknown"]
    }
    if axBool(tab, kAXValueAttribute) == true || axBool(tab, kAXSelectedAttribute) == true {
        return ["ok": true, "message": "already selected", "selected": true, "changed": false]
    }
    var error = AXUIElementPerformAction(tab, kAXPressAction as CFString)
    if error != .success {
        error = AXUIElementSetAttributeValue(tab, kAXSelectedAttribute as CFString, kCFBooleanTrue)
    }
    guard error == .success else {
        return ["ok": false, "message": "The browser did not accept the tab selection (AX \(error.rawValue)).",
                "detail": "reason=ax_error;ax=\(error.rawValue)"]
    }
    // Verify on the tab strip itself: a press that returned is not a switch.
    let deadline = Date().addingTimeInterval(1.5)
    while Date() < deadline {
        if axBool(tab, kAXValueAttribute) == true || axBool(tab, kAXSelectedAttribute) == true {
            return ["ok": true, "message": "tab selected", "selected": true, "changed": true]
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return ["ok": false, "message": "The tab was pressed but is not selected.", "detail": "reason=not_selected"]
}

// MARK: - browser.save_dialog

func sheet(of window: AXUIElement) -> AXUIElement? {
    let children = (axAttr(window, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    return children.first { (axString($0, kAXRoleAttribute) ?? "") == "AXSheet" }
}

/// The recognizer's view of a sheet (and of an alert sheet nested in it).
func dialogElements(_ sheet: AXUIElement) -> ([BridgeDialogElement], [AXUIElement]) {
    var facts: [BridgeDialogElement] = []
    var live: [AXUIElement] = []
    func collect(_ root: AXUIElement, depth: Int) {
        let defaultButton = axElement(root, kAXDefaultButtonAttribute)
        let cancelButton = axElement(root, kAXCancelButtonAttribute)
        var queue: [AXUIElement] = (axAttr(root, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        var visited = 0
        while !queue.isEmpty, visited < 800 {
            let node = queue.removeFirst()
            visited += 1
            let role = axString(node, kAXRoleAttribute) ?? ""
            if role == "AXSheet" { collect(node, depth: depth + 1); continue }
            if ["AXTextField", "AXButton", "AXStaticText"].contains(role) {
                facts.append(BridgeDialogElement(
                    role: role, subrole: axString(node, kAXSubroleAttribute),
                    title: axString(node, kAXTitleAttribute) ?? "",
                    identifier: axString(node, kAXIdentifierAttribute) ?? "",
                    isDefault: defaultButton.map { CFEqual($0, node) } ?? false,
                    isCancel: cancelButton.map { CFEqual($0, node) } ?? false, depth: depth))
                live.append(node)
            }
            queue.append(contentsOf: ((axAttr(node, kAXChildrenAttribute) as? [AXUIElement]) ?? []).prefix(maxChildrenPerNode))
        }
    }
    collect(sheet, depth: 0)
    return (facts, live)
}

func browserSaveDialog(_ params: [String: Any]) -> [String: Any] {
    guard let target = requestBrowserTarget, let window = target.sheetWindow, let outer = sheet(of: window) else {
        return ["ok": false, "message": "The save dialog is gone.", "detail": "reason=no_sheet"]
    }
    let overwrite = params["overwrite"] as? Bool == true
    func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }
    func recognize() -> (BridgeSavePanel?, [AXUIElement]) {
        guard let current = sheet(of: window) else { return (nil, []) }
        let (facts, live) = dialogElements(current)
        return (bridgeRecognizeSavePanel(facts), live)
    }
    var (panel, live) = recognize()
    _ = outer
    var report: [String: Any] = ["filename_set": false, "confirmed": false, "replaced": false]
    if params["cancel"] as? Bool == true {
        guard let panel, let cancel = panel.cancel else {
            return ["ok": false, "message": "The dialog has no recognizable cancel button.", "detail": "reason=no_cancel"]
        }
        let pressed = press(live[cancel])
        return ["ok": pressed, "message": pressed ? "cancelled" : "cancel failed", "dialog": panel.kind.rawValue,
                "cancelled": pressed]
    }
    if panel?.kind == .save, let name = params["filename"] as? String, let field = panel?.nameField {
        let element = live[field]
        let error = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, name as CFString)
        let readBack = axString(element, kAXValueAttribute)
        guard error == .success, bridgeSetValueCheck(requested: name, readBack: readBack) == .verified else {
            return ["ok": false, "message": "The file name could not be set.", "detail": "reason=filename_not_set"]
        }
        report["filename_set"] = true
    }
    if panel?.kind == .save, params["confirm"] as? Bool == true, let confirm = panel?.confirm {
        guard press(live[confirm]) else {
            return ["ok": false, "message": "The save button did not respond.", "detail": "reason=confirm_failed"]
        }
        report["confirmed"] = true
        Thread.sleep(forTimeInterval: 0.6)
        (panel, live) = recognize()
    }
    if panel?.kind == .replaceConfirmation {
        guard overwrite else {
            report["ok"] = false
            report["message"] = "A file with that name already exists. Choose another name, or confirm the overwrite explicitly."
            report["detail"] = "reason=name_conflict"
            report["dialog"] = BridgeSavePanelKind.replaceConfirmation.rawValue
            return report
        }
        guard let replace = panel?.replace else {
            return ["ok": false, "message": "The overwrite button could not be identified; nothing was replaced.",
                    "detail": "reason=replace_unidentified", "dialog": "replace_confirmation"]
        }
        guard press(live[replace]) else {
            return ["ok": false, "message": "The replace button did not respond.", "detail": "reason=replace_failed"]
        }
        report["replaced"] = true
        Thread.sleep(forTimeInterval: 0.4)
        (panel, live) = recognize()
    }
    report["ok"] = true
    report["message"] = "save dialog handled"
    report["dialog"] = panel?.kind.rawValue ?? "closed"
    report["closed"] = sheet(of: window) == nil
    return report
}

// MARK: - Downloads

/// One level of `root`, metadata only (lstat). A WebKit bundle reports the
/// bytes of the largest regular file inside it. Bounded to 10 000 entries.
func scanDownloadRoot(_ root: String) -> Result<[BridgeDirectoryEntry], BridgePolicyRefusal> {
    let manager = FileManager.default
    let names: [String]
    do { names = try manager.contentsOfDirectory(atPath: root) } catch {
        return .failure(BridgePolicyRefusal(
            code: "DOWNLOAD_ROOT_UNAVAILABLE",
            message: "The download directory cannot be read by the helper (missing, or not permitted by macOS).",
            detail: "reason=root_unreadable;errno=\((error as NSError).code)"))
    }
    var entries: [BridgeDirectoryEntry] = []
    for name in names.prefix(10_000) {
        let path = (root as NSString).appendingPathComponent(name)
        var info = stat()
        guard lstat(path, &info) == 0 else { continue }
        let kind = info.st_mode & S_IFMT
        guard kind == S_IFREG || kind == S_IFDIR else { continue }
        var size = Int64(info.st_size)
        if kind == S_IFDIR {
            size = 0
            if name.hasSuffix(".download"), let inner = try? manager.contentsOfDirectory(atPath: path) {
                for child in inner.prefix(64) {
                    var childInfo = stat()
                    if lstat((path as NSString).appendingPathComponent(child), &childInfo) == 0,
                       childInfo.st_mode & S_IFMT == S_IFREG {
                        size = max(size, Int64(childInfo.st_size))
                    }
                }
            }
        }
        let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        entries.append(BridgeDirectoryEntry(name: name, isDirectory: kind == S_IFDIR, size: size,
                                            inode: UInt64(info.st_ino), modified: modified))
    }
    return .success(entries)
}

func downloadExpectRequest(_ arguments: [String: Any]) -> (Bool, Any?, [String: Any?]?) {
    let context: BridgeContextRecord<BridgeLiveHandle>
    let app: NSRunningApplication
    switch browserContext(arguments, scope: .observe) {
    case .failure(let refusal): return (false, nil, refusalFrame(refusal))
    case .success(let pair): (context, app) = pair
    }
    let owner = bridgeTargetApp(app)
    let roots = authorization.grant(bundleID: owner.bundleID, name: owner.name)?.downloadRoots ?? []
    guard !roots.isEmpty else {
        return (false, nil, bridgeError(
            code: "DOWNLOADS_NOT_ENABLED",
            message: "The policy declares no download directory for this application.",
            detail: "reason=no_download_roots;bundle=\(owner.bundleID)"))
    }
    let requested = (arguments["directory"] as? String).flatMap {
        bridgeNormalizedDownloadRoot($0, home: NSHomeDirectory())
    } ?? (arguments["directory"] == nil ? roots[0] : nil)
    guard let root = requested, bridgeDownloadRootAllowed(root, roots: roots) else {
        return (false, nil, bridgeError(
            code: "DOWNLOAD_ROOT_NOT_ALLOWED",
            message: "That directory is not one the policy allows for this application's downloads.",
            detail: "reason=root_not_allowed"))
    }
    let opID = (arguments["op_id"] as? String).flatMap { bridgeValidOperationID($0) ? $0 : nil }
    if arguments["op_id"] != nil && opID == nil {
        return (false, nil, bridgeError(code: "CAPABILITY_UNSUPPORTED", message: "The op_id is malformed.",
                                        detail: "reason=op_id_invalid"))
    }
    let hint = (arguments["name_hint"] as? String).flatMap { bridgeValidSaveName($0) ? $0 : nil }
    let expectedBytes = (arguments["expected_bytes"] as? NSNumber)?.int64Value
    let expectedSHA = (arguments["expected_sha256"] as? String).flatMap {
        $0.count == 64 && $0.allSatisfy { $0.isHexDigit } ? $0 : nil
    }
    if (arguments["expected_bytes"] != nil && (expectedBytes ?? 0) <= 0)
        || (arguments["expected_sha256"] != nil && expectedSHA == nil) {
        return (false, nil, bridgeError(code: "CAPABILITY_UNSUPPORTED", message: "expected_bytes / expected_sha256 is malformed.",
                                        detail: "reason=expected_invalid"))
    }
    let entries: [BridgeDirectoryEntry]
    switch scanDownloadRoot(root) {
    case .failure(let refusal): return (false, nil, refusalFrame(refusal))
    case .success(let found): entries = found
    }
    switch downloadMonitor.expect(
        principal: currentPrincipal, contextID: context.id, bundleID: owner.bundleID, root: root,
        entries: entries, opID: opID, nameHint: hint, now: Date().timeIntervalSince1970,
        expectedBytes: expectedBytes, expectedSHA256: expectedSHA, appName: owner.name) {
    case .failure(let refusal): return (false, nil, refusalFrame(refusal))
    case .success(let id):
        log("download expectation \(id) context=\(context.label) bundle=\(owner.bundleID)")
        return downloadStatusRequest(["download_id": id])
    }
}

func downloadStatusRequest(_ arguments: [String: Any]) -> (Bool, Any?, [String: Any?]?) {
    reapIdleContexts()
    guard let id = arguments["download_id"] as? String, bridgeValidOpaqueID(id, prefix: "dl"),
          let root = downloadMonitor.root(of: id, principal: currentPrincipal) else {
        return (false, nil, bridgeError(code: "DOWNLOAD_UNKNOWN", message: "No such download expectation for this client.",
                                        detail: "reason=download_unknown"))
    }
    // Decided again at every read: a grant revoked since `download.expect`
    // ends the expectation before its directory is scanned or a byte is read.
    if let refusal = revokedDownloadRefusal(id) {
        return (false, nil, refusalFrame(refusal))
    }
    let scanned = scanDownloadRoot(root)
    let entries: [BridgeDirectoryEntry]?
    if case .success(let found) = scanned { entries = found } else { entries = nil }
    switch downloadMonitor.status(principal: currentPrincipal, id: id, entries: entries, now: Date().timeIntervalSince1970) {
    case .failure(let refusal): return (false, nil, refusalFrame(refusal))
    case .success(let status):
        // Only on explicit request (`checksum`, or an expected_sha256 the
        // caller declared) are a downloaded file's bytes read.
        var result = bridgeDownloadReport(
            status, expectedSHA256: downloadMonitor.expectedSHA256(of: id, principal: currentPrincipal),
            requested: arguments["checksum"] as? Bool == true, probe: bridgeProbeFile, digestOf: cachedDigest)
        if entries == nil { result["scan"] = "unavailable" }
        return (true, result, nil)
    }
}

/// The refusal for an expectation the policy no longer covers (application,
/// `observe` scope or root revoked), which is then forgotten; nil if covered.
func revokedDownloadRefusal(_ id: String) -> BridgePolicyRefusal? {
    guard let subject = downloadMonitor.subject(of: id, principal: currentPrincipal),
          let refusal = bridgeDownloadAuthorizationRefusal(
              policy: authorization, client: currentClient, bundleID: subject.bundleID,
              appName: subject.appName, root: subject.root) else { return nil }
    downloadMonitor.forget(principal: currentPrincipal, id: id)
    log("download expectation \(id) ended: no longer authorized (\(refusal.detail))")
    return refusal
}

func downloadListRequest() -> (Bool, Any?, [String: Any?]?) {
    reapIdleContexts()
    let now = Date().timeIntervalSince1970
    for id in downloadMonitor.ids(principal: currentPrincipal) { _ = revokedDownloadRefusal(id) }
    // The same integrity rule as `download.status`: a declared checksum is
    // never listed as complete unless verified (audit N1).
    return (true, ["downloads": downloadMonitor.listReports(
        principal: currentPrincipal, now: now, probe: bridgeProbeFile, digestOf: cachedDigest)], nil)
}

/// The SHA-256 of the regular file `probe` describes (never a link, never a
/// different inode, bounded), reused while that exact file is unchanged.
func cachedDigest(_ path: String, _ probe: BridgeFileProbe) -> String? {
    if let cached = downloadDigestCache[path], cached.probe == probe { return cached.digest }
    downloadDigestCache.removeValue(forKey: path)
    guard let digest = bridgeSHA256(ofFileAt: path, expectedInode: probe.inode) else { return nil }
    if downloadDigestCache.count >= 64 { downloadDigestCache.removeAll() }
    downloadDigestCache[path] = (probe, digest)
    return digest
}

func downloadForgetRequest(_ arguments: [String: Any]) -> (Bool, Any?, [String: Any?]?) {
    guard let id = arguments["download_id"] as? String, bridgeValidOpaqueID(id, prefix: "dl") else {
        return (false, nil, bridgeError(code: "DOWNLOAD_UNKNOWN", message: "No such download expectation.",
                                        detail: "reason=download_unknown"))
    }
    return (true, ["forgotten": downloadMonitor.forget(principal: currentPrincipal, id: id), "download_id": id], nil)
}

// MARK: - Waits (outside dispatchLock)

/// `download.wait` and `browser.wait` poll the read-only status operation,
/// taking `dispatchLock` for each sample only — never for the whole wait, so
/// the other context, the streams and every other client keep working.
/// Bounded: at most `timeout` seconds (≤ 120), samples every 250 ms.
func waitLoop(operation: String, arguments: [String: Any], peer: BridgePeerCode?) -> (Bool, Any?, [String: Any?]?) {
    let requested = (arguments["timeout"] as? NSNumber)?.doubleValue ?? 30
    let timeout = min(max(requested, 0.5), 120)
    let deadline = Date().addingTimeInterval(timeout)
    let started = Date()
    var samples: [BridgePageState] = []
    var closedTabs: [String] = []
    while true {
        let sample: (Bool, Any?, [String: Any?]?) = withRequestState(peer: peer) {
            if operation == "download.wait" { return downloadStatusRequest(arguments) }
            return browserWaitSample(arguments, samples: &samples, closedTabs: &closedTabs)
        }
        guard sample.0, let result = sample.1 as? [String: Any] else { return sample }
        if waitSatisfied(operation: operation, result: result, arguments: arguments) || Date() >= deadline {
            var final = result
            final["waited_ms"] = Int(Date().timeIntervalSince(started) * 1000)
            final["timed_out"] = !waitSatisfied(operation: operation, result: result, arguments: arguments)
            return (true, final, nil)
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
}

func waitSatisfied(operation: String, result: [String: Any], arguments: [String: Any]) -> Bool {
    let until = (arguments["until"] as? String) ?? (operation == "download.wait" ? "terminal" : "settled")
    if operation == "download.wait" {
        let state = result["state"] as? String ?? ""
        switch until {
        case "started": return state != BridgeDownloadState.notStarted.rawValue
        default: return result["terminal"] as? Bool == true
        }
    }
    let transition = (result["transition"] as? [String: Any])?["kind"] as? String ?? "unchanged"
    switch until {
    case "loaded": return result["load"] as? String == BridgeLoadState.loaded.rawValue
    case "changed": return transition != BridgeBrowserTransition.unchanged.rawValue
        && transition != BridgeBrowserTransition.loading.rawValue
    default: return result["settled"] as? Bool == true
    }
}

func browserWaitSample(_ arguments: [String: Any], samples: inout [BridgePageState],
                       closedTabs: inout [String]) -> (Bool, Any?, [String: Any?]?) {
    guard AXIsProcessTrusted() else {
        return (false, nil, bridgeError(code: "COMPUTER_PERMISSION_DENIED", message: "Accessibility permission is required.",
                                        detail: "reason=accessibility_not_trusted"))
    }
    let context: BridgeContextRecord<BridgeLiveHandle>
    let app: NSRunningApplication
    switch browserContext(arguments, scope: .observe) {
    case .failure(let refusal):
        // The application vanished mid-wait: that IS the answer.
        if refusal.detail.contains("app_closed"), let first = samples.first {
            samples.append(BridgePageState(appRunning: false, pid: first.pid, windowKey: nil, selectedTab: nil,
                                           documentDigest: "", webAreaKey: nil, load: .unknown, title: ""))
            let summary = bridgeSummarizeNavigation(samples, closedTabs: closedTabs)
            return (true, ["transition": transitionDictionary(summary.transition), "settled": true,
                           "load": BridgeLoadState.unknown.rawValue, "intermediate_documents": 0], nil)
        }
        return (false, nil, refusalFrame(refusal))
    case .success(let pair): (context, app) = pair
    }
    let reading = readBrowser(app)
    let followed = contextWindow(reading, context: context)
    closedTabs += reading.windows.flatMap { $0.delta?.closed ?? [] }
    if samples.isEmpty, let baseline = browserLastPage[context.id] { samples.append(baseline) }
    let page = pageState(reading, window: followed)
    samples.append(page)
    browserLastPage[context.id] = page
    let summary = bridgeSummarizeNavigation(samples, closedTabs: closedTabs)
    return (true, [
        "context_id": context.id,
        "transition": transitionDictionary(summary.transition),
        "intermediate_documents": summary.intermediateDocuments,
        "load": summary.finalLoad.rawValue,
        "settled": summary.settled,
        "url": bridgeRedactedURL(followed?.web?.url) as Any,
        "selected_tab": followed?.delta?.selected as Any,
        "window_key": followed?.key as Any,
    ], nil)
}
