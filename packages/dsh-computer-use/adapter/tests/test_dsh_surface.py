"""Contract tests for what a DSH-hosted session actually sees.

The MCP adapter was already tested as a protocol endpoint. These tests pin the
four properties the DSH phase adds, because they are the ones a host and a model
act on:

* READ vs CONTROL is published (MCP annotations), not only described in prose;
* ``list_apps`` says what the deployment authorized, and never invents an app;
* the interference ledger survives a FAILED action (``error.interference``) and
  is rendered on two axes (environment vs attributable emission);
* a recorded breach ends the call as an error, and a timeout cannot be mistaken
  for a retryable success (exactly one frame per attempt, a fresh connection
  afterwards).

Everything runs against ``tests/fake_bridge.py``: a real Unix socket, the real
wire protocol, no helper process and no desktop event.
"""

from __future__ import annotations

import pathlib
import sys
import time
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tests"))

from fake_bridge import FakeBridge, failure, ok  # noqa: E402

from cmm_computer_use import client as client_module  # noqa: E402
from cmm_computer_use.client import BridgeClient  # noqa: E402
from cmm_computer_use.mcp_server import (  # noqa: E402
    READ_ONLY_TOOLS,
    ToolRegistry,
    handle_message,
)


def text_of(response):
    result = response["result"]
    return "\n".join(
        block["text"] for block in result["content"] if block["type"] == "text"
    )


def is_error(response):
    return bool(response["result"].get("isError"))


class SurfaceCase(unittest.TestCase):
    responder = None

    def setUp(self):
        self.bridge = FakeBridge(self.responder).start()
        self.addCleanup(self.bridge.stop)

    def registry(self, mode="background", socket_path=None):
        client = BridgeClient(socket_path or self.bridge.socket_path, policy=mode)
        self.addCleanup(client.close)
        return ToolRegistry(client, mode)

    def call(self, name, arguments=None, registry=None):
        return handle_message(
            registry or self.registry(),
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": {"name": name, "arguments": arguments or {}},
            },
        )

    def swap_responder(self, responder):
        self.bridge.stop()
        self.bridge = FakeBridge(responder).start()
        self.addCleanup(self.bridge.stop)


class AnnotationTests(SurfaceCase):
    def test_read_tools_declare_readonly_and_control_tools_do_not(self):
        tools = {tool["name"]: tool for tool in self.registry().tools()}
        for name in READ_ONLY_TOOLS:
            self.assertTrue(tools[name]["annotations"]["readOnlyHint"], name)
            self.assertFalse(tools[name]["annotations"]["destructiveHint"], name)
        for name in ("computer_use_press", "computer_use_set_value", "computer_use_release"):
            self.assertFalse(tools[name]["annotations"]["readOnlyHint"], name)
            self.assertTrue(tools[name]["annotations"]["destructiveHint"], name)

    def test_read_only_set_matches_the_background_catalog(self):
        names = {tool["name"] for tool in self.registry().tools()}
        self.assertEqual(READ_ONLY_TOOLS, {"computer_use_status", "computer_use_list_apps",
                                           "computer_use_observe", "computer_use_capture_window"})
        self.assertTrue(READ_ONLY_TOOLS.issubset(names))


class ListAppsTests(SurfaceCase):
    def test_listing_reports_the_allowlist_scopes_and_nothing_else(self):
        text = text_of(self.call("computer_use_list_apps"))
        self.assertIn("authorized by the deployment's allowlist only", text)
        self.assertIn("- Finder [com.apple.finder] pid=100 active scopes=control,observe", text)

    def test_an_app_the_helper_does_not_return_is_never_invented(self):
        def only_fixture(request):
            payload = {
                "authorized_only": True,
                "apps": [
                    {
                        "name": "CMM Computer Use Fixture",
                        "bundle_id": "com.example.computer-use-fixture",
                        "pid": 4242,
                        "is_active": False,
                        "scopes": ["observe"],
                        "window_limited": True,
                    }
                ],
            }
            return ok(request, payload)

        self.swap_responder(only_fixture)
        text = text_of(self.call("computer_use_list_apps"))
        self.assertIn("CMM Computer Use Fixture", text)
        self.assertIn("scopes=observe window-limited", text)
        self.assertNotIn("Finder", text)

    def test_window_limited_apps_are_labelled(self):
        def limited(request):
            return ok(
                request,
                {
                    "authorized_only": True,
                    "apps": [
                        {
                            "name": "Notes",
                            "bundle_id": "com.apple.Notes",
                            "pid": 7,
                            "is_active": False,
                            "scopes": ["control"],
                            "window_limited": True,
                        }
                    ],
                },
            )

        self.swap_responder(limited)
        self.assertIn("window-limited", text_of(self.call("computer_use_list_apps")))


LEDGER = {
    "verdict": "cursor_moved",
    "frontmost_before": "Finder",
    "frontmost_after": "Finder",
    "cursor_moved": True,
    "cursor_dx": 12,
    "cursor_dy": 0,
    "cursor_events_posted": False,
    "cursor_moved_by_action": False,
    "focus_became_target": False,
    "external_activity": True,
    "action_class": "accessibility",
    "policy": "background",
    "attributed": False,
    "breach": False,
    "sampled": 3,
    "transient_focus_changes": 0,
    "transient_cursor_max_delta": 12,
    "restored": False,
}


class LedgerTests(SurfaceCase):
    def test_the_two_axes_are_reported_separately(self):
        def acted(request):
            payload = {
                "ok": True,
                "message": "pressed",
                "interference": dict(LEDGER, verdict="cursor_moved", breach=False),
            }
            return ok(request, payload)

        self.swap_responder(acted)
        text = text_of(self.call("computer_use_press", {"element_id": 7, "snapshot": 3}))
        self.assertIn("verdict=cursor_moved", text)
        self.assertIn("cursor_events_posted=False", text)
        self.assertIn("cursor_moved_by_action=False", text)
        self.assertIn("external_activity=True", text)
        self.assertIn("sampled: n=3", text)

    def test_a_failed_action_still_reports_error_interference(self):
        def refused(request):
            return failure(
                request,
                "COMPUTER_TARGET_UNAVAILABLE",
                "The application is no longer running.",
                "reason=pid_changed;app=com.apple.Notes",
                interference=dict(LEDGER, verdict="untouched", cursor_moved=False,
                                  external_activity=False),
            )

        self.swap_responder(refused)
        response = self.call("computer_use_press", {"element_id": 4, "snapshot": 9})
        text = text_of(response)
        self.assertTrue(is_error(response))
        self.assertIn("REFUSED COMPUTER_TARGET_UNAVAILABLE", text)
        self.assertIn("reason=pid_changed", text)
        self.assertIn("interference: verdict=untouched", text)
        self.assertIn("cursor_events_posted=False", text)

    def test_a_breach_on_success_is_an_error_not_a_note(self):
        def breached(request):
            return ok(
                request,
                {
                    "ok": True,
                    "message": "pressed",
                    "interference": dict(
                        LEDGER,
                        verdict="focus_changed",
                        cursor_moved=False,
                        focus_became_target=True,
                        external_activity=False,
                        frontmost_after="Terminal",
                        breach=True,
                    ),
                },
            )

        self.swap_responder(breached)
        response = self.call("computer_use_press", {"element_id": 1, "snapshot": 1})
        text = text_of(response)
        self.assertTrue(is_error(response), "a breach must not return a success")
        self.assertIn("WARNING", text)
        self.assertIn("Finder -> Terminal", text)
        self.assertIn("STOP: breach recorded", text)

    def test_a_breach_on_a_failure_is_also_an_error_with_a_stop(self):
        def breached_failure(request):
            return failure(
                request,
                "ACTION_FAILED",
                "The element disappeared mid-action.",
                "",
                interference=dict(LEDGER, verdict="focus_changed", focus_became_target=True,
                                  breach=True, frontmost_after="Terminal"),
            )

        self.swap_responder(breached_failure)
        response = self.call("computer_use_press", {"element_id": 1, "snapshot": 1})
        text = text_of(response)
        self.assertTrue(is_error(response))
        self.assertIn("STOP: breach recorded on a failed action", text)


class RefusalTests(SurfaceCase):
    def _refuse_with(self, code, message, detail):
        def refuse(request):
            return failure(request, code, message, detail)

        self.swap_responder(refuse)

    def test_an_unauthorized_app_is_a_refusal_with_one_frame(self):
        self._refuse_with(
            "APPROVAL_REJECTED",
            "The deployment does not authorize this application.",
            "auth=app_not_granted;app=com.apple.mail",
        )
        response = self.call("computer_use_observe", {"app": "Mail"})
        self.assertTrue(is_error(response))
        self.assertIn("REFUSED APPROVAL_REJECTED", text_of(response))
        self.assertIn("auth=app_not_granted", text_of(response))
        self.assertEqual(len(self.bridge.frames), 1, "a refusal must not be retried")

    def test_a_stale_window_is_a_refusal_not_a_retarget(self):
        self._refuse_with(
            "COMPUTER_TARGET_UNAVAILABLE",
            "The window the element was read from no longer exists.",
            "reason=window_changed",
        )
        response = self.call("computer_use_press", {"element_id": 2, "snapshot": 5})
        self.assertTrue(is_error(response))
        self.assertIn("reason=window_changed", text_of(response))
        self.assertEqual(self.bridge.frames[0]["arguments"]["params"]["element_id"], 2)
        self.assertEqual(len(self.bridge.frames), 1)

    def test_an_expired_snapshot_is_a_refusal(self):
        self._refuse_with(
            "CAPABILITY_UNSUPPORTED",
            "The observation expired.",
            "reason=expired;policy=background",
        )
        response = self.call("computer_use_set_value",
                             {"element_id": 1, "text": "x", "snapshot": 1})
        self.assertTrue(is_error(response))
        self.assertIn("REFUSED CAPABILITY_UNSUPPORTED", text_of(response))

    def test_a_permission_failure_names_what_is_missing(self):
        self._refuse_with(
            "COMPUTER_PERMISSION_DENIED",
            "Accessibility is not granted to the helper.",
            "missing=accessibility",
        )
        text = text_of(self.call("computer_use_status"))
        self.assertIn("REFUSED COMPUTER_PERMISSION_DENIED", text)
        self.assertIn("missing=accessibility", text)


class AvailabilityTests(SurfaceCase):
    def test_an_unreachable_helper_does_not_break_the_handshake(self):
        missing = str(pathlib.Path(self.bridge.socket_path).with_name("absent.sock"))
        registry = self.registry(socket_path=missing)
        initialized = handle_message(
            registry, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}
        )
        assert initialized is not None
        self.assertEqual(initialized["result"]["serverInfo"]["name"], "cmm-computer-use")
        catalog = handle_message(registry, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        assert catalog is not None
        self.assertEqual(len(catalog["result"]["tools"]), 7)
        response = self.call("computer_use_status", registry=registry)
        self.assertTrue(is_error(response))
        self.assertIn("REFUSED COMPUTER_RUNTIME_UNAVAILABLE", text_of(response))

    def test_a_timeout_is_a_typed_refusal_and_the_next_call_reconnects(self):
        def slow(request):
            # Accept the frame and stay silent past the client's deadline: the
            # connection is alive, so the failure can only come from the clock.
            time.sleep(0.6)
            return ok(request, {"ok": True, "message": "too late"})

        self.swap_responder(slow)
        with mock.patch.dict(client_module.OPERATION_TIMEOUTS, {"action.execute": 0.2}):
            response = self.call("computer_use_press", {"element_id": 1, "snapshot": 1})
        text = text_of(response)
        self.assertTrue(is_error(response))
        self.assertIn("REFUSED COMPUTER_RUNTIME_UNAVAILABLE", text)
        self.assertIn("did not answer action.execute in time", text)
        self.assertEqual(len(self.bridge.frames), 1, "a timeout must not be retried")

        # A timed-out connection is dropped, so the next call opens a new one
        # instead of matching a late answer to a new request.
        self.swap_responder(None)
        registry = self.registry()
        self.assertEqual(registry.client.request("bridge.ping")["bridge"], "cmm-computer-use")
        self.assertEqual(self.bridge.connections, 1, "a fresh connection, not the dead one")


if __name__ == "__main__":
    unittest.main()
