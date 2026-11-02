"""Background-mode contract for the 2026-11-02 findings.

* a breach the helper now fails closed (``INTERFERENCE_BREACH``) is rendered
  with the STOP line the DSH projection latches on;
* the accessibility-only ``computer_use_scroll`` sends ``ui.scroll`` and a
  missing AX primitive is ``CAPABILITY_UNSUPPORTED``, never a fallback;
* an Electron window that exposes only its title-bar buttons is reported as
  ``AX_TREE_UNAVAILABLE``, and window controls are not offered as pressable;
* the server tells the host, in its MCP ``instructions`` and on every refusal,
  not to work around a missing capability with scripts or synthetic events.
"""

from __future__ import annotations

import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tests"))

from fake_bridge import FakeBridge, failure, ok  # noqa: E402

from cmm_computer_use.client import ACTION_KINDS, ERROR_CODES, BridgeClient  # noqa: E402
from cmm_computer_use.mcp_server import (  # noqa: E402
    NO_BYPASS_POLICY,
    ToolRegistry,
    handle_message,
)

CLAUDE = "com.anthropic.claudefordesktop"

#: The ledger the fixed helper produces for the observed press: the target came
#: to the front 620 ms after the press started, inside the settle window.
BREACH_LEDGER = {
    "verdict": "focus_changed",
    "frontmost_before": "DeepSeek Harness",
    "frontmost_after": "Claude",
    "cursor_moved": False,
    "cursor_dx": 0,
    "cursor_dy": 0,
    "action_class": "accessibility",
    "policy": "background",
    "attributed": False,
    "breach": True,
    "cursor_events_posted": False,
    "cursor_moved_by_action": False,
    "focus_became_target": True,
    "external_activity": False,
    "sampled": 180,
    "transient_focus_changes": 1,
    "transient_cursor_max_delta": 0,
    "restored": False,
    "window_raised_over_person": False,
    "observed_for_ms": 1130,
    "target_front_at_ms": 620,
}


def text_of(response):
    return "\n".join(b["text"] for b in response["result"]["content"] if b["type"] == "text")


class Case(unittest.TestCase):
    responder = None

    def setUp(self):
        self.bridge = FakeBridge(self.respond).start()
        self.addCleanup(self.bridge.stop)
        client = BridgeClient(self.bridge.socket_path, policy="background")
        self.addCleanup(client.close)
        self.registry = ToolRegistry(client, "background")

    def respond(self, request):
        return type(self).responder(request)

    def call(self, name, arguments=None):
        return handle_message(self.registry, {
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": {"name": name, "arguments": arguments or {}},
        })


class BreachFailClosedTests(Case):
    @staticmethod
    def responder(request):
        return failure(
            request, "INTERFERENCE_BREACH",
            "The action brought the target application in front of the person's work in a mode that promised no interference.",
            "policy=background;reason=breach;kind=ui.press;action_ok=true;breach_id=3f2a",
            interference=BREACH_LEDGER)

    def test_breach_is_an_error_with_stop_and_settle_evidence(self):
        response = self.call("computer_use_press", {"element_id": 2, "snapshot": 5})
        self.assertTrue(response["result"].get("isError"))
        text = text_of(response)
        self.assertIn("REFUSED INTERFERENCE_BREACH", text)
        self.assertIn(
            "attributable: cursor_events_posted=False cursor_moved_by_action=False "
            "focus_became_target=True external_activity=False", text)
        self.assertIn("STOP: breach recorded on a failed action (policy=background). Do not retry; "
                      "report it and let the operator review the ledger.", text)
        self.assertIn("settle: observed_for_ms=1130 target_front_at_ms=620 "
                      "window_raised_over_person=False", text)
        # Decision 2026-11-02: no automatic focus restoration after a breach —
        # re-activating the previous app would be a second interference.
        self.assertNotIn("focus_restore", text)
        self.assertIn("breach_id=3f2a", text)
        self.assertIn("Do not work around this", text)

    def test_breach_code_is_part_of_the_error_grammar(self):
        self.assertIn("INTERFERENCE_BREACH", ERROR_CODES)


class ScrollTests(Case):
    sent = []

    @staticmethod
    def responder(request):
        ScrollTests.sent.append(request)
        params = request["arguments"]["params"]
        if params["element_id"] == 9:
            return failure(
                request, "CAPABILITY_UNSUPPORTED",
                "This element offers no accessibility scroll primitive; background mode will not post a scroll-wheel event.",
                "policy=background;kind=ui.scroll;reason=scroll_area_without_scrollbar;role=AXScrollArea")
        return ok(request, {"ok": True, "message": "scrolled down 2 page(s) via AXScrollDownByPage",
                            "interference": dict(BREACH_LEDGER, verdict="untouched", breach=False,
                                                 focus_became_target=False, frontmost_after="DeepSeek Harness",
                                                 transient_focus_changes=0)})

    def setUp(self):
        ScrollTests.sent = []
        super().setUp()

    def test_scroll_is_in_the_background_catalog_and_the_wheel_is_not(self):
        names = {t["name"] for t in self.registry.tools()}
        self.assertIn("computer_use_scroll", names)
        self.assertNotIn("computer_use_pointer_scroll", names)
        self.assertIn("ui.scroll", ACTION_KINDS)

    def test_scroll_sends_an_accessibility_action_with_the_background_policy(self):
        response = self.call("computer_use_scroll",
                             {"element_id": 4, "snapshot": 5, "direction": "down", "pages": 2})
        self.assertFalse(response["result"].get("isError", False))
        frame = ScrollTests.sent[-1]
        self.assertEqual(frame["operation"], "action.execute")
        self.assertEqual(frame["arguments"]["kind"], "ui.scroll")
        self.assertEqual(frame["arguments"]["policy"], "background")
        self.assertEqual(frame["arguments"]["params"],
                         {"element_id": 4, "snapshot": 5, "direction": "down", "pages": 2})

    def test_missing_ax_primitive_is_capability_unsupported_with_no_bypass(self):
        response = self.call("computer_use_scroll",
                             {"element_id": 9, "snapshot": 5, "direction": "down"})
        self.assertTrue(response["result"].get("isError"))
        text = text_of(response)
        self.assertIn("REFUSED CAPABILITY_UNSUPPORTED", text)
        self.assertIn("reason=scroll_area_without_scrollbar", text)
        self.assertIn("CGEvent", text)
        self.assertEqual(len(ScrollTests.sent), 1, "an unsupported scroll is never retried another way")


class ElectronTreeTests(Case):
    @staticmethod
    def responder(request):
        if request["operation"] != "observation.describe":
            return failure(request, "CAPABILITY_UNSUPPORTED", "unexpected")
        chrome = [
            {"element_id": i + 1, "role": "AXButton", "subrole": sub, "title": title,
             "value": "", "x": 0, "y": 0, "width": 14, "height": 16,
             "pressable": True, "window_chrome": True}
            for i, (sub, title) in enumerate([
                ("AXCloseButton", "cerrar"), ("AXZoomButton", "ampliar"),
                ("AXMinimizeButton", "minimizar")])
        ]
        return ok(request, {
            "frontmost_app": "DeepSeek Harness", "frontmost_bundle": "com.deepseek.harness",
            "target_app": "Claude", "target_bundle": CLAUDE, "target_pid": 777,
            "target_window": "Claude", "target_window_id": 41, "target_is_frontmost": False,
            "windows": [], "elements": chrome, "content": [], "snapshot": 5, "captured_at": 1.0,
            "screenshot_scope": "none",
            "ax_enrichment": {"mechanism": "AXManualAccessibility", "state": "enabled_still_sparse",
                              "nodes_before": 5, "nodes_after": 5},
            "ax_tree": "chrome_only",
        })

    def test_chrome_only_tree_is_an_explicit_capability_gap(self):
        text = text_of(self.call("computer_use_observe", {"app": CLAUDE}))
        self.assertIn("target: Claude [%s] (background)" % CLAUDE, text)
        self.assertIn("ax_enrichment: enabled_still_sparse via AXManualAccessibility nodes 5->5", text)
        self.assertIn("AX_TREE_UNAVAILABLE", text)
        self.assertIn("window-control(not pressable in background)", text)
        for line in text.splitlines():
            if line.startswith("[") and "window-control" in line:
                self.assertNotIn(") pressable", line)


class BreachLatchStatusTests(Case):
    @staticmethod
    def responder(request):
        op = request["operation"]
        if op == "bridge.ping":
            return ok(request, {"bridge": "cmm-computer-use", "protocol": 1, "pid": 1,
                                "bundle_id": "com.cmm.chat.computer-use", "policy": "background"})
        if op == "permissions.status":
            return ok(request, {"accessibility": True, "screen_recording": True, "detail": ""})
        if op == "policy.status":
            return ok(request, {"apps": [{"name": "", "bundle_id": CLAUDE, "scopes": ["control", "observe"],
                                          "windows": 0}],
                                "effective_mode": "background", "launch_mode": "background",
                                "policy_mode": "background"})
        if op == "breach.status":
            return ok(request, {"state": "ok", "breaches": [
                {"id": "3f2a", "target_bundle": CLAUDE, "target_name": "Claude", "kind": "ui.press"}]})
        return failure(request, "CAPABILITY_UNSUPPORTED", "unexpected")

    def test_status_reports_open_latches_and_the_console_unlock_path(self):
        text = text_of(self.call("computer_use_status"))
        self.assertIn("breach_latch: state=ok open=1", text)
        self.assertIn("- latched: Claude [%s] breach_id=3f2a kind=ui.press — rearm from CMM Console" % CLAUDE, text)

    def test_the_agent_has_no_way_to_rearm(self):
        names = {t["name"] for t in self.registry.tools()}
        self.assertFalse(any("rearm" in n or "breach" in n for n in names))
        self.assertFalse(any("rearm" in m for m in dir(BridgeClient)))
        self.assertNotIn("breach.rearm", ACTION_KINDS)


class InstructionsTests(unittest.TestCase):
    def test_initialize_carries_the_no_bypass_policy(self):
        client = BridgeClient("/nonexistent/socket", policy="background")
        registry = ToolRegistry(client, "background")
        response = handle_message(registry, {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                             "params": {"protocolVersion": "2025-06-18"}})
        instructions = response["result"]["instructions"]
        self.assertEqual(instructions, NO_BYPASS_POLICY)
        for word in ("Bash", "osascript", "JXA", "System Events", "Swift", "CGEvent"):
            self.assertIn(word, instructions)


if __name__ == "__main__":
    unittest.main()
