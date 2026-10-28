"""MCP stdio adapter for the CMM Computer Use bridge.

WHAT THIS IS
------------

A thin, stateless adapter: MCP tool call -> ``BridgeClient.act``/``.observe``
-> newline-delimited JSON on the helper's Unix socket. It is NOT a second
engine, it owns no permissions, and it never touches TCC or the window server
directly. Every guarantee it offers is the helper's (see
``apps/apple/Shared/ComputerUsePolicy.swift``).

NOTHING HERE IS INSTALLED
-------------------------

DeepSeek Harness is not modified and no profile, plugin or ``~/.dsh`` file is
touched by this repository. The intended wiring is described in
``docs/architecture/CMM-ComputerUse-Reutilizacion-Evidencia.md``: DSH's
``@deepseek-ai/dsh-mcp-client`` launches this file over stdio and sees the
``computer_use_*`` tools under one stable server namespace.

WHY THE TOOL LIST DEPENDS ON THE MODE
-------------------------------------

An agent should not be shown tools it cannot use. In the default ``background``
mode there is no tool that activates an application, moves the pointer or types
into whatever holds focus: the adapter would only ever relay a refusal, and an
allowlist that never lists them is easier to audit than one that lists and
rejects them. Raising the mode is an explicit operator decision
(``--mode focus`` or ``--mode unrestricted``), and the helper still applies the
stricter of that and its own launch policy.
"""

from __future__ import annotations

import argparse
import json
import sys
from typing import Any, Dict, List, Optional, TextIO

from .client import (
    ACTION_KINDS,
    POLICIES,
    BridgeClient,
    BridgeError,
    BridgeProtocolError,
    BridgeUnavailable,
    default_socket_path,
)

__all__ = [
    "READ_ONLY_TOOLS",
    "SERVER_NAME",
    "SERVER_VERSION",
    "ToolRegistry",
    "main",
    "serve",
]

SERVER_NAME = "cmm-computer-use"
SERVER_VERSION = "0.1.0"

#: Tools that only read. Everything else changes the helper's state or acts on
#: another application, so the distinction is published in the MCP tool
#: annotations instead of living only in prose: a host that respects
#: ``readOnlyHint`` can auto-approve these and still ask about ``press``.
READ_ONLY_TOOLS = frozenset(
    {
        "computer_use_status",
        "computer_use_list_apps",
        "computer_use_observe",
        "computer_use_capture_window",
    }
)

#: MCP revisions this adapter knows how to answer. The server echoes the
#: client's choice when it is one of these and otherwise states its own.
SUPPORTED_PROTOCOL_VERSIONS = ("2024-11-05", "2025-03-26", "2025-06-18")
DEFAULT_PROTOCOL_VERSION = "2024-11-05"

#: Bound on the observation text handed to a model. The helper already bounds
#: its own lists; this is the adapter's own display budget.
MAX_ELEMENTS_IN_TEXT = 40
MAX_CONTENT_IN_TEXT = 60


def _schema(
    properties: Dict[str, Any], required: Optional[List[str]] = None
) -> Dict[str, Any]:
    return {
        "type": "object",
        "properties": properties,
        "required": required or [],
        "additionalProperties": False,
    }


class ToolRegistry:
    """The tools this adapter exposes, filtered by the effective mode."""

    def __init__(self, client: BridgeClient, mode: str) -> None:
        if mode not in POLICIES:
            raise ValueError("mode must be one of %s" % ", ".join(POLICIES))
        self.client = client
        self.mode = mode

    # ── catalog ───────────────────────────────────────────────────────

    def tools(self) -> List[Dict[str, Any]]:
        tools = [
            {
                "name": "computer_use_status",
                "description": (
                    "Report the macOS Computer Use helper's identity, its "
                    "interaction policy and the Accessibility / Screen Recording "
                    "permissions it measured. Read-only."
                ),
                "inputSchema": _schema({}),
            },
            {
                "name": "computer_use_list_apps",
                "description": (
                    "List running applications (name, bundle id, pid, whether "
                    "active). Read-only; activates nothing."
                ),
                "inputSchema": _schema({}),
            },
            {
                "name": "computer_use_observe",
                "description": (
                    "Read the accessibility tree of one application's window "
                    "WITHOUT activating it. Returns interactive elements (with "
                    "element ids), readable content, on-screen windows and the "
                    "snapshot generation. Element ids are only valid for the "
                    "snapshot that produced them and expire in 30 seconds."
                ),
                "inputSchema": _schema(
                    {
                        "app": {
                            "type": "string",
                            "description": "Application name or bundle id. Omit for the frontmost app.",
                        },
                        "filter": {
                            "type": "string",
                            "description": (
                                "Only list interactive elements whose title, value "
                                "or role contains this text (case-insensitive). Use "
                                "it when the element you need is past the 40-item cut."
                            ),
                        },
                        "include_screenshot": {
                            "type": "boolean",
                            "description": (
                                "Include a PNG of the target window. In background "
                                "mode this requires 'app' and captures only that "
                                "window, never the display."
                            ),
                            "default": False,
                        },
                    }
                ),
            },
            {
                "name": "computer_use_capture_window",
                "description": (
                    "Capture exactly ONE window as a PNG, selected by application "
                    "and title fragment. Refuses when several windows match; "
                    "never falls back to a display capture."
                ),
                "inputSchema": _schema(
                    {
                        "app": {"type": "string", "description": "Application name or bundle id."},
                        "window_title": {
                            "type": "string",
                            "description": "Window title or fragment.",
                        },
                    },
                    required=["app", "window_title"],
                ),
            },
            {
                "name": "computer_use_press",
                "description": (
                    "Press one accessibility element of an observed window "
                    "(AXPress: the application's own action, no synthetic input). "
                    "Requires the element id and the snapshot it came from. The "
                    "result reports whether the action changed the frontmost "
                    "application or the cursor."
                ),
                "inputSchema": _schema(
                    {
                        "element_id": {"type": "integer", "minimum": 1},
                        "snapshot": {
                            "type": "integer",
                            "minimum": 1,
                            "description": "Snapshot generation returned by computer_use_observe.",
                        },
                    },
                    required=["element_id", "snapshot"],
                ),
            },
            {
                "name": "computer_use_set_value",
                "description": (
                    "Set the value of one accessibility text field (AXSetAttributeValue). "
                    "No keystrokes are synthesized and the field's application need not "
                    "be frontmost. Secure text fields are refused by the helper."
                ),
                "inputSchema": _schema(
                    {
                        "element_id": {"type": "integer", "minimum": 1},
                        "text": {"type": "string", "maxLength": 65536},
                        "snapshot": {"type": "integer", "minimum": 1},
                    },
                    required=["element_id", "text", "snapshot"],
                ),
            },
            {
                "name": "computer_use_release",
                "description": "Drop the element handles the helper holds for this session.",
                "inputSchema": _schema({}),
            },
        ]
        if self.mode in ("focus", "unrestricted"):
            tools.extend(
                [
                    {
                        "name": "computer_use_activate_app",
                        "description": (
                            "Bring an application to the front. THIS CHANGES THE "
                            "PERSON'S FOCUS; the policy in force allows it, but it "
                            "is an announced side effect and the result reports it."
                        ),
                        "inputSchema": _schema(
                            {"app": {"type": "string"}}, required=["app"]
                        ),
                    },
                    {
                        "name": "computer_use_focus_window",
                        "description": (
                            "Raise one window of a running application, activating "
                            "its owner first when needed. Changes focus."
                        ),
                        "inputSchema": _schema(
                            {"window_title": {"type": "string"}},
                            required=["window_title"],
                        ),
                    },
                ]
            )
        if self.mode == "unrestricted":
            tools.extend(
                [
                    {
                        "name": "computer_use_click",
                        "description": (
                            "UNSAFE: post a global click at absolute screen "
                            "coordinates. Moves the system cursor and lands on "
                            "whatever is topmost. Only available in unrestricted mode."
                        ),
                        "inputSchema": _schema(
                            {
                                "x": {"type": "number"},
                                "y": {"type": "number"},
                            },
                            required=["x", "y"],
                        ),
                    },
                    {
                        "name": "computer_use_type_text",
                        "description": (
                            "UNSAFE: type text through a global Cmd+V event. Reaches "
                            "whichever application holds the keyboard focus and "
                            "rewrites the pasteboard. Only available in unrestricted mode."
                        ),
                        "inputSchema": _schema(
                            {"text": {"type": "string", "maxLength": 65536}},
                            required=["text"],
                        ),
                    },
                    {
                        "name": "computer_use_shortcut",
                        "description": (
                            "UNSAFE: post a global keyboard shortcut. Only available "
                            "in unrestricted mode."
                        ),
                        "inputSchema": _schema(
                            {"keys": {"type": "string"}}, required=["keys"]
                        ),
                    },
                    {
                        "name": "computer_use_scroll",
                        "description": (
                            "UNSAFE: post a global scroll event at the cursor. Only "
                            "available in unrestricted mode."
                        ),
                        "inputSchema": _schema(
                            {"dy": {"type": "integer", "minimum": -100, "maximum": 100}},
                        ),
                    },
                ]
            )
        self._annotate(tools)
        return tools

    @staticmethod
    def _annotate(tools: List[Dict[str, Any]]) -> None:
        """Publish read/control in the MCP annotations (additive, standard).

        A host without annotation support ignores the key and keeps the
        description; a host that reads it can treat ``observe`` differently
        from ``press`` without parsing English.
        """

        for tool in tools:
            read_only = tool["name"] in READ_ONLY_TOOLS
            tool["annotations"] = {
                "readOnlyHint": read_only,
                # A control action can change another application's state and
                # cannot be undone from here; say so instead of inheriting the
                # protocol default silently.
                "destructiveHint": not read_only,
                "idempotentHint": read_only,
                "openWorldHint": False,
            }

    # ── dispatch ──────────────────────────────────────────────────────

    def call(self, name: str, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Run one tool call and shape the MCP result."""

        if name not in {tool["name"] for tool in self.tools()}:
            raise _ToolNotFound(name)
        arguments = arguments or {}
        try:
            if name == "computer_use_status":
                return _text(_render_status(self.client))
            if name == "computer_use_list_apps":
                return _text(_render_apps(self.client.apps()))
            if name == "computer_use_observe":
                return self._observe(arguments)
            if name == "computer_use_capture_window":
                return self._capture(arguments)
            if name == "computer_use_release":
                return _text(_render_release(self.client.release()))
            if name == "computer_use_press":
                return self._element_action(
                    "ui.press",
                    {"element_id": _int(arguments, "element_id"),
                     "snapshot": _int(arguments, "snapshot")},
                )
            if name == "computer_use_set_value":
                return self._element_action(
                    "ui.set_value",
                    {"element_id": _int(arguments, "element_id"),
                     "text": str(arguments.get("text", "")),
                     "snapshot": _int(arguments, "snapshot")},
                )
            if name == "computer_use_activate_app":
                return self._action("app.activate", {"app": str(arguments.get("app", ""))})
            if name == "computer_use_focus_window":
                return self._action(
                    "window.focus", {"title": str(arguments.get("window_title", ""))}
                )
            if name == "computer_use_click":
                return self._action(
                    "pointer.click",
                    {"x": float(arguments.get("x", 0)), "y": float(arguments.get("y", 0))},
                )
            if name == "computer_use_type_text":
                return self._action("keyboard.type", {"text": str(arguments.get("text", ""))})
            if name == "computer_use_shortcut":
                return self._action(
                    "keyboard.shortcut", {"keys": str(arguments.get("keys", ""))}
                )
            if name == "computer_use_scroll":
                return self._action(
                    "pointer.scroll", {"dy": int(arguments.get("dy", -3))}
                )
        except BridgeError as error:
            return _render_refusal(error)
        raise _ToolNotFound(name)

    # ── tools ─────────────────────────────────────────────────────────

    def _observe(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        app = arguments.get("app") or None
        include = bool(arguments.get("include_screenshot", False))
        observation = self.client.observe(app=app, include_screenshot=include)
        blocks: List[Dict[str, Any]] = [_text(_render_observation(
            observation, str(arguments.get("filter") or "")))["content"][0]]
        image = observation.get("screenshot_base64") if isinstance(observation, dict) else None
        if image:
            blocks.append({"type": "image", "data": image, "mimeType": "image/png"})
        elif isinstance(observation, dict) and observation.get("screenshot_error"):
            blocks[0]["text"] += "\nscreenshot: unavailable (%s)" % observation["screenshot_error"]
        return {"content": blocks}

    def _capture(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        result = self.client.capture_window(
            str(arguments.get("app", "")), str(arguments.get("window_title", ""))
        )
        data = result.get("screenshot_base64") if isinstance(result, dict) else None
        if not data:
            return _text("The helper returned no image.", is_error=True)
        return {
            "content": [
                {
                    "type": "text",
                    "text": ("Captured one window (scope=%s)."
                    % (result.get("screenshot_scope", "window"))) + _view_metadata(result.get("view_identity")),
                },
                {"type": "image", "data": data, "mimeType": "image/png"},
            ]
        }

    def _element_action(self, kind: str, params: Dict[str, Any]) -> Dict[str, Any]:
        return self._action(kind, params)

    def _action(self, kind: str, params: Dict[str, Any]) -> Dict[str, Any]:
        if kind not in ACTION_KINDS:
            return _text("Unsupported action: %s" % kind, is_error=True)
        result = self.client.act(kind, **params)
        text, is_error = _render_action(kind, result)
        return _text(text, is_error=is_error)


class _ToolNotFound(Exception):
    pass


def _int(arguments: Dict[str, Any], key: str) -> int:
    value = arguments.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError("%s must be an integer" % key)
    return int(value)


# ── rendering (text a model can read; bounded) ───────────────────────


def _text(text: str, *, is_error: bool = False) -> Dict[str, Any]:
    result: Dict[str, Any] = {"content": [{"type": "text", "text": text}]}
    if is_error:
        result["isError"] = True
    return result


def _read_with_retry(call):
    """Run one status read, retrying once after a dead cached channel.

    The helper can be restarted between turns (the gate starts a fresh one while
    the adapter keeps its Unix socket). The first read after that restart fails
    with ``BrokenPipeError``; the retry reconnects and answers with the live
    helper. Only reads take this path: an action is never replayed.
    """
    try:
        return call()
    except BridgeUnavailable:
        return call()


def _render_status(client: BridgeClient) -> str:
    ping = _read_with_retry(client.ping)
    permissions = _read_with_retry(client.status)
    lines = [
        "helper: %s protocol=%s pid=%s" % (ping.get("bridge"), ping.get("protocol"), ping.get("pid")),
        "bundle: %s" % ping.get("bundle_id"),
        "deployment_policy: %s (this adapter asks for %s)" % (ping.get("policy"), client.policy),
        "accessibility: %s" % permissions.get("accessibility"),
        "screen_recording: %s" % permissions.get("screen_recording"),
    ]
    if permissions.get("detail"):
        lines.append("missing: %s" % permissions["detail"])
    authorization = ping.get("authorization")
    if isinstance(authorization, dict):
        lines.append(
            "authorization: loaded=%s apps=%s default=%s"
            % (
                authorization.get("loaded"),
                authorization.get("apps"),
                authorization.get("default"),
            )
        )
    try:
        policy = _read_with_retry(client.policy_status)
    except BridgeError:
        # An older helper has no policy endpoint; say so instead of failing
        # the whole status call.
        policy = None
    if isinstance(policy, dict):
        for grant in policy.get("apps", [])[:20]:
            lines.append(
                "- authorized: %s [%s] scopes=%s windows=%s"
                % (
                    grant.get("name", ""),
                    grant.get("bundle_id", ""),
                    ",".join(grant.get("scopes", [])),
                    grant.get("windows", 0),
                )
            )
        lines.append(
            "effective_mode: %s (launch=%s policy=%s)"
            % (
                policy.get("effective_mode"),
                policy.get("launch_mode"),
                policy.get("policy_mode"),
            )
        )
    return "\n".join(lines)


def _render_apps(result: Any) -> str:
    apps = result.get("apps", []) if isinstance(result, dict) else []
    authorized_only = result.get("authorized_only") if isinstance(result, dict) else None
    header = "running applications (%d)" % len(apps)
    if authorized_only:
        header += " — authorized by the deployment's allowlist only"
    lines = [header + ":"]
    for app in apps[:80]:
        scopes = app.get("scopes") or []
        lines.append(
            "- %s [%s] pid=%s%s scopes=%s%s"
            % (
                app.get("name", ""),
                app.get("bundle_id", ""),
                app.get("pid", ""),
                " active" if app.get("is_active") else "",
                ",".join(scopes) if scopes else "unknown",
                " window-limited" if app.get("window_limited") else "",
            )
        )
    return "\n".join(lines)


def _render_release(result: Any) -> str:
    if not isinstance(result, dict):
        return "released"
    return "released %s element handle(s); snapshot=%s" % (
        result.get("released", 0),
        result.get("snapshot", "?"),
    )


def _view_metadata(identity: Any) -> str:
    """Additive helper-owned identity, never image data or arbitrary fields."""
    if not isinstance(identity, dict):
        return ""
    fields = {key: identity[key] for key in ("bundle", "pid", "snapshot", "window", "window_id") if key in identity}
    if not all(key in fields for key in ("bundle", "pid", "snapshot", "window")):
        return ""
    return "\ncmm_view: " + json.dumps(fields, ensure_ascii=True, separators=(",", ":"))


def _render_observation(observation: Any, element_filter: str = "") -> str:
    if not isinstance(observation, dict):
        return "The helper returned no observation."
    lines = [
        "frontmost: %s [%s]" % (
            observation.get("frontmost_app", ""),
            observation.get("frontmost_bundle", ""),
        ),
        "target: %s [%s]%s" % (
            observation.get("target_app", ""),
            observation.get("target_bundle", ""),
            " (frontmost)" if observation.get("target_is_frontmost") else " (background)",
        ),
        "snapshot: %s (pass it back with element actions)" % observation.get("snapshot"),
    ]
    if "target_pid" in observation and "target_window" in observation:
        metadata = _view_metadata({"bundle": observation.get("target_bundle"),
            "pid": observation.get("target_pid"), "snapshot": observation.get("snapshot"),
            "window": observation.get("target_window"), "window_id": observation.get("target_window_id")})
        # Before all untrusted AX content; fourth line of the observation.
        lines.extend(metadata.lstrip("\n").splitlines())
    windows = observation.get("windows") or []
    if windows:
        lines.append("windows on screen (%d):" % len(windows))
        for window in windows[:10]:
            lines.append(
                '- %s / "%s" (%sx%s at %s,%s)'
                % (
                    window.get("app", ""),
                    (window.get("title") or "")[:80],
                    window.get("width", 0),
                    window.get("height", 0),
                    window.get("x", 0),
                    window.get("y", 0),
                )
            )
    content = observation.get("content") or []
    if content:
        lines.append("readable content (%d, read-only):" % len(content))
        for item in content[:MAX_CONTENT_IN_TEXT]:
            lines.append('- %s "%s"' % (item.get("role", ""), (item.get("text") or "")[:120]))
        if len(content) > MAX_CONTENT_IN_TEXT:
            lines.append("- … %d more" % (len(content) - MAX_CONTENT_IN_TEXT))
    elements = observation.get("elements") or []
    if element_filter:
        needle = element_filter.strip().lower()
        elements = [e for e in elements
                    if needle in (e.get("title") or "").lower()
                    or needle in (e.get("value") or "").lower()
                    or needle in (e.get("role") or "").lower()]
    if elements:
        lines.append("interactive elements (%d):" % len(elements))
        limit = len(elements) if element_filter else MAX_ELEMENTS_IN_TEXT
        for element in elements[:limit]:
            lines.append(
                '[%s] %s "%s" (%s,%s %sx%s)%s'
                % (
                    element.get("element_id"),
                    element.get("role", ""),
                    (element.get("title") or element.get("value") or "")[:80],
                    element.get("x", 0),
                    element.get("y", 0),
                    element.get("width", 0),
                    element.get("height", 0),
                    " pressable" if element.get("pressable") else "",
                )
            )
        if len(elements) > limit:
            lines.append("- … %d more" % (len(elements) - limit))
    else:
        lines.append("interactive elements: none detected")
    return "\n".join(lines)


def _render_action(kind: str, result: Any) -> "tuple":
    """Render one successful action, and decide whether it stays a success.

    A recorded ``breach`` is not a warning to mention in passing: the helper
    measured that an accessibility-only action made its own target the
    frontmost application in a mode that promised not to interfere. The adapter
    turns that into an error so a model cannot retry it as if it had worked.
    """

    if not isinstance(result, dict):
        return "%s: done" % kind, False
    lines = ["%s: %s" % (kind, result.get("message", "done"))]
    interference = result.get("interference")
    lines.extend(_render_interference(interference))
    if isinstance(interference, dict) and interference.get("breach"):
        lines.append(
            "WARNING: this accessibility-only action changed the person's "
            "frontmost application (%s -> %s) in a no-interference mode. "
            "Report it; do not retry blindly."
            % (
                interference.get("frontmost_before"),
                interference.get("frontmost_after"),
            )
        )
        lines.append(
            "STOP: breach recorded (policy=%s). Do not retry this action; report "
            "it and let the operator review the ledger." % interference.get("policy")
        )
        return "\n".join(lines), True
    return "\n".join(lines), False


def _render_interference(interference: Any) -> List[str]:
    """The ledger has two axes; report both, never merge them.

    ``verdict`` is what the ENVIRONMENT did between samples (the person may have
    moved the mouse). ``cursor_events_posted`` / ``cursor_moved_by_action`` /
    ``focus_became_target`` describe what this action's code path could have
    caused. ``external_activity`` names the delta this action cannot explain.
    """

    if not isinstance(interference, dict):
        return []
    lines = [
        "interference: verdict=%s cursor_moved=%s policy=%s"
        % (
            interference.get("verdict"),
            interference.get("cursor_moved"),
            interference.get("policy"),
        )
    ]
    if "cursor_events_posted" in interference or "cursor_moved_by_action" in interference:
        lines.append(
            "attributable: cursor_events_posted=%s cursor_moved_by_action=%s "
            "focus_became_target=%s external_activity=%s"
            % (
                interference.get("cursor_events_posted"),
                interference.get("cursor_moved_by_action"),
                interference.get("focus_became_target"),
                interference.get("external_activity"),
            )
        )
    if interference.get("sampled") is not None:
        lines.append(
            "sampled: n=%s transient_focus_changes=%s transient_cursor_max_delta=%s restored=%s"
            % (
                interference.get("sampled"),
                interference.get("transient_focus_changes"),
                interference.get("transient_cursor_max_delta"),
                interference.get("restored"),
            )
        )
    return lines


def _render_refusal(error: BridgeError) -> Dict[str, Any]:
    """A typed refusal, plus the ledger the helper attached to the failure.

    The refusal is the answer; the ledger is the evidence. Keeping them in one
    error result is what lets a model report "it was denied AND nothing moved"
    instead of guessing.
    """

    lines = [
        "REFUSED %s: %s%s"
        % (
            error.code,
            error.message,
            (" [%s]" % error.detail) if error.detail else "",
        )
    ]
    interference = getattr(error, "interference", None)
    lines.extend(_render_interference(interference))
    if isinstance(interference, dict) and interference.get("breach"):
        lines.append(
            "STOP: breach recorded on a failed action (policy=%s). Do not retry; "
            "report it and let the operator review the ledger."
            % interference.get("policy")
        )
    return _text("\n".join(lines), is_error=True)


# ── JSON-RPC / MCP ───────────────────────────────────────────────────


def _error(request_id: Any, code: int, message: str) -> Dict[str, Any]:
    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "error": {"code": code, "message": message},
    }


def _result(request_id: Any, result: Dict[str, Any]) -> Dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "result": result}


def handle_message(registry: ToolRegistry, message: Any) -> Optional[Dict[str, Any]]:
    """Answer one JSON-RPC message; ``None`` for notifications."""

    if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
        return _error(None, -32600, "Invalid Request")
    method = message.get("method")
    request_id = message.get("id")
    is_notification = "id" not in message
    if not isinstance(method, str) or not method:
        return None if is_notification else _error(request_id, -32600, "Invalid Request")
    params = message.get("params") or {}

    if is_notification:
        # notifications/initialized and friends: acknowledged by silence.
        return None

    if method == "initialize":
        requested = params.get("protocolVersion") if isinstance(params, dict) else None
        version = (
            requested
            if requested in SUPPORTED_PROTOCOL_VERSIONS
            else DEFAULT_PROTOCOL_VERSION
        )
        return _result(
            request_id,
            {
                "protocolVersion": version,
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            },
        )
    if method == "ping":
        return _result(request_id, {})
    if method == "tools/list":
        return _result(request_id, {"tools": registry.tools()})
    if method == "tools/call":
        if not isinstance(params, dict):
            return _error(request_id, -32602, "Invalid params")
        name = params.get("name")
        arguments = params.get("arguments") or {}
        if not isinstance(name, str) or not isinstance(arguments, dict):
            return _error(request_id, -32602, "Invalid params")
        try:
            return _result(request_id, registry.call(name, arguments))
        except _ToolNotFound:
            return _error(request_id, -32602, "Unknown tool: %s" % name)
        except ValueError as error:
            return _error(request_id, -32602, str(error))
    return _error(request_id, -32601, "Method not found: %s" % method)


def serve(
    registry: ToolRegistry, stdin: TextIO = sys.stdin, stdout: TextIO = sys.stdout
) -> None:
    """Read newline-delimited JSON-RPC from stdin until EOF."""

    for raw in stdin:
        line = raw.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except ValueError:
            stdout.write(json.dumps(_error(None, -32700, "Parse error")) + "\n")
            stdout.flush()
            continue
        response = handle_message(registry, message)
        if response is None:
            continue
        stdout.write(json.dumps(response) + "\n")
        stdout.flush()


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        prog="cmm-computer-use-mcp",
        description="MCP stdio adapter for the CMM Computer Use bridge.",
    )
    parser.add_argument(
        "--socket",
        default=default_socket_path(),
        help="Helper socket path (default: %(default)s).",
    )
    parser.add_argument(
        "--mode",
        choices=POLICIES,
        default="background",
        help="Interaction policy this adapter asks for (default: background).",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Print the tool catalog for the chosen mode and exit.",
    )
    args = parser.parse_args(argv)

    client = BridgeClient(args.socket, policy=args.mode)
    registry = ToolRegistry(client, args.mode)
    if args.check:
        print(json.dumps({"mode": args.mode, "tools": registry.tools()}, indent=2))
        return 0
    try:
        serve(registry)
    except (BridgeUnavailable, BridgeProtocolError) as error:  # pragma: no cover - transport
        print("cmm-computer-use-mcp: %s" % error.message, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
