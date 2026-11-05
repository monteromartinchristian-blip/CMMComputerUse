#!/usr/bin/env python3
"""Static contract checks on the helper source. Runs anywhere (no Swift needed).

Pins decisions that XCTest cannot reach because they live in main.swift:

  B. After a breach nothing is activated: no focus restoration. The only
     `.activate(` calls allowed are the focus-class actions' own.
  C. The breach latch is cleared by `breach.rearm`, never by a restart; the
     adapter (the agent's side) has no way to issue `breach.rearm`.
  -  scripts/build-helper.sh compiles every Shared/*.swift file, so the helper
     never ships without a rule the tests pin.
  -  the test-only rearm probe can send breach.status / breach.rearm and nothing
     else, needs a reason and refuses the production socket.

Exit 0 when every check holds.
"""

from __future__ import annotations

import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parents[2]
MAIN = REPO / "apps/macos/CMMComputerUse/main.swift"
LATCH = REPO / "apps/macos/Shared/ComputerUseBreachLatch.swift"
BUILD = REPO / "scripts/build-helper.sh"
ADAPTER = REPO / "packages/dsh-computer-use/adapter/cmm_computer_use"

ALLOWED_ACTIVATORS = {"attemptActivate", "appOpen"}

failures: list[str] = []


def check(condition: bool, message: str) -> None:
    print(("PASS " if condition else "FAIL ") + message)
    if not condition:
        failures.append(message)


main = MAIN.read_text()
POLICY_SRC = (REPO / "apps/macos/Shared/ComputerUsePolicy.swift").read_text()
lines = main.splitlines()

# Enclosing top-level func of each `.activate(` call.
current = None
offenders = []
for number, line in enumerate(lines, 1):
    m = re.match(r"^func (\w+)", line)
    if m:
        current = m.group(1)
    elif re.match(r"^\S", line) and not line.startswith(("//", "}", "@")):
        current = None  # top-level statement, not inside a func
    code = line.split("//", 1)[0]
    if ".activate(" in code and current not in ALLOWED_ACTIVATORS:
        offenders.append("%d:%s" % (number, current))
check(not offenders, "B: .activate( only inside %s (offenders: %s)" % (sorted(ALLOWED_ACTIVATORS), offenders))

start = main.index("if report.breach {")
depth, end = 0, start
for index in range(start, len(main)):
    if main[index] == "{":
        depth += 1
    elif main[index] == "}":
        depth -= 1
        if depth == 0:
            end = index
            break
breach_block = "\n".join(l.split("//", 1)[0] for l in main[start:end].splitlines())
check("activate" not in breach_block, "B: the breach branch activates nothing")
check("restorePersonFocus" not in main and "focus_restore" not in main,
      "B: no focus-restore routine or ledger field")

latch = LATCH.read_text()
messages = re.findall(r'message: "([^"]*)"', latch)
check(messages and not any("restart" in m.lower() for m in messages),
      "C: no latch/rearm message offers a restart as the unlock")
check('case "breach.rearm":' in main and "bridgeRearmDecision(" in main,
      "C: the helper serves breach.rearm through the pinned decision")
check("breachLatchedTargets" not in main, "C: no in-memory-only latch remains")
adapter = "".join(p.read_text() for p in ADAPTER.glob("*.py"))
check('"breach.rearm"' not in adapter and "def rearm" not in adapter,
      "C: the adapter cannot issue breach.rearm")

probe = (REPO / "scripts/verification/rearm-probe/main.swift").read_text()
check(set(re.findall(r'operation = "([^"]+)"', probe)) == {"breach.status", "breach.rearm"},
      "probe: only breach.status / breach.rearm can be sent")
check('fail("a reason is required")' in probe and 'fail("refusing the production socket")' in probe,
      "probe: mandatory reason, production socket refused")
check("var launched: NSRunningApplication?" not in main and "LaunchedAppBox()" in main,
      "Swift 6: appOpen no longer mutates a captured var in a @Sendable handler")

scroll_start = main.index("func uiScroll(")
scroll_body = main[scroll_start:main.index("\nfunc ", scroll_start + 10)]
scroll_code = "\n".join(l.split("//", 1)[0] for l in scroll_body.splitlines())
check(not re.search(r"CGEvent|scrollWheel|CGWarp|CGDisplayMoveCursor|\.post\(", scroll_code)
      and "bridgeScrollEffect(" in scroll_code,
      "ui.scroll: AX-only (no wheel/CGEvent/cursor) and verified by a measured postcondition")

reveal_start = main.index("func revealCandidates(")
reveal_code = "\n".join(l.split("//", 1)[0] for l in main[reveal_start:scroll_start].splitlines())
check(not re.search(r"CGEvent|scrollWheel|CGWarp|CGDisplayMoveCursor|\.post\(|kAXFocused|AXRaise|activate\(", reveal_code + scroll_code)
      and scroll_code.count('AXUIElementPerformAction(reveal[index].element, "AXScrollToVisible"') == 1
      and scroll_code.count("AXUIElementPerformAction(") == 2
      and "bridgeRevealEffect(" in scroll_code and "bridgeRevealNext(" in scroll_code
      and "steps.count < 12, Date() < deadline" in scroll_code
      and scroll_code.index("if case .unsupported = plan") < scroll_code.index("revealCandidates(of: el)"),
      "F8: the reveal scroll route (D5) is AXScrollToVisible only, last resort, bounded steps, each measured; "
      "no wheel, cursor, focus or activation")

sv_start = main.index("func uiSetValue(")
sv_body = main[sv_start:main.index("\nfunc ", sv_start + 10)]
check("bridgeSetValueCheck(" in sv_body and "AXUIElementIsAttributeSettable(" in sv_body
      and not re.search(r"CGEvent|\.post\(|keyboard", sv_body),
      "ui.set_value: settable precheck, read-back verification, no synthetic input")
check("bridgeEnrichmentTrigger(" in main
      and not re.search(r'AXUIElementSetAttributeValue\([^)]*"AXEnhancedUserInterface"', main),
      "enrichment decided after a first walk (readable_not_actionable); AXEnhancedUserInterface never set")

def enclosing_funcs(source: str, needle: str) -> set:
    """Top-level func names whose bodies contain `needle` (comments ignored)."""
    names, current = set(), None
    for line in source.splitlines():
        m = re.match(r"^func (\w+)", line)
        if m:
            current = m.group(1)
        elif re.match(r"^\S", line) and not line.startswith(("//", "}", "@", "#", ")")):
            current = None  # `)` closes a multi-line signature: still the same func
        if needle in line.split("//", 1)[0]:
            names.add(current)
    return names


legacy_global_input = {"keyboardType", "keyboardShortcut", "pointerClick", "pointerScroll"}
posting = enclosing_funcs(main, ".post(")
check(posting <= legacy_global_input,
      "18: CGEvents are posted only by the legacy global-input actions %s (refused in background and "
      "under any allowlist); found in %s" % (sorted(legacy_global_input), sorted(posting)))
witness_start = main.index("func humanInputSample(")
witness_body = main[witness_start:main.index("\n}\n", witness_start)]
witness_code = "\n".join(l.split("//", 1)[0] for l in witness_body.splitlines())
check("secondsSinceLastEventType" in witness_code and "flagsState" in witness_code
      and not re.search(r"\.post\(|CGEvent\(|tapCreate|CGEventTap|mouseMoved|CGWarp", witness_code),
      "18: the human-input witness only QUERIES HID state (no event created/posted, no tap, no mouseMoved)")
helper_sources = main + "".join(p.read_text() for p in (REPO / "apps/macos/Shared").glob("*.swift"))
helper_code = "\n".join(l.split("//", 1)[0] for l in helper_sources.splitlines())
check(not re.search(r"NSAppleScript|OSAScript|osascript|System Events|JavaScript for Automation", helper_code),
      "19: no AppleScript / JXA / System Events in the helper")
removals = enclosing_funcs(main, "state.remove(id:") | enclosing_funcs(main, "breachLatch = .loaded(empty)")
check(removals <= {"breachRearm"} and enclosing_funcs(main, "breachRearm(arguments:") <= {"dispatch", "breachRearm"},
      "20: latches are removed only by breach.rearm (no automatic reset/rearm); found in %s" % sorted(removals))
def top_func(source: str, name: str) -> str:
    start = source.index("func %s(" % name)
    return source[start:source.index("\n}\n", start)]


def strip_comments(source: str) -> str:
    return "\n".join(l.split("//", 1)[0] for l in source.splitlines())


takeover_match = re.search(r"^( +)if report\.requiresReobserve \{$", main, re.M)
takeover_start = takeover_match.start() if takeover_match else -1
takeover_block = (main[takeover_start:main.index("\n%s}\n" % takeover_match.group(1), takeover_start)]
                  if takeover_match else "")
takeover_code = "\n".join(l.split("//", 1)[0] for l in takeover_block.splitlines())
check(not re.search(r"breachLatch|saveBreachLatch|appendBreachAudit|activate\(|retry", takeover_code.split("log(")[0]),
      "a human takeover only invalidates the snapshot: no latch, no audit entry, no activation, no retry")
check(len(re.findall(r"^ +if report\.requiresReobserve \{$", main, re.M)) == 1
      and re.search(r"public var requiresReobserve: Bool \{\s*focusChangeAttribution == \.user "
                    r"\|\| focusChangeAttribution == \.ambiguousExternal\s*\}", POLICY_SRC) is not None,
      "T: the takeover condition is unchanged (`if report.requiresReobserve {`, user|ambiguous_external)")
check('invalidateObservation(contextID: contextID, reason: "user_takeover")' in takeover_code
      and "capturedAt" not in takeover_code
      and "requestContext.map { [$0.id] }" in takeover_code,
      "T: a takeover invalidates through the SAME operation as release, only in the affected context "
      "(no zeroed timestamp, no epoch age)")
check("elementChromeRefusal(kind: kind, params: params, mode: mode)" in main
      and all(sub in POLICY_SRC for sub in ('"AXCloseButton"', '"AXMinimizeButton"', '"AXZoomButton"', '"AXFullScreenButton"')),
      "21: window chrome guard intact (all four subroles, checked before every press)")
check(re.search(r"case \.accessibility, \.focus:\s*return BridgeSettleWindow\(minimum: 0\.8, quiet: 0\.25, maximum: 2\.0\)",
                POLICY_SRC) is not None,
      "22: settle window unchanged (accessibility/focus: 0.8 s min, 0.25 s quiet, 2.0 s max)")
check(re.search(r"&& \(attributed\.attribution == \.action \|\| attributed\.attribution == \.unknown\)", POLICY_SRC)
      is not None and "bridgeHumanActivationInputs(sequence)" in POLICY_SRC,
      "breach excused ONLY by a correlated human input; no witness -> unknown -> breach (fail closed)")

describe_start = main.index("func describe(")
describe_body = main[describe_start:main.index("\nfunc buildDescription(", describe_start)]
check(describe_body.index("authorization.decision(") < describe_body.index("walkTarget(traversal)")
      and "Traversal(elementFilter: elementFilter)" in describe_body,
      "P: the pushed-down filter is applied only after the app/window authorization, inside the target walk")
release_start = main.index("func releaseObservation(")
release_body = main[release_start:main.index("\n}\n", release_start)]
invalidate_start = main.index("func invalidateObservation(")
invalidate_body = main[invalidate_start:main.index("\n}\n", invalidate_start)]
retire_start = POLICY_SRC.index("public func bridgeRetireObservation(")
retire_body = POLICY_SRC[retire_start:POLICY_SRC.index("\n}\n", retire_start)]
WORKSPACE_SRC = (REPO / "apps/macos/Shared/ComputerUseWorkspace.swift").read_text()
def swift_method(source: str, signature: str) -> str:
    start = source.index(signature)
    return source[start:source.index("\n    }\n", start)]
ws_invalidate = swift_method(WORKSPACE_SRC, "public func invalidate(id: String, reason: String, now: Double)")
ws_begin = swift_method(WORKSPACE_SRC, "public func beginObservation(")
ws_resolve = swift_method(WORKSPACE_SRC, "public func resolveHandle(")
check('invalidateObservation(contextID: context.id, reason: "release")' in release_body
      and "workspace.invalidate(" in invalidate_body
      and "bridgeRetireObservation(" in ws_invalidate
      and "record.handles.removeAll()" in ws_invalidate
      and "record.released = retirement.releasedSnapshots" in ws_invalidate
      and "let current = nextGeneration()" in ws_invalidate
      and "record.generation = current" in ws_invalidate
      and "generation: current" in ws_invalidate
      and "record.generation = nextGeneration()" in ws_begin
      and "record.capturedAt = retirement.capturedAt" in ws_invalidate
      and "released.insert(generation)" in retire_body and "generation: generation + 1" in retire_body
      and "capturedAt: now" in retire_body,
      "R: release retires the context's generation through the one shared invalidation "
      "(its handles emptied, the next WORKSPACE-WIDE generation (audit X-04), time=now)")
main_code = "\n".join(l.split("//", 1)[0] for l in main.splitlines())
check(not re.search(r"\bcapturedAt\s*=", main_code)
      and set(re.findall(r"record\.capturedAt = [^\n]+", WORKSPACE_SRC))
          <= {"record.capturedAt = now", "record.capturedAt = retirement.capturedAt"}
      and "record.capturedAt = now" in ws_begin
      and not re.search(r"capturedAt = 0\b", WORKSPACE_SRC)
      and enclosing_funcs(main, "invalidateObservation(contextID:")
          <= {"releaseObservation", "executeActionRequest", "invalidateObservation"},
      "R/T: the observation time is set only by a new observation and the shared invalidation, never to 0")
pre_start = main.index("func elementPreconditions(")
pre_body = main[pre_start:main.index("\n}\n", pre_start)]
check("workspace.resolveHandle(" in pre_body
      and ws_resolve.index("bridgeReleasedSnapshotRefusal(") < ws_resolve.index("bridgeObservationExpired(")
      < ws_resolve.index("bridgeSnapshotRefusal("),
      "R: a released snapshot is refused as `released` before any expiry/age is computed (per context)")

# ---- W: Multi-App Workspace (0.3.3) -------------------------------------
check(not re.search(r"^nonisolated\(unsafe\) var (elementTable|elementRoles|elementSubroles|elementContexts|"
                    r"observationGeneration|observationCapturedAt|releasedSnapshots)\b", main, re.M),
      "W1: no process-wide element table or generation: handles live in workspace contexts")
check("traversal.handles[elementID] = BridgeLiveHandle(" in main
      and "workspace.commit(id: context.id, generation: start.generation, handles: traversal.handles)" in main,
      "W2: an observation commits its handles into ONE context, under that context's new generation")
frame_path = main[main.index('if operation == "observation.stream_frame" {'):]
frame_path = frame_path[:frame_path.index("return\n")]
check("authorizationLock.lock()" in frame_path and "requestPrincipal(peer: peer" in frame_path
      and "streamFrameResponse(args, principal: principal)" in frame_path,
      "W3: frames are served outside dispatchLock only to the principal that owns the stream")
stream_src = (REPO / "apps/macos/CMMComputerUse/WindowStream.swift").read_text()
check("windowTitle: pair.0.title, scope: .observe, client: client" in stream_src
      and "stopWindowStream()" not in stream_src,
      "W4: a stream is authorized for THIS client's .observe grant (0.3.2 omitted the client)")
ledger_body = main[main.index("func executeActionWithLedger("):]
ledger_body = ledger_body[:ledger_body.index("\n}\n")]
check(ledger_body.count("executeActionRequest(") == 1
      and not re.search(r"\bwhile\b|\bfor\s+\w+\s+in\b|\brepeat\s*\{", strip_comments(ledger_body)),
      "W5: an action is executed at most once per request (no retry loop around it)")
check(main.count("executed = true\n") == 1
      and main.index("executed = true\n") < main.index("let result = executeAction(kind: kind, params: params)"),
      "W6: `executed` is set exactly once, immediately before the action is handed to the machine")



socket_src = (REPO / "apps/macos/Shared/ComputerUseSocketPath.swift").read_text()
socket_code = strip_comments(socket_src)
addr_body = strip_comments(top_func(main, "unixAddr"))
check("-> sockaddr_un?" in addr_body and "bridgeUnixSocketPathBytes(path)" in addr_body
      and "path.utf8.prefix(" not in addr_body and ".prefix(" not in addr_body
      and "utf8.prefix(" not in strip_comments(main),
      "S: unixAddr never truncates (no utf8.prefix; optional address from the shared validator)")
check("MemoryLayout.size(ofValue: sockaddr_un().sun_path)" in socket_code
      and not re.search(r"\b10[34]\b", socket_code)
      and "bytes.count + 1 <= capacity" in socket_code and "Array(path.utf8)" in socket_code,
      "S: one capacity derived from sockaddr_un.sun_path, measured in UTF-8 bytes, NUL reserved")
serve_body = strip_comments(top_func(main, "serveSocket"))
validate_at = serve_body.find("guard var addr = unixAddr(path) else {")
check(validate_at >= 0
      and "exit(2)" in serve_body[validate_at:serve_body.index("}", validate_at)]
      and all(validate_at < serve_body.index(step)
              for step in ("socket(AF_UNIX", "probeSocket(at: path)", "unlink(path)", "bind(fd"))
      and serve_body.count("unixAddr(") == 1,
      "S: serveSocket refuses an overlong path (FATAL, exit 2) BEFORE socket/probe/unlink/bind")
probe_body = strip_comments(top_func(main, "probeSocket"))
probe_at = probe_body.find("guard var addr = unixAddr(path) else { return false }")
check(probe_at >= 0 and probe_at < probe_body.index("socket(AF_UNIX") < probe_body.index("connect("),
      "S: probeSocket uses the same validation and never connects to a truncated address")

# F-09 browser and downloads (BrowserSupport.swift).
browser_src = (REPO / "apps/macos/CMMComputerUse/BrowserSupport.swift").read_text()
browser_code = strip_comments(browser_src)
check(not re.search(r"NSAppleScript|osascript|OSAScript|CGEvent|Process\(|/usr/bin|cookie|Cookies|History\.db|"
                    r"Login Data|keychain|SecItem|remote-debugging|webdriver|marionette", browser_code, re.I),
      "F1: browser code uses no scripting, synthetic input, subprocess, profile/cookie/keychain or automation protocol")
wait_body = browser_code[browser_code.index("func waitLoop("):]
wait_body = wait_body[:wait_body.index("\n}\n")]
check("withRequestState(peer: peer)" in wait_body and "dispatchLock" not in wait_body
      and wait_body.index("withRequestState(peer: peer)") < wait_body.index("Thread.sleep("),
      "F2: waits take dispatchLock per sample only (never across the sleep)")
downloads_code = strip_comments((REPO / "apps/macos/Shared/ComputerUseDownloads.swift").read_text())
status_body = browser_code[browser_code.index("func downloadStatusRequest("):]
status_body = status_body[:status_body.index("\n}\n")]
report_body = downloads_code[downloads_code.index("public func bridgeDownloadReport("):]
report_body = report_body[:report_body.index("\n}\n")]
reader_body = downloads_code[downloads_code.index("public func bridgeSHA256("):]
reader_body = reader_body[:reader_body.index("\n}\n")]
digest_body = browser_code[browser_code.index("func cachedDigest("):]
digest_body = digest_body[:digest_body.index("\n}\n")]
check("FileHandle(forReadingAtPath:" not in browser_code + downloads_code
      and browser_code.count("bridgeSHA256(") == 1 and "bridgeSHA256(ofFileAt: path, expectedInode: probe.inode)" in digest_body
      and browser_code.count("probe: bridgeProbeFile, digestOf: cachedDigest)") == 2
      and "open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK" in reader_body
      and "fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG" in reader_body
      and "Int64(info.st_size) <= maxBytes" in reader_body and "try?" not in reader_body
      and "guard let found = probe(path)" in report_body
      and report_body.index("guard let found = probe(path)") < report_body.index("if requested || expectedSHA256 != nil")
      < report_body.index("digestOf(path, found)")
      and "requested: false, probe: probe, digestOf: digestOf)" in downloads_code
      and "Data(contentsOf" not in browser_code + downloads_code
      and "contentsOfFile" not in browser_code + downloads_code,
      "F3: a finished download is re-checked with lstat at every read; its bytes are read only for an explicit "
      "checksum or a declared expected_sha256, from a regular file opened without following links, bounded")
list_body = browser_code[browser_code.index("func downloadListRequest("):]
list_body = list_body[:list_body.index("\n}\n")]
reap_body = main[main.index("func reapIdleContexts("):]
reap_body = reap_body[:reap_body.index("\n}\n")]
close_body = main[main.index("func contextClose("):]
close_body = close_body[:close_body.index("\n}\n")]
check("revokedDownloadRefusal(id)" in status_body
      and status_body.index("revokedDownloadRefusal(id)") < status_body.index("scanDownloadRoot(root)")
      and "revokedDownloadRefusal(id)" in list_body
      and "downloadMonitor.listReports(" in list_body and ".dictionary" not in list_body
      and "bridgeDownloadReport(" in status_body and ".dictionary" not in status_body
      and "bridgeDownloadAuthorizationRefusal(" in browser_code
      and "downloadMonitor.forget(principal: currentPrincipal, contextID: id)" in close_body
      and "reapIdleContexts()" in status_body and "reapIdleContexts()" in list_body
      and status_body.index("reapIdleContexts()") < status_body.index("revokedDownloadRefusal(id)")
      and status_body.index("reapIdleContexts()") < status_body.index("scanDownloadRoot(root)")
      and "downloadMonitor.forget(principal: record.principal, contextID: record.id)" in reap_body
      and downloads_code.count("        reap(now: now)\n") >= 4,
      "F6: every download read is re-decided against the policy before scanning, status and list share one "
      "integrity rule; a closed or expired context's expectations end")
check('"browser.select_tab", "browser.save_dialog":\n        return .accessibility' in POLICY_SRC.replace(
          '"ui.press", "ui.set_value", "ui.scroll", "wait", "finish",\n         ', '')
      and "browserPreconditions(kind: kind, params: params, mode: mode)" in main,
      "F4: browser actions are accessibility-class and pass their preconditions inside the action pipeline")
check('scope: .control' in browser_code and "bridgeDownloadRootAllowed(root, roots: roots)" in browser_code
      and "downloadRoots ?? []" in browser_code,
      "F5: browser actions need a control grant; downloads watch only the grant's declared roots")

describe_body = main[main.index("func describe("):]
describe_body = describe_body[:describe_body.index("\n}\n")]
browser_shared = strip_comments((REPO / "apps/macos/Shared/ComputerUseBrowser.swift").read_text())
resolve_body = browser_shared[browser_shared.index("public func bridgeResolveWindow("):]
resolve_body = resolve_body[:resolve_body.index("\n}")]
check("bridgeResolveWindow(resolveWindow, pause:" in describe_body
      and describe_body.index("bridgeResolveWindow(") < describe_body.index("authorization.decision(")
      and "windowResolution.map { \";\" + $0.diagnostics }" in describe_body
      and resolve_body.count("resolve()") == 2 and resolve_body.count("pause()") == 1,
      "F7: an observation resolves its window with ONE bounded retry before deciding, and a refusal says what it decided on")

timeouts = re.findall(r"AXUIElementSetMessagingTimeout\(([^\n]*)\)", strip_comments(main + browser_src))
check(timeouts == ["AXUIElementCreateSystemWide(), Float(bridgeAXMessagingTimeoutSeconds)"]
      and "private let axFocusedReader = BridgeBoundedReader<String>" in main
      and "axFocusedReader.read(timeout: 0.1)" in main,
      "F9: exactly ONE accessibility timeout, set once at start from a constant; the focus sampler is bounded "
      "by a reader, never by lowering the process-wide timeout")

stream_src = (REPO / "apps/macos/CMMComputerUse/WindowStream.swift").read_text()
cap_body = main[main.index("func captureScreenRequest("):]
cap_body = cap_body[:cap_body.index("\n}\n")]
str_body = main[main.index("func streamStartRequest("):]
str_body = str_body[:str_body.index("\n}\n")]
check("bridgeSelectWindow(" not in strip_comments(main) + strip_comments(stream_src)
      and "bridgeResolveWindowById(" not in strip_comments(main) + strip_comments(stream_src)
      and strip_comments(main).count("bridgeSelectAuthorizedWindow(") == 1
      and strip_comments(stream_src).count("bridgeSelectAuthorizedWindow(") == 1
      and strip_comments(stream_src).count("bridgeResolveAuthorizedWindowById(") == 1
      and 'clientRequiredRefusal(operation: "observation.capture_screen")' in cap_body
      and 'clientRequiredRefusal(operation: "observation.stream_start")' in str_body
      and "let policy = authorization" in main and "let policy = authorization" in stream_src,
      "F10: windows are selected only among those the caller may observe (policy and caller captured by value "
      "before the task); a caller with no identity under a client-required policy never reaches selection")

frame_body = stream_src[stream_src.index("func windowStreamFrame("):]
frame_body = frame_body[:frame_body.index("\n}\n")]
reval_body = stream_src[stream_src.index("func revalidateWindowStreams("):]
reval_body = reval_body[:reval_body.index("\n}\n")]
check("guard recheckStreamAuthorization(entry, now: now) else" in frame_body
      and frame_body.index("recheckStreamAuthorization(") < frame_body.index("latestFrame()")
      and "bridgeStreamRecheck(" in reval_body and "currentWindowTitle(windowID:" in reval_body
      and "entry.identity.windowTitle, scope" not in reval_body
      and "CGWindowListCopyWindowInfo([.optionIncludingWindow]" in stream_src,
      "F11: a stream is judged again on the window's CURRENT title before any frame is served and on "
      "policy.reload (never only the title it started with)")

check("bridgeBoundWindowOutcome(boundRequested: true, found: false, openWindows: standard.count)" in describe_body
      and "reason=bound_window_closed;windows=" in describe_body
      and '"bound_window_replaced"' in describe_body
      and describe_body.index("bridgeBoundWindowOutcome(") < describe_body.index("authorization.decision("),
      "F12: a lost bound window is refused (several windows) or used and named (one window), decided before "
      "the window is authorized; never silently re-bound to the focused window")

check("workspace.touch(principal: currentPrincipal, id: contextID" in status_body
      and status_body.index("workspace.touch(") < status_body.index("reapIdleContexts()")
      and "workspace.touch(principal: currentPrincipal, id: contextID" in list_body
      and list_body.index("workspace.touch(") < list_body.index("reapIdleContexts()"),
      "F13: reading a download (status, wait, list) keeps the context that declared it alive, before idle "
      "contexts are reaped")

check("bridgePreferBoundProcess(" in describe_body and "reason=bound_process_gone" in describe_body
      and describe_body.index("bridgePreferBoundProcess(") < describe_body.index("authorization.decision("),
      "F14: an explicit context keeps the process it was bound to when several processes share a bundle id; a "
      "bound process that is gone is refused, never replaced by another instance")

build = BUILD.read_text()
check("BrowserSupport.swift" in build, "build-helper.sh compiles BrowserSupport.swift")
shared = sorted(p.name for p in (REPO / "apps/macos/Shared").glob("*.swift"))
missing = [name for name in shared if name not in build]
check(not missing, "build-helper.sh compiles every Shared file (missing: %s)" % missing)

sys.exit(1 if failures else 0)
