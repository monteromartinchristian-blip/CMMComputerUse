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
        elif re.match(r"^\S", line) and not line.startswith(("//", "}", "@", "#")):
            current = None
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
takeover_start = main.index("if report.requiresReobserve {")
takeover_block = main[takeover_start:main.index("\n        }\n", takeover_start)]
check("observationCapturedAt = 0" in takeover_block
      and not re.search(r"breachLatch|saveBreachLatch|appendBreachAudit|activate\(|retry", takeover_block.split("log(")[0]),
      "a human takeover only invalidates the snapshot: no latch, no audit entry, no activation, no retry")
check("elementChromeRefusal(kind: kind, params: params, mode: mode)" in main
      and all(sub in POLICY_SRC for sub in ('"AXCloseButton"', '"AXMinimizeButton"', '"AXZoomButton"', '"AXFullScreenButton"')),
      "21: window chrome guard intact (all four subroles, checked before every press)")
check(re.search(r"case \.accessibility, \.focus:\s*return BridgeSettleWindow\(minimum: 0\.8, quiet: 0\.25, maximum: 2\.0\)",
                POLICY_SRC) is not None,
      "22: settle window unchanged (accessibility/focus: 0.8 s min, 0.25 s quiet, 2.0 s max)")
check(re.search(r"&& \(attributed\.attribution == \.action \|\| attributed\.attribution == \.unknown\)", POLICY_SRC)
      is not None and "bridgeHumanActivationInputs(sequence)" in POLICY_SRC,
      "breach excused ONLY by a correlated human input; no witness -> unknown -> breach (fail closed)")

build = BUILD.read_text()
shared = sorted(p.name for p in (REPO / "apps/macos/Shared").glob("*.swift"))
missing = [name for name in shared if name not in build]
check(not missing, "build-helper.sh compiles every Shared file (missing: %s)" % missing)

sys.exit(1 if failures else 0)
