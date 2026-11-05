"""Audit X-09 (C-05 / D-02 / E-11): the adapter and the helper negotiate.

Today production is the OTHER way round from what 0.3.3 was built for: a 0.3.3
package in front of a 0.3.2 helper. The helper answers every new operation with
CAPABILITY_UNSUPPORTED, the server instructions say STOP, and — worse — it
silently IGNORES a `context_id`, acting on whatever application is in front.
The adapter therefore reads the helper's own capabilities from `bridge.ping`
and refuses, with a typed and actionable answer, what the helper cannot do;
it never forwards a `context` to a helper that would ignore it.
"""

from __future__ import annotations

import json
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from fake_bridge import FakeBridge, default_responder, ok  # noqa: E402

from cmm_computer_use.client import BridgeClient  # noqa: E402
from cmm_computer_use.mcp_server import SERVER_VERSION, ToolRegistry  # noqa: E402

CTX = "ctx_" + "a" * 32
DL = "dl_" + "c" * 32

#: What a 0.3.2 helper answers: capabilities, but none of the 0.3.3 ones.
LEGACY_CAPABILITIES = {"background_actions": True, "window_capture": True, "ax_scroll": True,
                       "window_stream": True, "client_authentication": True}
MODERN_CAPABILITIES = dict(LEGACY_CAPABILITIES, workspace={"contract": "cmm-computer-use/workspace"},
                           browser={"contract": "cmm-computer-use/browser"},
                           downloads={"verified": True}, scroll_reveal=True)


def text_of(result):
    return "\n".join(b["text"] for b in result["content"] if b["type"] == "text")


class Helper:
    def __init__(self, capabilities, version=None, build=None):
        self.capabilities = capabilities
        self.version = version
        self.build = build
        self.instance = "ins_" + "7" * 32

    def __call__(self, request):
        op = request.get("operation")
        if op == "bridge.ping":
            result = default_responder(request)["result"]
            result["capabilities"] = self.capabilities
            result["instance_id"] = self.instance
            # A 0.3.2 helper does not carry these keys at all.
            result.pop("helper_version", None)
            result.pop("helper_build", None)
            if self.version:
                result["helper_version"] = self.version
                result["helper_build"] = self.build
            return ok(request, result)
        if op == "observation.describe":
            return ok(request, {"target_app": "Safari", "target_bundle": "com.apple.Safari", "snapshot": 1,
                                "elements": [], "windows": []})
        if op == "workspace.context_create":
            return ok(request, {"context_id": CTX, "label": "A", "legacy": False, "snapshot": 0,
                                "instance_id": self.instance})
        return default_responder(request)


class Base(unittest.TestCase):
    def build(self, capabilities, **kwargs):
        self.helper = Helper(capabilities, **kwargs)
        self.bridge = FakeBridge(self.helper).start()
        self.addCleanup(self.bridge.stop)
        self.client = BridgeClient(self.bridge.socket_path, policy="background")
        self.client._sleep = lambda _seconds: None
        self.addCleanup(self.client.close)
        self.registry = ToolRegistry(self.client, "background")

    def frames(self, operation):
        return [f for f in self.bridge.frames if f.get("operation") == operation]


class LegacyHelperTests(Base):
    def setUp(self):
        self.build(LEGACY_CAPABILITIES)

    def test_every_0_3_3_tool_is_refused_with_an_actionable_answer_and_nothing_is_sent(self):
        calls = {
            "computer_use_context_open": {"app": "Safari"},
            "computer_use_workspace_status": {},
            "computer_use_browser_state": {},
            "computer_use_browser_wait": {},
            "computer_use_browser_select_tab": {"tab_id": "tab_x"},
            "computer_use_download": {"element_id": 1, "snapshot": 1},
            "computer_use_download_expect": {},
            "computer_use_download_status": {"download_id": DL},
            "computer_use_save_dialog": {},
        }
        for name, arguments in calls.items():
            result = self.registry.call(name, arguments)
            text = text_of(result)
            self.assertTrue(result.get("isError"), name)
            self.assertIn("HELPER_TOO_OLD", text, name)
            self.assertIn("computer_use_observe", text, "it says what still works: " + name)
            self.assertNotIn("STOP", text, "not a dead end: " + name)
        sent = {f["operation"] for f in self.bridge.frames}
        self.assertTrue(sent <= {"bridge.ping"}, "nothing but the capability check reached the helper: %s" % sent)

    def test_an_explicit_context_is_never_forwarded_to_a_helper_that_would_ignore_it(self):
        result = self.registry.call("computer_use_observe", {"app": "Safari", "context": CTX})
        self.assertTrue(result.get("isError"))
        self.assertIn("HELPER_TOO_OLD", text_of(result))
        self.assertIn("ignores", text_of(result))
        self.assertEqual(self.frames("observation.describe"), [], "the observation was not made on another app")
        for name in ("computer_use_press", "computer_use_set_value", "computer_use_scroll"):
            args = {"element_id": 1, "snapshot": 1, "context": CTX, "text": "x", "direction": "down"}
            self.assertIn("HELPER_TOO_OLD", text_of(self.registry.call(name, args)), name)
        self.assertEqual(self.frames("action.execute"), [])

    def test_the_tools_that_need_no_context_keep_working(self):
        result = self.registry.call("computer_use_observe", {"app": "Safari"})
        self.assertFalse(result.get("isError"), text_of(result))
        self.assertEqual(len(self.frames("observation.describe")), 1)

    def test_status_names_both_versions_and_what_the_helper_lacks(self):
        text = text_of(self.registry.call("computer_use_status", {}))
        self.assertIn("adapter_version: %s" % SERVER_VERSION, text)
        self.assertIn("helper_version: unknown", text, "a 0.3.2 helper does not say")
        self.assertIn("helper_features:", text)
        self.assertNotIn("workspace", text.split("helper_features:")[1].splitlines()[0])


class ModernHelperTests(Base):
    def setUp(self):
        self.build(MODERN_CAPABILITIES, version="0.3.3", build="6")

    def test_a_current_helper_is_not_gated(self):
        result = self.registry.call("computer_use_context_open", {"app": "Safari"})
        self.assertFalse(result.get("isError"), text_of(result))
        self.assertEqual(len(self.frames("workspace.context_create")), 1)
        observed = self.registry.call("computer_use_observe", {"app": "Safari", "context": CTX})
        self.assertFalse(observed.get("isError"), text_of(observed))

    def test_status_shows_helper_and_adapter_versions_and_features(self):
        text = text_of(self.registry.call("computer_use_status", {}))
        self.assertIn("helper_version: 0.3.3 (build 6)", text)
        line = next(l for l in text.splitlines() if l.startswith("helper_features:"))
        for feature in ("workspace", "browser", "downloads", "scroll_reveal"):
            self.assertIn(feature, line)

    def test_the_capability_check_is_cached_not_a_ping_per_call(self):
        for _ in range(4):
            self.registry.call("computer_use_workspace_status", {})
        pings = self.frames("bridge.ping")
        self.assertLessEqual(len(pings), 2, "one ping serves the calls inside its freshness window")

    def test_a_restarted_helper_is_looked_at_again(self):
        self.registry.call("computer_use_workspace_status", {})
        self.helper.capabilities = LEGACY_CAPABILITIES
        self.helper.instance = "ins_" + "8" * 32
        self.client.instance_id = self.helper.instance  # what any answer from the new instance records
        result = self.registry.call("computer_use_workspace_status", {})
        self.assertIn("HELPER_TOO_OLD", text_of(result), "a downgraded helper is detected after a restart")


class VersionsAgreeTests(unittest.TestCase):
    def test_the_adapter_version_is_the_package_version(self):
        package = json.loads((pathlib.Path(__file__).resolve().parents[2] / "package.json").read_text())
        self.assertEqual(SERVER_VERSION, package["version"], "one version, not two that drift apart")
        self.assertNotEqual(SERVER_VERSION, "0.1.0", "the frozen placeholder (audit M-23)")


if __name__ == "__main__":
    unittest.main()
