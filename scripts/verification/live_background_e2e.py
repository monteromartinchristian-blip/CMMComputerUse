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

    def call(self, step: str, tool: str, args=None, quiet=True, target=None):
        """Run one tool call. After a QUIET call, wait a real TAIL before
        returning, so the witness window of that step (end .. end + TAIL)
        belongs to it alone: a late interference caused by this step is still
        inside its window, and the next step — e.g. the deliberate breach —
        cannot start inside it. The window is not cut short; the runner waits."""

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
                           "quiet": quiet, "isError": is_error, "text": text[:4000],
                           # The app this step acts on: the witness judges THIS
                           # app's activation/raise (default: the run's --app).
                           "target": target})
        print("── %s (%s) %s" % (step, tool, "ERROR" if is_error else "ok"))
        print(text[:2000])
        if quiet:
            remaining = end + TAIL - uptime()
            if remaining > 0:
                time.sleep(remaining)
        return text, is_error


def quiet_step_ok(verdict: dict) -> bool:
    """The quiet gate for one step's witness window (unchanged criterion)."""

    return (verdict["samples"] > 0 and not verdict["target_front"] and not verdict["target_top"]
            and verdict["cursor_max_delta"] <= 0.5)


def witness_window_overlaps(steps, tail: float = TAIL) -> list:
    """Every later call that STARTED inside a quiet step's witness window
    (end .. end + tail). Any entry means that window is contaminated and the
    run must say `witness_window_overlap`."""

    overlaps = []
    for index, step in enumerate(steps):
        if not step.get("quiet"):
            continue
        limit = step["end"] + tail
        for later in steps[index + 1:]:
            if later["start"] < limit:
                overlaps.append({"quiet_step": step["step"], "next_call": later["step"],
                                 "overlap_ms": round((limit - later["start"]) * 1000)})
    return overlaps


def person_frontmost(lsappinfo_info: str, monitor_rows, observe_text: str):
    """The person's frontmost app at the start, from three sources:
    LaunchServices (`lsappinfo`), the independent witness's first sample, and
    the helper's first observation (`frontmost: Name [bundle]`). Returns
    (bundle, source, every source) so an empty or disagreeing reading is
    visible in the evidence instead of silently blank."""

    sources = {}
    m = re.search(r'"(?:CFBundleIdentifier|bundleID)"\s*=\s*"([^"]+)"', lsappinfo_info or "")
    sources["lsappinfo"] = m.group(1) if m else ""
    sources["witness"] = (monitor_rows[0].get("front") or "") if monitor_rows else ""
    m = re.search(r"^frontmost: .* \[([\w.-]*)\]$", observe_text or "", re.M)
    sources["helper_observe"] = m.group(1) if m else ""
    for source in ("lsappinfo", "witness", "helper_observe"):
        if sources[source]:
            return sources[source], source, sources
    return "", "none", sources


def scroll_verdict(text: str, is_error: bool, on_fixture: bool,
                   state_before=None, state_after=None) -> dict:
    """Judge one `computer_use_scroll` result.

    The helper's verdict is the MEASURED effect (`scroll: … effect=moved`),
    never the AX return code. On the fixture — an NSScrollView with a real
    scroll bar — a verified scroll is mandatory and the fixture's own
    `scroll_y` must have grown (second channel). Elsewhere, an explicit
    CAPABILITY_UNSUPPORTED is an acceptable, honest answer.
    """

    verified = (not is_error) and bool(re.search(r"^scroll: route=(page_action|scroll_bar) effect=moved ", text, re.M))
    untouched = "verdict=untouched" in text
    ax_error = re.search(r"^scroll: .* ax_error=(-?\d+) ", text, re.M)
    out = {"verified": verified, "untouched": untouched,
           "ax_error_diagnostic": int(ax_error.group(1)) if ax_error else None,
           "unsupported": is_error and "REFUSED CAPABILITY_UNSUPPORTED" in text}
    if on_fixture:
        grew = None
        if state_before is not None and state_after is not None:
            grew = state_after.get("scroll_y", -1) > state_before.get("scroll_y", -1)
        out["fixture_scroll_y_grew"] = grew
        out["ok"] = verified and untouched and grew is True
    else:
        out["ok"] = (verified and untouched) or out["unsupported"]
    return out


def electron_verdict(text: str, is_error: bool) -> dict:
    """Observe-only verdict for an Electron app (the isolated policy grants it
    `observe` only). `readable` is the gate; `actionable` is a diagnostic and
    does NOT mean the app can be controlled — real control stays unproven."""

    m = re.search(r"^ax_access: (actionable|readable|unavailable) ", text, re.M)
    access = m.group(1) if m else None
    readable = (not is_error) and access in ("readable", "actionable") and "AX_TREE_UNAVAILABLE" not in text
    return {"access": access, "readable": readable,
            "actionable": (not is_error) and access == "actionable",
            "unavailable": access == "unavailable" or "AX_TREE_UNAVAILABLE" in text,
            "control_proven": False}


TEXT_INPUT_LINE = re.compile(
    r'^\[(\d+)\] (AXTextArea|AXTextField|AXComboBox) "(.*)" \((-?\d+),(-?\d+) (\d+)x(\d+)\)'
    r'.* (settable|not-settable) value=("(?:[^"\\]|\\.)*")$', re.M)


def text_inputs(text: str) -> list:
    """Every text input the observation lists, with settability and value."""

    out = []
    for m in TEXT_INPUT_LINE.finditer(text):
        out.append({"id": int(m.group(1)), "role": m.group(2), "title": m.group(3),
                    "x": int(m.group(4)), "y": int(m.group(5)), "w": int(m.group(6)), "h": int(m.group(7)),
                    "settable": m.group(8) == "settable", "value": json.loads(m.group(9))})
    return out


def pick_composer(text: str):
    """The control to prove control on: a SETTABLE text input — an AXTextArea
    first, then the lowest on screen (a chat composer sits at the bottom).
    None when there is none: that is a capability gap, never a reason to use
    window controls or anything else."""

    settable = [t for t in text_inputs(text) if t["settable"]]
    if not settable:
        return None
    return sorted(settable, key=lambda t: (t["role"] != "AXTextArea", -t["y"]))[0]


def find_same_input(text: str, composer: dict):
    """The same control in a later observation (ids change per snapshot):
    same role and geometry (±4 pt), else same role and title."""

    inputs = [t for t in text_inputs(text) if t["role"] == composer["role"]]
    for t in inputs:
        if all(abs(t[k] - composer[k]) <= 4 for k in ("x", "y", "w", "h")):
            return t
    for t in inputs:
        if t["title"] and t["title"] == composer["title"]:
            return t
    return None


# ── AXPress control proof (Claude Desktop) ───────────────────────────

ELEMENT_LINE = re.compile(r'^\[(\d+)\] (\S+) "(.*)" \((-?\d+),(-?\d+) (\d+)x(\d+)\)(.*)$', re.M)
SETTINGS_LABELS = ("ajustes", "settings", "configuración", "configuracion")
NAV_LABELS = ("cuenta", "account", "general")
CLOSE_LABELS = ("cerrar", "close")
#: Words that a settings view shows and a chat view normally does not.
SETTINGS_MARKERS = ("general", "cuenta", "account", "privacidad", "privacy", "apariencia", "appearance",
                    "perfil", "profile", "facturación", "billing", "capacidades", "capabilities",
                    "conectores", "connectors", "desarrollador", "developer", "extensiones", "extensions",
                    "notificaciones", "notifications")


def elements_of(text: str) -> list:
    """Interactive elements as the adapter rendered them."""

    out = []
    for m in ELEMENT_LINE.finditer(text):
        flags = m.group(8)
        chrome = "window-control" in flags
        out.append({"id": int(m.group(1)), "role": m.group(2), "title": m.group(3),
                    "x": int(m.group(4)), "y": int(m.group(5)), "w": int(m.group(6)), "h": int(m.group(7)),
                    "pressable": flags.startswith(" pressable") and not chrome, "window_chrome": chrome})
    return out


def normalized_label(title: str) -> str:
    return re.sub(r"(\u2026|\.\.\.|:)\s*$", "", (title or "").strip()).strip().casefold()


def pick_labeled(text: str, labels) -> tuple:
    """Exactly ONE pressable, non-window-control element whose title IS one of
    `labels` (exact, normalized), else whose title contains one as a word.
    Returns (element|None, status, matches) with status exact | semantic |
    ambiguous | not_found. Ambiguity is never resolved by guessing."""

    candidates = [e for e in elements_of(text) if e["pressable"] and not e["window_chrome"]]
    labels = tuple(l.casefold() for l in labels)
    exact = [e for e in candidates if normalized_label(e["title"]) in labels]
    if len(exact) > 1:
        preferred = [e for e in exact if e["role"] in ("AXButton", "AXMenuItem")]
        exact = preferred if len(preferred) == 1 else exact
    if len(exact) == 1:
        return exact[0], "exact", exact
    if len(exact) > 1:
        return None, "ambiguous", exact
    semantic = [e for e in candidates if len(e["title"]) <= 40 and any(
        re.search(r"(^|\W)%s(\W|$)" % re.escape(l), normalized_label(e["title"])) for l in labels)]
    if len(semantic) == 1:
        return semantic[0], "semantic", semantic
    return None, ("ambiguous" if semantic else "not_found"), semantic


def settings_markers(text: str) -> set:
    """Settings-view words present as element titles or readable content."""

    found = set()
    for line in text.splitlines():
        m = re.match(r'^(?:\[\d+\] \S+|- \S+) "(.*?)"', line)
        if not m:
            continue
        label = normalized_label(m.group(1))
        for marker in SETTINGS_MARKERS:
            if re.search(r"(^|\W)%s(\W|$)" % re.escape(marker), label):
                found.add(marker)
    return found


def view_lines(text: str) -> set:
    """Readable content and element titles: the fingerprint of what is shown."""

    lines = set()
    for line in text.splitlines():
        m = re.match(r'^(?:\[\d+\] (\S+)|- (\S+)) "(.*?)"', line)
        if m:
            lines.add(((m.group(1) or m.group(2)), m.group(3)))
    return lines


def settings_opened(before: str, after: str) -> dict:
    """Did the press open a settings view? Two NEW settings markers, or a
    window title that now names settings."""

    new = settings_markers(after) - settings_markers(before)
    window = re.search(r'"window":"([^"]*)"', after)
    window_says = bool(window) and any(l in window.group(1).casefold() for l in SETTINGS_LABELS)
    return {"new_markers": sorted(new), "window_title_says_settings": window_says,
            "opened": len(new) >= 2 or window_says}


def panel_changed(before: str, after: str, minimum: int = 3) -> dict:
    changed = view_lines(before) ^ view_lines(after)
    return {"changed_lines": len(changed), "changed": len(changed) >= minimum}


def environment_quiet(rows, now: float, person_bundle: str, tail: float = TAIL,
                      min_samples: int = 50, threshold: float = 0.5) -> dict:
    """Precondition before touching Claude: over the last `tail` seconds the
    INDEPENDENT witness saw the person's app in front the whole time, enough
    samples, and a still cursor. Not satisfied -> do not operate Claude."""

    window = [r for r in rows if now - tail <= r["t"] <= now]
    facts = {"samples": len(window), "person": person_bundle,
             "fronts": sorted({r.get("front", "") for r in window}),
             "tops": sorted({r.get("top", "") for r in window})}
    if len(window) < min_samples:
        return dict(facts, ok=False, reason="witness_samples_insufficient")
    if any(r.get("front") != person_bundle for r in window):
        return dict(facts, ok=False, reason="frontmost_not_person")
    ref = window[0]
    delta = max(abs(r["x"] - ref["x"]) + abs(r["y"] - ref["y"]) for r in window)
    facts["cursor_delta"] = delta
    if delta > threshold:
        return dict(facts, ok=False, reason="cursor_moving")
    return dict(facts, ok=True, reason=None)


def read_monitor(path: str) -> list:
    rows = []
    try:
        for line in pathlib.Path(path).read_text().splitlines():
            try:
                rows.append(json.loads(line))
            except ValueError:
                pass  # a line being written
    except OSError:
        pass
    return rows


def wait_for_quiet_environment(monitor_path: str, person_bundle: str, attempts: int = 3) -> dict:
    """Wait (bounded) for one full quiet TAIL window; report every attempt."""

    tries = []
    for _ in range(attempts):
        time.sleep(TAIL)
        verdict = environment_quiet(read_monitor(monitor_path), uptime(), person_bundle)
        tries.append(verdict)
        if verdict["ok"]:
            break
    return {"ok": tries[-1]["ok"], "reason": None if tries[-1]["ok"] else "environment_not_quiet",
            "attempts": tries}


def run_press_control(d, app: str) -> dict:
    """Prove control of `app` with reversible, non-destructive AXPresses through
    computer_use_* only: open Settings, prove it by AX content, optionally
    switch to another settings tab and prove the panel changed, optionally
    close Settings again. No preference is ever changed: only navigation
    controls are pressed. Every step is quiet and judged against `app`."""

    out = {"attempted": False, "reason": None, "steps": [], "presses": []}

    def call(step, tool, args):
        out["steps"].append(step)
        return d.call(step, tool, args, quiet=True, target=app)

    def press(step, element, snapshot_text):
        text, err = call(step, "computer_use_press",
                         {"element_id": element["id"], "snapshot": snapshot_of(snapshot_text)})
        record = {"step": step, "role": element["role"], "title": element["title"], "ok": not err,
                  "untouched": "verdict=untouched" in text, "breach": "INTERFERENCE_BREACH" in text}
        out["presses"].append(record)
        out["breach"] = out.get("breach") or record["breach"]
        return record

    # 1. Find Settings: unfiltered first (40-element cut), then by label.
    base, err = call("P1 observe", "computer_use_observe", {"app": app})
    if err or "(background)" not in base:
        out["reason"] = "observe_failed_or_not_background"
        return out
    found, status, matches, source = None, "not_found", [], base
    for label in ("Ajustes", "Settings", "Configuración"):
        text, err = call("P1 find %s" % label, "computer_use_observe", {"app": app, "filter": label})
        found, status, matches = pick_labeled(text, SETTINGS_LABELS)
        if found or status == "ambiguous":
            source = text
            break
    out["settings_match"] = {"status": status, "matches": [{k: m[k] for k in ("role", "title")} for m in matches]}
    if not found:
        out["reason"] = "settings_control_%s" % status
        return out
    out["attempted"] = True
    out["settings_element"] = {k: found[k] for k in ("role", "title")}
    first = press("P2 press Settings", found, source)
    if not first["ok"] or first["breach"]:
        out["reason"] = "breach_stop" if first["breach"] else "press_failed"
        return out
    after, _ = call("P3 re-observe (settings)", "computer_use_observe", {"app": app, "ax_diagnostics": True})
    out["settings_evidence"] = settings_opened(base, after)
    out["settings_opened"] = out["settings_evidence"]["opened"]
    if not out["settings_opened"]:
        out["reason"] = "settings_not_observed"
        return out

    # 2. Optional internal navigation (never a preference toggle).
    for label in ("Cuenta", "Account", "General"):
        text, _ = call("P4 find %s" % label, "computer_use_observe", {"app": app, "filter": label})
        tab, tab_status, _ = pick_labeled(text, (label,))
        if tab:
            record = press("P5 press %s" % label, tab, text)
            if record["breach"]:
                out["reason"] = "breach_stop"
                return out
            later, _ = call("P6 re-observe (%s)" % label, "computer_use_observe", {"app": app})
            out["navigation"] = dict(panel_changed(after, later), label=label, pressed_ok=record["ok"])
            after = later
            break
    else:
        out["navigation"] = {"label": None, "changed": None, "reason": "no_unambiguous_tab"}

    # 3. Optional: close Settings again (an in-window close, never a window control).
    text, _ = call("P7 find close", "computer_use_observe", {"app": app, "filter": "Cerrar"})
    close, _, _ = pick_labeled(text, CLOSE_LABELS)
    if close is None:
        text, _ = call("P7 find close (en)", "computer_use_observe", {"app": app, "filter": "Close"})
        close, _, _ = pick_labeled(text, CLOSE_LABELS)
    if close:
        record = press("P8 press close", close, text)
        if record["breach"]:
            out["reason"] = "breach_stop"
            return out
        final, _ = call("P9 re-observe (closed)", "computer_use_observe", {"app": app})
        out["closed"] = record["ok"] and not settings_opened(base, final)["opened"]
    else:
        out["closed"] = None  # Settings left open: harmless, reported
    return out


def control_claims(observe: dict, control: dict, witness_ok_for_control,
                   press: dict = None, witness_ok_for_press=None, environment: dict = None) -> dict:
    """The claims, kept apart and never inferred from one another.

    observe_proven                     the window is readable (observe-only gate)
    actionable                         the helper reports a real control
    press_control_proven               an AXPress opened Settings, PROVEN by AX content
                                       on re-observation, every press untouched
    set_value_control_proven           (optional composer test) a test text set,
                                       verified twice and restored
    control_proven                     press_control_proven OR set_value_control_proven
    background_noninterference_proven  for every Claude control step: environment
                                       quiet beforehand, witness quiet (no activation,
                                       no raise, cursor <= 0.5), ledger untouched, no breach
    """

    control = control or {}
    press = press or {}
    env_ok = None if environment is None else environment.get("ok") is True

    composer_attempted = bool(control.get("attempted"))
    composer_quiet = None
    if composer_attempted:
        composer_quiet = bool(witness_ok_for_control) and control.get("set_untouched") is True \
            and control.get("restore_untouched") is True and not control.get("breach")
    set_proven = composer_attempted and composer_quiet is True and all(control.get(k) is True for k in (
        "set_verified", "observed_changed", "restore_verified", "observed_restored"))

    press_attempted = bool(press.get("attempted"))
    press_quiet = None
    if press_attempted:
        presses = press.get("presses") or []
        press_quiet = bool(witness_ok_for_press) and bool(presses) and not press.get("breach") \
            and all(p.get("untouched") for p in presses)
    press_proven = press_attempted and press_quiet is True and press.get("settings_opened") is True \
        and bool(press.get("presses")) and press["presses"][0].get("ok") is True

    attempted_quiet = [q for q in (press_quiet, composer_quiet) if q is not None]
    noninterference = None
    if attempted_quiet:
        noninterference = all(attempted_quiet) and env_ok is not False
    proven = press_proven or set_proven
    reason = None
    if not proven:
        if env_ok is False:
            reason = "environment_not_quiet"
        else:
            reason = press.get("reason") or control.get("reason") or (
                "not_attempted" if not (press_attempted or composer_attempted) else "checks_failed")
    return {
        "observe_proven": observe.get("readable") is True,
        "actionable": observe.get("actionable") is True,
        "press_control_proven": press_proven,
        "set_value_control_proven": set_proven,
        "control_proven": proven,
        "background_noninterference_proven": noninterference,
        "control_unproven_reason": reason,
    }


def run_electron_control(d, app: str, token: str) -> dict:
    """Reversible, non-destructive control of a text input in `app`, through
    computer_use_* only: set a test text WITHOUT sending it, verify, restore.
    Every step is quiet and judged against `app` by the witness. A composer
    that already holds text is never touched (it may be the person's draft)."""

    out = {"attempted": False, "reason": None, "steps": []}

    def call(step, tool, args):
        out["steps"].append(step)
        return d.call(step, tool, args, quiet=True, target=app)

    text, err = call("E1 electron observe (diagnostics)", "computer_use_observe", {"app": app, "ax_diagnostics": True})
    m = re.search(r"^ax_access: (actionable|readable|unavailable) ", text, re.M)
    out["access"] = m.group(1) if m else None
    out["actionable"] = out["access"] == "actionable"
    out["text_inputs"] = text_inputs(text)
    if err or "(background)" not in text:
        out["reason"] = "observe_failed_or_not_background"
        return out
    composer = pick_composer(text)
    if composer is None:
        out["reason"] = "no_settable_text_input"
        return out
    out["composer"] = {k: composer[k] for k in ("role", "title", "x", "y", "w", "h")}
    if composer["value"] != "":
        out["reason"] = "composer_not_empty"
        return out
    out["attempted"] = True
    text2, err2 = call("E2 set test text (not sent)", "computer_use_set_value",
                       {"element_id": composer["id"], "text": token, "snapshot": snapshot_of(text)})
    out["breach"] = "INTERFERENCE_BREACH" in text2
    out["set_verified"] = (not err2) and "set_value: check=verified" in text2
    out["set_untouched"] = "verdict=untouched" in text2
    if not out["set_verified"]:
        out["reason"] = "breach_stop" if out["breach"] else (
            "value_not_settable" if "reason=value_not_settable" in text2 else "set_not_verified")
        return out
    text3, _ = call("E3 re-observe (changed)", "computer_use_observe", {"app": app})
    again = find_same_input(text3, composer)
    out["observed_changed"] = bool(again) and token in again["value"]
    if not again:
        out["reason"] = "composer_lost"
        return out
    text4, err4 = call("E4 restore (empty)", "computer_use_set_value",
                       {"element_id": again["id"], "text": "", "snapshot": snapshot_of(text3)})
    out["breach"] = out["breach"] or "INTERFERENCE_BREACH" in text4
    out["restore_verified"] = (not err4) and "set_value: check=verified" in text4
    out["restore_untouched"] = "verdict=untouched" in text4
    text5, _ = call("E5 re-observe (restored)", "computer_use_observe", {"app": app})
    final = find_same_input(text5, composer)
    out["observed_restored"] = bool(final) and final["value"] == ""
    if not out["observed_restored"]:
        out["reason"] = "not_restored"
    return out


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
        bundle = step.get("target") or target_bundle
        target_front = any(r["front"] == bundle for r in window)
        target_top = any(r["top"] == bundle for r in window) and (ref is None or ref["top"] != bundle)
        verdicts.append({
            "step": step["step"], "samples": len(window), "fronts": fronts, "tops": tops,
            "cursor_max_delta": moved, "target_front": target_front, "target_top": target_top,
            "person_front_throughout": all(r["front"] == person_bundle for r in window) if window else None,
        })
    return verdicts


def helper_ledger(text: str) -> dict:
    """The helper's own interference facts for one step, as printed."""

    facts = {}
    for key in ("verdict", "cursor_moved", "cursor_events_posted", "cursor_moved_by_action",
                "focus_became_target", "external_activity", "transient_cursor_max_delta", "sampled"):
        m = re.search(r"(?:^|[ :])%s=([^\s]+)" % key, text, re.M)
        if m:
            facts[key] = m.group(1)
    return facts


def cursor_motion(steps, rows, threshold: float = 0.5) -> list:
    """WHICH step moved the cursor, and WHEN — diagnosis only, never a verdict.

    For every step whose witness window (call + TAIL) saw the cursor move:
    when it first moved relative to the call (`during_call` vs `tail`), how
    far, how many samples moved, which OTHER steps' calls overlap the moving
    samples (a tail overlaps the next call), and what the helper's ledger said
    for that call. The quiet gate itself is unchanged.
    """

    out = []
    for index, step in enumerate(steps):
        window = [r for r in rows if step["start"] - 0.05 <= r["t"] <= step["end"] + TAIL]
        before = [r for r in rows if r["t"] < step["start"]]
        ref = before[-1] if before else (window[0] if window else None)
        if not ref:
            continue
        moving = [r for r in window if abs(r["x"] - ref["x"]) + abs(r["y"] - ref["y"]) > threshold]
        if not moving:
            continue
        first, peak = moving[0], max(moving, key=lambda r: abs(r["x"] - ref["x"]) + abs(r["y"] - ref["y"]))

        def phase(t):
            return "during_call" if t <= step["end"] else "tail"

        overlapping = sorted({other["step"] for j, other in enumerate(steps) if j != index
                              and any(other["start"] <= r["t"] <= other["end"] for r in moving)})
        out.append({
            "step": step["step"],
            "first_move_ms": round((first["t"] - step["start"]) * 1000),
            "first_move_phase": phase(first["t"]),
            "peak_delta": round(abs(peak["x"] - ref["x"]) + abs(peak["y"] - ref["y"]), 1),
            "peak_phase": phase(peak["t"]),
            "moving_samples": len(moving),
            "during_call_samples": sum(1 for r in moving if r["t"] <= step["end"]),
            "from": [ref["x"], ref["y"]],
            "to": [moving[-1]["x"], moving[-1]["y"]],
            "overlaps_calls_of": overlapping,
            "helper_ledger": helper_ledger(step.get("text", "")),
        })
    return out


def describe_cursor_motion(item: dict) -> str:
    ledger = item["helper_ledger"]
    return ("CURSOR moved around step '%s': peak %.0fpt (%s), first move %+dms (%s), "
            "%d moving samples (%d during the call), overlaps calls of %s; helper ledger: "
            "cursor_events_posted=%s cursor_moved_by_action=%s external_activity=%s "
            "transient_cursor_max_delta=%s" % (
                item["step"], item["peak_delta"], item["peak_phase"], item["first_move_ms"],
                item["first_move_phase"], item["moving_samples"], item["during_call_samples"],
                item["overlaps_calls_of"] or "no other step",
                ledger.get("cursor_events_posted"), ledger.get("cursor_moved_by_action"),
                ledger.get("external_activity"), ledger.get("transient_cursor_max_delta")))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", default=default_socket_path())
    parser.add_argument("--app", default=FIXTURE, help="bundle id of the authorized target")
    parser.add_argument("--press-title", default="Incrementar")
    parser.add_argument("--fixture-state", default=os.environ.get("CMM_CU_FIXTURE_STATE", ""))
    parser.add_argument("--electron-app", default="", help="e.g. com.anthropic.claudefordesktop")
    parser.add_argument("--breach-control", action="store_true",
                        help="press the fixture's self-activating button (latches the fixture until CMM Console rearms it)")
    parser.add_argument("--electron-control", action="store_true",
                        help="with --electron-app: prove control with reversible AXPresses (open Settings, "
                             "prove it by AX content, optionally switch tab and close); needs `control`")
    parser.add_argument("--electron-composer-test", action="store_true",
                        help="also run the optional composer set_value test (diagnostic)")
    parser.add_argument("--person-app", default="com.apple.Terminal",
                        help="the app that must stay in front during the Claude control steps")
    parser.add_argument("--monitor", required=True, help="JSONL written by focus-monitor")
    parser.add_argument("--report", required=True)
    args = parser.parse_args()

    # `lsappinfo info … front` is not accepted as a specifier on every macOS:
    # resolve the front ASN first, then ask for its bundle id.
    front_asn = subprocess.run(["lsappinfo", "front"], capture_output=True, text=True).stdout.strip()
    person_info = subprocess.run(["lsappinfo", "info", "-only", "bundleid", front_asn or "front"],
                                 capture_output=True, text=True).stdout

    d = Driver(args.socket)
    checks = {}
    # Facts reported next to the checks; they never decide PASS/FAIL.
    diagnostics = {}

    text, err = d.call("1 status", "computer_use_status")
    checks["status"] = (not err) and "effective_mode: background" in text and "- authorized:" in text

    text, err = d.call("2 observe", "computer_use_observe", {"app": args.app})
    first_observe = text
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
        time.sleep(0.3)
        state_after = fixture_state(args.fixture_state) if args.fixture_state else None
        verdict = scroll_verdict(text, err, args.app == FIXTURE, state_before, state_after)
        diagnostics["scroll"] = verdict
        checks["scroll"] = verdict["ok"]
        if args.app == FIXTURE:
            checks["scroll_verified_by_helper"] = verdict["verified"]
            checks["scroll_effect"] = verdict["fixture_scroll_y_grew"] is True
    else:
        # The fixture always has a scroll area: not finding one is a failure there.
        checks["scroll"] = False if args.app == FIXTURE else None

    environment = None
    if args.electron_app and args.electron_control:
        # Precondition BEFORE the first Claude step: the person's app in front,
        # a still cursor, a stable witness for a full TAIL. Otherwise nothing
        # in Claude is operated (and the run says why).
        environment = wait_for_quiet_environment(args.monitor, args.person_app)
        diagnostics["electron_environment"] = environment
        checks["electron_control_environment_quiet"] = environment["ok"]
        if not environment["ok"]:
            print("!! environment_not_quiet before Claude: %s — Claude will not be operated"
                  % environment["attempts"][-1].get("reason"))

    if args.electron_app:
        text, err = d.call("7 electron observe", "computer_use_observe", {"app": args.electron_app},
                           target=args.electron_app)
        verdict = electron_verdict(text, err)
        checks["electron_observe_readable"] = verdict["readable"]
        # Diagnostic only: an actionable tree is not proof of control.
        diagnostics["electron"] = verdict
    electron_observe = verdict if args.electron_app else {}
    control = {"attempted": False, "reason": "not_requested"}
    press_control = {"attempted": False, "reason": "not_requested"}
    if args.electron_app and args.electron_control and environment and environment["ok"]:
        press_control = run_press_control(d, args.electron_app)
        diagnostics["electron_press_control"] = press_control
        checks["electron_control_no_breach"] = not press_control.get("breach")
    elif args.electron_app and args.electron_control:
        press_control = {"attempted": False, "reason": "environment_not_quiet"}
    if args.electron_app and args.electron_composer_test and environment and environment["ok"] \
            and not press_control.get("breach"):
        token = "CMM-CU control test - not sent %d" % int(time.time())
        control = run_electron_control(d, args.electron_app, token)
        diagnostics["electron_control"] = control
        if control.get("access"):
            electron_observe = dict(electron_observe, actionable=control["access"] == "actionable")
        # Safety gates (the claim itself may honestly stay unproven):
        checks["electron_control_no_breach"] = checks.get("electron_control_no_breach", True) \
            and not control.get("breach")
        if control.get("attempted") and control.get("set_verified"):
            # A verified test text MUST be gone again: never leave it behind.
            checks["electron_control_restored"] = control.get("restore_verified") is True \
                and control.get("observed_restored") is True
            if not checks["electron_control_restored"]:
                print("!! the test text may still be in %s's composer: clear it by hand" % args.electron_app)

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
    person_bundle, person_source, person_sources = person_frontmost(person_info, rows, first_observe)
    diagnostics["person_frontmost"] = {"bundle": person_bundle, "source": person_source,
                                       "sources": person_sources, "front_asn": front_asn}
    print("person's frontmost app: %s (source=%s; lsappinfo=%r witness=%r helper=%r)" % (
        person_bundle or "UNKNOWN", person_source, person_sources["lsappinfo"],
        person_sources["witness"], person_sources["helper_observe"]))
    verdicts = judge(d.steps, rows, args.app, person_bundle)
    # No later call may start inside a quiet step's witness window.
    overlaps = witness_window_overlaps(d.steps)
    checks["witness_windows_disjoint"] = not overlaps
    if overlaps:
        diagnostics["witness_window_overlap"] = overlaps
        for item in overlaps:
            print("witness_window_overlap: call '%s' started %d ms inside the tail of quiet step '%s'"
                  % (item["next_call"], item["overlap_ms"], item["quiet_step"]))
    quiet_ok = True
    for step, v in zip(d.steps, verdicts):
        if step["quiet"]:
            ok = quiet_step_ok(v)
            v["ok"] = ok
            quiet_ok &= ok
        elif step["step"] == "9 breach control":
            # The controlled breach: the independent witness must have seen it
            # too, or the ledger and reality disagree.
            v["ok"] = v["target_front"] or v["target_top"]
            checks["witness_saw_breach"] = v["ok"]
    checks["witness_quiet"] = quiet_ok
    def witness_ok_for(steps):
        names = set(steps or [])
        return all(v.get("ok") for st, v in zip(d.steps, verdicts) if st["step"] in names) if names else None

    claims = control_claims(electron_observe, control, witness_ok_for(control.get("steps")),
                            press=press_control, witness_ok_for_press=witness_ok_for(press_control.get("steps")),
                            environment=environment) if args.electron_app else None
    # Diagnosis of any cursor movement the witness saw: which step, when, and
    # what the helper's own ledger said. It explains the gate; it never
    # changes it, and external activity is never turned into a PASS.
    motion = cursor_motion(d.steps, rows)
    if motion:
        diagnostics["cursor_motion"] = motion
        for item in motion:
            print(describe_cursor_motion(item))

    report = {"person_bundle": person_bundle, "target": args.app, "checks": checks,
              "claims": claims,
              "diagnostics": diagnostics,
              "witness": verdicts, "steps": d.steps}
    pathlib.Path(args.report).write_text(json.dumps(report, indent=2, ensure_ascii=False))
    print("\n══ checks")
    failed = False
    for key, value in checks.items():
        print("  %-22s %s" % (key, "PASS" if value is True else ("n/a" if value is None else "FAIL")))
        failed |= value is False
    if claims is not None:
        print("══ claims (%s)" % args.electron_app)
        for key, value in claims.items():
            print("  %-34s %s" % (key, value))
    if diagnostics:
        print("══ diagnostics (never decide PASS/FAIL)")
        for key, value in diagnostics.items():
            print("  %-22s %s" % (key, json.dumps(value, ensure_ascii=False)[:300]))
    print("report: %s" % args.report)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
