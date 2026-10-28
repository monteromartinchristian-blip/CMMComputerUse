"""A scripted NDJSON helper for tests.

It is NOT a simulator of macOS behaviour: it speaks the wire protocol, records
every frame it received, and answers with whatever the test scripted. That is
enough to pin the client's and the adapter's side of the contract without a
helper, a TCC grant or a single desktop event.
"""

from __future__ import annotations

import json
import os
import socket
import tempfile
import threading
from typing import Any, Callable, Dict, List, Optional


class FakeBridge:
    def __init__(
        self,
        responder: Optional[Callable[[Dict[str, Any]], Dict[str, Any]]] = None,
        *,
        directory: Optional[str] = None,
    ) -> None:
        self._directory = directory or tempfile.mkdtemp(prefix="cmm-cu-")
        self.socket_path = os.path.join(self._directory, "bridge.sock")
        self.frames: List[Dict[str, Any]] = []
        self._responder = responder or default_responder
        self._listener: Optional[socket.socket] = None
        self._thread: Optional[threading.Thread] = None
        self._stop = threading.Event()
        self._lock = threading.Lock()
        self.connections = 0

    # ── lifecycle ─────────────────────────────────────────────────────

    def start(self) -> "FakeBridge":
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(self.socket_path)
        listener.listen(4)
        listener.settimeout(0.2)
        self._listener = listener
        self._thread = threading.Thread(target=self._accept_loop, daemon=True)
        self._thread.start()
        return self

    def stop(self) -> None:
        self._stop.set()
        if self._listener is not None:
            try:
                self._listener.close()
            except OSError:
                pass
        if self._thread is not None:
            self._thread.join(timeout=2)
        try:
            os.unlink(self.socket_path)
        except OSError:
            pass

    def __enter__(self) -> "FakeBridge":
        return self.start()

    def __exit__(self, *exc_info: Any) -> None:
        self.stop()

    # ── server ────────────────────────────────────────────────────────

    def _accept_loop(self) -> None:
        while not self._stop.is_set():
            listener = self._listener
            if listener is None:
                return
            try:
                connection, _ = listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            with self._lock:
                self.connections += 1
            threading.Thread(
                target=self._serve, args=(connection,), daemon=True
            ).start()

    def _serve(self, connection: socket.socket) -> None:
        buffer = b""
        try:
            while not self._stop.is_set():
                chunk = connection.recv(65536)
                if not chunk:
                    return
                buffer += chunk
                while b"\n" in buffer:
                    line, _, buffer = buffer.partition(b"\n")
                    if not line.strip():
                        continue
                    request = json.loads(line.decode("utf-8"))
                    with self._lock:
                        self.frames.append(request)
                    response = self._responder(request)
                    if response is None:
                        return
                    connection.sendall((json.dumps(response) + "\n").encode("utf-8"))
        except (OSError, ValueError):
            return
        finally:
            try:
                connection.close()
            except OSError:
                pass


def ok(request: Dict[str, Any], result: Any) -> Dict[str, Any]:
    return {
        "version": 1,
        "id": request.get("id"),
        "ok": True,
        "result": result,
    }


def failure(
    request: Dict[str, Any],
    code: str,
    message: str,
    detail: str = "",
    interference: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    error: Dict[str, Any] = {"code": code, "message": message, "detail": detail}
    if interference is not None:
        error["interference"] = interference
    return {
        "version": 1,
        "id": request.get("id"),
        "ok": False,
        "result": None,
        "error": error,
    }


def default_responder(request: Dict[str, Any]) -> Dict[str, Any]:
    operation = request.get("operation")
    if operation == "bridge.ping":
        return ok(
            request,
            {
                "bridge": "cmm-computer-use",
                "protocol": 1,
                "pid": 4242,
                "bundle_id": "com.cmm.chat.computer-use",
                "policy": "unrestricted",
                "authorization": {"loaded": True, "apps": 1, "default": "deny"},
            },
        )
    if operation == "permissions.status":
        return ok(
            request,
            {"accessibility": True, "screen_recording": True, "detail": ""},
        )
    if operation == "apps.list":
        return ok(
            request,
            {
                "authorized_only": True,
                "apps": [
                    {
                        "name": "Finder",
                        "bundle_id": "com.apple.finder",
                        "pid": 100,
                        "is_active": True,
                        "hidden": False,
                        "scopes": ["control", "observe"],
                        "window_limited": False,
                    }
                ],
            },
        )
    if operation == "observation.describe":
        return ok(
            request,
            {
                "frontmost_app": "Finder",
                "frontmost_bundle": "com.apple.finder",
                "target_app": "Finder",
                "target_bundle": "com.apple.finder",
                "target_is_frontmost": True,
                "snapshot": 3,
                "captured_at": 1000.0,
                "windows": [],
                "content": [],
                "elements": [
                    {
                        "element_id": 7,
                        "role": "AXButton",
                        "title": "Atrás",
                        "value": "",
                        "x": 10,
                        "y": 20,
                        "width": 30,
                        "height": 30,
                        "pressable": True,
                    }
                ],
                "screenshot_base64": None,
                "screenshot_scope": "none",
            },
        )
    if operation == "observation.release":
        return ok(request, {"released": 1, "snapshot": 3})
    if operation in ("policy.status", "policy.reload"):
        return ok(
            request,
            {
                "loaded": True,
                "source": ".cmm/computer-bridge/policy.json",
                "policy_mode": "background",
                "launch_mode": "background",
                "effective_mode": "background",
                "default": "deny",
                "apps": [
                    {
                        "bundle_id": "com.example.computer-use-fixture",
                        "name": "CMM Computer Use Fixture",
                        "scopes": ["observe", "control"],
                        "windows": 1,
                    }
                ],
            },
        )
    if operation == "observation.capture_screen":
        return ok(request, {"screenshot_base64": "QUJD", "screenshot_scope": "window"})
    if operation == "action.execute":
        kind = (request.get("arguments") or {}).get("kind")
        return ok(
            request,
            {
                "ok": True,
                "message": "pressed",
                "interference": {
                    "verdict": "untouched",
                    "frontmost_before": "Finder",
                    "frontmost_after": "Finder",
                    "cursor_moved": False,
                    "cursor_dx": 0,
                    "cursor_dy": 0,
                    "action_class": "accessibility",
                    "policy": "background",
                    "attributed": False,
                    "breach": False,
                    "kind": kind,
                },
            },
        )
    return failure(request, "CAPABILITY_UNSUPPORTED", "Unknown operation: %s" % operation)
