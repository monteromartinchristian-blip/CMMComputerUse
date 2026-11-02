#!/usr/bin/env python3
"""Isolated live lane for CMM Computer Use (macOS only).

A SECOND instance of the helper, launched through LaunchServices from a copy of
the staged, signed build, serving a temporary socket with a temporary policy.
Socket, policy, breach latch, audit, logs, fixture and reports all live in one
exclusive directory under /tmp. Production is snapshotted first and compared
byte-for-byte and config-for-config at the end.

It never touches: ~/.cmm/computer-bridge (policy, socket, logs), the
LaunchAgent, the installed helper, TCC (no tccutil, no permission request, the
helper runs with --no-permission-bootstrap).

Phases (each a gate; `all` runs them in order and ALWAYS tears down):

  prepare          snapshot production; copy the staged helper; build and sign
                   the rearm probe; exact requirement; seeded latch; policy
  start            launch the isolated instance via `open -n -g -a`; identify
                   the driver; write the full policy; reload
  verify-tcc       prove the instance holds Accessibility + Screen Recording
                   and is attributed to the app bundle (functional AX + SCK)
  rearm-tests      without admin -> refused; self-rearm -> refused; rearm with
                   reason -> ok; probe refuses other operations / empty reason
  live             live-background-e2e.sh against the isolated socket; the
                   controlled breach is its LAST step
  after-breach     restart the instance: the latch persists; the agent cannot
                   rearm; the probe rearms with a reason
  teardown         stop ONLY the isolated instance + fixture; unregister the
                   temporary bundles; keep evidence under build/
  verify-production  diff production against the snapshot from `prepare`

  scripts/verification/isolated-live.py all --staged-app build/stage-20261102/CMMComputerUse.app \
      [--electron-app com.anthropic.claudefordesktop]
  scripts/verification/isolated-live.py <phase> --work /tmp/cmm-cu-isolated-XXXX
"""

from __future__ import annotations

import argparse
import ctypes
import json
import os
import pathlib
import platform
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from typing import Any, Dict, List, Optional

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(REPO / "packages" / "dsh-computer-use" / "adapter"))

import isolated_live_lib as lib  # noqa: E402
from cmm_computer_use.client import BridgeClient, BridgeError  # noqa: E402
from cmm_computer_use.mcp_server import ToolRegistry, handle_message  # noqa: E402

HOME = str(pathlib.Path.home())
LSREGISTER = ("/System/Library/Frameworks/CoreServices.framework/Frameworks/"
              "LaunchServices.framework/Support/lsregister")
REASON_OK = "LIVE aislado: rearm de prueba tras verificar el ledger (isolated-live.py)"


class Gate(Exception):
    pass


def say(message: str) -> None:
    print(message, flush=True)


def run(cmd: List[str], check: bool = True, **kw) -> subprocess.CompletedProcess:
    result = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if check and result.returncode != 0:
        raise Gate("command failed (%d): %s\n%s%s" % (
            result.returncode, " ".join(cmd), result.stdout[-2000:], result.stderr[-2000:]))
    return result


def expect(condition: bool, message: str, results: Dict[str, Any], key: str) -> None:
    results[key] = bool(condition)
    say(("PASS " if condition else "FAIL ") + message)
    if not condition:
        raise Gate(message)


# ── lane state ────────────────────────────────────────────────────────

class Lane:
    def __init__(self, work: str):
        self.work = lib.assert_isolated(work, HOME)
        if not os.path.exists(os.path.join(self.work, lib.MARKER)):
            raise Gate("%s is not an isolated lane (no %s)" % (self.work, lib.MARKER))
        self.state_path = os.path.join(self.work, "lane.json")
        self.state: Dict[str, Any] = {}
        if os.path.exists(self.state_path):
            self.state = json.loads(pathlib.Path(self.state_path).read_text())

    def path(self, name: str) -> str:
        return os.path.join(self.work, name)

    def save(self) -> None:
        pathlib.Path(self.state_path).write_text(json.dumps(self.state, indent=2, sort_keys=True))

    @property
    def socket(self) -> str:
        return self.path("bridge.sock")

    def client(self) -> BridgeClient:
        return BridgeClient(self.socket, policy="background", timeout=30)

    def write_policy(self, admin: bool) -> None:
        policy = lib.build_policy(self.state["probe_requirement"], self.state.get("driver_requirement"),
                                  probe_admin=admin, electron_bundle=self.state.get("electron_app", ""))
        target = self.path("policy.json")
        pathlib.Path(target).write_text(json.dumps(policy, indent=2))
        os.chmod(target, 0o600)
        self.state["probe_admin"] = admin
        self.save()


def new_lane() -> Lane:
    work = tempfile.mkdtemp(prefix="cmm-cu-isolated-", dir="/tmp")
    os.chmod(work, 0o700)
    pathlib.Path(work, lib.MARKER).write_text("isolated live lane; safe to delete\n")
    return Lane(work)


# ── production snapshot ───────────────────────────────────────────────

def file_facts(path: str) -> Dict[str, Any]:
    st = os.lstat(path)
    import stat as S
    facts: Dict[str, Any] = {"mode": oct(S.S_IMODE(st.st_mode)), "mtime_ns": st.st_mtime_ns}
    if S.S_ISSOCK(st.st_mode):
        facts.update(type="socket", inode=st.st_ino)
    elif S.S_ISREG(st.st_mode):
        facts.update(type="file", size=st.st_size,
                     sha256=lib.sha256_bytes(pathlib.Path(path).read_bytes()))
    elif S.S_ISDIR(st.st_mode):
        facts.update(type="dir")
    else:
        facts.update(type="other")
    return facts


def tree(path: str) -> Any:
    if not os.path.lexists(path):
        return "missing"
    if not os.path.isdir(path) or os.path.islink(path):
        return file_facts(path)
    out: Dict[str, Any] = {".": file_facts(path)}
    for root, dirs, files in os.walk(path):
        for name in sorted(dirs + files):
            full = os.path.join(root, name)
            out[os.path.relpath(full, path)] = file_facts(full)
    return out


def launchservices_paths() -> Any:
    if not os.path.exists(LSREGISTER):
        return "lsregister_unavailable"
    dump = run([LSREGISTER, "-dump"], check=False).stdout
    paths = set()
    for block in re.split(r"\n-{20,}\n", dump):
        if re.search(r"^identifier:\s+%s\s*$" % re.escape(lib.HELPER_BUNDLE_ID), block, re.M):
            m = re.search(r"^path:\s+(.*?)(?:\s+\(0x[0-9a-f]+\))?\s*$", block, re.M)
            if m:
                paths.add(m.group(1))
    return sorted(paths)


def production_snapshot() -> Dict[str, Any]:
    P = lib.production_paths(HOME)
    uid = os.getuid()
    lc = run(["launchctl", "print", "gui/%d/%s" % (uid, lib.LAUNCH_AGENT_LABEL)], check=False)
    pids = run(["pgrep", "-f", "--", "--serve-socket %s" % P["socket"]], check=False).stdout.split()
    helpers = {}
    for pid in pids:
        helpers[pid] = run(["ps", "-o", "lstart=", "-p", pid], check=False).stdout.strip()
    installed = tree(P["installed_app"])
    cs = run(["codesign", "-d", "--verbose=4", P["installed_app"]], check=False)
    return {
        "support_dir": tree(P["support_dir"]),
        "launch_agent": tree(P["launch_agent"]),
        "installed_app": installed,
        "installed_app_signature": lib.parse_codesign_display(cs.stderr) if cs.returncode == 0 else "unsigned_or_missing",
        "launchctl": lib.launchctl_facts(lc.stdout) if lc.returncode == 0 else "not_loaded",
        "production_helper_processes": helpers,
        "launchservices_paths": launchservices_paths(),
    }


# ── process helpers ───────────────────────────────────────────────────

def pid_path(pid: int) -> Optional[str]:
    try:
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
        buf = ctypes.create_string_buffer(4096)
        n = libproc.proc_pidpath(pid, buf, ctypes.c_uint32(4096))
        return buf.value.decode() if n > 0 else None
    except OSError:
        return None


def isolated_helper_pids(lane: Lane) -> List[int]:
    out = run(["pgrep", "-f", "--", "--serve-socket %s" % lane.socket], check=False).stdout.split()
    return [int(p) for p in out]


def signing_identity() -> str:
    identities = run(["security", "find-identity", "-v", "-p", "codesigning"], check=False).stdout
    for kind in ("Apple Development", "Developer ID Application"):
        m = re.search(r'"(%s: [^"]+)"' % kind, identities)
        if m:
            return m.group(1)
    raise Gate("no Apple Development / Developer ID identity: the probe needs a verifiable signature")


def build_fixture(dest_dir: str) -> str:
    app = os.path.join(dest_dir, "CMM Computer Use Fixture.app")
    os.makedirs(os.path.join(app, "Contents", "MacOS"), exist_ok=True)
    run(["swiftc", "-O", "-framework", "AppKit", "-framework", "Foundation",
         str(REPO / "examples/fixture/main.swift"), "-o", os.path.join(app, "Contents/MacOS/Fixture")])
    pathlib.Path(app, "Contents/Info.plist").write_text("""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>%s</string>
  <key>CFBundleExecutable</key><string>Fixture</string>
  <key>CFBundleName</key><string>CMM Computer Use Fixture</string>
  <key>CFBundleDisplayName</key><string>CMM Computer Use Fixture</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
</dict></plist>
""" % lib.FIXTURE_BUNDLE_ID)
    run(["codesign", "--force", "--sign", "-", app])
    return app


def stop_fixtures(lane: Lane) -> None:
    for pid in run(["pgrep", "-f", "--", lane.work + "/"], check=False).stdout.split():
        pid_i = int(pid)
        exe = pid_path(pid_i) or ""
        if exe.startswith(lane.work + "/") and "/Fixture" in exe:
            os.kill(pid_i, signal.SIGTERM)


def probe(lane: Lane, *args: str) -> subprocess.CompletedProcess:
    result = run([lane.path("rearm-probe"), "--socket", lane.socket] + list(args), check=False)
    say("  probe %s -> exit %d %s%s" % (" ".join(args[:1]), result.returncode,
                                       result.stdout.strip()[:400], result.stderr.strip()[:200]))
    return result


def frame_detail(result: subprocess.CompletedProcess) -> str:
    try:
        frame = json.loads(result.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return ""
    error = frame.get("error") or {}
    return "%s %s" % (error.get("code", ""), error.get("detail", ""))


# ── phases ────────────────────────────────────────────────────────────

def phase_prepare(args) -> Lane:
    if platform.system() != "Darwin":
        raise Gate("macOS only")
    lane = new_lane()
    say("work dir: %s" % lane.work)
    r: Dict[str, Any] = {}
    lane.state.update(work=lane.work, electron_app=args.electron_app or "", results={})

    snap = production_snapshot()
    pathlib.Path(lane.path("production-before.json")).write_text(json.dumps(snap, indent=2, sort_keys=True))
    say("production snapshot taken (%d support files, launchctl=%s)" % (
        len(snap["support_dir"]) if isinstance(snap["support_dir"], dict) else 0,
        snap["launchctl"] if isinstance(snap["launchctl"], str) else snap["launchctl"].get("state")))

    staged = os.path.realpath(args.staged_app)
    lib.assert_isolated(staged, HOME)
    run(["codesign", "--verify", "--deep", "--strict", staged])
    copy = lane.path("CMMComputerUse.app")
    run(["ditto", staged, copy])
    run(["codesign", "--verify", "--deep", "--strict", copy])
    copy_facts = lib.parse_codesign_display(run(["codesign", "-d", "--verbose=4", copy]).stderr)
    copy_dr = lib.designated_requirement(run(["codesign", "-d", "-r-", copy]).stdout)
    installed = lib.production_paths(HOME)["installed_app"]
    installed_dr = lib.designated_requirement(run(["codesign", "-d", "-r-", installed], check=False).stdout)
    lane.state.update(helper_signature=copy_facts, helper_dr=copy_dr, installed_dr=installed_dr)
    say("helper copy: %s cdhash=%s team=%s" % (copy_facts["identifier"], copy_facts["cdhash"], copy_facts["team_id"]))
    expect(copy_facts["identifier"] == lib.HELPER_BUNDLE_ID, "copy is %s" % lib.HELPER_BUNDLE_ID, r, "helper_identifier")
    expect(bool(copy_dr) and copy_dr == installed_dr,
           "designated requirement of the copy == installed helper's (TCC keys on it)", r, "same_dr")

    probe_bin = lane.path("rearm-probe")
    run(["swiftc", "-O", str(HERE / "rearm-probe/main.swift"), "-o", probe_bin])
    identity = signing_identity()
    run(["codesign", "--force", "--options", "runtime", "--sign", identity,
         "--identifier", lib.PROBE_IDENTIFIER, probe_bin])
    run(["codesign", "--verify", "--strict", probe_bin])
    probe_facts = lib.parse_codesign_display(run(["codesign", "-d", "--verbose=4", probe_bin]).stderr)
    requirement = lib.compose_requirement(probe_facts)
    lane.state.update(probe_signature=probe_facts, probe_requirement=requirement, signing_identity=identity)
    expect(probe_facts["identifier"] == lib.PROBE_IDENTIFIER, "probe identifier %s" % lib.PROBE_IDENTIFIER, r, "probe_identifier")
    expect(probe_facts["identifier"] != lib.HELPER_BUNDLE_ID and "python" not in (probe_facts["identifier"] or ""),
           "probe identity shared with neither the helper nor the python/DSH adapter", r, "probe_distinct")
    say("probe requirement: %s" % requirement)

    latch = lane.path("breach-latch.json")
    pathlib.Path(latch).write_text(json.dumps(lib.seeded_latch(time.time()), indent=2))
    os.chmod(latch, 0o600)
    lane.write_policy(admin=False)
    lane.state["results"]["prepare"] = r
    lane.save()
    return lane


def launch(lane: Lane) -> int:
    if isolated_helper_pids(lane):
        raise Gate("an isolated instance already serves %s" % lane.socket)
    if os.path.exists(lane.socket):
        os.unlink(lane.socket)
    # LaunchServices launch: the instance is the app's own process (responsible
    # process = itself), as the product LaunchAgent does via run-helper.sh.
    # Never Contents/MacOS/<exe>, which loses ScreenCaptureKit attribution.
    run(["/usr/bin/open", "-n", "-g", "-a", lane.path("CMMComputerUse.app"), "--args",
         "--serve-socket", lane.socket, "--policy", "background",
         "--policy-file", lane.path("policy.json"), "--log-file", lane.path("helper.log"),
         "--no-permission-bootstrap"])
    for _ in range(200):
        pids = isolated_helper_pids(lane)
        if pids and os.path.exists(lane.socket):
            break
        time.sleep(0.05)
    pids = isolated_helper_pids(lane)
    if len(pids) != 1:
        raise Gate("expected exactly one isolated instance, found %s" % pids)
    time.sleep(0.5)
    lane.state["helper_pid"] = pids[0]
    lane.save()
    return pids[0]


def phase_start(lane: Lane) -> None:
    r: Dict[str, Any] = {}
    pid = launch(lane)
    say("isolated instance pid=%d" % pid)
    client = lane.client()
    try:
        ping = client.ping()
        expect(ping.get("bundle_id") == lib.HELPER_BUNDLE_ID and ping.get("policy") == "background",
               "isolated socket answers as %s in background" % lib.HELPER_BUNDLE_ID, r, "ping")
        expect((ping.get("capabilities") or {}).get("breach_rearm") is True, "build has breach.rearm", r, "capability")
        status = client.policy_status()
        peer = status.get("peer") or {}
        exe = pid_path(os.getpid()) or sys.executable
        driver_facts = lib.parse_codesign_display(run(["codesign", "-d", "--verbose=4", exe]).stderr)
        driver_requirement = lib.compose_requirement(driver_facts)
        say("driver: %s (peer as seen by the helper: %s)" % (exe, peer))
        check = client.request("policy.requirements.check", {
            "requirements": [
                {"client_id": lib.DRIVER_CLIENT_ID, "requirement": driver_requirement},
                {"client_id": lib.PROBE_CLIENT_ID, "requirement": lane.state["probe_requirement"]},
            ],
            "evaluate_path": lane.path("rearm-probe"),
        })
        rows = {row.get("client_id"): row for row in check.get("requirements", [])}
        drv, prb = rows.get(lib.DRIVER_CLIENT_ID, {}), rows.get(lib.PROBE_CLIENT_ID, {})
        expect(drv.get("compiles") and drv.get("matches_peer"), "driver requirement compiles and matches the driver", r, "driver_req")
        expect(prb.get("compiles") and prb.get("matches_evaluated_path") and not prb.get("matches_peer"),
               "probe requirement compiles, matches the signed probe, not the driver", r, "probe_req")
        lane.state["driver_requirement"] = driver_requirement
        lane.write_policy(admin=False)
        client.reload_policy()
        status = client.policy_status()
        clients = {c.get("client_id"): c for c in status.get("clients", [])}
        expect(status.get("load_error") == "none" and all(c.get("requirement_valid") for c in clients.values()),
               "temporary policy loaded, both requirements valid at load", r, "policy_loaded")
        expect(clients.get(lib.PROBE_CLIENT_ID, {}).get("scopes") == [] and clients.get(lib.PROBE_CLIENT_ID, {}).get("apps") == 0
               and clients.get(lib.PROBE_CLIENT_ID, {}).get("admin") == [],
               "probe: no apps, no scopes, no admin (yet)", r, "probe_unprivileged")
        expect(clients.get(lib.DRIVER_CLIENT_ID, {}).get("admin") == [], "driver never has admin", r, "driver_no_admin")
    finally:
        client.close()
    lane.state["results"]["start"] = r
    lane.save()


def registry(lane: Lane):
    client = lane.client()
    return client, ToolRegistry(client, "background")


def tool(reg, name: str, arguments: Dict[str, Any]) -> Dict[str, Any]:
    response = handle_message(reg, {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                    "params": {"name": name, "arguments": arguments}})
    return response.get("result") or {}


def phase_verify_tcc(lane: Lane) -> None:
    r: Dict[str, Any] = {}
    pid = int(lane.state["helper_pid"])
    exe = pid_path(pid) or ""
    expect(exe.startswith(lane.path("CMMComputerUse.app") + "/"),
           "running image is the isolated copy (%s)" % exe, r, "image")
    ppid = run(["ps", "-o", "ppid=", "-p", str(pid)]).stdout.strip()
    expect(ppid == "1", "parent is launchd (LaunchServices launch), ppid=%s" % ppid, r, "ppid")
    running = lib.parse_codesign_display(run(["codesign", "-d", "--verbose=4", exe]).stderr)
    expect(running["cdhash"] == lane.state["helper_signature"]["cdhash"],
           "running code cdhash == staged build cdhash", r, "cdhash")
    ls = run(["lsappinfo", "list"], check=False).stdout
    block = next((b for b in re.split(r"\n(?=\s*\d+\) )", ls) if re.search(r"\bpid = %d\b" % pid, b)), "")
    r["lsappinfo_block"] = block.strip()[:600]
    expect(lib.HELPER_BUNDLE_ID in block and lane.path("CMMComputerUse.app") in block,
           "LaunchServices knows pid %d as %s from the isolated copy" % (pid, lib.HELPER_BUNDLE_ID), r, "launchservices")

    client, reg = registry(lane)
    try:
        ok, line = lib.tcc_ready(client.status())
        expect(ok, "TCC on the isolated instance: %s" % line, r, "tcc_flags")
        fixture = build_fixture(lane.path("tcc-fixture"))
        state_file = lane.path("tcc-fixture/state.json")
        run(["/usr/bin/open", "-g", "-n", "--env", "CMM_CU_FIXTURE_STATE=%s" % state_file, fixture])
        for _ in range(100):
            if os.path.exists(state_file):
                break
            time.sleep(0.1)
        time.sleep(1.0)
        obs = tool(reg, "computer_use_observe", {"app": lib.FIXTURE_BUNDLE_ID})
        text = "\n".join(b.get("text", "") for b in obs.get("content", []) if b.get("type") == "text")
        elements = len(re.findall(r"^\[\d+\] ", text, re.M))
        expect(not obs.get("isError") and elements >= 3 and "Incrementar" in text,
               "Accessibility works: fixture tree has %d elements" % elements, r, "ax_functional")
        title = re.search(r'"window":"([^"]+)"', text)
        cap = tool(reg, "computer_use_capture_window",
                   {"app": lib.FIXTURE_BUNDLE_ID, "window_title": title.group(1) if title else "CMM Computer Use Fixture"})
        images = [b for b in cap.get("content", []) if b.get("type") == "image" and b.get("data")]
        expect(not cap.get("isError") and len(images) == 1 and len(images[0]["data"]) > 1000,
               "Screen Recording works: one window captured through ScreenCaptureKit", r, "sck_functional")
    finally:
        client.close()
        stop_fixtures(lane)
    lane.state["results"]["verify_tcc"] = r
    lane.save()


def phase_rearm_tests(lane: Lane) -> None:
    r: Dict[str, Any] = {}
    # Local refusals: the probe cannot be used for anything else.
    for bad in (["apps.list"], ["observe"], ["rearm", "--breach-id", lib.SEED_OTHER_ID],
                ["rearm", "--breach-id", lib.SEED_OTHER_ID, "--reason", "   "]):
        res = probe(lane, *bad)
        expect(res.returncode == 2, "probe refuses locally: %s" % " ".join(bad), r, "local_" + "_".join(bad)[:40])
    res = run([lane.path("rearm-probe"), "--socket", lib.production_paths(HOME)["socket"], "status"], check=False)
    expect(res.returncode == 2 and "production" in res.stderr, "probe refuses the production socket", r, "local_prod_socket")

    status = probe(lane, "status")
    expect(status.returncode == 0 and lib.SEED_SELF_ID in status.stdout and lib.SEED_OTHER_ID in status.stdout,
           "breach.status lists both seeded breaches", r, "status_seeded")

    # 7a — no admin: refused, and the probe IS identified (not 'no identity').
    res = probe(lane, "rearm", "--breach-id", lib.SEED_OTHER_ID, "--reason", "sin admin: debe fallar")
    expect(res.returncode == 1 and "auth=rearm_not_granted;client=%s" % lib.PROBE_CLIENT_ID in frame_detail(res),
           "7a probe without admin -> rearm_not_granted", r, "no_admin")
    client = lane.client()
    try:
        try:
            client.request("breach.rearm", {"breach_id": lib.SEED_OTHER_ID, "reason": "agente: debe fallar"})
            agent_refused = False
        except BridgeError as error:
            agent_refused = "auth=rearm_not_granted;client=%s" % lib.DRIVER_CLIENT_ID in error.detail
        expect(agent_refused, "7a' agent client (no admin) -> rearm_not_granted", r, "agent_no_admin")

        # 7b — admin granted: self-rearm still refused.
        lane.write_policy(admin=True)
        client.reload_policy()
        admin = {c["client_id"]: c for c in client.policy_status().get("clients", [])}
        expect(admin.get(lib.PROBE_CLIENT_ID, {}).get("admin") == ["breach.rearm"]
               and admin.get(lib.PROBE_CLIENT_ID, {}).get("scopes") == [],
               "probe now has exactly admin [breach.rearm], still no scopes", r, "admin_granted")
        res = probe(lane, "rearm", "--breach-id", lib.SEED_SELF_ID, "--reason", "self: debe fallar")
        expect(res.returncode == 1 and "auth=self_rearm_not_permitted" in frame_detail(res),
               "7b breach caused by the probe's own client -> self_rearm_not_permitted", r, "self_rearm")

        # 7c — correct rearm with a reason.
        res = probe(lane, "rearm", "--breach-id", lib.SEED_OTHER_ID, "--reason", REASON_OK)
        expect(res.returncode == 0 and '"rearmed"' in res.stdout, "7c rearm with reason -> rearmed", r, "rearm_ok")
        after = probe(lane, "status")
        expect(lib.SEED_OTHER_ID not in after.stdout and lib.SEED_SELF_ID in after.stdout,
               "only the rearmed breach left the latch", r, "latch_after")
    finally:
        client.close()
    audit = [json.loads(l) for l in pathlib.Path(lane.path("breach-audit.jsonl")).read_text().splitlines() if l.strip()]
    rearmed = [a for a in audit if a.get("event") == "rearmed"]
    refused = [a for a in audit if a.get("event") == "rearm_refused"]
    expect(len(rearmed) == 1 and rearmed[0].get("actor_client_id") == lib.PROBE_CLIENT_ID
           and rearmed[0].get("actor_signing_id") == lib.PROBE_IDENTIFIER
           and rearmed[0].get("reason") == REASON_OK and rearmed[0]["breach"]["id"] == lib.SEED_OTHER_ID,
           "audit: rearmed by test-rearm / %s with the reason" % lib.PROBE_IDENTIFIER, r, "audit_rearmed")
    expect(len(refused) >= 3, "audit: the %d refused attempts are recorded" % len(refused), r, "audit_refused")
    lane.state["results"]["rearm_tests"] = r
    lane.save()


def phase_live(lane: Lane) -> None:
    results = lane.state.get("results", {})
    for prior in ("verify_tcc", "rearm_tests"):
        if not results.get(prior) or not all(results[prior].values()):
            raise Gate("phase %s has not passed: LIVE refused" % prior)
    env = dict(os.environ, CMM_COMPUTER_BRIDGE_SOCKET=lane.socket, CMM_E2E_DIR=lane.path("e2e"),
               CMM_E2E_PYTHON=sys.executable)
    os.makedirs(lane.path("e2e"), exist_ok=True)
    cmd = [str(HERE / "live-background-e2e.sh")]
    if lane.state.get("electron_app"):
        cmd += ["--electron-app", lane.state["electron_app"]]
    cmd += ["--breach-control"]  # the controlled breach is the e2e's LAST step
    say("== LIVE: %s" % " ".join(cmd))
    proc = subprocess.run(cmd, env=env)
    report = lane.path("e2e/report.json")
    checks = json.loads(pathlib.Path(report).read_text()).get("checks", {}) if os.path.exists(report) else {}
    lane.state["results"]["live"] = {k: v is not False for k, v in checks.items()} or {"report": False}
    lane.save()
    if proc.returncode != 0:
        raise Gate("LIVE e2e failed (exit %d); evidence in %s" % (proc.returncode, lane.path("e2e")))


def phase_after_breach(lane: Lane, confirm_control: bool) -> None:
    r: Dict[str, Any] = {}
    before = probe(lane, "status")
    frame = json.loads(before.stdout.strip().splitlines()[-1])
    real = [b for b in frame["result"]["breaches"] if b["target_bundle"] == lib.FIXTURE_BUNDLE_ID]
    expect(len(real) == 1 and real[0]["client_id"] == lib.DRIVER_CLIENT_ID,
           "the controlled breach is latched for the fixture, caused by the agent client", r, "real_latched")
    breach_id = real[0]["id"]

    # A restart is not an unlock.
    old = int(lane.state["helper_pid"])
    os.kill(old, signal.SIGTERM)
    for _ in range(100):
        if not isolated_helper_pids(lane):
            break
        time.sleep(0.05)
    launch(lane)
    again = probe(lane, "status")
    expect(breach_id in again.stdout, "after restarting the isolated instance the breach is still latched", r, "persists")

    client = lane.client()
    try:
        try:
            client.request("breach.rearm", {"breach_id": breach_id, "reason": "el agente intenta limpiar su breach"})
            refused = False
        except BridgeError as error:
            refused = "auth=rearm_not_granted" in error.detail
        expect(refused, "the agent client cannot rearm its own breach", r, "agent_cannot")
        res = probe(lane, "rearm", "--breach-id", breach_id, "--reason", REASON_OK)
        expect(res.returncode == 0, "probe rearms the real breach with a reason", r, "real_rearmed")
        if confirm_control:
            reg = ToolRegistry(client, "background")
            obs = tool(reg, "computer_use_observe", {"app": lib.FIXTURE_BUNDLE_ID})
            text = "\n".join(b.get("text", "") for b in obs.get("content", []) if b.get("type") == "text")
            snap = re.search(r"^snapshot: (\d+)", text, re.M)
            el = re.search(r'^\[(\d+)\] \S+ "Incrementar"', text, re.M)
            pressed = tool(reg, "computer_use_press", {"element_id": int(el.group(1)), "snapshot": int(snap.group(1))}) if el and snap else {"isError": True}
            expect(not pressed.get("isError"), "control of the fixture works again after the rearm", r, "control_back")
    finally:
        client.close()
    lane.state["results"]["after_breach"] = r
    lane.save()


def phase_teardown(lane: Lane) -> str:
    stop_fixtures(lane)
    for pid in isolated_helper_pids(lane):
        exe = pid_path(pid) or ""
        if exe.startswith(lane.work + "/"):  # never anything outside the lane
            os.kill(pid, signal.SIGTERM)
    for _ in range(100):
        if not isolated_helper_pids(lane):
            break
        time.sleep(0.05)
    left = isolated_helper_pids(lane)
    if os.path.exists(lane.socket):
        os.unlink(lane.socket)
    for app in pathlib.Path(lane.work).rglob("*.app"):
        if os.path.exists(LSREGISTER):
            run([LSREGISTER, "-u", str(app)], check=False)
    evidence = REPO / "build" / "isolated-live-evidence" / os.path.basename(lane.work)
    evidence.mkdir(parents=True, exist_ok=True)
    for name in ("lane.json", "policy.json", "breach-latch.json", "breach-audit.jsonl", "helper.log",
                 "production-before.json"):
        if os.path.exists(lane.path(name)):
            shutil.copy2(lane.path(name), evidence / name)
    if os.path.isdir(lane.path("e2e")):
        for name in ("report.json", "monitor.jsonl", "fixture-state.json"):
            if os.path.exists(lane.path("e2e/" + name)):
                shutil.copy2(lane.path("e2e/" + name), evidence / ("e2e-" + name))
    if left:
        raise Gate("isolated instance still running: %s (work dir kept: %s)" % (left, lane.work))
    shutil.rmtree(lane.work)
    say("teardown: isolated instance stopped, temporary bundles unregistered, %s removed" % lane.work)
    say("evidence: %s" % evidence)
    return str(evidence)


def phase_verify_production(evidence: str) -> None:
    before = json.loads(pathlib.Path(evidence, "production-before.json").read_text())
    after = production_snapshot()
    pathlib.Path(evidence, "production-after.json").write_text(json.dumps(after, indent=2, sort_keys=True))
    diff = lib.diff_snapshots(before, after)
    pathlib.Path(evidence, "production-diff.txt").write_text("\n".join(diff) + "\n")
    if diff:
        say("FAIL production changed:\n  " + "\n  ".join(diff[:50]))
        raise Gate("production differs from the snapshot (%d differences)" % len(diff))
    say("PASS production identical: support dir, policy, socket inode, LaunchAgent plist, "
        "installed app (every file hash + signature), launchctl job, production helper pid/start, "
        "LaunchServices registrations")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("phase", choices=["all", "prepare", "start", "verify-tcc", "rearm-tests", "live",
                                          "after-breach", "teardown", "verify-production"])
    parser.add_argument("--work", help="isolated lane directory (phases after prepare)")
    parser.add_argument("--evidence", help="evidence directory (verify-production)")
    parser.add_argument("--staged-app", default=str(REPO / "build/stage-20261102/CMMComputerUse.app"))
    parser.add_argument("--electron-app", default="")
    parser.add_argument("--no-live", action="store_true", help="all: stop after rearm-tests (no LIVE, no breach)")
    parser.add_argument("--confirm-control", action="store_true",
                        help="after-breach: one fixture press after the rearm, to show control is back")
    args = parser.parse_args()
    try:
        if args.phase == "all":
            lane = phase_prepare(args)
            evidence = None
            try:
                phase_start(lane)
                phase_verify_tcc(lane)
                phase_rearm_tests(lane)
                if not args.no_live:
                    phase_live(lane)
                    phase_after_breach(lane, args.confirm_control)
            finally:
                evidence = phase_teardown(lane)
                phase_verify_production(evidence)
            return 0
        if args.phase == "prepare":
            phase_prepare(args)
            return 0
        if args.phase == "verify-production":
            if not args.evidence:
                raise Gate("--evidence is required")
            phase_verify_production(args.evidence)
            return 0
        if not args.work:
            raise Gate("--work is required")
        lane = Lane(args.work)
        {"start": lambda: phase_start(lane),
         "verify-tcc": lambda: phase_verify_tcc(lane),
         "rearm-tests": lambda: phase_rearm_tests(lane),
         "live": lambda: phase_live(lane),
         "after-breach": lambda: phase_after_breach(lane, args.confirm_control),
         "teardown": lambda: phase_teardown(lane)}[args.phase]()
        return 0
    except Gate as gate:
        say("GATE: %s" % gate)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
