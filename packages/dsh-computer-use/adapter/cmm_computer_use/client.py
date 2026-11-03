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
import time
import uuid
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
    "BridgeOutcomeUnknown",
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
    "breach.status": 10.0,
    "observation.capture_screen": 30.0,
    "action.execute": 60.0,
    "action.outcome": 10.0,
    # 0.3.3 Multi-App Workspace. Bookkeeping is fast; starting or recovering
    # a stream waits on ScreenCaptureKit; a frame is a memory read.
    "workspace.status": 10.0,
    "workspace.context_create": 10.0,
    "workspace.context_list": 10.0,
    "workspace.context_status": 10.0,
    "workspace.context_close": 10.0,
    "observation.stream_start": 20.0,
    "observation.stream_stop": 10.0,
    "observation.stream_frame": 5.0,
    "observation.stream_status": 10.0,
    "observation.stream_recover": 25.0,
}

#: Operations that never change anything outside the helper's own read path:
#: retried after a transport failure with bounded backoff. Mirrors
#: ``bridgeRetryClass`` in apps/macos/Shared/ComputerUseReliability.swift.
READ_OPERATIONS = frozenset(
    {
        "bridge.ping", "permissions.status", "policy.status", "breach.status", "apps.list",
        "observation.describe", "observation.capture_screen", "observation.stream_frame",
        "observation.stream_status", "workspace.status", "workspace.context_list",
        "workspace.context_status", "action.outcome",
    }
)
#: Helper bookkeeping that is idempotent: one retry.
IDEMPOTENT_OPERATIONS = frozenset(
    {"observation.release", "observation.stream_stop", "workspace.context_close"}
)
RETRY_DELAYS = {"read": (0.25, 0.75), "idempotent": (0.25,), "mutating": ()}

#: Action kinds that do nothing to any application: everything else is
#: mutating and is NEVER resent automatically.
NON_MUTATING_KINDS = frozenset({"wait", "finish"})

#: Frozen action vocabulary (parity with the helper's allowlist and CMM OS's
#: ACTION_KINDS). Unknown names are refused on both sides.
ACTION_KINDS = frozenset(
    {
        "app.open",
        "app.activate",
        "window.focus",
        "ui.press",
        "ui.set_value",
        "ui.scroll",
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
        # The action ran and brought its target in front of the person's work
        # in a no-interference mode; the helper fails it closed.
        "INTERFERENCE_BREACH",
        # 0.3.3 Multi-App Workspace.
        "CONTEXT_UNKNOWN",
        "CONTEXT_CLOSED",
        "CONTEXT_LIMIT",
        "CONTEXT_TARGET_MISMATCH",
        "STREAM_UNKNOWN",
        "STREAM_LIMIT",
        "STREAM_IDENTITY_MISMATCH",
        "STREAM_RECOVERY_EXHAUSTED",
        "STREAM_RECOVERY_BACKOFF",
        "OPERATION_ID_CONFLICT",
        "OPERATION_IN_PROGRESS",
        # Adapter-side: the answer to a mutating action was lost and nobody
        # can say whether it ran. Never resent automatically.
        "OUTCOME_UNKNOWN",
    }
)


def retry_class(operation: str, kind: Optional[str] = None) -> str:
    """``read`` / ``idempotent`` / ``mutating`` — unknown fails closed."""

    if operation == "action.execute":
        return "read" if kind in NON_MUTATING_KINDS else "mutating"
    if operation in READ_OPERATIONS:
        return "read"
    if operation in IDEMPOTENT_OPERATIONS:
        return "idempotent"
    return "mutating"


def new_operation_id() -> str:
    """A fresh, unpredictable operation id (``op_`` + 128 random bits)."""

    return "op_" + uuid.uuid4().hex


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
        scroll: Optional[Dict[str, Any]] = None,
        set_value: Optional[Dict[str, Any]] = None,
        execution: Optional[Dict[str, Any]] = None,
    ) -> None:
        super().__init__(message)
        self.message = message
        self.code = code if code in ERROR_CODES else "ACTION_FAILED"
        self.detail = detail
        self.interference = interference if isinstance(interference, dict) else None
        #: `ui.scroll` evidence (routes tried, measured before/after, AX errors)
        #: when the helper attached it to a failure.
        self.scroll = scroll if isinstance(scroll, dict) else None
        #: `ui.set_value` evidence (check, lengths, AX error) on a failure.
        self.set_value = set_value if isinstance(set_value, dict) else None
        #: 0.3.3: whether the action was handed to the machine and its
        #: outcome (`not_executed` / `succeeded` / `failed`), op id, instance.
        self.execution = execution if isinstance(execution, dict) else None

    def as_dict(self) -> Dict[str, Any]:
        payload: Dict[str, Any] = {
            "code": self.code,
            "message": self.message,
            "detail": self.detail,
        }
        if self.interference is not None:
            payload["interference"] = self.interference
        if self.execution is not None:
            payload["execution"] = self.execution
        return payload


class BridgeUnavailable(BridgeError):
    """The helper could not be reached, or did not identify itself as ours."""

    def __init__(self, message: str, *, detail: str = "") -> None:
        super().__init__(message, code="COMPUTER_RUNTIME_UNAVAILABLE", detail=detail)


class BridgeProtocolError(BridgeUnavailable):
    """The helper answered outside the protocol; the connection is dropped."""


class BridgeOutcomeUnknown(BridgeError):
    """The answer to a MUTATING action was lost and its outcome cannot be
    established: it may or may not have run. Never resent automatically.

    ``reason`` says why the ledger could not answer: the helper restarted
    (``helper_restarted``), it never recorded the id (``not_recorded``), it is
    still executing it (``in_progress``) or it could not be reached
    (``unreachable``).
    """

    def __init__(self, message: str, *, op_id: str, reason: str,
                 cause: Optional[BaseException] = None) -> None:
        cause_kind = "protocol" if isinstance(cause, BridgeProtocolError) else "transport"
        if cause is not None:
            message = "%s Transport: %s" % (message, getattr(cause, "message", str(cause)))
        super().__init__(message, code="OUTCOME_UNKNOWN",
                         detail="reason=%s;op_id=%s;cause=%s" % (reason, op_id, cause_kind),
                         execution={"executed": None, "outcome": "unknown", "op_id": op_id})
        self.op_id = op_id
        self.reason = reason
        #: The transport failure that lost the answer (timeout, closed socket,
        #: protocol violation). The connection it happened on was dropped.
        self.cause = cause


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
        #: The helper process last seen answering (0.3.3 ``instance_id``). A
        #: change means it restarted: contexts, streams and recorded outcomes
        #: of the previous instance are gone.
        self.instance_id: Optional[str] = None
        #: Injected for tests; the retry backoff sleeps through it.
        self._sleep = time.sleep

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

        Transport failures are retried ONLY for reads and idempotent helper
        bookkeeping (:func:`retry_class`), with bounded backoff. A mutating
        request is sent once: a timeout does not mean it did not run.
        """

        kind = (arguments or {}).get("kind") if operation == "action.execute" else None
        delays = RETRY_DELAYS[retry_class(operation, kind)]
        attempt = 0
        while True:
            try:
                result = self._request_once(operation, arguments, timeout=timeout)
            except BridgeUnavailable:
                if attempt >= len(delays):
                    raise
                self._sleep(delays[attempt])
                attempt += 1
                continue
            self._note_instance(result)
            return result

    def _note_instance(self, result: Any) -> None:
        if not isinstance(result, dict):
            return
        instance = result.get("instance_id")
        execution = result.get("execution")
        if not instance and isinstance(execution, dict):
            instance = execution.get("instance_id")
        if isinstance(instance, str) and instance:
            self.instance_id = instance

    def _request_once(
        self,
        operation: str,
        arguments: Optional[Dict[str, Any]] = None,
        *,
        timeout: Optional[float] = None,
    ) -> Any:

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
        scroll = error.get("scroll") if isinstance(error, dict) else None
        set_value = error.get("set_value") if isinstance(error, dict) else None
        execution = error.get("execution") if isinstance(error, dict) else None
        if isinstance(execution, dict) and isinstance(execution.get("instance_id"), str):
            self.instance_id = execution["instance_id"]
        raise BridgeError(
            str(message or "The computer bridge refused %s." % operation),
            code=str(code or "ACTION_FAILED"),
            detail=str(detail or "")[:500],
            interference=interference,
            scroll=scroll,
            set_value=set_value,
            execution=execution,
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

    def observe(self, app: Optional[str] = None, include_screenshot: bool = False,
                include_ax_diagnostics: bool = False, element_filter: Optional[str] = None,
                context_id: Optional[str] = None) -> Any:
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
        if include_ax_diagnostics:
            # Read-only deep scan of the tree (roles, depth, would-be controls).
            arguments["include_ax_diagnostics"] = True
        needle = (element_filter or "").strip()
        if needle:
            # Pushed down so the helper looks for it BEFORE its element budget:
            # a named control is not lost because unrelated controls filled
            # the ordinary projection. Same app, same authorization.
            arguments["element_filter"] = needle[:200]
        if context_id:
            # 0.3.3: observe INTO one context. Its generation and handles move;
            # no other context's do. Absent, the 0.3.2 default context is used.
            arguments["context_id"] = context_id
        return self.request("observation.describe", arguments)

    def capture_window(self, app: str, window_title: str, context_id: Optional[str] = None) -> Any:
        """Capture exactly one window (base64 PNG), refusing ambiguity."""

        arguments: Dict[str, Any] = {"app": app, "window_title": window_title, "policy": self.policy}
        if context_id:
            arguments["context_id"] = context_id
        return self.request("observation.capture_screen", arguments)

    def release(self, context_id: Optional[str] = None) -> Any:
        """Drop the helper's element handles for one context (default: the
        0.3.2 default context of this client)."""

        return self.request("observation.release", {"context_id": context_id} if context_id else {})

    # ── 0.3.3 workspace ───────────────────────────────────────────────

    def workspace_status(self) -> Any:
        """This client's contexts and streams, the limits, the instance id."""

        return self.request("workspace.status")

    def context_create(self, app: Optional[str] = None) -> Any:
        """Open a context (optionally bound to one authorized application)."""

        return self.request("workspace.context_create", {"app": app} if app else {})

    def context_list(self) -> Any:
        return self.request("workspace.context_list")

    def context_status(self, context_id: str) -> Any:
        return self.request("workspace.context_status", {"context_id": context_id})

    def context_close(self, context_id: str) -> Any:
        """Close a context: its handles drop and its stream stops. Idempotent."""

        return self.request("workspace.context_close", {"context_id": context_id})

    def stream_start(self, *, app: Optional[str] = None, window_title: str = "",
                     window_id: Optional[int] = None, context_id: Optional[str] = None,
                     stream_key: Optional[str] = None, expected_bundle: Optional[str] = None,
                     expected_pid: Optional[int] = None) -> Any:
        arguments: Dict[str, Any] = {"policy": self.policy, "window_title": window_title}
        for key, value in (("app", app), ("window_id", window_id), ("context_id", context_id),
                           ("stream_key", stream_key), ("expected_bundle", expected_bundle),
                           ("expected_pid", expected_pid)):
            if value is not None and value != "":
                arguments[key] = value
        return self.request("observation.stream_start", arguments)

    def stream_stop(self, stream_id: Optional[str] = None, context_id: Optional[str] = None) -> Any:
        arguments: Dict[str, Any] = {}
        if stream_id:
            arguments["stream_id"] = stream_id
        elif context_id:
            arguments["context_id"] = context_id
        return self.request("observation.stream_stop", arguments)

    def stream_frame(self, stream_id: Optional[str] = None) -> Any:
        return self.request("observation.stream_frame", {"stream_id": stream_id} if stream_id else {})

    def stream_status(self, stream_id: Optional[str] = None) -> Any:
        return self.request("observation.stream_status", {"stream_id": stream_id} if stream_id else {})

    def stream_recover(self, stream_id: str) -> Any:
        return self.request("observation.stream_recover", {"stream_id": stream_id})

    def action_outcome(self, op_id: str) -> Any:
        return self.request("action.outcome", {"op_id": op_id})

    def policy_status(self) -> Any:
        """The deployment's allowlist as diagnostics (never window content)."""

        return self.request("policy.status")

    def breach_status(self) -> Any:
        """Open breach latches, read-only. There is deliberately no rearm here:
        clearing a latch is CMM Console's audited operation, under its own
        signed identity, never the agent's."""

        return self.request("breach.status")

    def reload_policy(self) -> Any:
        """Re-read the allowlist from disk (the user's own file)."""

        return self.request("policy.reload")

    def act(self, kind: str, *, context_id: Optional[str] = None,
            op_id: Optional[str] = None, **params: Any) -> Any:
        """Execute one allowlisted action under this client's policy.

        The policy travels with the request so the helper can enforce it even
        when the deployment is more permissive than this client is willing to
        be.

        A mutating action carries an operation id and is sent ONCE. If its
        answer is lost (timeout, closed socket, helper restart) it is never
        resent: the helper's ledger is asked what happened to that id, and
        when it cannot say, :class:`BridgeOutcomeUnknown` is raised.
        """

        if kind not in ACTION_KINDS:
            raise ValueError("unknown action kind: %r" % (kind,))
        arguments: Dict[str, Any] = {"kind": kind, "params": params, "policy": self.policy}
        if context_id:
            arguments["context_id"] = context_id
        mutating = kind not in NON_MUTATING_KINDS
        if mutating:
            arguments["op_id"] = op_id or new_operation_id()
        instance_before = self.instance_id
        try:
            return self.request("action.execute", arguments)
        except BridgeUnavailable as lost:
            if not mutating:
                raise
            return self._recover_lost_outcome(arguments["op_id"], instance_before, lost)

    def _recover_lost_outcome(self, op_id: str, instance_before: Optional[str],
                              lost: BridgeUnavailable) -> Any:
        """Establish what happened to a mutating action whose answer was lost.

        Only READS are sent here (``bridge.ping``, ``action.outcome``); the
        action itself is never sent again. A recorded outcome is reported
        (``recovered: True``); anything else is ``OUTCOME_UNKNOWN``.
        """

        try:
            ping = self.ping()
        except BridgeError:
            raise BridgeOutcomeUnknown(
                "The answer to this action was lost and the helper cannot be reached; it may or "
                "may not have run. Do not resend it; observe again once the helper is back.",
                op_id=op_id, reason="unreachable", cause=lost) from lost
        instance = ping.get("instance_id") if isinstance(ping, dict) else None
        if not instance:
            raise BridgeOutcomeUnknown(
                "The answer to this action was lost and this helper keeps no outcome ledger; it may "
                "or may not have run. Do not resend it; observe again.",
                op_id=op_id, reason="no_ledger", cause=lost) from lost
        if instance_before and instance != instance_before:
            raise BridgeOutcomeUnknown(
                "The helper restarted while this action was in flight; it may or may not have run. "
                "Do not resend it; create contexts and observe again.",
                op_id=op_id, reason="helper_restarted", cause=lost) from lost
        reason = "not_recorded"
        for attempt in range(3):
            outcome = self.action_outcome(op_id)
            if isinstance(outcome, dict) and outcome.get("known") is True:
                recorded = str(outcome.get("outcome") or "unknown")
                execution = {"executed": True, "outcome": recorded, "op_id": op_id,
                             "instance_id": instance, "replayed": False, "recovered": True}
                if recorded == "succeeded":
                    return {"message": "outcome recovered from the helper's ledger after a lost answer",
                            "execution": execution}
                raise BridgeError(
                    "The action ran and failed (recovered from the helper's ledger after a lost answer).",
                    code="ACTION_FAILED", detail="reason=recorded_%s;op_id=%s" % (recorded, op_id),
                    execution=execution)
            if isinstance(outcome, dict) and outcome.get("outcome") == "in_progress":
                reason = "in_progress"
                self._sleep(0.5 * (attempt + 1))
                continue
            break
        raise BridgeOutcomeUnknown(
            "The answer to this action was lost and the helper has no record of its outcome; it may "
            "or may not have run. Do not resend it; observe again to see the current state.",
            op_id=op_id, reason=reason, cause=lost) from lost
