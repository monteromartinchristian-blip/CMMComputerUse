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
takeover_start = main.find("if report.requiresReobserve {")
takeover_block = main[takeover_start:main.index("\n        }\n", takeover_start)] if takeover_start >= 0 else ""
takeover_code = "\n".join(l.split("//", 1)[0] for l in takeover_block.splitlines())
check(not re.search(r"breachLatch|saveBreachLatch|appendBreachAudit|activate\(|retry", takeover_code.split("log(")[0]),
      "a human takeover only invalidates the snapshot: no latch, no audit entry, no activation, no retry")
check(len(re.findall(r"^        if report\.requiresReobserve \{$", main, re.M)) == 1
      and re.search(r"public var requiresReobserve: Bool \{\s*focusChangeAttribution == \.user "
                    r"\|\| focusChangeAttribution == \.ambiguousExternal\s*\}", POLICY_SRC) is not None,
      "T: the takeover condition is unchanged (`if report.requiresReobserve {`, user|ambiguous_external)")
check('invalidateObservation(reason: "user_takeover")' in takeover_code
      and "observationCapturedAt" not in takeover_code,
      "T: a takeover invalidates through the SAME operation as release (no zeroed timestamp, no epoch age)")
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
check('invalidateObservation(reason: "release")' in release_body
      and all(t + ".removeAll()" in invalidate_body
              for t in ("elementTable", "elementRoles", "elementSubroles", "elementContexts"))
      and "bridgeRetireObservation(" in invalidate_body
      and "releasedSnapshots = retirement.releasedSnapshots" in invalidate_body
      and "observationGeneration = retirement.generation" in invalidate_body
      and "observationCapturedAt = retirement.capturedAt" in invalidate_body
      and "released.insert(generation)" in retire_body and "generation: generation + 1" in retire_body
      and "capturedAt: now" in retire_body,
      "R: release retires the generation through the one shared invalidation (tables emptied, N+1, time=now)")
check(enclosing_funcs(main, "observationCapturedAt = ") <= {"describe", "invalidateObservation"}
      and not re.search(r"observationCapturedAt = 0\b", "\n".join(l.split("//", 1)[0] for l in main.splitlines()))
      and enclosing_funcs(main, "invalidateObservation(reason:") <= {"releaseObservation", "dispatch", "invalidateObservation"},
      "R/T: the observation time is set only by describe and the shared invalidation, never to 0")
pre_start = main.index("func elementPreconditions(")
pre_body = main[pre_start:main.index("\n}\n", pre_start)]
check(pre_body.index("bridgeReleasedSnapshotRefusal(") < pre_body.index("bridgeObservationExpired("),
      "R: a released snapshot is refused as `released` before any expiry/age is computed")

def top_func(source: str, name: str) -> str:
    start = source.index("func %s(" % name)
    return source[start:source.index("\n}\n", start)]


def strip_comments(source: str) -> str:
    return "\n".join(l.split("//", 1)[0] for l in source.splitlines())


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

build = BUILD.read_text()
shared = sorted(p.name for p in (REPO / "apps/macos/Shared").glob("*.swift"))
missing = [name for name in shared if name not in build]
check(not missing, "build-helper.sh compiles every Shared file (missing: %s)" % missing)

sys.exit(1 if failures else 0)
