#!/usr/bin/env python3
"""0.3.3 workspace integration against the REAL helper binary, isolated.

What it proves on the built helper (not a fake): the workspace contract over
the real socket — contexts per principal, per-context generations, ownership
between two different client processes, the context/stream limits, fail-closed
streams without Screen Recording, operation ids and outcomes, idempotent close,
helper restart (new instance id, contexts gone, lost action reported unknown
and never resent) and that a 0.3.2 adapter still works unchanged.

What it does NOT need and never touches:

* no TCC grant: the lane helper is a re-signed (ad hoc) COPY with its own
  bundle id (``com.cmm.chat.computer-use.dev-lane``), so it shares no identity
  and no permission with production. Without Accessibility it walks nothing;
  without Screen Recording it opens no stream — both are asserted fail-closed;
* no production path: socket, policy, latch, audit and log live in the lane;
  any path inside ``~/.cmm/computer-bridge``, ``~/Library/LaunchAgents`` or
  ``~/Applications/CMMComputerUse.app`` is refused;
* no activation, no input: only ``observe`` of Finder is granted (no
  ``control``), and every action exercised is refused before execution;
* teardown signals ONLY the pid this script started, after checking that its
  executable lives inside the lane, then unregisters only the lane bundle.

Production is snapshotted before and after (policy, latch, audit, LaunchAgent,
installed helper executable, production helper pid) and must be identical.

    python3 scripts/verification/workspace-lane.py --app <DerivedData>/.../CMMComputerUse.app
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import plistlib
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid

REPO = pathlib.Path(__file__).resolve().parents[2]
ADAPTER = REPO / "packages/dsh-computer-use/adapter"
HOME = pathlib.Path.home()
PROD_DIR = HOME / ".cmm/computer-bridge"
PROD_AGENT = HOME / "Library/LaunchAgents/com.cmm.chat.computer-use.plist"
PROD_APP = HOME / "Applications/CMMComputerUse.app"
LANE_BUNDLE = "com.cmm.chat.computer-use.dev-lane"
LSREGISTER = ("/System/Library/Frameworks/CoreServices.framework/Frameworks/"
              "LaunchServices.framework/Support/lsregister")

results: list[tuple[str, str, str]] = []


def record(name: str, ok: bool, evidence: str = "") -> None:
    results.append((name, "PASS" if ok else "FAIL", evidence))
    print(("PASS " if ok else "FAIL ") + name + (("  # " + evidence) if evidence else ""), flush=True)


def assert_isolated(path: pathlib.Path) -> None:
    resolved = path.resolve()
    for forbidden in (PROD_DIR, PROD_AGENT.parent, PROD_APP):
        try:
            resolved.relative_to(forbidden.resolve())
        except ValueError:
            continue
        raise SystemExit("refusing a production path: %s" % resolved)


def digest(path: pathlib.Path) -> str:
    if not path.exists():
        return "absent"
    if path.is_socket():
        st = path.stat()
        return "socket ino=%d mode=%o" % (st.st_ino, st.st_mode)
    return hashlib.sha256(path.read_bytes()).hexdigest()


def production_snapshot() -> dict:
    """Read-only facts about production. The production LOG is excluded: a
    running DeepSeek Harness may legitimately use the production helper."""

    snapshot = {name: digest(PROD_DIR / name)
                for name in ("policy.json", "breach-latch.json", "breach-audit.jsonl", "bridge.sock")}
    snapshot["launch_agent"] = digest(PROD_AGENT)
    snapshot["helper_executable"] = digest(PROD_APP / "Contents/MacOS/CMMComputerUse")
    try:
        out = subprocess.run(["pgrep", "-f", str(PROD_APP / "Contents/MacOS/CMMComputerUse")],
                             capture_output=True, text=True, check=False).stdout.split()
    except OSError:
        out = []
    pids = []
    for pid in out:
        start = subprocess.run(["ps", "-o", "lstart=", "-p", pid], capture_output=True, text=True).stdout.strip()
        pids.append("%s@%s" % (pid, start))
    snapshot["helper_processes"] = sorted(pids)
    return snapshot


class Lane:
    def __init__(self, app: pathlib.Path) -> None:
        self.scratch = pathlib.Path(tempfile.mkdtemp(prefix="cmm-ws-lane-"))
        # sun_path is 104 bytes: the socket gets the shortest private dir.
        self.sockdir = pathlib.Path(tempfile.mkdtemp(prefix="cmmws"))
        for path in (self.scratch, self.sockdir):
            assert_isolated(path)
            os.chmod(path, 0o700)
        self.socket = self.sockdir / "b.sock"
        self.policy = self.scratch / "policy.json"
        self.log = self.scratch / "helper.log"
        self.app = self.scratch / "CMMComputerUseLane.app"
        subprocess.run(["ditto", str(app), str(self.app)], check=True)
        info = self.app / "Contents/Info.plist"
        plist = plistlib.loads(info.read_bytes())
        plist["CFBundleIdentifier"] = LANE_BUNDLE
        info.write_bytes(plistlib.dumps(plist))
        subprocess.run(["codesign", "--force", "--deep", "-s", "-", str(self.app)],
                       check=True, capture_output=True)
        self.executable = self.app / "Contents/MacOS/CMMComputerUse"
        self.write_policy({"version": 1, "mode": "background", "default": "deny",
                           "apps": [{"bundle_id": "com.apple.finder", "scopes": ["observe"]}]})
        self.process: subprocess.Popen | None = None

    def write_policy(self, document: dict) -> None:
        self.policy.write_text(json.dumps(document))

    def start(self) -> None:
        self.process = subprocess.Popen(
            [str(self.executable), "--serve-socket", str(self.socket), "--policy", "background",
             "--policy-file", str(self.policy), "--log-file", str(self.log), "--no-permission-bootstrap"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.time() + 10
        while time.time() < deadline:
            if self.socket.exists():
                try:
                    raw(self.socket, "bridge.ping")
                    return
                except OSError:
                    pass
            time.sleep(0.1)
        raise SystemExit("lane helper did not start")

    def stop(self) -> None:
        if not self.process or self.process.poll() is not None:
            return
        # Signal ONLY our own child, and only after checking its image.
        image = subprocess.run(["ps", "-o", "comm=", "-p", str(self.process.pid)],
                               capture_output=True, text=True).stdout.strip()
        if not image.startswith(str(self.scratch)):
            raise SystemExit("refusing to signal pid %d (%s): not the lane helper" % (self.process.pid, image))
        self.process.send_signal(signal.SIGTERM)
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)

    def teardown(self, keep: pathlib.Path | None) -> None:
        self.stop()
        if os.path.exists(LSREGISTER):
            subprocess.run([LSREGISTER, "-u", str(self.app)], capture_output=True)
        if keep:
            keep.mkdir(parents=True, exist_ok=True)
            for name in ("helper.log", "policy.json"):
                if (self.scratch / name).exists():
                    shutil.copy2(self.scratch / name, keep / name)
        shutil.rmtree(self.scratch, ignore_errors=True)
        shutil.rmtree(self.sockdir, ignore_errors=True)


def raw(path: pathlib.Path, operation: str, arguments: dict | None = None, timeout: float = 10) -> dict:
    """One request on one connection, from THIS process (python principal)."""

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(timeout)
        sock.connect(str(path))
        rid = "lane-" + uuid.uuid4().hex[:8]
        sock.sendall((json.dumps({"version": 1, "id": rid, "operation": operation,
                                  "arguments": arguments or {}}) + "\n").encode())
        buffer = b""
        while b"\n" not in buffer:
            chunk = sock.recv(65536)
            if not chunk:
                break
            buffer += chunk
    frame = json.loads(buffer.split(b"\n")[0])
    assert frame.get("id") == rid
    return frame


def other(path: pathlib.Path, operation: str, arguments: dict | None = None) -> dict:
    """The same request from ANOTHER process with another code identity
    (/usr/bin/nc, Apple-signed): a different principal."""

    rid = "nc-" + uuid.uuid4().hex[:8]
    line = json.dumps({"version": 1, "id": rid, "operation": operation, "arguments": arguments or {}}) + "\n"
    out = subprocess.run(["/usr/bin/nc", "-U", "-w", "3", str(path)], input=line,
                         capture_output=True, text=True, timeout=15).stdout
    return json.loads(out.splitlines()[0])


FIXTURE_BUNDLE = "com.cmm.computer-use.lane-fixture"


def frontmost() -> str:
    """Who the person has in front, from LaunchServices (read-only)."""

    asn = subprocess.run(["lsappinfo", "front"], capture_output=True, text=True).stdout.strip()
    info = subprocess.run(["lsappinfo", "info", "-only", "bundleid", asn], capture_output=True, text=True).stdout
    return info.strip()


def build_fixture(lane: Lane) -> pathlib.Path:
    app = lane.scratch / "LaneFixture.app"
    (app / "Contents/MacOS").mkdir(parents=True)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": FIXTURE_BUNDLE, "CFBundleExecutable": "LaneFixture",
        "CFBundleName": "CMM Lane Fixture", "CFBundlePackageType": "APPL", "LSUIElement": True}))
    subprocess.run(["swiftc", "-O", "-o", str(app / "Contents/MacOS/LaneFixture"),
                    str(REPO / "scripts/verification/lane-fixture/main.swift")], check=True, capture_output=True)
    subprocess.run(["codesign", "--force", "-s", "-", str(app)], check=True, capture_output=True)
    return app


def frames_of(sock: pathlib.Path, stream_id: str, seconds: float) -> list:
    seen = []
    deadline = time.time() + seconds
    while time.time() < deadline:
        frame = raw(sock, "observation.stream_frame", {"stream_id": stream_id})
        if frame.get("ok"):
            r = frame["result"]
            seen.append((r["frame_index"], r["phase"], hashlib.sha256(r["screenshot_base64"].encode()).hexdigest()[:12],
                         r["view_identity"]["window_id"]))
        time.sleep(0.08)
    return seen


class FrontWitness:
    """Samples the frontmost application every 100 ms on its own thread.

    A before/after pair cannot tell "the lane activated something" from "the
    person switched apps". The witness can: a lane process (fixture or lane
    helper) in front at ANY sample is the lane's fault; another application
    in front is external activity, reported, never blamed on the lane.
    """

    def __init__(self) -> None:
        import threading
        self.samples: list[str] = []
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def _run(self) -> None:
        while not self._stop.is_set():
            self.samples.append(frontmost())
            self._stop.wait(0.1)

    def __enter__(self) -> "FrontWitness":
        self._thread.start()
        return self

    def __exit__(self, *exc) -> None:
        self._stop.set()
        self._thread.join(timeout=2)


def stream_phase(lane: Lane, sock: pathlib.Path) -> None:
    with FrontWitness() as witness:
        stream_checks(lane, sock)
    lane_front = [s for s in witness.samples if FIXTURE_BUNDLE in s or LANE_BUNDLE in s]
    distinct = []
    for sample in witness.samples:
        if not distinct or distinct[-1] != sample:
            distinct.append(sample)
    record("S8 no lane process (fixture or helper) was ever frontmost (continuous witness)",
           not lane_front and len(witness.samples) > 20,
           "%d samples; frontmost sequence: %s" % (len(witness.samples),
           " → ".join(d.split("=")[-1].strip('"') for d in distinct)))


def stream_checks(lane: Lane, sock: pathlib.Path) -> None:
    """Two REAL SCStreams on two windows of the lane's own fixture."""

    fixture_app = build_fixture(lane)
    lane.write_policy({"version": 1, "mode": "background", "default": "deny",
                       "apps": [{"bundle_id": "com.apple.finder", "scopes": ["observe"]},
                                {"bundle_id": FIXTURE_BUNDLE, "scopes": ["observe"]}]})
    raw(sock, "policy.reload")
    fixture = subprocess.Popen([str(fixture_app / "Contents/MacOS/LaneFixture")], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, text=True)
    try:
        line = fixture.stdout.readline().split()
        wa, wb = int(line[1]), int(line[2])
        time.sleep(0.6)
        common = {"app": FIXTURE_BUNDLE, "expected_bundle": FIXTURE_BUNDLE, "expected_pid": fixture.pid}
        sa = raw(sock, "observation.stream_start", {**common, "window_id": wa, "stream_key": "A"}, timeout=25)
        sb = raw(sock, "observation.stream_start", {**common, "window_id": wb, "stream_key": "B"}, timeout=25)
        if not (sa.get("ok") and sb.get("ok")):
            record("S0 two real streams start", False, json.dumps([sa.get("error"), sb.get("error")])[:300])
            return
        ida, idb = sa["result"]["stream_id"], sb["result"]["stream_id"]
        fa, fb = frames_of(sock, ida, 2.0), frames_of(sock, idb, 2.0)
        record("S1 two live streams with independent frame indices and their own windows",
               len(fa) > 3 and len(fb) > 3 and fa[-1][0] > fa[0][0] and fb[-1][0] > fb[0][0]
               and {f[3] for f in fa} == {wa} and {f[3] for f in fb} == {wb}
               and not ({f[2] for f in fa} & {f[2] for f in fb}) and fa[-1][1] == "live" and fb[-1][1] == "live",
               "A idx %s→%s B idx %s→%s" % (fa[0][0], fa[-1][0], fb[0][0], fb[-1][0]))

        third = raw(sock, "observation.stream_start", {**common, "window_id": wa, "stream_key": "C"}, timeout=25)
        same = raw(sock, "observation.stream_start", {**common, "window_id": wa, "stream_key": "A"}, timeout=25)
        record("S2 a third stream is refused; restarting A on its window is idempotent",
               (third.get("error") or {}).get("code") == "STREAM_LIMIT"
               and same.get("ok") and same["result"]["stream_id"] == ida and same["result"]["stream"] == "existing",
               (third.get("error") or {}).get("detail", ""))

        theirs = [other(sock, "observation.stream_frame", {"stream_id": ida}),
                  other(sock, "observation.stream_stop", {"stream_id": ida}),
                  other(sock, "observation.stream_recover", {"stream_id": ida})]
        record("S3 another client can neither read, stop nor recover A",
               all(code(f) == "STREAM_UNKNOWN" for f in theirs), str([code(f) for f in theirs]))

        stop_a = raw(sock, "observation.stream_stop", {"stream_id": ida})["result"]
        fb2 = frames_of(sock, idb, 1.0)
        status = raw(sock, "observation.stream_status")["result"]["streams"]
        record("S4 stopping A leaves B live",
               stop_a["stopped"] and [s["stream_id"] for s in status] == [idb]
               and fb2 and fb2[-1][0] > fb[-1][0] and fb2[-1][1] == "live",
               "B idx %s→%s" % (fb[-1][0], fb2[-1][0] if fb2 else None))

        sa2 = raw(sock, "observation.stream_start", {**common, "window_id": wa, "stream_key": "A"}, timeout=25)
        ida2 = sa2["result"]["stream_id"]
        fixture.stdin.write("closeB\n"); fixture.stdin.flush()
        time.sleep(3.0)
        b_status = raw(sock, "observation.stream_status", {"stream_id": idb})
        b_phase = b_status["result"]["streams"][0]["phase"] if b_status.get("ok") else code(b_status)
        fa2 = frames_of(sock, ida2, 1.0)
        record("S5 B's window closes: B leaves `live` (error/stale), A keeps streaming",
               b_phase in ("error", "stale") and fa2 and fa2[-1][1] == "live" and fa2[-1][0] > fa2[0][0],
               "B=%s A idx %s→%s" % (b_phase, fa2[0][0] if fa2 else None, fa2[-1][0] if fa2 else None))

        recover = raw(sock, "observation.stream_recover", {"stream_id": idb}, timeout=30)
        fa3 = frames_of(sock, ida2, 1.0)
        record("S6 recovering B fails honestly (window gone) without touching A",
               not recover.get("ok") and fa3 and fa3[-1][1] == "live" and fa3[-1][0] > fa2[-1][0],
               "%s %s" % (code(recover), (recover.get("error") or {}).get("detail", "")))

        log = lane.log.read_text()
        record("S7 helper log: streams started/stopped by id, no breach, no activation",
               log.count("WINDOW_STREAM_STARTED") >= 3 and "WINDOW_STREAM_STOPPED id=%s" % ida in log
               and "INTERFERENCE_BREACH" not in log)
        for sid in (ida2, idb):
            raw(sock, "observation.stream_stop", {"stream_id": sid})
    finally:
        image = subprocess.run(["ps", "-o", "comm=", "-p", str(fixture.pid)], capture_output=True, text=True).stdout
        if image.strip().startswith(str(lane.scratch)):
            fixture.terminate()
            try:
                fixture.wait(timeout=5)
            except subprocess.TimeoutExpired:
                fixture.kill()
        if os.path.exists(LSREGISTER):
            subprocess.run([LSREGISTER, "-u", str(fixture_app)], capture_output=True)


def code(frame: dict) -> str:
    return (frame.get("error") or {}).get("code", "") if not frame.get("ok") else "OK"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, type=pathlib.Path, help="built CMMComputerUse.app (dev)")
    parser.add_argument("--evidence", type=pathlib.Path, default=None)
    parser.add_argument("--streams", action="store_true",
                        help="also stream two windows of the lane's OWN fixture (needs Screen Recording "
                             "for the lane helper; never streams a window of another application)")
    args = parser.parse_args()
    assert_isolated(args.app)

    before = production_snapshot()
    lane = Lane(args.app)
    try:
        lane.start()
        sock = lane.socket

        ping = raw(sock, "bridge.ping")["result"]
        instance1 = ping.get("instance_id", "")
        caps = ping.get("capabilities", {}).get("workspace", {})
        record("L1 ping: instance id and workspace capability",
               instance1.startswith("ins_") and caps.get("max_streams") == 2
               and caps.get("max_contexts_per_client") == 2 and ping.get("bundle_id") == LANE_BUNDLE,
               "instance=%s… caps=%s" % (instance1[:12], caps))

        perms = raw(sock, "permissions.status")["result"]
        record("L1b lane helper has no TCC grant (fail-closed environment)",
               perms.get("accessibility") is False or perms.get("screen_recording") is False, json.dumps(perms))

        a = raw(sock, "workspace.context_create")
        b = raw(sock, "workspace.context_create")
        c = raw(sock, "workspace.context_create")
        ida, idb = a["result"]["context_id"], b["result"]["context_id"]
        record("L2 two contexts A/B; the third is refused",
               a["result"]["label"] == "A" and b["result"]["label"] == "B" and code(c) == "CONTEXT_LIMIT"
               and ida != idb and len(ida) == 36, "third=%s" % (c.get("error") or {}).get("detail"))

        refused = raw(sock, "workspace.context_close", {"context_id": idb})
        bound_refusal = raw(sock, "workspace.context_create", {"app": "Calendar"})
        record("L3 a context for an unauthorized/unavailable app is refused (deny by default)",
               refused.get("ok") and code(bound_refusal) in ("APP_NOT_AUTHORIZED", "APPROVAL_REJECTED",
                                                               "COMPUTER_TARGET_UNAVAILABLE"),
               "calendar=%s" % code(bound_refusal))

        finder = raw(sock, "workspace.context_create", {"app": "com.apple.finder"})
        idf = finder["result"]["context_id"]
        o1 = raw(sock, "observation.describe", {"app": "com.apple.finder", "context_id": ida})
        o2 = raw(sock, "observation.describe", {"app": "com.apple.finder", "context_id": ida})
        o3 = raw(sock, "observation.describe", {"context_id": idf})
        legacy = raw(sock, "observation.describe", {"app": "com.apple.finder"})
        record("L4 per-context generations on the real helper (A=1,2; B=1; default=1)",
               o1["result"]["snapshot"] == 1 and o2["result"]["snapshot"] == 2
               and o3["result"]["snapshot"] == 1 and legacy["result"]["snapshot"] == 1
               and o3["result"]["context_id"] == idf and legacy["result"]["context_label"] == "default"
               and finder["result"].get("bound_bundle") == "com.apple.finder",
               "A=%s,%s B=%s default=%s ax_tree=%s" % (o1["result"]["snapshot"], o2["result"]["snapshot"],
                                                      o3["result"]["snapshot"], legacy["result"]["snapshot"],
                                                      o1["result"].get("ax_tree")))

        mismatch = raw(sock, "observation.describe", {"app": "com.apple.dock", "context_id": ida})
        record("L4b a bound context refuses another application",
               code(mismatch) in ("CONTEXT_TARGET_MISMATCH", "APP_NOT_AUTHORIZED", "APPROVAL_REJECTED"),
               code(mismatch))

        theirs = [other(sock, "workspace.context_status", {"context_id": ida}),
                  other(sock, "workspace.context_close", {"context_id": ida}),
                  other(sock, "observation.release", {"context_id": ida}),
                  other(sock, "action.execute", {"kind": "ui.press", "context_id": ida,
                                                 "params": {"element_id": 1, "snapshot": 2}})]
        listed = other(sock, "workspace.context_list")
        record("L5 another client process cannot read, close, release or act in A",
               all(code(f) == "CONTEXT_UNKNOWN" for f in theirs) and listed["result"]["contexts"] == []
               and raw(sock, "workspace.context_status", {"context_id": ida}).get("ok"),
               "codes=%s" % [code(f) for f in theirs])

        op = "op_" + uuid.uuid4().hex
        press = raw(sock, "action.execute", {"kind": "ui.press", "context_id": ida, "op_id": op,
                                             "params": {"element_id": 1, "snapshot": 2}})
        execution = (press.get("error") or {}).get("execution", {})
        outcome = raw(sock, "action.outcome", {"op_id": op})["result"]
        record("L6 a refused press is not_executed; its op id is not recorded",
               not press["ok"] and execution.get("executed") is False and execution.get("outcome") == "not_executed"
               and outcome.get("known") is False and outcome.get("outcome") == "unknown",
               "detail=%s outcome=%s" % ((press.get("error") or {}).get("detail"), outcome.get("outcome")))

        bad = raw(sock, "action.execute", {"kind": "ui.press", "op_id": "x", "params": {}})
        record("L7 a malformed op id is refused, not executed",
               code(bad) == "CAPABILITY_UNSUPPORTED" and bad["error"]["execution"]["executed"] is False)

        released = raw(sock, "observation.release", {"context_id": ida})["result"]
        stale = raw(sock, "action.execute", {"kind": "ui.press", "context_id": ida,
                                             "params": {"element_id": 1, "snapshot": 2}})
        record("L8 release retires ONLY A's generation; its old handle is `released`",
               released.get("invalidated_snapshot") == 2 and released.get("snapshot") == 3
               and "reason=released" in stale["error"]["detail"]
               and raw(sock, "workspace.context_status", {"context_id": idf})["result"]["snapshot"] == 1,
               stale["error"]["detail"])

        stream = raw(sock, "observation.stream_start", {"context_id": idf, "window_id": 1})
        streams = raw(sock, "observation.stream_status")["result"]["streams"]
        # The lane helper may INHERIT Screen Recording from its responsible
        # process (the terminal/agent that launched it): then it is refused
        # because the window does not exist; without it, by TCC. Either way:
        # refused, nothing registered, nothing captured.
        record("L9 a stream on a window that is not there is refused and nothing is registered",
               not stream["ok"] and stream["error"].get("detail", "") in
               ("screen_recording_denied", "window_not_found_by_id")
               and streams == [] and "WINDOW_STREAM_STARTED" not in lane.log.read_text(),
               stream["error"].get("detail"))

        foreign = other(sock, "observation.stream_frame", {"stream_id": "str_" + "0" * 32})
        malformed = raw(sock, "observation.stream_frame", {"stream_id": "../x"})
        legacy_frame = raw(sock, "observation.stream_frame")
        record("L10 frames: unknown/foreign stream ids are STREAM_UNKNOWN; no legacy stream is not_active",
               code(foreign) == "STREAM_UNKNOWN" and code(malformed) == "STREAM_UNKNOWN"
               and legacy_frame["error"].get("detail") == "stream_not_active")

        close1 = raw(sock, "workspace.context_close", {"context_id": ida})["result"]
        close2 = raw(sock, "workspace.context_close", {"context_id": ida})["result"]
        after = raw(sock, "workspace.context_status", {"context_id": ida})
        record("L11 close is idempotent; a closed context says CONTEXT_CLOSED",
               close1["closed"] and not close2["closed"] and close2["already_closed"]
               and code(after) == "CONTEXT_CLOSED")

        if args.streams:
            stream_phase(lane, sock)

        # 0.3.2 adapter, byte for byte from the accepted release, against 0.3.3.
        old_dir = lane.scratch / "adapter-0.3.2" / "cmm_computer_use"
        old_dir.mkdir(parents=True)
        for name in ("__init__.py", "client.py", "mcp_server.py"):
            blob = subprocess.run(["git", "-C", str(REPO), "show",
                                   "e0a14cbc81cc826072f5393547a2f3f46e59e11c:packages/dsh-computer-use/adapter/"
                                   "cmm_computer_use/" + name], capture_output=True, check=True).stdout
            (old_dir / name).write_bytes(blob)
        probe = r'''
import json, sys
sys.path.insert(0, sys.argv[1])
import cmm_computer_use.client as c
c.BRIDGE_BUNDLE_ID = sys.argv[3]
client = c.BridgeClient(sys.argv[2], policy="background")
out = {"ping": client.ping().get("protocol")}
obs = client.observe(app="com.apple.finder")
out["snapshot"] = obs["snapshot"]
out["release"] = client.release()
try:
    client.act("ui.press", element_id=1, snapshot=obs["snapshot"])
except c.BridgeError as e:
    out["press"] = [e.code, e.detail]
print(json.dumps(out))
'''
        old = subprocess.run([sys.executable, "-I", "-c", probe, str(old_dir.parent), str(sock), LANE_BUNDLE],
                             capture_output=True, text=True, timeout=60)
        old_out = json.loads(old.stdout.strip().splitlines()[-1]) if old.returncode == 0 else {"stderr": old.stderr[-400:]}
        record("L12 the 0.3.2 adapter works unchanged against the 0.3.3 helper",
               old_out.get("ping") == 1 and isinstance(old_out.get("snapshot"), int)
               and old_out.get("release", {}).get("invalidated_snapshot") == old_out.get("snapshot")
               and old_out.get("press", ["", ""])[0] == "ACTION_FAILED"
               and "reason=released" in old_out.get("press", ["", ""])[1],
               json.dumps(old_out)[:300])

        # Restart: contexts and the instance are gone; a mutation in flight on
        # the dead connection is reported UNKNOWN and never resent.
        sys.path.insert(0, str(ADAPTER))
        from cmm_computer_use import client as client_module  # noqa: E402
        client_module.BRIDGE_BUNDLE_ID = LANE_BUNDLE
        client = client_module.BridgeClient(str(sock), policy="background")
        client.ping()
        seen_instance = client.instance_id
        lane.stop()
        lane.start()
        executes_before = lane.log.read_text().count("refused ui.press")
        try:
            client.act("ui.press", context_id=idf, element_id=1, snapshot=1)
            unknown = None
        except client_module.BridgeOutcomeUnknown as error:
            unknown = error
        executes_after = lane.log.read_text().count("refused ui.press")
        instance2 = raw(sock, "bridge.ping")["result"]["instance_id"]
        gone = raw(sock, "workspace.context_status", {"context_id": idf})
        reobserve = client.observe(app="com.apple.finder")
        record("L13 restart: new instance, contexts gone, lost press UNKNOWN and not resent, reads reconnect",
               unknown is not None and unknown.reason in ("helper_restarted", "not_recorded")
               and instance2 != seen_instance and code(gone) == "CONTEXT_UNKNOWN"
               and executes_after == executes_before and reobserve.get("snapshot") == 1,
               "reason=%s instance %s→%s" % (getattr(unknown, "reason", None), seen_instance[:10], instance2[:10]))
        client.close()

        log = lane.log.read_text()
        record("L14 helper log: contexts created/closed, no activation, no breach",
               "CONTEXT_CREATED" in log and "CONTEXT_CLOSED" in log and "INTERFERENCE_BREACH" not in log
               and "activate" not in log.lower().replace("activation", ""),
               "%d lines" % len(log.splitlines()))
    finally:
        lane.teardown(args.evidence)
    after_snapshot = production_snapshot()
    diff = {k: (before[k], after_snapshot.get(k)) for k in before if before[k] != after_snapshot.get(k)}
    record("L15 production unchanged (policy, latch, audit, socket, LaunchAgent, helper binary, helper pid)",
           not diff, json.dumps(diff)[:400] if diff else "identical")
    record("L16 teardown left no lane helper running",
           not lane.scratch.exists() and (lane.process is None or lane.process.poll() is not None))

    failed = [r for r in results if r[1] != "PASS"]
    print("\n%d checks, %d failed" % (len(results), len(failed)))
    if args.evidence:
        (args.evidence / "workspace-lane.json").write_text(json.dumps(
            [{"check": n, "result": r, "evidence": e} for n, r, e in results], indent=2))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
