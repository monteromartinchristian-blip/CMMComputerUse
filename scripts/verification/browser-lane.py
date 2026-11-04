#!/usr/bin/env python3
"""F-09 live lane: verified downloads from REAL browsers into the REAL helper.

What it proves on the built helper binary (not a fake) with real Google
Chrome and real Firefox:

* the helper reports a download COMPLETE only when the finished file is in
  the policy's directory, non-empty and stable — and the file's SHA-256 equals
  what the server sent (direct file, PDF, ZIP, redirect to a dynamically named
  file, two simultaneous downloads, a download triggered by script);
* a transfer that dies or stalls is never reported complete;
* a browser that dies mid-download affects ONLY its own context/expectation:
  the other browser's download completes and its context stays valid;
* expectations are owned (another process cannot read them), roots are
  exact (anything else is refused, a grant without roots watches nothing),
  a resent expect with the same op_id is the same expectation, and a long
  `download.wait` never blocks other requests;
* without Accessibility the browser operations fail closed (no AX read of
  any browser, no tab action).

Isolation, as in workspace-lane.py: an ad hoc re-signed COPY of the helper
with its own bundle id and no TCC grant; socket/policy/log in a private
directory; browsers run HEADLESS with throwaway profiles (no window, no
keychain: `--use-mock-keychain`), against a server on 127.0.0.1 with an
ephemeral port. The person's own Chrome/Firefox profiles, windows and
sessions are never touched (the helper has no Accessibility and the download
operations never use it). Every launched process is stopped by pid after its
command line is checked to point into the lane directory. A frontmost-app
witness runs the whole time. Safari is NOT exercised: it cannot run as an
isolated instance (one process per user, global download settings), so a
live Safari test would act inside the person's open session.

    python3 scripts/verification/browser-lane.py --app <DerivedData>/.../CMMComputerUse.app
"""

from __future__ import annotations

import argparse
import hashlib
import http.server
import importlib.util
import io
import json
import os
import pathlib
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
import uuid
import zipfile

HERE = pathlib.Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("workspace_lane", HERE / "workspace-lane.py")
lane_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(lane_mod)  # type: ignore[union-attr]

Lane = lane_mod.Lane
raw = lane_mod.raw
other = lane_mod.other
record = lane_mod.record
results = lane_mod.results
production_snapshot = lane_mod.production_snapshot
assert_isolated = lane_mod.assert_isolated
frontmost = lane_mod.frontmost

CHROME_BIN = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
FIREFOX_BIN = "/Applications/Firefox.app/Contents/MacOS/firefox"
CHROME = "com.google.Chrome"
FIREFOX = "org.mozilla.firefox"


# ── content the server sends (digests are what the files must hash to) ──

def _pdf() -> bytes:
    body = b"%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[]/Count 0>>endobj\n"
    return body + b"%" + os.urandom(60_000).hex().encode()[:60_000] + b"\ntrailer<</Root 1 0 R>>\n%%EOF\n"


def _zip() -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        for index in range(5):
            archive.writestr("part-%d.txt" % index, os.urandom(8_000).hex())
    return buffer.getvalue()


FILES = {
    "direct.csv": ("text/csv", b"id,value\n" + b"".join(b"%d,%s\n" % (i, os.urandom(8).hex().encode())
                                                          for i in range(1500))),
    "paper.pdf": ("application/pdf", _pdf()),
    "archive.zip": ("application/zip", _zip()),
    "slow-a.bin": ("application/octet-stream", os.urandom(600_000)),
    "slow-b.bin": ("application/octet-stream", os.urandom(600_000)),
    "victim.bin": ("application/octet-stream", os.urandom(2_000_000)),
}
SERVED: dict[str, str] = {name: hashlib.sha256(body).hexdigest() for name, (_, body) in FILES.items()}
SLOW = {"slow-a.bin", "slow-b.bin", "victim.bin"}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args) -> None:  # quiet
        pass

    def _attachment(self, name: str, mime: str, body: bytes, *, slow: bool = False, cut: int | None = None,
                    stall: bool = False) -> None:
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Disposition", 'attachment; filename="%s"' % name)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        step = 20_000 if slow or cut or stall else len(body)
        sent = 0
        try:
            while sent < len(body):
                if cut is not None and sent >= cut:
                    # Abort mid-transfer: the browser sees a broken connection.
                    self.connection.shutdown(socket.SHUT_RDWR)
                    return
                if stall and sent >= 200_000:
                    time.sleep(90)  # keep the connection open, send nothing
                    return
                self.wfile.write(body[sent:sent + step])
                self.wfile.flush()
                sent += step
                if slow:
                    time.sleep(0.12)
        except OSError:
            return

    def do_GET(self) -> None:
        url = urllib.parse.urlparse(self.path)
        query = dict(urllib.parse.parse_qsl(url.query))
        name = url.path.lstrip("/")
        if name == "delay":
            # A page that navigates to a file after a delay: the expectation
            # is declared while the browser is already running.
            target = query.get("to", "/direct.csv")
            ms = int(query.get("ms", "4000"))
            html = ("<html><body>wait<script>setTimeout(function(){location.href=%s},%d)</script></body></html>"
                    % (json.dumps(target), ms)).encode()
            return self._page(html)
        if name == "multi":
            ms = int(query.get("ms", "4000"))
            files = query.get("files", "slow-a.bin,slow-b.bin").split(",")
            frames = "".join("var f=document.createElement('iframe');f.src=%s;document.body.appendChild(f);"
                             % json.dumps("/" + f) for f in files)
            html = ("<html><body>multi<script>setTimeout(function(){%s},%d)</script></body></html>"
                    % (frames, ms)).encode()
            return self._page(html)
        if name == "redirect":
            self.send_response(302)
            self.send_header("Location", "/generated?n=%s" % query.get("n", "1"))
            self.end_headers()
            return
        if name == "generated":
            body = ("generated report %s\n" % query.get("n", "1")).encode() * 400
            filename = "generated-%s.txt" % query.get("n", "1")
            SERVED[filename] = hashlib.sha256(body).hexdigest()
            return self._attachment(filename, "text/plain", body)
        if name == "cut.bin":
            body = FILES["victim.bin"][1]
            # Slow enough that the partial file is visible before the cut.
            return self._attachment("cut.bin", "application/octet-stream", body, slow=True, cut=300_000)
        if name == "stall.bin":
            body = FILES["victim.bin"][1]
            return self._attachment("stall.bin", "application/octet-stream", body, stall=True)
        if name in FILES:
            mime, body = FILES[name]
            return self._attachment(name, mime, body, slow=name in SLOW)
        self.send_response(404)
        self.end_headers()

    def _page(self, html: bytes) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(html)))
        self.end_headers()
        self.wfile.write(html)


class Server:
    def __init__(self) -> None:
        http.server.ThreadingHTTPServer.daemon_threads = True
        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def url(self, path: str) -> str:
        return "http://127.0.0.1:%d%s" % (self.port, path)

    def stop(self) -> None:
        self.httpd.shutdown()
        self.httpd.server_close()


# ── browsers (headless, throwaway profiles) ─────────────────────────────

class Browser:
    """One headless browser process with its own profile inside the lane."""

    def __init__(self, kind: str, scratch: pathlib.Path, downloads: pathlib.Path, label: str) -> None:
        self.kind = kind
        self.profile = scratch / ("profile-%s-%s" % (kind, label))
        self.profile.mkdir(parents=True)
        self.downloads = downloads
        self.process: subprocess.Popen | None = None
        if kind == "chrome":
            (self.profile / "Default").mkdir()
            (self.profile / "Default/Preferences").write_text(json.dumps({
                "download": {"default_directory": str(downloads), "prompt_for_download": False,
                             "directory_upgrade": True},
                "profile": {"default_content_setting_values": {"automatic_downloads": 1}},
                "safebrowsing": {"enabled": False}}))
        else:
            prefs = {
                "browser.download.folderList": 2, "browser.download.dir": str(downloads),
                "browser.download.useDownloadDir": True,
                "browser.download.always_ask_before_handling_new_types": False,
                "browser.helperApps.neverAsk.saveToDisk":
                    "application/octet-stream,application/pdf,application/zip,text/csv,text/plain",
                "pdfjs.disabled": True, "browser.shell.checkDefaultBrowser": False,
                "browser.aboutwelcome.enabled": False, "datareporting.policy.dataSubmissionEnabled": False,
                "toolkit.telemetry.reportingpolicy.firstRun": False, "app.update.enabled": False,
                "browser.download.manager.addToRecentDocs": False,
            }
            (self.profile / "user.js").write_text("".join(
                "user_pref(%s, %s);\n" % (json.dumps(k), json.dumps(v)) for k, v in prefs.items()))

    def open(self, url: str) -> None:
        if self.kind == "chrome":
            argv = [CHROME_BIN, "--headless=new", "--user-data-dir=" + str(self.profile), "--no-first-run",
                    "--no-default-browser-check", "--use-mock-keychain", "--password-store=basic",
                    "--disable-sync", "--disable-background-networking", "--disable-component-update", url]
            env = dict(os.environ)
        else:
            argv = [FIREFOX_BIN, "--headless", "--no-remote", "--profile", str(self.profile), url]
            env = {**os.environ, "MOZ_HEADLESS": "1"}
        self.process = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env)
        LAUNCHED.add(self.process.pid)

    def pids(self) -> list[int]:
        """Every process running with THIS profile. Firefox re-executes itself
        on a new profile (observed live: a new pid, parent launchd), so the
        Popen pid alone is not the browser."""

        out = subprocess.run(["ps", "-axo", "pid=,args="], capture_output=True, text=True).stdout
        found = []
        for line in out.splitlines():
            pid, _, args = line.strip().partition(" ")
            if str(self.profile) in args and args.split()[0] in (CHROME_BIN, FIREFOX_BIN):
                found.append(int(pid))
        return found

    def stop(self, sig: int = signal.SIGTERM) -> None:
        if self.process and self.process.poll() is None:
            self.process.send_signal(sig)
        deadline = time.time() + 15
        while time.time() < deadline:
            alive = self.pids()
            if not alive:
                break
            for pid in alive:
                # Only a main browser process whose command line names this
                # lane profile (checked in pids()) is ever signalled.
                try:
                    os.kill(pid, sig if time.time() < deadline - 5 else signal.SIGKILL)
                except ProcessLookupError:
                    pass
            time.sleep(0.5)
        if self.process:
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass


LAUNCHED: set[int] = set()


class PidWitness:
    """Frontmost application (bundle and pid) every 100 ms. A lane browser in
    front is told apart from the person's own Chrome/Firefox by pid."""

    def __init__(self, scratch: str = "") -> None:
        self.scratch = scratch
        self._args: dict[int, str] = {}
        self.lane_front: list[int] = []
        self.samples: list[tuple[str, int]] = []
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def _run(self) -> None:
        while not self._stop.is_set():
            asn = subprocess.run(["lsappinfo", "front"], capture_output=True, text=True).stdout.strip()
            info = subprocess.run(["lsappinfo", "info", "-only", "pid", asn], capture_output=True, text=True).stdout
            try:
                pid = int(info.strip().split("=")[-1])
            except ValueError:
                pid = -1
            if pid not in self._args:
                self._args[pid] = subprocess.run(["ps", "-o", "args=", "-p", str(pid)],
                                                 capture_output=True, text=True).stdout
            self.samples.append((frontmost(), pid))
            if self.scratch and self.scratch in self._args[pid]:
                self.lane_front.append(pid)
            self._stop.wait(0.1)

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        self._thread.join(timeout=2)


def lane_processes(scratch: pathlib.Path) -> list[str]:
    out = subprocess.run(["ps", "-axo", "pid=,args="], capture_output=True, text=True).stdout
    return [line.strip() for line in out.splitlines() if str(scratch) in line]


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


# ── helper calls ────────────────────────────────────────────────────────

def ok(frame: dict) -> dict:
    if not frame.get("ok"):
        raise AssertionError("helper refused: %s" % json.dumps(frame.get("error"))[:300])
    return frame["result"]


def expect(sock, context: str, hint: str | None = None, directory: str | None = None,
           op_id: str | None = None, **extra) -> dict:
    arguments = {"context_id": context, "op_id": op_id or "op_" + uuid.uuid4().hex, **extra}
    if hint:
        arguments["name_hint"] = hint
    if directory:
        arguments["directory"] = directory
    return raw(sock, "download.expect", arguments)


def wait(sock, download_id: str, timeout: float = 60, until: str = "terminal") -> dict:
    return ok(raw(sock, "download.wait", {"download_id": download_id, "timeout": timeout, "until": until},
                  timeout=timeout + 15))


def verified(sock, status: dict, directory: pathlib.Path, served_name: str) -> tuple[bool, str]:
    """Complete per the helper AND the file on disk hashes to what was sent."""

    if status.get("state") != "complete":
        return False, "state=%s reason=%s" % (status.get("state"), status.get("reason"))
    path = pathlib.Path(status["path"])
    checksum = ok(raw(sock, "download.status", {"download_id": status["download_id"], "checksum": True}))
    on_disk = sha256(path) if path.exists() else "absent"
    good = (path.parent == directory and path.exists() and path.stat().st_size == status["bytes"]
            and checksum.get("sha256") == on_disk == SERVED.get(served_name))
    return good, "file=%s bytes=%s sha=%s… served=%s…" % (path.name, status["bytes"], on_disk[:12],
                                                          SERVED.get(served_name, "?")[:12])


# ── scenarios ───────────────────────────────────────────────────────────

def scenario(sock, server, lane, kind, context, dl, label, path, hint, served_name, check_id, title,
             timeout=60):
    browser = Browser(kind, lane.scratch, dl, label)
    browser.open(server.url("/delay?ms=5000&to=" + urllib.parse.quote(path)))
    try:
        time.sleep(1.0)
        declared = ok(expect(sock, context, hint))
        status = wait(sock, declared["download_id"], timeout)
        good, evidence = verified(sock, status, dl, served_name)
        record("%s %s: %s" % (check_id, kind, title), good, evidence)
        return status
    finally:
        browser.stop()


def forget_all(sock) -> None:
    """Client hygiene: an interrupted download stays open until forgotten."""

    for entry in ok(raw(sock, "download.list")).get("downloads", []):
        raw(sock, "download.forget", {"download_id": entry["download_id"]})


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, type=pathlib.Path, help="built CMMComputerUse.app (dev)")
    parser.add_argument("--evidence", type=pathlib.Path, default=None)
    parser.add_argument("--browsers", default="chrome,firefox")
    args = parser.parse_args()
    assert_isolated(args.app)
    kinds = [k for k in args.browsers.split(",") if k]

    before = production_snapshot()
    lane = Lane(args.app)
    server = Server()
    dls = {"chrome": lane.scratch / "dl-chrome", "firefox": lane.scratch / "dl-firefox"}
    for path in dls.values():
        path.mkdir()
    lane.write_policy({"version": 1, "mode": "background", "default": "deny", "apps": [
        {"bundle_id": CHROME, "scopes": ["observe"], "downloads": {"roots": [str(dls["chrome"])]}},
        {"bundle_id": FIREFOX, "scopes": ["observe"], "downloads": {"roots": [str(dls["firefox"])]}},
        {"bundle_id": "com.apple.finder", "scopes": ["observe"]},
    ]})
    witness = PidWitness(str(lane.scratch))
    keepers: list[Browser] = []
    try:
        lane.start()
        sock = lane.socket
        witness.start()
        ping = ok(raw(sock, "bridge.ping"))
        caps = ping.get("capabilities", {})
        record("B0 ping advertises the browser contract and verified downloads",
               caps.get("browser", {}).get("contract") == "cmm-computer-use/browser"
               and caps.get("downloads", {}).get("verified") is True, json.dumps(caps.get("browser")))

        # A browser of each kind must be running for its context to bind.
        idle = {}
        contexts = {}
        for kind in kinds:
            idle[kind] = Browser(kind, lane.scratch, dls[kind], "idle")
            idle[kind].open("about:blank")
            keepers.append(idle[kind])
        for kind in kinds:
            bundle = CHROME if kind == "chrome" else FIREFOX
            # A browser registers with LaunchServices a few seconds after it
            # starts (Firefox: after re-executing itself on a new profile).
            deadline = time.time() + 30
            while True:
                frame = raw(sock, "workspace.context_create", {"app": bundle})
                if frame.get("ok") or time.time() > deadline:
                    break
                time.sleep(1)
            contexts[kind] = frame["result"]["context_id"] if frame.get("ok") else None
            record("B1 %s: a context binds to the browser by bundle" % kind, frame.get("ok") is True,
                   json.dumps(frame.get("error") or {"label": frame["result"].get("label")})[:200])
        kinds = [k for k in kinds if contexts.get(k)]

        # Fail closed without Accessibility: no AX read, no tab action.
        if kinds:
            first = contexts[kinds[0]]
            state = raw(sock, "browser.state", {"context_id": first})
            tab = raw(sock, "action.execute", {"kind": "browser.select_tab", "op_id": "op_" + uuid.uuid4().hex,
                                               "context_id": first, "params": {"tab_id": "tab_" + "0" * 32}})
            record("B2 without Accessibility browser.state and select_tab fail closed (nothing executed)",
                   not state.get("ok") and state["error"]["code"] == "COMPUTER_PERMISSION_DENIED"
                   and not tab.get("ok") and tab["error"].get("execution", {}).get("executed") is False,
                   "%s / %s" % (state.get("error", {}).get("code"), tab.get("error", {}).get("code")))

        for kind in kinds:
            context, dl = contexts[kind], dls[kind]
            scenario(sock, server, lane, kind, context, dl, "direct", "/direct.csv", "direct.csv",
                     "direct.csv", "B3", "direct download verified on disk (SHA-256 equals what was served)")
            scenario(sock, server, lane, kind, context, dl, "pdf", "/paper.pdf", "paper.pdf", "paper.pdf",
                     "B4", "PDF download verified")
            scenario(sock, server, lane, kind, context, dl, "zip", "/archive.zip", "archive.zip", "archive.zip",
                     "B5", "ZIP download verified")
            n = uuid.uuid4().hex[:6]
            status = scenario(sock, server, lane, kind, context, dl, "redirect", "/redirect?n=" + n, None,
                              "generated-%s.txt" % n, "B6", "302 redirect to a dynamically named file, no hint")

            # B7: two simultaneous downloads, attributed by hint.
            browser = Browser(kind, lane.scratch, dl, "multi")
            browser.open(server.url("/multi?ms=5000"))
            try:
                time.sleep(1.0)
                a = ok(expect(sock, context, "slow-a.bin"))
                b = ok(expect(sock, context, "slow-b.bin"))
                mid = wait(sock, a["download_id"], 20, until="started")
                sa = wait(sock, a["download_id"], 60)
                sb = wait(sock, b["download_id"], 60)
                ga, ea = verified(sock, sa, dl, "slow-a.bin")
                gb, eb = verified(sock, sb, dl, "slow-b.bin")
                record("B7 %s: two simultaneous downloads, each verified and attributed to its own expectation"
                       % kind, ga and gb and sa.get("file_name") == "slow-a.bin"
                       and sb.get("file_name") == "slow-b.bin", "%s | %s | first seen %s" % (ea, eb, mid.get("state")))
            finally:
                browser.stop()

            # B8: a connection cut mid-transfer is never reported complete.
            browser = Browser(kind, lane.scratch, dl, "cut")
            browser.open(server.url("/delay?ms=5000&to=/cut.bin"))
            try:
                time.sleep(1.0)
                # The server's Content-Length is declared: a browser may keep
                # a truncated file as if it had finished (Firefox does).
                declared = ok(expect(sock, context, "cut.bin", expected_bytes=len(FILES["victim.bin"][1])))
                status = wait(sock, declared["download_id"], 45)
                leftover = sorted(p.name for p in dl.iterdir() if p.name.startswith("cut"))
                record("B8 %s: an aborted transfer is seen and reported failed or interrupted, never complete" % kind,
                       status.get("state") in ("failed", "interrupted"),
                       "state=%s reason=%s resumable=%s on_disk=%s" % (status.get("state"), status.get("reason"),
                                                                        status.get("resumable"), leftover))
            finally:
                browser.stop()

            # B9: a transfer that stalls (connection open, no bytes) becomes interrupted.
            browser = Browser(kind, lane.scratch, dl, "stall")
            browser.open(server.url("/delay?ms=5000&to=/stall.bin"))
            try:
                time.sleep(1.0)
                declared = ok(expect(sock, context, "stall.bin"))
                started = wait(sock, declared["download_id"], 20, until="started")
                status = wait(sock, declared["download_id"], 40)
                record("B9 %s: a stalled transfer is reported interrupted (resumable), never complete" % kind,
                       status.get("state") == "interrupted" and status.get("resumable") is True,
                       "started=%s end=%s reason=%s bytes=%s" % (started.get("state"), status.get("state"),
                                                                 status.get("reason"), status.get("bytes")))
            finally:
                browser.stop()

            forget_all(sock)

        # B10: a browser that dies mid-download affects only its own context.
        if len(kinds) == 2:
            survivor_kind, victim_kind = kinds
            survivor = Browser(survivor_kind, lane.scratch, dls[survivor_kind], "survivor")
            victim = Browser(victim_kind, lane.scratch, dls[victim_kind], "victim")
            survivor.open(server.url("/delay?ms=5000&to=/slow-a.bin"))
            victim.open(server.url("/delay?ms=5000&to=/victim.bin"))
            try:
                time.sleep(1.0)
                sa = ok(expect(sock, contexts[survivor_kind], "slow-a.bin"))
                sv = ok(expect(sock, contexts[victim_kind], "victim.bin"))
                wait(sock, sv["download_id"], 20, until="started")
                victim.stop(signal.SIGKILL)  # the browser crashes
                good, evidence = verified(sock, wait(sock, sa["download_id"], 60), dls[survivor_kind], "slow-a.bin")
                victim_status = wait(sock, sv["download_id"], 40)
                context_ok = raw(sock, "workspace.context_status", {"context_id": contexts[survivor_kind]}).get("ok")
                record("B10 a browser crash mid-download leaves the other context and its download intact",
                       good and context_ok and victim_status.get("state") != "complete",
                       "survivor: %s | victim: state=%s reason=%s" % (evidence, victim_status.get("state"),
                                                                     victim_status.get("reason")))
            finally:
                survivor.stop()
                victim.stop()

        if kinds:
            context, kind = contexts[kinds[0]], kinds[0]
            # B11: same op_id → same expectation (a lost answer cannot declare twice).
            op = "op_" + uuid.uuid4().hex
            first = ok(expect(sock, context, "x.bin", op_id=op))
            again = ok(expect(sock, context, "x.bin", op_id=op))
            record("B11 a resent download.expect with the same op_id is the same expectation",
                   first["download_id"] == again["download_id"], first["download_id"][:12] + "…")
            # B12: ownership.
            foreign = other(sock, "download.status", {"download_id": first["download_id"]})
            record("B12 another client process cannot read this expectation",
                   not foreign.get("ok") and foreign["error"]["code"] == "DOWNLOAD_UNKNOWN",
                   foreign.get("error", {}).get("code", ""))
            # B13: roots are exact; a grant without roots watches nothing.
            outside = expect(sock, context, directory=str(lane.scratch))
            # This client already holds two contexts: the no-roots grant is
            # exercised by another client process (its own principal).
            finder = other(sock, "workspace.context_create", {"app": "com.apple.finder"})
            no_roots = other(sock, "download.expect", {"context_id": finder["result"]["context_id"],
                                                       "op_id": "op_" + uuid.uuid4().hex}) \
                if finder.get("ok") else {"error": {"code": "finder_context:" + str(finder.get("error"))}}
            record("B13 a directory outside the roots is refused; a grant without roots cannot watch",
                   outside.get("error", {}).get("code") == "DOWNLOAD_ROOT_NOT_ALLOWED"
                   and no_roots.get("error", {}).get("code") in ("DOWNLOADS_NOT_ENABLED", "CONTEXT_UNOBSERVED"),
                   "%s / %s" % (outside.get("error", {}).get("code"), no_roots.get("error", {}).get("code")))
            if finder.get("ok"):
                other(sock, "workspace.context_close", {"context_id": finder["result"]["context_id"]})
            # B14: a long wait does not hold the helper.
            pending = ok(expect(sock, context, "never.bin"))
            box: dict = {}
            waiter = threading.Thread(target=lambda: box.update(
                wait(sock, pending["download_id"], 6)), daemon=True)
            waiter.start()
            time.sleep(0.5)
            t0 = time.time()
            ping_ok = raw(sock, "workspace.status").get("ok")
            latency = time.time() - t0
            waiter.join(timeout=20)
            record("B14 a 6 s download.wait does not block other requests",
                   ping_ok and latency < 1.0 and box.get("timed_out") is True and box.get("state") == "not_started",
                   "workspace.status in %.0f ms while waiting; wait ended timed_out=%s" % (latency * 1000,
                                                                                         box.get("timed_out")))
            raw(sock, "download.forget", {"download_id": pending["download_id"]})
    finally:
        witness.stop()
        for browser in keepers:
            browser.stop()
        server.stop()
        for kind in ("chrome", "firefox"):
            for profile in lane.scratch.glob("profile-%s-*" % kind):
                stray = Browser.__new__(Browser)
                stray.profile, stray.process = profile, None
                stray.stop()
        leftovers = lane_processes(lane.scratch)
        # Lane helper first (its image is checked inside), then anything else of ours.
        lane.stop()
        record("B15 every browser the lane started is stopped (pids checked against the lane path)",
               not [p for p in leftovers if "CMMComputerUse" not in p], "; ".join(leftovers)[:300] or "none")
        lane.teardown(args.evidence)
    helper_pid = lane.process.pid if lane.process else -1
    lane_front = [s for s in witness.samples
                  if s[1] in LAUNCHED or s[1] == helper_pid or lane_mod.LANE_BUNDLE in s[0]] + witness.lane_front
    record("B16 no lane process (headless browser or lane helper) came to the front (witness every 100 ms)",
           not lane_front and len(witness.samples) > 10,
           "%d samples; fronts seen: %s" % (len(witness.samples), sorted({s[0] for s in witness.samples}))[:300])
    after = production_snapshot()
    diff = {k: (before[k], after.get(k)) for k in before if before[k] != after.get(k)}
    record("B17 production unchanged (policy, latch, audit, socket, LaunchAgent, helper binary, helper pid)",
           not diff, json.dumps(diff)[:300] if diff else "identical")

    failed = [r for r in results if r[1] != "PASS"]
    print("\n%d checks, %d failed" % (len(results), len(failed)))
    if args.evidence:
        args.evidence.mkdir(parents=True, exist_ok=True)
        (args.evidence / "browser-lane.json").write_text(json.dumps(
            [{"check": n, "result": r, "evidence": e} for n, r, e in results], indent=2))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
