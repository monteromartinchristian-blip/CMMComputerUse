"""Contract tests for the MCP stdio adapter.

The adapter is the part a host (DeepSeek Harness today, another client
tomorrow) actually sees. These tests pin the three things that decide whether
it is safe to attach:

* what it ADVERTISES (no activation, pointer or keyboard tool in the default
  mode, and those tools absent from the catalog rather than listed-and-refused),
* what it SENDS (the policy travels with every action; the snapshot travels
  with every element action),
* what it REPORTS (a typed refusal becomes an ``isError`` result a model can
  read, never a silent success).
"""

from __future__ import annotations

import io
import json
import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tests"))

from fake_bridge import FakeBridge, failure, ok  # noqa: E402

from cmm_computer_use.client import BridgeClient, BridgeUnavailable  # noqa: E402
from cmm_computer_use.mcp_server import (  # noqa: E402
    DEFAULT_PROTOCOL_VERSION,
    SERVER_NAME,
    ToolRegistry,
    _render_status,
    handle_message,
    serve,
)


def tool_names(registry):
    return [tool["name"] for tool in registry.tools()]


def body(response):
    assert response is not None
    return response.get("result") or response.get("error")


def text_of(response):
    result = response["result"]
    return "\n".join(
        block["text"] for block in result["content"] if block["type"] == "text"
    )


class ServerTestCase(unittest.TestCase):
    def setUp(self):
        self.bridge = FakeBridge().start()
        self.addCleanup(self.bridge.stop)

    def registry(self, mode="background"):
        client = BridgeClient(self.bridge.socket_path, policy=mode)
        self.addCleanup(client.close)
        return ToolRegistry(client, mode)

    def call(self, registry, name, arguments=None):
        return handle_message(
            registry,
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": {"name": name, "arguments": arguments or {}},
            },
        )


class CatalogTests(ServerTestCase):
    def test_background_catalog_has_no_interfering_tool(self):
        names = tool_names(self.registry("background"))
        for name in (
            "computer_use_status",
            "computer_use_list_apps",
            "computer_use_observe",
            "computer_use_capture_window",
            "computer_use_press",
            "computer_use_set_value",
            "computer_use_release",
        ):
            self.assertIn(name, names)
        for forbidden in (
            "computer_use_activate_app",
            "computer_use_focus_window",
            "computer_use_click",
            "computer_use_type_text",
            "computer_use_shortcut",
            "computer_use_scroll",
        ):
            self.assertNotIn(
                forbidden, names,
                "background mode must not even offer a tool that steals focus, "
                "moves the cursor or types into whatever holds focus",
            )

    def test_focus_catalog_adds_activation_but_still_no_global_input(self):
        names = tool_names(self.registry("focus"))
        self.assertIn("computer_use_activate_app", names)
        self.assertIn("computer_use_focus_window", names)
        for forbidden in (
            "computer_use_click",
            "computer_use_type_text",
            "computer_use_shortcut",
            "computer_use_scroll",
        ):
            self.assertNotIn(forbidden, names)

    def test_unrestricted_catalog_is_the_legacy_surface(self):
        names = tool_names(self.registry("unrestricted"))
        for name in (
            "computer_use_activate_app",
            "computer_use_click",
            "computer_use_type_text",
            "computer_use_shortcut",
            "computer_use_scroll",
        ):
            self.assertIn(name, names)

    def test_every_tool_declares_an_object_schema(self):
        for tool in self.registry("unrestricted").tools():
            self.assertEqual(tool["inputSchema"]["type"], "object", tool["name"])
            self.assertTrue(tool["description"], tool["name"])
            self.assertTrue(tool["name"].startswith("computer_use_"), tool["name"])

    def test_unsafe_tool_descriptions_say_what_they_do(self):
        tools = {tool["name"]: tool for tool in self.registry("unrestricted").tools()}
        self.assertIn("cursor", tools["computer_use_click"]["description"].lower())
        self.assertIn("focus", tools["computer_use_type_text"]["description"].lower())


class StatusReadRetryTests(unittest.TestCase):
    def test_status_reads_reconnect_once_after_a_restarted_helper(self):
        class RestartedHelper:
            policy = "background"

            def __init__(self):
                self.pings = 0

            def ping(self):
                self.pings += 1
                if self.pings == 1:
                    raise BridgeUnavailable("closed", detail="BrokenPipeError")
                return {"bridge": "cmm-computer-use", "protocol": 1, "pid": 7,
                        "bundle_id": "com.cmm.chat.computer-use", "policy": "background",
                        "authorization": {"loaded": True, "apps": 1, "default": "deny"}}

            def status(self):
                return {"accessibility": True, "screen_recording": True}

            def policy_status(self):
                return {"apps": [{"name": "CMM Computer Use Fixture",
                                  "bundle_id": "com.example.computer-use-fixture",
                                  "scopes": ["control", "observe"], "windows": 1}]}

        helper = RestartedHelper()
        text = _render_status(helper)
        self.assertEqual(helper.pings, 2)
        self.assertIn("- authorized: CMM Computer Use Fixture [com.example.computer-use-fixture] "
                      "scopes=control,observe windows=1", text)


class HandshakeTests(ServerTestCase):
    def test_initialize_names_the_server_and_echoes_a_supported_version(self):
        response = handle_message(
            self.registry(),
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {"protocolVersion": "2025-06-18", "capabilities": {}},
            },
        )
        result = body(response)
        self.assertEqual(result["protocolVersion"], "2025-06-18")
        self.assertEqual(result["serverInfo"]["name"], SERVER_NAME)
        self.assertFalse(result["capabilities"]["tools"]["listChanged"])

    def test_unknown_protocol_version_falls_back_to_a_supported_one(self):
        result = body(
            handle_message(
                self.registry(),
                {
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "initialize",
                    "params": {"protocolVersion": "1999-01-01"},
                },
            )
        )
        self.assertEqual(result["protocolVersion"], DEFAULT_PROTOCOL_VERSION)

    def test_notifications_get_no_response(self):
        self.assertIsNone(
            handle_message(
                self.registry(),
                {"jsonrpc": "2.0", "method": "notifications/initialized"},
            )
        )

    def test_unknown_method_is_a_jsonrpc_error(self):
        response = handle_message(
            self.registry(), {"jsonrpc": "2.0", "id": 9, "method": "resources/list"}
        )
        self.assertEqual(response["error"]["code"], -32601)

    def test_invalid_request_is_rejected(self):
        response = handle_message(self.registry(), {"id": 1})
        self.assertEqual(response["error"]["code"], -32600)


class ToolCallTests(ServerTestCase):
    def test_observe_returns_text_with_the_snapshot_to_reuse(self):
        text = text_of(self.call(self.registry(), "computer_use_observe", {"app": "Finder"}))
        self.assertIn("snapshot: 3", text)
        self.assertIn('target: Finder', text)
        self.assertIn('[7] AXButton "Atrás"', text)
        frame = self.bridge.frames[0]
        self.assertEqual(frame["arguments"]["app"], "Finder")

    def test_observe_attaches_a_png_block_only_when_present(self):
        response = self.call(self.registry(), "computer_use_observe", {})
        self.assertEqual(
            [block["type"] for block in response["result"]["content"]], ["text"]
        )

        def with_image(request):
            result = ok(
                request,
                {
                    "frontmost_app": "Finder",
                    "frontmost_bundle": "com.apple.finder",
                    "target_app": "Finder",
                    "target_bundle": "com.apple.finder",
                    "target_is_frontmost": True,
                    "snapshot": 4,
                    "windows": [],
                    "elements": [],
                    "content": [],
                    "screenshot_base64": "QUJD",
                    "screenshot_scope": "window",
                },
            )
            return result

        self.bridge.stop()
        self.bridge = FakeBridge(with_image).start()
        self.addCleanup(self.bridge.stop)
        response = self.call(self.registry(), "computer_use_observe", {"app": "Finder"})
        blocks = response["result"]["content"]
        self.assertEqual(blocks[1]["type"], "image")
        self.assertEqual(blocks[1]["mimeType"], "image/png")
        self.assertEqual(blocks[1]["data"], "QUJD")

    def test_press_sends_element_snapshot_and_policy(self):
        response = self.call(
            self.registry(), "computer_use_press", {"element_id": 7, "snapshot": 3}
        )
        arguments = self.bridge.frames[0]["arguments"]
        self.assertEqual(arguments["kind"], "ui.press")
        self.assertEqual(arguments["params"], {"element_id": 7, "snapshot": 3})
        self.assertEqual(arguments["policy"], "background")
        self.assertIn("ui.press: pressed", text_of(response))
        self.assertIn("interference: verdict=untouched", text_of(response))
        self.assertFalse(response["result"].get("isError", False))

    def test_set_value_carries_text_and_snapshot(self):
        self.call(
            self.registry(),
            "computer_use_set_value",
            {"element_id": 2, "text": "hola", "snapshot": 3},
        )
        arguments = self.bridge.frames[0]["arguments"]
        self.assertEqual(arguments["kind"], "ui.set_value")
        self.assertEqual(arguments["params"]["text"], "hola")
        self.assertEqual(arguments["params"]["snapshot"], 3)

    def test_a_refusal_becomes_a_readable_error_not_a_silent_success(self):
        def refuse(request):
            return failure(
                request,
                "CAPABILITY_UNSUPPORTED",
                "The bridge runs in background mode: pointer.click posts a global "
                "pointer event, which moves the system cursor.",
                "policy=background;kind=pointer.click;requirement=global_pointer",
            )

        self.bridge.stop()
        self.bridge = FakeBridge(refuse).start()
        self.addCleanup(self.bridge.stop)
        response = self.call(
            self.registry(), "computer_use_press", {"element_id": 1, "snapshot": 1}
        )
        self.assertTrue(response["result"]["isError"])
        self.assertIn("REFUSED CAPABILITY_UNSUPPORTED", text_of(response))
        self.assertIn("cursor", text_of(response))

    def test_breach_is_surfaced_as_a_warning(self):
        def breach(request):
            return ok(
                request,
                {
                    "ok": True,
                    "message": "pressed",
                    "interference": {
                        "verdict": "focus_changed",
                        "frontmost_before": "Finder",
                        "frontmost_after": "Terminal",
                        "cursor_moved": False,
                        "policy": "background",
                        "breach": True,
                    },
                },
            )

        self.bridge.stop()
        self.bridge = FakeBridge(breach).start()
        self.addCleanup(self.bridge.stop)
        text = text_of(
            self.call(
                self.registry(), "computer_use_press", {"element_id": 1, "snapshot": 1}
            )
        )
        self.assertIn("WARNING", text)
        self.assertIn("Finder -> Terminal", text)

    def test_activation_tool_is_not_callable_in_background_mode(self):
        response = self.call(
            self.registry("background"), "computer_use_activate_app", {"app": "Finder"}
        )
        self.assertEqual(response["error"]["code"], -32602)
        self.assertEqual(self.bridge.frames, [], "nothing may be sent for a tool that is not offered")

    def test_status_reports_deployment_and_requested_policy(self):
        text = text_of(self.call(self.registry("background"), "computer_use_status", {}))
        self.assertIn("deployment_policy: unrestricted", text)
        self.assertIn("this adapter asks for background", text)
        self.assertIn("accessibility: True", text)
        self.assertIn("authorization: loaded=True apps=1 default=deny", text)
        self.assertIn("authorized: CMM Computer Use Fixture [com.example.computer-use-fixture] scopes=observe,control", text)
        self.assertIn("effective_mode: background", text)

    def test_element_id_must_be_an_integer(self):
        response = self.call(
            self.registry(), "computer_use_press", {"element_id": "7", "snapshot": 3}
        )
        self.assertEqual(response["error"]["code"], -32602)


class ServeTests(ServerTestCase):
    def test_serve_answers_in_order_and_stays_silent_for_notifications(self):
        stdin = io.StringIO(
            "\n".join(
                [
                    json.dumps(
                        {
                            "jsonrpc": "2.0",
                            "id": 1,
                            "method": "initialize",
                            "params": {"protocolVersion": "2024-11-05"},
                        }
                    ),
                    json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}),
                    json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}),
                    "",
                ]
            )
        )
        stdout = io.StringIO()
        serve(self.registry(), stdin=stdin, stdout=stdout)
        lines = [json.loads(line) for line in stdout.getvalue().splitlines() if line]
        self.assertEqual([line["id"] for line in lines], [1, 2])
        self.assertIn("tools", lines[1]["result"])

    def test_parse_error_is_reported_and_the_loop_continues(self):
        stdin = io.StringIO("\n".join(["not json", json.dumps({"jsonrpc": "2.0", "id": 1, "method": "ping"}), ""]))
        stdout = io.StringIO()
        serve(self.registry(), stdin=stdin, stdout=stdout)
        lines = [json.loads(line) for line in stdout.getvalue().splitlines() if line]
        self.assertEqual(lines[0]["error"]["code"], -32700)
        self.assertEqual(lines[1]["result"], {})


if __name__ == "__main__":
    unittest.main()
