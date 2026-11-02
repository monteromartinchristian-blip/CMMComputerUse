"""Pure judgment functions of live_background_e2e.py (run anywhere)."""

from __future__ import annotations

import importlib.util
import pathlib
import unittest
from unittest import mock

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
        # Same criterion, now named quiet_step_ok() and used by the quiet loop.
        self.assertIn('return (verdict["samples"] > 0 and not verdict["target_front"] and not verdict["target_top"]\n'
                      '            and verdict["cursor_max_delta"] <= 0.5)', source)
        self.assertIn("ok = quiet_step_ok(v)", source)
        self.assertIn('checks["witness_quiet"] = quiet_ok', source)
        self.assertNotIn('external_activity") == "True" and', source)


class FakeClock:
    """Simulated CLOCK_UPTIME_RAW: each tool call takes `call_s`; sleep advances."""

    def __init__(self, call_s=0.2):
        self.now = 100.0
        self.call_s = call_s

    def uptime(self):
        return self.now

    def sleep(self, seconds):
        self.now += max(0.0, seconds)

    def handle(self, registry, message):
        self.now += self.call_s
        return {"result": {"content": [{"type": "text", "text": "ok " + message["params"]["name"]}]}}


class WitnessWindowTests(unittest.TestCase):
    TARGET = "com.example.computer-use-fixture"
    PERSON = "com.apple.Terminal"

    def run_steps(self, plan):
        """plan: [(step, quiet)] executed through the REAL Driver.call."""
        clock = FakeClock()
        with mock.patch.object(e2e, "uptime", clock.uptime), \
             mock.patch.object(e2e.time, "sleep", clock.sleep), \
             mock.patch.object(e2e, "handle_message", clock.handle), \
             mock.patch("builtins.print"):
            d = e2e.Driver("/nonexistent/socket")
            for step, quiet in plan:
                d.call(step, "computer_use_observe", {}, quiet=quiet)
        return d.steps, clock

    def rows(self, start, end, events=()):
        """Witness samples every 10 ms; events: (t_from, t_to, field, value)."""
        rows = []
        t = start
        while t <= end:
            row = {"t": round(t, 3), "front": self.PERSON, "top": self.PERSON, "x": 50.0, "y": 50.0}
            for t0, t1, field, value in events:
                if t0 <= t <= t1:
                    row[field] = value
            rows.append(row)
            t += 0.01
        return rows

    def quiet_verdict(self, steps, rows, name):
        verdicts = e2e.judge(steps, rows, self.TARGET, self.PERSON)
        return [v for s, v in zip(steps, verdicts) if s["step"] == name][0]

    def test_quiet_step_with_a_silent_tail_passes(self):
        steps, clock = self.run_steps([("2 observe", True)])
        step = steps[0]
        self.assertGreaterEqual(clock.now, step["end"] + e2e.TAIL, "the driver waited the whole tail")
        v = self.quiet_verdict(steps, self.rows(step["start"] - 0.5, step["end"] + e2e.TAIL + 0.2), "2 observe")
        self.assertTrue(e2e.quiet_step_ok(v))

    def test_late_interference_800ms_after_the_step_fails_it(self):
        steps, _ = self.run_steps([("5 press", True)])
        end = steps[0]["end"]
        late = [(end + 0.8, end + 1.0, "front", self.TARGET), (end + 0.8, end + 1.0, "top", self.TARGET)]
        v = self.quiet_verdict(steps, self.rows(steps[0]["start"] - 0.5, end + e2e.TAIL + 0.2, late), "5 press")
        self.assertTrue(v["target_front"])
        self.assertFalse(e2e.quiet_step_ok(v), "a late interference of the step itself must still fail it")
        # and the cursor criterion is unchanged
        moved = [(end + 0.8, end + 0.9, "x", 51.0)]
        v = self.quiet_verdict(steps, self.rows(steps[0]["start"] - 0.5, end + e2e.TAIL + 0.2, moved), "5 press")
        self.assertFalse(e2e.quiet_step_ok(v))

    def test_no_call_can_start_inside_a_quiet_tail(self):
        steps, _ = self.run_steps([("2 observe", True), ("5 press", True), ("9 breach control", False),
                                   ("9c latched", False)])
        self.assertEqual(e2e.witness_window_overlaps(steps), [])
        for earlier, later in zip(steps, steps[1:]):
            if earlier["quiet"]:
                self.assertGreaterEqual(later["start"], earlier["end"] + e2e.TAIL)

    def test_an_overlap_is_named_explicitly(self):
        steps = [{"step": "9b observe", "start": 1.0, "end": 1.2, "quiet": True},
                 {"step": "9 breach control", "start": 1.3, "end": 1.5, "quiet": False}]
        self.assertEqual(e2e.witness_window_overlaps(steps),
                         [{"quiet_step": "9b observe", "next_call": "9 breach control", "overlap_ms": 1400}])

    def test_the_deliberate_breach_no_longer_contaminates_9b_observe(self):
        steps, _ = self.run_steps([("9b observe", True), ("9 breach control", False)])
        observe, breach = steps
        # The fixture raises itself ~430 ms after the breach press starts.
        raised = [(breach["start"] + 0.43, breach["end"] + 2.0, "front", self.TARGET),
                  (breach["start"] + 0.43, breach["end"] + 2.0, "top", self.TARGET)]
        rows = self.rows(observe["start"] - 0.5, breach["end"] + 2.0, raised)
        v_observe = self.quiet_verdict(steps, rows, "9b observe")
        v_breach = self.quiet_verdict(steps, rows, "9 breach control")
        self.assertTrue(e2e.quiet_step_ok(v_observe), "9b observe stays clean")
        self.assertTrue(v_breach["target_front"] or v_breach["target_top"], "the witness still sees the breach")
        self.assertEqual(e2e.witness_window_overlaps(steps), [])

    def test_the_old_back_to_back_timing_is_what_contaminated_it(self):
        # Without the tail wait (the previous runner), the same breach falls
        # inside 9b's window and the overlap gate names it.
        steps = [{"step": "9b observe", "start": 10.0, "end": 10.2, "quiet": True},
                 {"step": "9 breach control", "start": 10.21, "end": 10.5, "quiet": False}]
        rows = self.rows(9.5, 12.5, [(10.64, 12.5, "front", self.TARGET), (10.64, 12.5, "top", self.TARGET)])
        self.assertFalse(e2e.quiet_step_ok(self.quiet_verdict(steps, rows, "9b observe")))
        self.assertTrue(e2e.witness_window_overlaps(steps))

    def test_gate_constants_are_unchanged(self):
        self.assertEqual(e2e.TAIL, 1.5)
        source = (VERIFY / "live_background_e2e.py").read_text()
        self.assertIn('verdict["cursor_max_delta"] <= 0.5', source)
        self.assertIn('checks["witness_quiet"] = quiet_ok', source)
        self.assertIn('"9 breach control", "computer_use_press",\n                           {"element_id": trigger, "snapshot": snap}, quiet=False)', source)


class PersonFrontmostTests(unittest.TestCase):
    def test_lsappinfo_formats(self):
        for out in ('"CFBundleIdentifier"="com.apple.Terminal"\n', '"bundleID"="com.apple.Terminal"'):
            self.assertEqual(e2e.person_frontmost(out, [], "")[:2], ("com.apple.Terminal", "lsappinfo"))

    def test_empty_lsappinfo_falls_back_and_says_so(self):
        rows = [{"t": 1, "front": "com.apple.Terminal", "top": "x", "x": 0, "y": 0}]
        bundle, source, sources = e2e.person_frontmost("", rows, "")
        self.assertEqual((bundle, source), ("com.apple.Terminal", "witness"))
        self.assertEqual(sources["lsappinfo"], "")
        observe = "frontmost: Terminal [com.apple.Terminal]\ntarget: X [y] (background)\n"
        self.assertEqual(e2e.person_frontmost("", [], observe)[:2], ("com.apple.Terminal", "helper_observe"))
        self.assertEqual(e2e.person_frontmost("", [], "")[:2], ("", "none"))


if __name__ == "__main__":
    unittest.main()
