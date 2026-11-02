"""Pure judgment functions of live_background_e2e.py (run anywhere)."""

from __future__ import annotations

import importlib.util
import pathlib
import unittest

VERIFY = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("live_e2e", str(VERIFY / "live_background_e2e.py"))
e2e = importlib.util.module_from_spec(spec)
spec.loader.exec_module(e2e)

LEDGER_OK = ("interference: verdict=untouched cursor_moved=False policy=background\n"
             "attributable: cursor_events_posted=False cursor_moved_by_action=False "
             "focus_became_target=False external_activity=False\n")


class ScrollVerdictTests(unittest.TestCase):
    MOVED_WITH_AX_ERROR = ("ui.scroll: scrolled down 1 page(s) via page_action (AX returned -25205; effect verified)\n"
                           "scroll: route=page_action effect=moved ax_error=-25205 before=origin=622 after=origin=498\n"
                           + LEDGER_OK)

    def test_the_live_case_passes_on_the_fixture_with_the_ax_error_as_diagnostic(self):
        v = e2e.scroll_verdict(self.MOVED_WITH_AX_ERROR, False, True, {"scroll_y": 0}, {"scroll_y": 120})
        self.assertTrue(v["ok"])
        self.assertEqual(v["ax_error_diagnostic"], -25205)

    def test_fixture_requires_the_second_channel(self):
        self.assertFalse(e2e.scroll_verdict(self.MOVED_WITH_AX_ERROR, False, True, {"scroll_y": 0}, {"scroll_y": 0})["ok"])
        self.assertFalse(e2e.scroll_verdict(self.MOVED_WITH_AX_ERROR, False, True, None, None)["ok"])

    def test_fixture_rejects_unsupported_and_unverified(self):
        unsupported = "REFUSED CAPABILITY_UNSUPPORTED: no AX scroll primitive [reason=scroll_area_without_scrollbar]\n"
        self.assertFalse(e2e.scroll_verdict(unsupported, True, True, {"scroll_y": 0}, {"scroll_y": 0})["ok"])
        failed = ("REFUSED ACTION_FAILED: The scroll had no verifiable effect through accessibility. "
                  "[policy=background;kind=ui.scroll;reason=no_effect;role=AXScrollArea;routes=page_action,scroll_bar;ax_error=-25205]\n"
                  "scroll: route=none effect=no_effect ax_error=none before=bar=0.000 after=bar=0.000\n")
        self.assertFalse(e2e.scroll_verdict(failed, True, True, {"scroll_y": 0}, {"scroll_y": 0})["ok"])

    def test_a_moved_scroll_that_disturbed_the_person_is_not_ok(self):
        disturbed = self.MOVED_WITH_AX_ERROR.replace("verdict=untouched", "verdict=cursor_moved")
        self.assertFalse(e2e.scroll_verdict(disturbed, False, True, {"scroll_y": 0}, {"scroll_y": 120})["ok"])

    def test_elsewhere_an_explicit_unsupported_is_acceptable(self):
        unsupported = "REFUSED CAPABILITY_UNSUPPORTED: no AX scroll primitive [reason=scroll_area_without_scrollbar]\n"
        self.assertTrue(e2e.scroll_verdict(unsupported, True, False)["ok"])


class ElectronVerdictTests(unittest.TestCase):
    CLAUDE = ("target: Claude [com.anthropic.claudefordesktop] (background)\n"
              "ax_access: readable content=4 elements=0 actionable=0 window_controls=0\n"
              "readable only: this window can be observed; it exposes no control to operate.\n"
              'readable content (4, read-only):\n- AXWebArea "Nuevo chat - Claude"\n'
              "interactive elements: none detected\n")

    def test_the_live_claude_observation_passes_the_readable_gate(self):
        v = e2e.electron_verdict(self.CLAUDE, False)
        self.assertTrue(v["readable"])
        self.assertFalse(v["actionable"])
        self.assertFalse(v["unavailable"])
        self.assertFalse(v["control_proven"], "observing is never proof of control")

    def test_unavailable_and_errors_fail_the_gate(self):
        chrome = ("ax_access: unavailable content=0 elements=3 actionable=0 window_controls=3\n"
                  "AX_TREE_UNAVAILABLE: this window exposes only its window controls\n")
        self.assertFalse(e2e.electron_verdict(chrome, False)["readable"])
        self.assertTrue(e2e.electron_verdict(chrome, False)["unavailable"])
        self.assertFalse(e2e.electron_verdict("REFUSED APPROVAL_REJECTED: x", True)["readable"])
        self.assertFalse(e2e.electron_verdict("no ax_access line at all", False)["readable"])

    def test_actionable_is_readable_and_reported_but_not_control(self):
        v = e2e.electron_verdict("ax_access: actionable content=10 elements=5 actionable=5 window_controls=3\n", False)
        self.assertTrue(v["readable"] and v["actionable"])
        self.assertFalse(v["control_proven"])


class CursorMotionTests(unittest.TestCase):
    STEPS = [
        {"step": "5b re-observe", "start": 10.0, "end": 10.2, "text": "observe"},
        {"step": "6 scroll", "start": 10.3, "end": 11.4,
         "text": "interference: verdict=cursor_moved cursor_moved=True policy=background\n"
                 "attributable: cursor_events_posted=False cursor_moved_by_action=False "
                 "focus_became_target=False external_activity=True\n"
                 "sampled: n=200 transient_focus_changes=0 transient_cursor_max_delta=256.0 restored=False\n"},
    ]

    def rows(self, moves):
        rows = [{"t": 9.0 + i / 100, "front": "p", "top": "p", "x": 100.0, "y": 100.0} for i in range(400)]
        for r in rows:
            for start, end, dx in moves:
                if start <= r["t"] <= end:
                    r["x"] = 100.0 + dx
        return rows

    def test_movement_during_the_scroll_call_is_attributed_with_the_ledger(self):
        motion = e2e.cursor_motion(self.STEPS, self.rows([(10.5, 10.9, 256.0)]))
        scroll = [m for m in motion if m["step"] == "6 scroll"][0]
        self.assertEqual(scroll["first_move_phase"], "during_call")
        self.assertEqual(scroll["peak_delta"], 256.0)
        self.assertGreater(scroll["during_call_samples"], 0)
        self.assertEqual(scroll["helper_ledger"]["external_activity"], "True")
        self.assertEqual(scroll["helper_ledger"]["cursor_events_posted"], "False")
        line = e2e.describe_cursor_motion(scroll)
        self.assertIn("step '6 scroll'", line)
        self.assertIn("during_call", line)
        # The previous step's tail also sees it, and is told it overlaps the scroll call.
        observe = [m for m in motion if m["step"] == "5b re-observe"][0]
        self.assertEqual(observe["first_move_phase"], "tail")
        self.assertEqual(observe["overlaps_calls_of"], ["6 scroll"])

    def test_no_movement_no_diagnostic(self):
        self.assertEqual(e2e.cursor_motion(self.STEPS, self.rows([])), [])

    def test_the_quiet_gate_is_unchanged(self):
        source = (VERIFY / "live_background_e2e.py").read_text()
        self.assertIn('v["cursor_max_delta"] <= 0.5', source)
        self.assertIn('checks["witness_quiet"] = quiet_ok', source)
        self.assertNotIn('external_activity") == "True" and', source)


if __name__ == "__main__":
    unittest.main()
