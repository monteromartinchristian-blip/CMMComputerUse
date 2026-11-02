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


class ScrollEvidenceTests(Case):
    @staticmethod
    def responder(request):
        params = request["arguments"]["params"]
        if params["element_id"] == 5:
            return ok(request, {"ok": True, "message": "scrolled down 1 page(s) via page_action (AX returned -25205; effect verified)",
                                "scroll": {"route": "page_action", "effect": "moved", "ax_error": -25205,
                                           "before": {"content_origin": 622}, "after": {"content_origin": 498},
                                           "attempts": [{"route": "page_action", "effect": "moved", "ax_error": -25205,
                                                         "before": {"content_origin": 622}, "after": {"content_origin": 498}}]},
                                "interference": dict(BREACH_LEDGER, verdict="untouched", breach=False,
                                                     focus_became_target=False, transient_focus_changes=0)})
        error = failure(request, "ACTION_FAILED", "The scroll had no verifiable effect through accessibility.",
                        "policy=background;kind=ui.scroll;reason=no_effect;role=AXScrollArea;routes=page_action,scroll_bar")
        error["error"]["scroll"] = {"effect": "no_effect", "before": {"bar_value": 0.5}, "after": {"bar_value": 0.5},
                                    "attempts": [{"route": "page_action", "effect": "unchanged"},
                                                 {"route": "scroll_bar", "effect": "unchanged"}]}
        return error

    def test_ax_error_with_observed_effect_is_a_success_with_the_error_as_diagnostic(self):
        response = self.call("computer_use_scroll", {"element_id": 5, "snapshot": 1, "direction": "down"})
        self.assertFalse(response["result"].get("isError", False))
        text = text_of(response)
        self.assertIn("scroll: route=page_action effect=moved ax_error=-25205 before=origin=622 after=origin=498", text)

    def test_no_verifiable_effect_is_a_failure_with_the_evidence(self):
        response = self.call("computer_use_scroll", {"element_id": 6, "snapshot": 1, "direction": "down"})
        self.assertTrue(response["result"].get("isError"))
        text = text_of(response)
        self.assertIn("reason=no_effect", text)
        self.assertIn("scroll: route=none effect=no_effect", text)
        self.assertIn("- attempt scroll_bar: effect=unchanged", text)


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


class ReadableVersusActionableTests(Case):
    """The live Claude observation: AXWindow / AXGroup / AXWebArea / AXHeading
    and no control. Readable, not unavailable, not actionable."""

    CLAUDE_LIVE = {
        "frontmost_app": "DeepSeek Harness", "frontmost_bundle": "com.deepseek.harness",
        "target_app": "Claude", "target_bundle": CLAUDE, "target_pid": 777,
        "target_window": "Claude", "target_window_id": 41, "target_is_frontmost": False,
        "windows": [], "elements": [], "snapshot": 9, "captured_at": 1.0, "screenshot_scope": "none",
        "content": [{"role": "AXWindow", "text": "Claude"}, {"role": "AXGroup", "text": "Claude"},
                    {"role": "AXWebArea", "text": "Nuevo chat - Claude"}, {"role": "AXHeading", "text": "Claude"}],
        "ax_tree": "ok", "ax_access": "readable",
        "ax_counts": {"content": 4, "elements": 0, "actionable": 0, "window_controls": 0},
    }
    observation = CLAUDE_LIVE

    @staticmethod
    def responder(request):
        return ok(request, ReadableVersusActionableTests.observation)

    def test_claude_live_shape_is_readable_not_unavailable(self):
        text = text_of(self.call("computer_use_observe", {"app": CLAUDE}))
        self.assertIn("ax_access: readable content=4 elements=0 actionable=0", text)
        self.assertIn("readable only", text)
        self.assertNotIn("AX_TREE_UNAVAILABLE", text)

    def test_older_helper_without_ax_access_is_derived_the_same_way(self):
        legacy = {k: v for k, v in self.CLAUDE_LIVE.items() if k not in ("ax_access", "ax_counts")}
        ReadableVersusActionableTests.observation = legacy
        try:
            text = text_of(self.call("computer_use_observe", {"app": CLAUDE}))
        finally:
            ReadableVersusActionableTests.observation = self.CLAUDE_LIVE
        self.assertIn("ax_access: readable content=4", text)
        self.assertNotIn("AX_TREE_UNAVAILABLE", text)

    def test_actionable_and_unavailable(self):
        from cmm_computer_use.mcp_server import _ax_access
        self.assertEqual(_ax_access({"elements": [{"role": "AXButton", "pressable": True}]}), "actionable")
        self.assertEqual(_ax_access({"elements": [{"role": "AXTextField"}]}), "actionable")
        self.assertEqual(_ax_access({"elements": [{"role": "AXButton", "pressable": True, "window_chrome": True}]}),
                         "unavailable")
        self.assertEqual(_ax_access({"elements": [], "content": []}), "unavailable")


class ClaudeControlSurfaceTests(Case):
    """What the agent sees about Claude's tree and a verified set_value."""

    sent = []
    composer_value = ""

    @staticmethod
    def responder(request):
        ClaudeControlSurfaceTests.sent.append(request)
        op = request["operation"]
        if op == "observation.describe":
            return ok(request, {
                "frontmost_app": "Terminal", "frontmost_bundle": "com.apple.Terminal",
                "target_app": "Claude", "target_bundle": CLAUDE, "target_pid": 777,
                "target_window": "Claude", "target_window_id": 41, "target_is_frontmost": False,
                "windows": [], "snapshot": 12, "captured_at": 1.0, "screenshot_scope": "none",
                "content": [{"role": "AXWebArea", "text": "Nuevo chat - Claude"}],
                "elements": [
                    {"element_id": 4, "role": "AXTextArea", "title": "Escribe a Claude", "value": ClaudeControlSurfaceTests.composer_value,
                     "x": 300, "y": 800, "width": 600, "height": 40, "pressable": False,
                     "value_settable": True, "actionable": True},
                    {"element_id": 5, "role": "AXTextField", "title": "Buscar", "value": "",
                     "x": 10, "y": 10, "width": 100, "height": 20, "pressable": False,
                     "value_settable": False, "actionable": False},
                ],
                "ax_tree": "ok", "ax_access": "actionable",
                "ax_counts": {"content": 1, "elements": 2, "actionable": 1, "window_controls": 0, "text_inputs": 2,
                              "limits": {"visited": 812, "deepest_depth": 27, "max_depth": 40, "depth_cutoffs": 0,
                                         "children_cutoffs": 0, "budget_skipped_controls": 0}},
                "ax_enrichment": {"state": "enabled", "mechanism": "AXManualAccessibility",
                                  "trigger": "readable_not_actionable", "nodes_before": 24, "nodes_after": 400,
                                  "access_before": "readable", "actionable_before": 0,
                                  "access_after": "actionable", "actionable_after": 1},
                "ax_diagnostics": {"after": {"visited": 812, "deepest_depth": 27, "depth_cutoffs": 0,
                                             "children_cutoffs": 0, "candidates_total": 1,
                                             "roles": [{"role": "AXGroup", "count": 600}],
                                             "candidates": [{"role": "AXTextArea", "title": "Escribe a Claude", "depth": 26,
                                                             "actions": [], "value_settable": True,
                                                             "path": "AXWebArea>AXGroup>AXGroup"}]}},
            })
        params = request["arguments"]["params"]
        if params["element_id"] == 5:
            return failure(request, "CAPABILITY_UNSUPPORTED",
                           "This element's value cannot be set through accessibility.",
                           "policy=background;kind=ui.set_value;reason=value_not_settable;role=AXTextField")
        if params["text"] == "no-take":
            error = failure(request, "ACTION_FAILED", "The value did not take (read back does not match).",
                            "policy=background;kind=ui.set_value;reason=value_not_applied;role=AXTextArea")
            error["error"]["set_value"] = {"check": "not_applied", "requested_length": 7, "read_back_length": 0}
            return error
        ClaudeControlSurfaceTests.composer_value = params["text"]
        return ok(request, {"ok": True, "message": "value set and verified",
                            "set_value": {"check": "verified", "requested_length": len(params["text"]),
                                          "read_back_length": len(params["text"]), "previous_length": 0},
                            "interference": dict(BREACH_LEDGER, verdict="untouched", breach=False,
                                                 focus_became_target=False, transient_focus_changes=0)})

    def setUp(self):
        ClaudeControlSurfaceTests.sent = []
        ClaudeControlSurfaceTests.composer_value = ""
        super().setUp()

    def test_enrichment_transition_walk_limits_and_text_inputs_are_visible(self):
        text = text_of(self.call("computer_use_observe", {"app": CLAUDE}))
        self.assertIn("ax_enrichment: enabled via AXManualAccessibility nodes 24->400 trigger=readable_not_actionable "
                      "access readable->actionable actionable 0->1", text)
        self.assertIn("ax_walk: visited=812 deepest=27/40 depth_cutoffs=0", text)
        self.assertIn('settable value=""', text)
        self.assertIn('not-settable value=""', text)
        self.assertNotIn("include_ax_diagnostics", ClaudeControlSurfaceTests.sent[-1]["arguments"])

    def test_diagnostics_only_when_asked(self):
        text = text_of(self.call("computer_use_observe", {"app": CLAUDE, "ax_diagnostics": True}))
        self.assertTrue(ClaudeControlSurfaceTests.sent[-1]["arguments"]["include_ax_diagnostics"])
        self.assertIn("ax_diagnostics after: visited=812 deepest=27", text)
        self.assertIn('- AXTextArea "Escribe a Claude" depth=26 actions=- value_settable=True', text)

    def test_verified_set_value_and_honest_failures(self):
        ok_text = text_of(self.call("computer_use_set_value", {"element_id": 4, "text": "CMM prueba", "snapshot": 12}))
        self.assertIn("set_value: check=verified requested_length=10 read_back_length=10", ok_text)
        refused = self.call("computer_use_set_value", {"element_id": 5, "text": "x", "snapshot": 12})
        self.assertTrue(refused["result"].get("isError"))
        self.assertIn("REFUSED CAPABILITY_UNSUPPORTED", text_of(refused))
        self.assertIn("reason=value_not_settable", text_of(refused))
        no_take = self.call("computer_use_set_value", {"element_id": 4, "text": "no-take", "snapshot": 12})
        self.assertIn("reason=value_not_applied", text_of(no_take))
        self.assertIn("set_value: check=not_applied", text_of(no_take))

    def test_read_only_text_input_is_not_actionable_in_the_derived_reading(self):
        from cmm_computer_use.mcp_server import _ax_access
        self.assertEqual(_ax_access({"elements": [{"role": "AXTextArea", "value_settable": False}],
                                     "content": [{"role": "AXWebArea"}]}), "readable")
        self.assertEqual(_ax_access({"elements": [{"role": "AXTextArea", "value_settable": True}]}), "actionable")


class HumanTakeoverTests(Case):
    TAKEOVER = dict(BREACH_LEDGER, breach=False, external_activity=True, focus_became_target=True,
                    focus_change_attribution="user", human_input_detected=True, human_input_kind="mouse_down",
                    human_input_age_ms=42, human_witness_available=True, requires_reobserve=True)
    sent = []

    @staticmethod
    def responder(request):
        HumanTakeoverTests.sent.append(request)
        return ok(request, {"ok": True, "message": "pressed", "interference": HumanTakeoverTests.TAKEOVER})

    def setUp(self):
        HumanTakeoverTests.sent = []
        super().setUp()

    def test_takeover_is_an_error_result_with_attribution_and_no_stop(self):
        response = self.call("computer_use_press", {"element_id": 2, "snapshot": 5})
        self.assertTrue(response["result"].get("isError"), "never a silent success")
        text = text_of(response)
        self.assertIn("attribution: focus_change_attribution=user human_input_detected=True "
                      "human_input_kind=mouse_down human_input_age_ms=42 human_witness=available", text)
        self.assertIn("USER_TAKEOVER: the person brought the target application to the front during this action "
                      "(attribution=user).", text)
        self.assertNotIn("STOP: breach", text)
        self.assertNotIn("REFUSED INTERFERENCE_BREACH", text)

    def test_takeover_never_names_the_final_frontmost_as_the_target(self):
        # Gate B on the Mac: the person clicked the target, but by the end of
        # the settle window Terminal was in front again.
        from cmm_computer_use.mcp_server import _render_action
        ledger = dict(self.TAKEOVER, frontmost_after="Terminal")
        text, is_error = _render_action("ui.press", {"ok": True, "message": "pressed", "interference": ledger})
        line = [l for l in text.splitlines() if l.startswith("USER_TAKEOVER:")]
        self.assertEqual(len(line), 1)
        self.assertNotIn("Terminal", line[0])
        self.assertIn("the person brought the target application to the front during this action", line[0])
        self.assertIn("(attribution=user)", line[0])
        self.assertIn("Not a breach; nothing is latched.", line[0])
        self.assertIn("observe again before any other action, and do not retry this one.", line[0])
        self.assertTrue(is_error, "classification unchanged: a takeover is an error result")
        self.assertNotIn("STOP: breach", text)

    def test_16_no_automatic_retry(self):
        self.call("computer_use_press", {"element_id": 2, "snapshot": 5})
        self.assertEqual([f["operation"] for f in HumanTakeoverTests.sent], ["action.execute"],
                         "one call, no retry, no implicit re-observe")


class FilterPushdownTests(Case):
    """`filter` reaches the helper as `element_filter` (applied before its
    budget); the adapter keeps a post-filter as defense."""

    sent = []

    @staticmethod
    def responder(request):
        FilterPushdownTests.sent.append(request)
        op = request["operation"]
        args = request["arguments"]
        if op == "observation.release":
            return ok(request, {"released": 54, "invalidated_snapshot": 21, "snapshot": 22})
        if op != "observation.describe":
            return failure(request, "CAPABILITY_UNSUPPORTED", "unexpected")
        if args.get("app") == "com.apple.mail":
            return failure(request, "APPROVAL_REJECTED", "The deployment does not authorize this application.",
                           "auth=app_not_granted;app=com.apple.mail")
        unrelated = [{"element_id": i, "role": "AXButton", "title": "Chat %d" % i, "value": "",
                      "x": 0, "y": i, "width": 10, "height": 10, "pressable": True, "actionable": True}
                     for i in range(1, 62)]
        gear = {"element_id": 62, "role": "AXButton", "title": "Configuración de Code", "value": "",
                "x": 900, "y": 20, "width": 24, "height": 24, "pressable": True, "actionable": True}
        icon_only = {"element_id": 63, "role": "AXButton", "title": "", "value": "",
                     "x": 950, "y": 20, "width": 24, "height": 24, "pressable": True, "actionable": True}
        base = {"frontmost_app": "Terminal", "frontmost_bundle": "com.apple.Terminal", "target_app": "Claude",
                "target_bundle": CLAUDE, "target_pid": 7, "target_window": "Claude", "target_window_id": 4,
                "target_is_frontmost": False, "windows": [], "content": [], "snapshot": 21, "captured_at": 1.0,
                "screenshot_scope": "none", "ax_tree": "ok", "ax_access": "actionable"}
        if args.get("element_filter"):
            # As the helper does: only matches, marked, plus the filter summary.
            needle = args["element_filter"].lower()
            matched = [dict(e, filter_match=True) for e in unrelated + [gear] if needle in e["title"].lower()]
            if needle == "ajustes":  # matched on a field the text does not show (description)
                matched = [dict(icon_only, filter_match=True)]
            return ok(request, dict(base, elements=matched, ax_filter={
                "text": args["element_filter"], "matched": len(matched), "skipped_non_matching": 62 - len(matched)}))
        # Unfiltered: the ordinary budget cut the gear off.
        return ok(request, dict(base, elements=unrelated[:60],
                                ax_counts={"content": 0, "elements": 60, "actionable": 60, "window_controls": 0,
                                           "limits": {"budget_skipped_controls": 2}}))

    def setUp(self):
        FilterPushdownTests.sent = []
        super().setUp()

    def describe_args(self):
        return [r["arguments"] for r in FilterPushdownTests.sent if r["operation"] == "observation.describe"][-1]

    def test_the_filter_is_pushed_down_and_finds_the_late_control(self):
        text = text_of(self.call("computer_use_observe", {"app": CLAUDE, "filter": "Configuración"}))
        self.assertEqual(self.describe_args()["element_filter"], "Configuración")
        self.assertEqual(self.describe_args()["app"], CLAUDE)
        self.assertIn('[62] AXButton "Configuración de Code"', text)
        self.assertIn('ax_filter: "Configuración" matched=1 skipped_non_matching=61', text)

    def test_no_filter_sends_nothing_new_and_keeps_the_bounded_projection(self):
        text = text_of(self.call("computer_use_observe", {"app": CLAUDE}))
        self.assertNotIn("element_filter", self.describe_args())
        self.assertNotIn("Configuración de Code", text)
        self.call("computer_use_observe", {"app": CLAUDE, "filter": "   "})
        self.assertNotIn("element_filter", self.describe_args(), "blank filter == no filter")

    def test_the_post_filter_keeps_what_the_helper_matched(self):
        text = text_of(self.call("computer_use_observe", {"app": CLAUDE, "filter": "ajustes"}))
        self.assertIn('[63] AXButton ""', text, "matched by the helper on description; kept by the adapter")

    def test_a_filter_never_widens_authorization(self):
        response = self.call("computer_use_observe", {"app": "com.apple.mail", "filter": "Configuración"})
        self.assertTrue(response["result"].get("isError"))
        self.assertIn("REFUSED APPROVAL_REJECTED", text_of(response))
        self.assertEqual(len([r for r in FilterPushdownTests.sent if r["operation"] == "observation.describe"]), 1,
                         "one request for the named app only; no global search")

    def test_release_reports_the_invalidated_snapshot_and_the_new_generation(self):
        text = text_of(self.call("computer_use_release"))
        self.assertEqual(text, "released 54 element handle(s); snapshot 21 invalidated; current generation=22")


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
