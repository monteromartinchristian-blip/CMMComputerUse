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

build = BUILD.read_text()
shared = sorted(p.name for p in (REPO / "apps/macos/Shared").glob("*.swift"))
missing = [name for name in shared if name not in build]
check(not missing, "build-helper.sh compiles every Shared file (missing: %s)" % missing)

sys.exit(1 if failures else 0)
