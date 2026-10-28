"""Client for the CMM Computer Use bridge (the signed macOS helper).

WHY THIS EXISTS
---------------

The native engine already exists: ``CMMComputerUse.app`` is a signed
LSUIElement helper, owned by a launchd job, that speaks newline-delimited JSON
over a user-private Unix socket (protocol v1, ``docs/computer-bridge-protocol.md``).
Every other client in the ecosystem needs the same three things and none of
them needs a second engine:

* the wire contract (frames, ids, error grammar, bounded sizes),
* the identity proof (this is OUR helper, not something else on the path),
* the interaction policy (what this client is willing to do to the person's
  session).

This module is the transport and identity half. The policy half lives in the
helper (``apps/apple/Shared/ComputerUsePolicy.swift``) and is enforced there:
every action request carries the policy the caller wants, and the helper
applies the STRICTER of that and its own launch policy. A client cannot widen
what the deployment allows, which is what makes "this client does not take your
focus" a property of the system rather than a promise in a README.

    client = BridgeClient(policy="background")
    client.ping()                      # identity + protocol + deployment policy
    obs = client.observe(app="Finder") # AX read, no activation
    client.press(element_id=12, snapshot=obs["snapshot"])

Nothing here reads TCC, asks for a grant, or touches the desktop on its own.
"""

from __future__ import annotations

import itertools
import json
import os
import socket
import threading
from pathlib import Path
from typing import Any, Dict, Optional

__all__ = [
    "BRIDGE_BUNDLE_ID",
    "BRIDGE_NAME",
    "DEFAULT_TIMEOUT",
    "PROTOCOL_VERSION",
    "REQUEST_BYTES_MAX",
    "RESPONSE_BYTES_MAX",
    "ACTION_KINDS",
    "POLICIES",
    "BridgeClient",
    "BridgeError",
    "BridgeProtocolError",
    "BridgeUnavailable",
    "default_socket_path",
]

PROTOCOL_VERSION = 1
BRIDGE_NAME = "cmm-computer-use"

#: The bundle identity the helper must report. A socket that answers our
#: protocol but is not this signed bundle is not the product path.
BRIDGE_BUNDLE_ID = "com.cmm.chat.computer-use"

#: Requests are control plane, never media; the helper enforces the same cap.
REQUEST_BYTES_MAX = 1_048_576
#: One PNG frame as base64 still fits under this.
RESPONSE_BYTES_MAX = 32_000_000
DEFAULT_TIMEOUT = 20.0

#: Per-operation timeouts, mirroring the helper's expectations. Observation and
#: execution can wait on the window server; nothing waits forever.
OPERATION_TIMEOUTS = {
    "bridge.ping": 10.0,
    "permissions.status": 10.0,
    "apps.list": 10.0,
    "observation.describe": 20.0,
    "observation.release": 10.0,
    "observation.capture_screen": 30.0,
    "action.execute": 60.0,
}

#: Frozen action vocabulary (parity with the helper's allowlist and CMM OS's
#: ACTION_KINDS). Unknown names are refused on both sides.
ACTION_KINDS = frozenset(
    {
        "app.open",
        "app.activate",
        "window.focus",
        "ui.press",
        "ui.set_value",
        "keyboard.type",
        "keyboard.shortcut",
        "pointer.click",
        "pointer.scroll",
        "wait",
        "finish",
    }
)

#: Interaction policies, strictest first. ``background`` is the default this
#: client asks for: accessibility primitives only.
POLICIES = ("background", "focus", "unrestricted")

#: The frozen error grammar. Anything else a helper sends is carried as a
#: generic action failure rather than invented here.
ERROR_CODES = frozenset(
    {
        "COMPUTER_RUNTIME_UNAVAILABLE",
        "COMPUTER_PERMISSION_DENIED",
        "COMPUTER_TARGET_UNAVAILABLE",
        "ACTION_FAILED",
        "APPROVAL_REJECTED",
        "CAPABILITY_UNSUPPORTED",
        "CANCELLED",
    }
)


def default_socket_path() -> str:
    """Rendezvous of the app-served helper.

    ``CMM_COMPUTER_BRIDGE_SOCKET`` overrides it, exactly as the CMM OS client
    does, so a test or a nonstandard install can point at its own socket.
    """

    override = os.environ.get("CMM_COMPUTER_BRIDGE_SOCKET")
    if override:
        return override
    return str(Path.home() / ".cmm" / "computer-bridge" / "bridge.sock")


class BridgeError(Exception):
    """A typed refusal from the helper, or a failure to reach it.

    A failed action still carries the helper's interference ledger
    (``error.interference``): the ledger answers "what did this attempt do to
    the person's session", which a caller needs precisely when the action did
    not succeed. Dropping it here would erase the only evidence a model could
    report, so it travels with the error instead of being flattened into the
    detail string.
    """

    def __init__(
        self,
        message: str,
        *,
        code: str = "ACTION_FAILED",
        detail: str = "",
        interference: Optional[Dict[str, Any]] = None,
    ) -> None:
        super().__init__(message)
        self.message = message
        self.code = code if code in ERROR_CODES else "ACTION_FAILED"
        self.detail = detail
        self.interference = interference if isinstance(interference, dict) else None

    def as_dict(self) -> Dict[str, Any]:
        payload: Dict[str, Any] = {
            "code": self.code,
            "message": self.message,
            "detail": self.detail,
        }
        if self.interference is not None:
            payload["interference"] = self.interference
        return payload


class BridgeUnavailable(BridgeError):
    """The helper could not be reached, or did not identify itself as ours."""

    def __init__(self, message: str, *, detail: str = "") -> None:
        super().__init__(message, code="COMPUTER_RUNTIME_UNAVAILABLE", detail=detail)


class BridgeProtocolError(BridgeUnavailable):
    """The helper answered outside the protocol; the connection is dropped."""


class BridgeClient:
    """One supervised helper connection speaking protocol v1.

    Single in-flight request (guarded by a lock): the helper serialises
    dispatch anyway, and matching by id on one stream is what makes a late
    answer impossible to mistake for the next request's response.
    """

    def __init__(
        self,
        socket_path: Optional[str] = None,
        *,
        policy: str = "background",
        timeout: float = DEFAULT_TIMEOUT,
    ) -> None:
        if policy not in POLICIES:
            raise ValueError(
                "policy must be one of %s, not %r" % (", ".join(POLICIES), policy)
            )
        self.socket_path = socket_path or default_socket_path()
        self.policy = policy
        self.timeout = timeout
        self._lock = threading.Lock()
        self._ids = itertools.count(1)
        self._socket: Optional[socket.socket] = None
        self._buffer = b""

    # ── lifecycle ─────────────────────────────────────────────────────

    def close(self) -> None:
        with self._lock:
            self._close_locked()

    def _close_locked(self) -> None:
        sock, self._socket = self._socket, None
        self._buffer = b""
        if sock is None:
            return
        try:
            sock.close()
        except OSError:
            pass

    @property
    def connected(self) -> bool:
        return self._socket is not None

    def __enter__(self) -> "BridgeClient":
        return self

    def __exit__(self, *exc_info: Any) -> None:
        self.close()

    # ── transport ─────────────────────────────────────────────────────

    def _ensure_connected_locked(self) -> socket.socket:
        if self._socket is not None:
            return self._socket
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.settimeout(5.0)
            sock.connect(self.socket_path)
            sock.settimeout(None)
        except (OSError, ValueError) as error:
            try:
                sock.close()
            except OSError:
                pass
            raise BridgeUnavailable(
                "The computer bridge is not serving (is CMM Computer Use running?).",
                detail=type(error).__name__,
            ) from error
        self._socket = sock
        self._buffer = b""
        return sock

    def _read_frame_locked(self, sock: socket.socket, limit: float) -> str:
        sock.settimeout(limit)
        while b"\n" not in self._buffer:
            chunk = sock.recv(65536)
            if not chunk:
                self._close_locked()
                raise BridgeUnavailable("The computer bridge closed the connection.")
            self._buffer += chunk
            if len(self._buffer) > RESPONSE_BYTES_MAX:
                self._close_locked()
                raise BridgeProtocolError("The computer bridge answered beyond the bounded size.")
        line, _, self._buffer = self._buffer.partition(b"\n")
        try:
            return line.decode("utf-8")
        except UnicodeDecodeError as error:
            self._close_locked()
            raise BridgeProtocolError(
                "The computer bridge answered with undecodable bytes.",
                detail=type(error).__name__,
            ) from error

    def request(
        self,
        operation: str,
        arguments: Optional[Dict[str, Any]] = None,
        *,
        timeout: Optional[float] = None,
    ) -> Any:
        """Send one versioned request and return its ``result``.

        Raises :class:`BridgeError` for a typed refusal and
        :class:`BridgeUnavailable` when the transport fails. A timeout closes
        the connection: a late answer must never surface as the next request's
        response.
        """

        if not operation or not isinstance(operation, str):
            raise ValueError("an operation name is required")
        request_id = "py-%d" % next(self._ids)
        payload = {
            "version": PROTOCOL_VERSION,
            "id": request_id,
            "operation": operation,
            "arguments": dict(arguments or {}),
        }
        try:
            body = json.dumps(payload).encode("utf-8")
        except (TypeError, ValueError) as error:
            raise ValueError("the request arguments are not JSON-encodable") from error
        if len(body) > REQUEST_BYTES_MAX:
            raise ValueError("the request exceeds the bounded size")
        limit = timeout or OPERATION_TIMEOUTS.get(operation, self.timeout)

        with self._lock:
            sock = self._ensure_connected_locked()
            try:
                sock.settimeout(limit)
                sock.sendall(body + b"\n")
                frame = json.loads(self._read_frame_locked(sock, limit))
            except socket.timeout as error:
                self._close_locked()
                raise BridgeUnavailable(
                    "The computer bridge did not answer %s in time." % operation,
                    detail="%gs" % limit,
                ) from error
            except (BrokenPipeError, ConnectionResetError, OSError) as error:
                self._close_locked()
                raise BridgeUnavailable(
                    "The computer bridge closed its request channel.",
                    detail=type(error).__name__,
                ) from error
            except ValueError as error:
                # json.loads: the helper answered outside the protocol.
                self._close_locked()
                raise BridgeProtocolError(
                    "The computer bridge answered with malformed JSON.",
                    detail=type(error).__name__,
                ) from error
        return self._decode(frame, request_id, operation)

    def _decode(self, frame: Any, request_id: str, operation: str) -> Any:
        # A frame that violates the protocol means the stream is no longer
        # trustworthy: drop it here so a desynchronised connection can never be
        # reused for the next request.
        if not isinstance(frame, dict):
            self._close_locked()
            raise BridgeProtocolError("The computer bridge answered outside the protocol.")
        if frame.get("version") != PROTOCOL_VERSION:
            self._close_locked()
            raise BridgeProtocolError("The computer bridge answered with the wrong protocol version.")
        if frame.get("id") != request_id:
            self._close_locked()
            raise BridgeProtocolError("The computer bridge answered for a different request.")
        if frame.get("ok") is True:
            return frame.get("result")
        error = frame.get("error")
        code = error.get("code") if isinstance(error, dict) else None
        message = error.get("message") if isinstance(error, dict) else None
        detail = error.get("detail") if isinstance(error, dict) else ""
        interference = error.get("interference") if isinstance(error, dict) else None
        raise BridgeError(
            str(message or "The computer bridge refused %s." % operation),
            code=str(code or "ACTION_FAILED"),
            detail=str(detail or "")[:500],
            interference=interference,
        )

    # ── contract ──────────────────────────────────────────────────────

    def ping(self) -> Dict[str, Any]:
        """Prove the server is OUR helper and report its deployment policy.

        A socket that exists proves nothing: a stale file, a wedged job and a
        foreign process on the path all look identical until the answer names
        the bundle. ``policy`` in the answer is what the helper was launched
        with, which may be stricter than what this client asked for.
        """

        result = self.request("bridge.ping")
        if not isinstance(result, dict):
            raise BridgeProtocolError("The computer bridge ping returned no object.")
        if result.get("bridge") != BRIDGE_NAME or result.get("protocol") != PROTOCOL_VERSION:
            raise BridgeUnavailable("The computer bridge answered, but not as the product helper.")
        bundle = result.get("bundle_id", "")
        if bundle != BRIDGE_BUNDLE_ID:
            raise BridgeUnavailable(
                "The computer bridge has an unexpected application identity.",
                detail=str(bundle)[:120],
            )
        return result

    def status(self) -> Dict[str, Any]:
        """Permissions as the helper measured them (never inferred here)."""

        return self.request("permissions.status")

    def apps(self) -> Any:
        return self.request("apps.list")

    def observe(self, app: Optional[str] = None, include_screenshot: bool = False) -> Any:
        """Observe one application (or the frontmost one) without activating it.

        Reading another application's accessibility tree does not bring it
        forward; that is what makes background observation possible. A named
        app that is not running is a ``COMPUTER_TARGET_UNAVAILABLE`` refusal,
        never an empty observation.

        The policy travels here too: in ``background`` mode a screenshot must
        name an application, so a display capture cannot be requested by a
        stricter client against a permissive deployment.
        """

        arguments: Dict[str, Any] = {
            "include_screenshot": bool(include_screenshot),
            "policy": self.policy,
        }
        if app:
            arguments["app"] = app
        return self.request("observation.describe", arguments)

    def capture_window(self, app: str, window_title: str) -> Any:
        """Capture exactly one window (base64 PNG), refusing ambiguity."""

        return self.request(
            "observation.capture_screen",
            {"app": app, "window_title": window_title, "policy": self.policy},
        )

    def release(self) -> Any:
        """Drop the helper's element handles for this session."""

        return self.request("observation.release")

    def policy_status(self) -> Any:
        """The deployment's allowlist as diagnostics (never window content)."""

        return self.request("policy.status")

    def reload_policy(self) -> Any:
        """Re-read the allowlist from disk (the user's own file)."""

        return self.request("policy.reload")

    def act(self, kind: str, **params: Any) -> Any:
        """Execute one allowlisted action under this client's policy.

        The policy travels with the request so the helper can enforce it even
        when the deployment is more permissive than this client is willing to
        be.
        """

        if kind not in ACTION_KINDS:
            raise ValueError("unknown action kind: %r" % (kind,))
        return self.request(
            "action.execute", {"kind": kind, "params": params, "policy": self.policy}
        )
