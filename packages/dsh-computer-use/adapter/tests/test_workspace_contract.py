"""0.3.3 Multi-App Workspace: the adapter's side of the contract.

What the adapter SENDS (context ids only when named, an operation id on every
mutating action), what it NEVER does (resend a mutating action whose answer was
lost), what it retries (reads only) and what it REPORTS (contexts, execution
outcome, OUTCOME_UNKNOWN). The helper's side is pinned by XCTest
(WorkspaceContextTests, StreamRegistryTests, ReliabilityTests).
"""

from __future__ import annotations

import pathlib
import re
import sys
import threading
import time
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
REPO = ROOT.parents[2]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tests"))

from fake_bridge import FakeBridge, default_responder, failure, ok  # noqa: E402

from cmm_computer_use import client as client_module  # noqa: E402
from cmm_computer_use.client import (  # noqa: E402
    IDEMPOTENT_OPERATIONS,
    READ_OPERATIONS,
    BridgeClient,
    BridgeOutcomeUnknown,
    retry_class,
)
from cmm_computer_use.mcp_server import (  # noqa: E402
    AUTO_INVOCATION_POLICY,
    CONTEXT_PROPERTY,
    NO_BYPASS_POLICY,
    ToolRegistry,
    handle_message,
)

CTX_A = "ctx_" + "a" * 32
CTX_B = "ctx_" + "b" * 32


def text_of(result):
    return "\n".join(b["text"] for b in result["content"] if b["type"] == "text")


class WorkspaceHelper:
    """A scripted helper that answers the 0.3.3 operations it is asked for."""

    def __init__(self):
        self.instance = "ins_" + "1" * 32
        self.outcomes = {}
        self.lock = threading.Lock()

    def __call__(self, request):
        op = request.get("operation")
        args = request.get("arguments") or {}
        if op == "bridge.ping":
            result = default_responder(request)["result"]
            result["instance_id"] = self.instance
            return ok(request, result)
        if op == "workspace.context_create":
            label = "A" if not hasattr(self, "_a") else "B"
            self._a = True
            return ok(request, {"context_id": CTX_A if label == "A" else CTX_B, "label": label,
                                "legacy": False, "snapshot": 0, "instance_id": self.instance})
        if op == "workspace.context_close":
            return ok(request, {"context_id": args.get("context_id"), "closed": True,
                                "already_closed": False, "released_handles": 3, "stream_stopped": True})
        if op == "workspace.status":
            return ok(request, {"contract": "cmm-computer-use/workspace", "contract_version": 1,
                                "instance_id": self.instance,
                                "limits": {"max_contexts_per_client": 2, "max_streams": 2},
                                "contexts": [{"label": "A", "context_id": CTX_A, "snapshot": 2, "handles": 4,
                                              "expired": False,
                                              "identity": {"app": "Safari", "bundle": "com.apple.Safari",
                                                           "window": "Docs"}}],
                                "streams": []})
        if op == "observation.describe":
            frame = default_responder(request)
            if args.get("context_id"):
                frame["result"]["context_id"] = args["context_id"]
                frame["result"]["context_label"] = "A" if args["context_id"] == CTX_A else "B"
            return frame
        if op == "action.outcome":
            with self.lock:
                recorded = self.outcomes.get(args.get("op_id"))
            if recorded:
                return ok(request, {"op_id": args["op_id"], "known": True, "outcome": recorded, "ok": True,
                                    "instance_id": self.instance})
            return ok(request, {"op_id": args["op_id"], "known": False, "outcome": "unknown",
                                "instance_id": self.instance})
        return default_responder(request)


class Base(unittest.TestCase):
    helper_class = WorkspaceHelper

    def setUp(self):
        self.helper = self.helper_class()
        self.bridge = FakeBridge(self.helper).start()
        self.addCleanup(self.bridge.stop)
        self.client = BridgeClient(self.bridge.socket_path, policy="background")
        self.client._sleep = lambda _seconds: None
        self.addCleanup(self.client.close)
        self.registry = ToolRegistry(self.client, "background")

    def frames(self, operation):
        return [f for f in self.bridge.frames if f.get("operation") == operation]


class CatalogTests(Base):
    def test_every_handle_tool_accepts_an_optional_context(self):
        tools = {t["name"]: t for t in self.registry.tools()}
        for name in ("computer_use_observe", "computer_use_capture_window", "computer_use_press",
                     "computer_use_set_value", "computer_use_scroll", "computer_use_release"):
            schema = tools[name]["inputSchema"]
            self.assertEqual(schema["properties"]["context"], CONTEXT_PROPERTY, name)
            self.assertNotIn("context", schema["required"], "%s: 0.3.2 calls stay valid" % name)
        self.assertIn("computer_use_context_open", tools)
        self.assertIn("computer_use_context_close", tools)
        self.assertIn("computer_use_workspace_status", tools)

    def test_background_catalog_still_has_no_focus_pointer_or_keyboard_tool(self):
        names = {t["name"] for t in self.registry.tools()}
        for absent in ("computer_use_activate_app", "computer_use_focus_window", "computer_use_click",
                       "computer_use_type_text", "computer_use_shortcut", "computer_use_pointer_scroll"):
            self.assertNotIn(absent, names)

    def test_instructions_make_gui_work_select_these_tools_automatically(self):
        reply = handle_message(self.registry, {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                               "params": {"protocolVersion": "2025-06-18"}})
        instructions = reply["result"]["instructions"]
        self.assertTrue(instructions.startswith(AUTO_INVOCATION_POLICY))
        self.assertIn("without waiting to be told", instructions)
        self.assertIn("Do not use them for work that is purely text", instructions)
        self.assertIn(NO_BYPASS_POLICY, instructions)

    def test_a_malformed_context_is_rejected_before_any_frame(self):
        reply = handle_message(self.registry, {"jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": {
            "name": "computer_use_press", "arguments": {"element_id": 1, "snapshot": 1, "context": "../x"}}})
        self.assertEqual(reply["error"]["code"], -32602)
        self.assertEqual(self.frames("action.execute"), [])


class WireTests(Base):
    def test_a_legacy_call_sends_no_context(self):
        self.registry.call("computer_use_observe", {"app": "Finder"})
        self.registry.call("computer_use_press", {"element_id": 3, "snapshot": 1})
        self.assertNotIn("context_id", self.frames("observation.describe")[-1]["arguments"])
        self.assertNotIn("context_id", self.frames("action.execute")[-1]["arguments"])

    def test_context_travels_with_observe_and_actions(self):
        self.registry.call("computer_use_observe", {"app": "Safari", "context": CTX_A})
        self.registry.call("computer_use_press", {"element_id": 3, "snapshot": 1, "context": CTX_B})
        self.assertEqual(self.frames("observation.describe")[-1]["arguments"]["context_id"], CTX_A)
        self.assertEqual(self.frames("action.execute")[-1]["arguments"]["context_id"], CTX_B)

    def test_every_mutating_action_carries_a_fresh_operation_id(self):
        self.client.act("ui.press", element_id=1, snapshot=1)
        self.client.act("ui.press", element_id=1, snapshot=1)
        self.client.act("wait", seconds=0)
        ids = [f["arguments"].get("op_id") for f in self.frames("action.execute")]
        self.assertTrue(ids[0] and ids[1] and ids[0] != ids[1])
        self.assertTrue(re.fullmatch(r"op_[0-9a-f]{32}", ids[0]))
        self.assertIsNone(ids[2], "wait changes nothing: no ledger entry needed")

    def test_observe_reports_its_context_and_the_facts_a_host_needs(self):
        text = text_of(self.registry.call("computer_use_observe", {"app": "Safari", "context": CTX_A}))
        self.assertIn("context: A %s" % CTX_A, text)
        # Helper facts printed before AX content (DSH can verify and show the
        # target without a prior computer_use_status call).
        self.assertRegex(text, r"(?m)^helper: cmm-computer-use protocol=1")
        self.assertRegex(text, r"(?m)^deployment_policy: \w+$")
        self.assertRegex(text, r"(?m)^- authorized: Finder \[com\.apple\.finder\] scopes=control,observe windows=0$")

    def test_cmm_view_names_the_context(self):
        from cmm_computer_use.mcp_server import _render_observation
        text = _render_observation({"target_app": "Safari", "target_bundle": "com.apple.Safari",
                                    "target_pid": 501, "target_window": "Docs", "target_window_id": 11,
                                    "snapshot": 2, "context_id": CTX_A, "context_label": "A"})
        view = next(line for line in text.splitlines() if line.startswith("cmm_view: "))
        self.assertIn('"context_id":"%s"' % CTX_A, view)
        self.assertIn('"context_label":"A"', view)
        legacy = _render_observation({"target_app": "Safari", "target_bundle": "com.apple.Safari",
                                      "target_pid": 501, "target_window": "Docs", "snapshot": 2,
                                      "context_id": CTX_B, "context_label": "default"})
        self.assertNotIn("context_id", legacy, "a 0.3.2 observation's metadata is unchanged")

    def test_workspace_tools_render(self):
        opened = text_of(self.registry.call("computer_use_context_open", {"app": "Safari"}))
        self.assertIn("context opened: A %s" % CTX_A, opened)
        status = text_of(self.registry.call("computer_use_workspace_status", {}))
        self.assertIn("- context A %s snapshot=2" % CTX_A, status)
        closed = text_of(self.registry.call("computer_use_context_close", {"context": CTX_A}))
        self.assertIn("closed; released 3 element handle(s); its stream stopped", closed)


class SlowActionHelper(WorkspaceHelper):
    """Records the outcome, then answers the action too late."""

    record = True
    restart = False
    in_progress = False

    def __call__(self, request):
        if request.get("operation") == "action.execute":
            op_id = (request.get("arguments") or {}).get("op_id")
            if self.record:
                with self.lock:
                    self.outcomes[op_id] = "succeeded"
            if self.restart:
                self.instance = "ins_" + "2" * 32
            time.sleep(0.5)
            return ok(request, {"ok": True, "message": "too late"})
        if request.get("operation") == "action.outcome" and self.in_progress:
            return ok(request, {"op_id": request["arguments"]["op_id"], "known": False,
                                "outcome": "in_progress", "instance_id": self.instance})
        return super().__call__(request)


class LostAnswerTests(Base):
    helper_class = SlowActionHelper

    def press(self):
        self.client.ping()  # the instance the action is sent to
        with mock.patch.dict(client_module.OPERATION_TIMEOUTS, {"action.execute": 0.15}):
            return self.client.act("ui.press", element_id=1, snapshot=1)

    def test_a_lost_answer_is_recovered_from_the_ledger_without_resending(self):
        result = self.press()
        self.assertEqual(result["execution"]["outcome"], "succeeded")
        self.assertTrue(result["execution"]["recovered"])
        self.assertEqual(len(self.frames("action.execute")), 1, "the press is never sent twice")
        self.assertEqual(len(self.frames("action.outcome")), 1)

    def test_an_unrecorded_outcome_is_unknown_and_never_resent(self):
        self.helper.record = False
        with self.assertRaises(BridgeOutcomeUnknown) as caught:
            self.press()
        self.assertEqual(caught.exception.reason, "not_recorded")
        self.assertEqual(caught.exception.code, "OUTCOME_UNKNOWN")
        self.assertEqual(len(self.frames("action.execute")), 1)

    def test_a_helper_restart_makes_the_outcome_unknown(self):
        self.helper.record = False
        self.helper.restart = True
        with self.assertRaises(BridgeOutcomeUnknown) as caught:
            self.press()
        self.assertEqual(caught.exception.reason, "helper_restarted")
        self.assertEqual(self.frames("action.outcome"), [], "a new instance has no ledger to ask")
        self.assertEqual(len(self.frames("action.execute")), 1)

    def test_in_progress_is_polled_boundedly_then_unknown(self):
        self.helper.record = False
        self.helper.in_progress = True
        with self.assertRaises(BridgeOutcomeUnknown) as caught:
            self.press()
        self.assertEqual(caught.exception.reason, "in_progress")
        self.assertEqual(len(self.frames("action.outcome")), 3)
        self.assertEqual(len(self.frames("action.execute")), 1)

    def test_the_mcp_surface_says_stop_do_not_resend(self):
        self.helper.record = False
        self.client.ping()
        with mock.patch.dict(client_module.OPERATION_TIMEOUTS, {"action.execute": 0.15}):
            result = self.registry.call("computer_use_press", {"element_id": 1, "snapshot": 1})
        text = text_of(result)
        self.assertTrue(result.get("isError"))
        self.assertIn("REFUSED OUTCOME_UNKNOWN", text)
        self.assertIn("STOP: outcome unknown", text)
        self.assertIn("execution: executed=None outcome=unknown", text)


class RetryTests(Base):
    def test_reads_are_retried_and_mutations_are_not(self):
        original = self.bridge._responder
        seen = set()

        def flaky(request):
            op = request.get("operation")
            if op not in seen and op in ("observation.describe", "action.execute"):
                seen.add(op)
                return None  # the fake bridge closes the connection without answering
            return original(request)

        self.bridge._responder = flaky
        observation = self.client.observe(app="Finder")
        self.assertIn("snapshot", observation)
        self.assertEqual(len(self.frames("observation.describe")), 2, "a read is retried once")
        with self.assertRaises(BridgeOutcomeUnknown):
            self.client.act("ui.press", element_id=1, snapshot=1)
        self.assertEqual(len(self.frames("action.execute")), 1, "a mutation is never retried")


class SwiftParityTests(unittest.TestCase):
    """The adapter's retry classes are the helper's (ComputerUseReliability)."""

    def test_retry_classes_match_the_helper_source(self):
        source = (REPO / "apps/macos/Shared/ComputerUseReliability.swift").read_text()
        body = source[source.index("public func bridgeRetryClass("):]
        body = body[:body.index("\n}\n")]
        read_case = re.search(r'case ("bridge\.ping".*?):\n\s*return \.read', body, re.S).group(1)
        idem_case = re.search(r'case ("observation\.release".*?):\n\s*return \.idempotent', body, re.S).group(1)
        swift_read = set(re.findall(r'"([a-z_.]+)"', read_case))
        swift_idem = set(re.findall(r'"([a-z_.]+)"', idem_case))
        # policy.requirements.check is a helper diagnostic the adapter never sends.
        self.assertEqual(READ_OPERATIONS, swift_read - {"policy.requirements.check"})
        # policy.reload is an operator action the adapter never sends.
        self.assertEqual(IDEMPOTENT_OPERATIONS, swift_idem - {"policy.reload"})
        self.assertEqual(retry_class("action.execute", "ui.press"), "mutating")
        self.assertEqual(retry_class("action.execute", "wait"), "read")
        self.assertEqual(retry_class("some.future_op"), "mutating")


if __name__ == "__main__":
    unittest.main()
