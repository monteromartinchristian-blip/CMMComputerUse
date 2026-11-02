"""Pure helpers for the isolated live lane (scripts/verification/isolated-live.py).

No subprocess, no socket, no macOS: everything here is testable anywhere
(scripts/verification/tests/test_isolated_live.py). The orchestrator does the
I/O and calls these to decide.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
from typing import Any, Dict, List, Optional, Tuple

PROBE_IDENTIFIER = "com.cmm.computer-use.test-rearm"
PROBE_CLIENT_ID = "test-rearm"
DRIVER_CLIENT_ID = "live-agent"
HELPER_BUNDLE_ID = "com.cmm.chat.computer-use"
FIXTURE_BUNDLE_ID = "com.example.computer-use-fixture"
MARKER = ".cmm-isolated-live"
LAUNCH_AGENT_LABEL = "com.cmm.chat.computer-use"

# Seeded breaches for the rearm-authority checks. Fake targets: nothing real is
# latched by the seed, so the LIVE steps on the fixture are unaffected.
SEED_SELF_ID = "seed-self-0000"
SEED_OTHER_ID = "seed-other-0000"


# ── code signatures and requirements ─────────────────────────────────

def codesign_text(stdout: Optional[str], stderr: Optional[str]) -> str:
    """Everything `codesign -d …` printed, whichever channel it used.

    `codesign -d` writes its display (Executable=, Identifier=, …) on stderr,
    and `-r-` writes the requirement to the named file `-` (stdout) — but that
    split is an implementation detail that has differed between releases. Both
    parsers below look for anchored `key=` / `designated =>` lines, so reading
    the two channels together can never lose a line nor invent one.
    """

    return (stdout or "") + "\n" + (stderr or "")


def parse_codesign_display(text: str) -> Dict[str, Any]:
    """Facts from `codesign -d --verbose=4 <path>` (it prints on stderr)."""

    def field(name: str) -> Optional[str]:
        m = re.search(r"^%s=(.*)$" % re.escape(name), text, re.M)
        return m.group(1).strip() if m else None

    team = field("TeamIdentifier")
    if team in (None, "", "not set"):
        team = None
    return {
        "identifier": field("Identifier"),
        "team_id": team,
        "cdhash": (field("CDHash") or "").lower() or None,
        "authorities": re.findall(r"^Authority=(.*)$", text, re.M),
        "adhoc": bool(re.search(r"^Signature=adhoc$", text, re.M)),
    }


def compose_requirement(facts: Dict[str, Any]) -> str:
    """An EXACT designated requirement: identifier + signer + cdhash.

    No wildcard and no identifier-only requirement: the cdhash pins this very
    binary, the anchor/team pins who signed it. Raises when the facts cannot
    support an exact requirement.
    """

    identifier = facts.get("identifier")
    cdhash = facts.get("cdhash")
    if not identifier or not re.fullmatch(r"[A-Za-z0-9._-]+", identifier):
        raise ValueError("no usable signing identifier")
    if not cdhash or not re.fullmatch(r"[0-9a-f]{40}", cdhash):
        raise ValueError("no usable cdhash")
    parts = ['identifier "%s"' % identifier]
    team = facts.get("team_id")
    if team:
        if not re.fullmatch(r"[A-Z0-9]{10}", team):
            raise ValueError("unexpected team identifier")
        parts.append("anchor apple generic")
        parts.append('certificate leaf[subject.OU] = "%s"' % team)
    elif "Software Signing" in (facts.get("authorities") or []):
        parts.append("anchor apple")  # Apple platform binary (e.g. python3)
    elif not facts.get("adhoc"):
        raise ValueError("signed by an unknown authority")
    parts.append('cdhash H"%s"' % cdhash)
    return " and ".join(parts)


#: One whole line: optional indentation, an optional `#` (codesign prints an
#: IMPLICIT designated requirement — e.g. the cdhash of ad-hoc code — commented
#: out), then `designated =>` and a non-empty requirement. `[ \t]` rather than
#: `\s` so the anchor can never run across a newline.
_DESIGNATED = re.compile(r"^[ \t]*#?[ \t]*designated[ \t]*=>[ \t]*(\S.*?)[ \t]*$", re.M)


def designated_requirement(text: str) -> Optional[str]:
    """`codesign -d -r- <path>` output → the designated requirement text,
    explicit (`designated => …`) or implicit (`# designated => …`)."""

    m = _DESIGNATED.search(text)
    return m.group(1) if m else None


# ── temporary policy and seeded latch ────────────────────────────────

def build_policy(
    probe_requirement: str,
    driver_requirement: Optional[str],
    probe_admin: bool,
    electron_bundle: str = "",
    electron_control: bool = False,
) -> Dict[str, Any]:
    """The isolated policy. The probe has NO apps and NO scopes; only `admin`
    when the step asks for it. The driver (stand-in for an agent) never has
    `admin`."""

    probe: Dict[str, Any] = {
        "client_id": PROBE_CLIENT_ID,
        "requirement": probe_requirement,
        "apps": [],
        "scopes": [],
    }
    if probe_admin:
        probe["admin"] = ["breach.rearm"]
    clients = [probe]
    apps: List[Dict[str, Any]] = [
        {"bundle_id": FIXTURE_BUNDLE_ID, "scopes": ["observe", "control"]},
    ]
    driver_apps = [FIXTURE_BUNDLE_ID]
    if electron_bundle:
        # Observe only, unless the run explicitly asks for the reversible
        # control test (`--electron-control`); only then, and only in this
        # temporary policy, does the Electron app get `control`.
        scopes = ["observe", "control"] if electron_control else ["observe"]
        apps.append({"bundle_id": electron_bundle, "scopes": scopes})
        driver_apps.append(electron_bundle)
    if driver_requirement:
        clients.append({
            "client_id": DRIVER_CLIENT_ID,
            "requirement": driver_requirement,
            "apps": driver_apps,
            "scopes": ["observe", "control"],
        })
    return {"version": 2, "mode": "background", "default": "deny",
            "clients": clients, "apps": apps}


def seeded_latch(now: float) -> Dict[str, Any]:
    def record(rid: str, target: str, client: str) -> Dict[str, Any]:
        return {"id": rid, "target_bundle": target, "target_name": "Seeded (%s)" % client,
                "client_id": client, "kind": "ui.press", "policy": "background", "at": now,
                "verdict": "focus_changed", "focus_became_target": True,
                "window_raised_over_person": False}
    return {"version": 1, "breaches": [
        record(SEED_SELF_ID, "com.example.seeded.self", PROBE_CLIENT_ID),
        record(SEED_OTHER_ID, "com.example.seeded.other", DRIVER_CLIENT_ID),
    ]}


# ── isolation guards ─────────────────────────────────────────────────

def production_paths(home: str) -> Dict[str, str]:
    return {
        "support_dir": os.path.join(home, ".cmm", "computer-bridge"),
        "policy": os.path.join(home, ".cmm", "computer-bridge", "policy.json"),
        "socket": os.path.join(home, ".cmm", "computer-bridge", "bridge.sock"),
        "launch_agent": os.path.join(home, "Library", "LaunchAgents", LAUNCH_AGENT_LABEL + ".plist"),
        "installed_app": os.path.join(home, "Applications", "CMMComputerUse.app"),
    }


def assert_isolated(path: str, home: str) -> str:
    """Resolve `path` and refuse anything that is, or is inside, a production
    location. Returns the resolved path."""

    resolved = os.path.realpath(path)
    forbidden = [os.path.realpath(p) for p in production_paths(home).values()]
    forbidden.append(os.path.realpath(os.path.join(home, "Library", "LaunchAgents")))
    for blocked in forbidden:
        if resolved == blocked or resolved.startswith(blocked.rstrip(os.sep) + os.sep):
            raise RuntimeError("refusing a production path: %s" % resolved)
        if blocked.startswith(resolved.rstrip(os.sep) + os.sep):
            raise RuntimeError("refusing a directory that contains production state: %s" % resolved)
    return resolved


# ── production snapshot / diff ───────────────────────────────────────

def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def diff_snapshots(before: Dict[str, Any], after: Dict[str, Any], prefix: str = "") -> List[str]:
    """Every difference between two JSON-like snapshots, as readable lines."""

    out: List[str] = []
    if isinstance(before, dict) and isinstance(after, dict):
        for key in sorted(set(before) | set(after)):
            name = prefix + "/" + str(key) if prefix else str(key)
            if key not in before:
                out.append("added   %s = %s" % (name, json.dumps(after[key], sort_keys=True)[:200]))
            elif key not in after:
                out.append("removed %s" % name)
            else:
                out.extend(diff_snapshots(before[key], after[key], name))
        return out
    if before != after:
        out.append("changed %s: %s -> %s" % (
            prefix, json.dumps(before, sort_keys=True)[:200], json.dumps(after, sort_keys=True)[:200]))
    return out


# ── LaunchServices: its own gate, not part of the strict diff ────────

#: Lane directories, as LaunchServices records them (realpath) or as typed.
LANE_PREFIXES = ("/private/tmp/cmm-cu-isolated-", "/tmp/cmm-cu-isolated-")


def classify_launchservices_path(path: str, home: str, repo: str) -> str:
    """canonical | lane | build | other, for one registered bundle path.

    `build` is non-production output that registers itself when built or
    opened: `<repo>/build/stage-*` and Xcode DerivedData. Anything else that
    is neither canonical nor ours is `other`, and stays strict.
    """

    norm = os.path.normpath(path)
    if norm == os.path.normpath(production_paths(home)["installed_app"]):
        return "canonical"
    if norm.startswith(LANE_PREFIXES):
        return "lane"
    stage_root = os.path.join(os.path.normpath(repo), "build") + os.sep
    if norm.startswith(stage_root) and norm[len(stage_root):].startswith("stage-"):
        return "build"
    derived = os.path.join(home, "Library", "Developer", "Xcode", "DerivedData") + os.sep
    if norm.startswith(derived):
        return "build"
    return "other"


def launchservices_verdict(
    before: Any, after: Any, home: str, repo: str
) -> Tuple[List[str], List[str]]:
    """(failures, diagnostics) for the LaunchServices registrations.

    Invariants:
      1. the canonical installed path is registered before AND after;
      2. no lane path survives the teardown;
      3. build paths (stage-*, DerivedData) appearing/disappearing is drift,
         reported, never a failure;
      -  any other path appearing or disappearing is a failure.
    """

    failures: List[str] = []
    diagnostics: List[str] = []
    if not isinstance(before, list) or not isinstance(after, list):
        failures.append("launchservices unreadable: before=%r after=%r" % (
            before if not isinstance(before, list) else "ok", after if not isinstance(after, list) else "ok"))
        return failures, diagnostics
    canonical = os.path.normpath(production_paths(home)["installed_app"])
    norm_before = {os.path.normpath(p) for p in before}
    norm_after = {os.path.normpath(p) for p in after}
    if canonical not in norm_before:
        failures.append("canonical %s was not registered BEFORE" % canonical)
    if canonical not in norm_after:
        failures.append("canonical %s is not registered AFTER" % canonical)
    for path in sorted(norm_after):
        if classify_launchservices_path(path, home, repo) == "lane":
            failures.append("lane path survived the teardown: %s" % path)
    for path in sorted(norm_after - norm_before):
        kind = classify_launchservices_path(path, home, repo)
        if kind == "build":
            diagnostics.append("drift (non-production build) added:   %s" % path)
        elif kind == "other":
            failures.append("unexpected registration added: %s" % path)
    for path in sorted(norm_before - norm_after):
        kind = classify_launchservices_path(path, home, repo)
        if kind in ("build", "lane"):
            diagnostics.append("drift (non-production %s) removed: %s" % (kind, path))
        elif kind == "other":
            failures.append("unexpected registration removed: %s" % path)
    return failures, diagnostics


def diff_file_text(failures: List[str]) -> str:
    """Contents of production-diff.txt: one line per failure with a final
    newline, and EXACTLY empty (0 bytes) when there is none, so "empty file"
    means "no difference" to any wrapper."""

    text = "\n".join(failures)
    return text + "\n" if text else ""


def launchctl_facts(text: str) -> Dict[str, Any]:
    """Stable facts from `launchctl print gui/<uid>/<label>`; volatile counters
    are left out on purpose, the pid and arguments are kept."""

    def first(pattern: str) -> Optional[str]:
        m = re.search(pattern, text, re.M)
        return m.group(1).strip() if m else None

    arguments = re.search(r"^\s*arguments = \{\n(.*?)^\s*\}", text, re.M | re.S)
    return {
        "loaded": bool(text.strip()),
        "state": first(r"^\s*state = (.*)$"),
        "pid": first(r"^\s*pid = (\d+)$"),
        "program": first(r"^\s*program = (.*)$"),
        "arguments": [line.strip() for line in arguments.group(1).splitlines()] if arguments else [],
    }


def tcc_ready(permissions: Dict[str, Any]) -> Tuple[bool, str]:
    ax = permissions.get("accessibility") is True
    sc = permissions.get("screen_recording") is True
    return ax and sc, "accessibility=%s screen_recording=%s" % (ax, sc)
