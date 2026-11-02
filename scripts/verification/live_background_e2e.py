#!/usr/bin/env python3
"""Live end-to-end check of CMM Computer Use in background mode (macOS only).

Drives the helper ONLY through the adapter's ``computer_use_*`` tools — the
exact code DeepSeek Harness runs — and judges every step against an
INDEPENDENT witness (``focus-monitor``: its own process and run loop, sampling
frontmost app, front-most window owner and cursor every 10 ms).

Steps (each recorded with CLOCK_UPTIME_RAW, the monitor's clock):

  1. status                      effective_mode=background, grants listed
  2. observe <app>               target line, cmm_view, no focus change
  3. PiP name                    the DSH projection folds the real outputs and
                                 must show the observed human name
  4. press window control        must be REFUSED CAPABILITY_UNSUPPORTED
                                 (reason=window_chrome), nothing moves
  5. press <title>               success, ledger untouched, no breach; the
                                 fixture's own state file proves the effect
  6. scroll                      AX scroll succeeds (fixture state proves it) or
                                 is CAPABILITY_UNSUPPORTED — never a wheel event
  7. electron observe (opt.)     useful tree, or explicit AX_TREE_UNAVAILABLE
  8. bypass guard                the DSH guard refuses osascript/CGEvent/Swift
  9. breach control (opt.)       fixture "Activarme" activates itself 400 ms
                                 late: must be INTERFERENCE_BREACH, latched, and
                                 the monitor must ALSO see it (ledger == witness)

For steps 1–8 the witness must show: frontmost never became the target, the
target's window never came to the front, the cursor did not move — during the
step and for 1.5 s after it.

Exit status 0 only when every check holds. The JSON report is the evidence.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import subprocess
import sys
import time

REPO = pathlib.Path(__file__).resolve().parents[2]
PKG = REPO / "packages" / "dsh-computer-use"
sys.path.insert(0, str(PKG / "adapter"))

from cmm_computer_use.client import BridgeClient, default_socket_path  # noqa: E402
from cmm_computer_use.mcp_server import ToolRegistry, handle_message  # noqa: E402

FIXTURE = "com.example.computer-use-fixture"
TAIL = 1.5  # seconds after a step during which the witness must stay quiet


def uptime() -> float:
    return time.clock_gettime(time.CLOCK_UPTIME_RAW)


class Driver:
    def __init__(self, socket: str):
        self.client = BridgeClient(socket, policy="background")
        self.registry = ToolRegistry(self.client, "background")
        self.steps = []
        self.transcript = []  # (tool, args, text, isError) for the DSH fold
        self.seq = 0

    def call(self, step: str, tool: str, args=None, quiet=True):
        args = args or {}
        start = uptime()
        response = handle_message(self.registry, {
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": {"name": tool, "arguments": args}})
        end = uptime()
        result = response.get("result") or {}
        text = "\n".join(b.get("text", "") for b in result.get("content", []) if b.get("type") == "text")
        is_error = bool(result.get("isError"))
        self.transcript.append({"tool": tool, "args": args, "text": text, "isError": is_error})
        self.steps.append({"step": step, "tool": tool, "start": start, "end": end,
                           "quiet": quiet, "isError": is_error, "text": text[:4000]})
        print("── %s (%s) %s" % (step, tool, "ERROR" if is_error else "ok"))
        print(text[:2000])
        return text, is_error


def element_id(text: str, predicate) -> int | None:
    for line in text.splitlines():
        m = re.match(r"^\[(\d+)\] (\S+) \"(.*)\" \(", line)
        if m and predicate(line, m.group(2), m.group(3)):
            return int(m.group(1))
    return None


def snapshot_of(text: str) -> int:
    m = re.search(r"^snapshot: (\d+)", text, re.M)
    return int(m.group(1)) if m else 0


def fixture_state(path: str):
    try:
        return json.loads(pathlib.Path(path).read_text())
    except (OSError, ValueError):
        return None


def dsh_fold(transcript) -> dict:
    """Fold the real tool results through the DSH projection (runtime.mjs)."""
    # ESM + stdin: a tiny module file, so `import` works.
    module = """
import {readFileSync} from 'node:fs';
import {initialState, fold, bypassReason} from %s;
const rows = JSON.parse(readFileSync(0, 'utf8'));
let s = initialState(); let seq = 0;
for (const r of rows) {
  const id = String(++seq);
  s = fold(s, {type:'assistant/message', seq, time: Date.now(), data:{message:{content:[{type:'tool-call', id, name:'mcp__cmm-computer-use__' + r.tool, arguments: JSON.stringify(r.args)}]}}});
  s = fold(s, {type:'tool/result', seq: ++seq, time: Date.now(), data:{message:{source:{callId:id}, isError:r.isError, content:[{type:'text', text:r.text}]}}});
}
const bypass = ['osascript -e \\'tell application "System Events" to keystroke "a"\\'',
  'swift - <<< "CGEvent(scrollWheelEvent2Source:nil,units:.line,wheelCount:1,wheel1:-3,wheel2:0,wheel3:0)"',
  'open -a Claude'].map(command => bypassReason({name:'bash', arguments:{command}}));
console.log(JSON.stringify({target: s.target, breach: s.breach, error: s.error, bridge: s.bridge, revision: s.revision, bypass}));
""" % json.dumps((PKG / "runtime.mjs").as_uri())
    tmp = pathlib.Path(os.environ.get("TMPDIR", "/tmp")) / ("cmm-e2e-fold-%d.mjs" % os.getpid())
    tmp.write_text(module)
    try:
        out = subprocess.run(["node", str(tmp)], input=json.dumps(transcript), capture_output=True,
                             text=True, check=True).stdout
    finally:
        tmp.unlink(missing_ok=True)
    return json.loads(out)


def judge(steps, monitor_rows, target_bundle, person_bundle):
    verdicts = []
    for step in steps:
        window = [r for r in monitor_rows if step["start"] - 0.05 <= r["t"] <= step["end"] + TAIL]
        before = [r for r in monitor_rows if r["t"] < step["start"]]
        ref = before[-1] if before else (window[0] if window else None)
        fronts = sorted({r["front"] for r in window})
        tops = sorted({r["top"] for r in window})
        moved = 0.0
        if ref:
            moved = max((abs(r["x"] - ref["x"]) + abs(r["y"] - ref["y"]) for r in window), default=0.0)
        target_front = any(r["front"] == target_bundle for r in window)
        target_top = any(r["top"] == target_bundle for r in window) and (ref is None or ref["top"] != target_bundle)
        verdicts.append({
            "step": step["step"], "samples": len(window), "fronts": fronts, "tops": tops,
            "cursor_max_delta": moved, "target_front": target_front, "target_top": target_top,
            "person_front_throughout": all(r["front"] == person_bundle for r in window) if window else None,
        })
    return verdicts


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", default=default_socket_path())
    parser.add_argument("--app", default=FIXTURE, help="bundle id of the authorized target")
    parser.add_argument("--press-title", default="Incrementar")
    parser.add_argument("--fixture-state", default=os.environ.get("CMM_CU_FIXTURE_STATE", ""))
    parser.add_argument("--electron-app", default="", help="e.g. com.anthropic.claudefordesktop")
    parser.add_argument("--breach-control", action="store_true",
                        help="press the fixture's self-activating button (latches the fixture until CMM Console rearms it)")
    parser.add_argument("--monitor", required=True, help="JSONL written by focus-monitor")
    parser.add_argument("--report", required=True)
    args = parser.parse_args()

    person = subprocess.run(["lsappinfo", "info", "-only", "bundleid", "front"],
                            capture_output=True, text=True).stdout
    m = re.search(r'"CFBundleIdentifier"="([^"]+)"', person)
    person_bundle = m.group(1) if m else ""
    print("person's frontmost app: %s" % person_bundle)

    d = Driver(args.socket)
    checks = {}

    text, err = d.call("1 status", "computer_use_status")
    checks["status"] = (not err) and "effective_mode: background" in text and "- authorized:" in text

    text, err = d.call("2 observe", "computer_use_observe", {"app": args.app})
    checks["observe"] = (not err) and "(background)" in text and "cmm_view: " in text
    snap = snapshot_of(text)
    observation = text

    folded = dsh_fold(d.transcript)
    name_line = re.search(r"^target: (.*) \[([\w.-]+)\] \(background\)$", observation, re.M)
    observed_name = name_line.group(1).strip() if name_line else ""
    checks["pip_name"] = bool(folded.get("target")) and folded["target"]["name"] == observed_name \
        and folded["target"]["name"] != folded["target"]["bundle"] and folded["target"]["bundle"] == args.app
    print("── 3 PiP name: %r (bundle %r)" % ((folded.get("target") or {}).get("name"),
                                           (folded.get("target") or {}).get("bundle")))

    chrome = element_id(observation, lambda line, role, title: "window-control" in line)
    if chrome:
        text, err = d.call("4 press window control", "computer_use_press", {"element_id": chrome, "snapshot": snap})
        checks["chrome_refused"] = err and "REFUSED CAPABILITY_UNSUPPORTED" in text and "reason=window_chrome" in text
    else:
        checks["chrome_refused"] = None  # nothing to test on this target

    state_before = fixture_state(args.fixture_state) if args.fixture_state else None
    text, err = d.call("2b re-observe", "computer_use_observe", {"app": args.app})
    snap, observation = snapshot_of(text), text
    press = element_id(observation, lambda line, role, title: title == args.press_title and " pressable" in line)
    if press:
        text, err = d.call("5 press", "computer_use_press", {"element_id": press, "snapshot": snap})
        checks["press_ok"] = (not err) and "verdict=untouched" in text and "focus_became_target=False" in text
        if state_before is not None:
            time.sleep(0.3)
            after = fixture_state(args.fixture_state) or {}
            checks["press_effect"] = after.get("counter") == state_before.get("counter", 0) + 1
    else:
        checks["press_ok"] = False

    text, err = d.call("5b re-observe", "computer_use_observe", {"app": args.app})
    snap, observation = snapshot_of(text), text
    scrollable = element_id(observation, lambda line, role, title: line.rstrip().endswith(" scrollable"))
    unscrollable = element_id(observation, lambda line, role, title: " not-scrollable(" in line)
    target_scroll = scrollable or unscrollable
    if target_scroll:
        state_before = fixture_state(args.fixture_state) if args.fixture_state else None
        text, err = d.call("6 scroll", "computer_use_scroll",
                           {"element_id": target_scroll, "snapshot": snap, "direction": "down"})
        if err:
            checks["scroll"] = "REFUSED CAPABILITY_UNSUPPORTED" in text
        else:
            checks["scroll"] = "verdict=untouched" in text
            if state_before is not None:
                time.sleep(0.3)
                after = fixture_state(args.fixture_state) or {}
                checks["scroll_effect"] = after.get("scroll_y", -1) > state_before.get("scroll_y", -1)
    else:
        checks["scroll"] = None

    if args.electron_app:
        text, err = d.call("7 electron observe", "computer_use_observe", {"app": args.electron_app})
        elements = len(re.findall(r"^\[\d+\] ", text, re.M))
        checks["electron_tree"] = (not err) and ("AX_TREE_UNAVAILABLE" in text or elements > 3)
        checks["electron_tree_useful"] = (not err) and "AX_TREE_UNAVAILABLE" not in text and elements > 3

    folded = dsh_fold(d.transcript)
    checks["bypass_guard"] = all(folded.get("bypass") or [None])
    print("── 8 bypass labels: %s" % folded.get("bypass"))

    if args.breach_control:
        text, err = d.call("9b observe", "computer_use_observe", {"app": args.app})
        snap = snapshot_of(text)
        trigger = element_id(text, lambda line, role, title: title == "Activarme")
        text, err = d.call("9 breach control", "computer_use_press",
                           {"element_id": trigger, "snapshot": snap}, quiet=False)
        checks["breach_detected"] = err and "REFUSED INTERFERENCE_BREACH" in text and "STOP: breach recorded" in text
        text2, err2 = d.call("9c latched", "computer_use_press",
                             {"element_id": trigger, "snapshot": snap}, quiet=False)
        checks["breach_latched"] = err2 and "reason=breach" in text2
        checks["dsh_latched"] = dsh_fold(d.transcript).get("breach") is True
        checks["no_focus_restore"] = "focus_restore" not in text
        status, _ = d.call("9d status shows latch", "computer_use_status", quiet=False)
        checks["latch_visible"] = bool(re.search(r"^breach_latch: state=ok open=[1-9]", status, re.M)) \
            and "rearm from CMM Console" in status

    # Let the witness cover the tail of the last step, then judge.
    time.sleep(TAIL + 0.2)
    rows = []
    for line in pathlib.Path(args.monitor).read_text().splitlines():
        try:
            rows.append(json.loads(line))
        except ValueError:
            pass
    verdicts = judge(d.steps, rows, args.app, person_bundle)
    quiet_ok = True
    for step, v in zip(d.steps, verdicts):
        if step["quiet"]:
            ok = v["samples"] > 0 and not v["target_front"] and not v["target_top"] and v["cursor_max_delta"] <= 0.5
            v["ok"] = ok
            quiet_ok &= ok
        elif step["step"] == "9 breach control":
            # The controlled breach: the independent witness must have seen it
            # too, or the ledger and reality disagree.
            v["ok"] = v["target_front"] or v["target_top"]
            checks["witness_saw_breach"] = v["ok"]
    checks["witness_quiet"] = quiet_ok

    report = {"person_bundle": person_bundle, "target": args.app, "checks": checks,
              "witness": verdicts, "steps": d.steps}
    pathlib.Path(args.report).write_text(json.dumps(report, indent=2, ensure_ascii=False))
    print("\n══ checks")
    failed = False
    for key, value in checks.items():
        print("  %-22s %s" % (key, "PASS" if value is True else ("n/a" if value is None else "FAIL")))
        failed |= value is False
    print("report: %s" % args.report)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
