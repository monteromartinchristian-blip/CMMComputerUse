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


import sys  # noqa: E402
sys.path.insert(0, str(VERIFY.parents[1] / "packages" / "dsh-computer-use" / "adapter"))
from cmm_computer_use.mcp_server import _render_observation  # noqa: E402

CLAUDE = "com.anthropic.claudefordesktop"


def claude_observation(composer_value="", composer_settable=True, with_composer=True):
    elements = [
        {"element_id": 1, "role": "AXButton", "subrole": "AXCloseButton", "title": "cerrar", "value": "",
         "x": 10, "y": 10, "width": 14, "height": 16, "pressable": True, "window_chrome": True, "actionable": False},
        {"element_id": 2, "role": "AXTextField", "title": "Buscar", "value": "", "x": 20, "y": 60,
         "width": 200, "height": 24, "pressable": False, "value_settable": True, "actionable": True},
    ]
    if with_composer:
        elements.append({"element_id": 3, "role": "AXTextArea", "title": "Escribe a Claude", "value": composer_value,
                         "x": 300, "y": 820, "width": 640, "height": 44, "pressable": False,
                         "value_settable": composer_settable, "actionable": composer_settable})
    return {"frontmost_app": "Terminal", "frontmost_bundle": "com.apple.Terminal", "target_app": "Claude",
            "target_bundle": CLAUDE, "target_pid": 7, "target_window": "Claude", "target_window_id": 4,
            "target_is_frontmost": False, "windows": [], "snapshot": 12, "captured_at": 1.0,
            "content": [{"role": "AXWebArea", "text": "Nuevo chat"}], "elements": elements,
            "ax_tree": "ok", "ax_access": "actionable" if (with_composer and composer_settable) else "readable",
            "ax_counts": {"content": 1, "elements": len(elements), "actionable": 1, "window_controls": 1}}


class ComposerParsingTests(unittest.TestCase):
    def test_parses_the_real_adapter_rendering(self):
        text = _render_observation(claude_observation(composer_value='hola "x"'))
        inputs = e2e.text_inputs(text)
        self.assertEqual([(t["role"], t["settable"]) for t in inputs], [("AXTextField", True), ("AXTextArea", True)])
        self.assertEqual(inputs[1]["value"], 'hola "x"')
        self.assertEqual((inputs[1]["x"], inputs[1]["y"], inputs[1]["w"], inputs[1]["h"]), (300, 820, 640, 44))

    def test_composer_is_the_settable_text_area_never_a_window_control(self):
        composer = e2e.pick_composer(_render_observation(claude_observation()))
        self.assertEqual((composer["role"], composer["id"]), ("AXTextArea", 3))
        # No settable text area: falls back to a settable field, never to a button.
        only_field = e2e.pick_composer(_render_observation(claude_observation(composer_settable=False)))
        self.assertEqual(only_field["role"], "AXTextField")
        nothing = claude_observation(with_composer=False)
        nothing["elements"][1]["value_settable"] = False
        self.assertIsNone(e2e.pick_composer(_render_observation(nothing)))

    def test_same_input_is_found_again_by_geometry(self):
        composer = e2e.pick_composer(_render_observation(claude_observation()))
        later = claude_observation(composer_value="CMM token")
        later["elements"][2]["element_id"] = 9
        again = e2e.find_same_input(_render_observation(later), composer)
        self.assertEqual((again["id"], again["value"]), (9, "CMM token"))


class ScriptedDriver:
    """Plays back adapter outputs; records calls (and their targets)."""

    LEDGER = ("interference: verdict=%s cursor_moved=False policy=background\n"
              "attributable: cursor_events_posted=False cursor_moved_by_action=False "
              "focus_became_target=%s external_activity=False\n")

    def __init__(self, composer_value="", composer_settable=True, breach_on_set=False, restore_fails=False,
                 with_composer=True):
        self.calls = []
        self.value = composer_value
        self.settable = composer_settable
        self.breach_on_set = breach_on_set
        self.restore_fails = restore_fails
        self.with_composer = with_composer

    def call(self, step, tool, args, quiet=True, target=None):
        self.calls.append((step, tool, args, quiet, target))
        if tool == "computer_use_observe":
            return _render_observation(claude_observation(self.value, self.settable, self.with_composer)), False
        if self.breach_on_set:
            return ("REFUSED INTERFERENCE_BREACH: raised [policy=background;reason=breach;kind=ui.set_value]\n"
                    + self.LEDGER % ("focus_changed", "True")), True
        if args["text"] == "" and self.restore_fails:
            return "REFUSED ACTION_FAILED: did not take [reason=value_not_applied]\nset_value: check=not_applied", True
        self.value = args["text"]
        return ("ui.set_value: value set and verified\nset_value: check=verified requested_length=%d\n"
                % len(args["text"]) + self.LEDGER % ("untouched", "False")), False


class ElectronControlRunTests(unittest.TestCase):
    TOKEN = "CMM-CU control test - not sent 1"

    def test_full_reversible_control_is_proven(self):
        d = ScriptedDriver()
        out = e2e.run_electron_control(d, CLAUDE, self.TOKEN)
        self.assertTrue(out["attempted"])
        for key in ("set_verified", "set_untouched", "observed_changed", "restore_verified",
                    "restore_untouched", "observed_restored"):
            self.assertTrue(out[key], key)
        self.assertEqual(d.value, "", "restored")
        # Every control step is quiet and judged against Claude, never the fixture.
        self.assertTrue(all(quiet and target == CLAUDE for _, _, _, quiet, target in d.calls))
        tools = [tool for _, tool, _, _, _ in d.calls]
        self.assertNotIn("computer_use_press", tools, "no press: nothing is sent")
        claims = e2e.control_claims({"readable": True, "actionable": True}, out, True)
        self.assertEqual((claims["observe_proven"], claims["actionable"], claims["control_proven"],
                          claims["background_noninterference_proven"]), (True, True, True, True))

    def test_a_draft_in_the_composer_is_never_touched(self):
        d = ScriptedDriver(composer_value="borrador de la persona")
        out = e2e.run_electron_control(d, CLAUDE, self.TOKEN)
        self.assertFalse(out["attempted"])
        self.assertEqual(out["reason"], "composer_not_empty")
        self.assertEqual([t for _, t, _, _, _ in d.calls], ["computer_use_observe"])
        self.assertEqual(d.value, "borrador de la persona")

    def test_no_settable_control_is_an_honest_gap(self):
        d = ScriptedDriver(with_composer=False)
        d_obs = claude_observation(with_composer=False)
        d_obs["elements"][1]["value_settable"] = False
        d.call = lambda step, tool, args, quiet=True, target=None: (_render_observation(d_obs), False)
        out = e2e.run_electron_control(d, CLAUDE, self.TOKEN)
        self.assertEqual(out["reason"], "no_settable_text_input")
        claims = e2e.control_claims({"readable": True, "actionable": False}, out, None)
        self.assertFalse(claims["control_proven"])
        self.assertIsNone(claims["background_noninterference_proven"])
        self.assertEqual(claims["control_unproven_reason"], "no_settable_text_input")

    def test_a_breach_stops_everything(self):
        d = ScriptedDriver(breach_on_set=True)
        out = e2e.run_electron_control(d, CLAUDE, self.TOKEN)
        self.assertTrue(out["breach"])
        self.assertEqual(out["reason"], "breach_stop")
        self.assertEqual(len(d.calls), 2, "observe, set_value, then STOP: no restore attempt, no retry")
        claims = e2e.control_claims({"readable": True, "actionable": True}, out, False)
        self.assertFalse(claims["control_proven"])
        self.assertFalse(claims["background_noninterference_proven"])

    def test_a_failed_restore_is_not_control(self):
        out = e2e.run_electron_control(ScriptedDriver(restore_fails=True), CLAUDE, self.TOKEN)
        self.assertFalse(out["restore_verified"])
        self.assertFalse(e2e.control_claims({"readable": True}, out, True)["control_proven"])

    def test_a_noisy_witness_withholds_both_claims(self):
        out = e2e.run_electron_control(ScriptedDriver(), CLAUDE, self.TOKEN)
        claims = e2e.control_claims({"readable": True, "actionable": True}, out, False)
        self.assertFalse(claims["background_noninterference_proven"])
        self.assertFalse(claims["control_proven"])

    def test_readable_alone_never_claims_control(self):
        claims = e2e.control_claims({"readable": True, "actionable": False}, {"attempted": False}, None)
        self.assertTrue(claims["observe_proven"])
        self.assertFalse(claims["actionable"])
        self.assertFalse(claims["control_proven"])


class PerStepTargetTests(unittest.TestCase):
    def test_the_witness_judges_each_step_against_its_own_target(self):
        steps = [{"step": "E2 set test text (not sent)", "start": 10.0, "end": 10.2, "quiet": True, "target": CLAUDE}]
        rows = [{"t": 9.9 + i / 100, "front": "com.apple.Terminal", "top": "com.apple.Terminal", "x": 0, "y": 0}
                for i in range(200)]
        for r in rows:
            if r["t"] >= 10.6:
                r["front"] = CLAUDE
        v = e2e.judge(steps, rows, "com.example.computer-use-fixture", "com.apple.Terminal")[0]
        self.assertTrue(v["target_front"], "Claude coming to the front is caught even though --app is the fixture")
        self.assertFalse(e2e.quiet_step_ok(v))


def claude_view(settings_open=False, tab="General", close_button=True, extra_settings=False, breach=False):
    """A Claude observation as the helper would return it."""
    elements = [
        {"element_id": 1, "role": "AXButton", "subrole": "AXCloseButton", "title": "cerrar", "value": "",
         "x": 8, "y": 8, "width": 14, "height": 16, "pressable": True, "window_chrome": True, "actionable": False},
        {"element_id": 2, "role": "AXButton", "title": "Nuevo chat", "value": "", "x": 20, "y": 60,
         "width": 120, "height": 28, "pressable": True, "actionable": True},
        {"element_id": 3, "role": "AXPopUpButton", "title": "Ajustes", "value": "", "x": 20, "y": 900,
         "width": 120, "height": 28, "pressable": True, "actionable": True},
    ]
    if extra_settings:
        elements.append({"element_id": 4, "role": "AXButton", "title": "Ajustes", "value": "", "x": 300,
                         "y": 900, "width": 80, "height": 28, "pressable": True, "actionable": True})
        elements.append({"element_id": 5, "role": "AXButton", "title": "Ajustes", "value": "", "x": 400,
                         "y": 900, "width": 80, "height": 28, "pressable": True, "actionable": True})
    content = [{"role": "AXWebArea", "text": "Nuevo chat - Claude"}, {"role": "AXHeading", "text": "Claude Code"}]
    if settings_open:
        for i, title in enumerate(("General", "Cuenta", "Privacidad", "Apariencia")):
            elements.append({"element_id": 10 + i, "role": "AXRadioButton", "title": title, "value": "",
                             "x": 200, "y": 100 + 30 * i, "width": 120, "height": 24,
                             "pressable": True, "actionable": True})
        if close_button:
            elements.append({"element_id": 20, "role": "AXButton", "title": "Cerrar", "value": "", "x": 900,
                             "y": 80, "width": 24, "height": 24, "pressable": True, "actionable": True})
        content = [{"role": "AXHeading", "text": tab}] + (
            [{"role": "AXStaticText", "text": "Nombre completo"}, {"role": "AXStaticText", "text": "Correo"},
             {"role": "AXStaticText", "text": "Cerrar sesión"}] if tab == "Cuenta" else
            [{"role": "AXStaticText", "text": "Tema"}, {"role": "AXStaticText", "text": "Idioma"},
             {"role": "AXStaticText", "text": "Atajos"}])
    obs = claude_observation()
    obs.update(elements=elements, content=content, snapshot=30, ax_access="actionable")
    return obs


class SettingsPressDriver:
    """Plays a Claude that opens Settings on AXPress of 'Ajustes'."""

    UNTOUCHED = ("interference: verdict=untouched cursor_moved=False policy=background\n"
                 "attributable: cursor_events_posted=False cursor_moved_by_action=False "
                 "focus_became_target=False external_activity=False\n")

    def __init__(self, extra_settings=False, breach_on_settings=False, opens=True, close_button=True):
        self.calls = []
        self.open = False
        self.tab = "General"
        self.extra = extra_settings
        self.breach_on_settings = breach_on_settings
        self.opens = opens
        self.close_button = close_button

    def view(self, element_filter=""):
        return _render_observation(claude_view(self.open, self.tab, self.close_button, self.extra), element_filter)

    def call(self, step, tool, args, quiet=True, target=None):
        self.calls.append((step, tool, dict(args), quiet, target))
        if tool == "computer_use_observe":
            return self.view(args.get("filter", "")), False
        element = args["element_id"]
        if element == 3:
            if self.breach_on_settings:
                return ("REFUSED INTERFERENCE_BREACH: raised [policy=background;reason=breach;kind=ui.press]\n"
                        + self.UNTOUCHED.replace("untouched", "focus_changed")), True
            self.open = self.opens
        elif element == 11:
            self.tab = "Cuenta"
        elif element == 20:
            self.open = False
        return "ui.press: pressed\n" + self.UNTOUCHED, False


class PressControlTests(unittest.TestCase):
    def test_open_settings_navigate_and_close_is_proven(self):
        d = SettingsPressDriver()
        out = e2e.run_press_control(d, CLAUDE)
        self.assertTrue(out["attempted"])
        self.assertEqual(out["settings_element"], {"role": "AXPopUpButton", "title": "Ajustes"})
        self.assertTrue(out["settings_opened"], out.get("settings_evidence"))
        self.assertGreaterEqual(len(out["settings_evidence"]["new_markers"]), 2)
        self.assertEqual(out["navigation"]["label"], "Cuenta")
        self.assertTrue(out["navigation"]["changed"])
        self.assertTrue(out["closed"])
        self.assertTrue(all(quiet and target == CLAUDE for _, _, _, quiet, target in d.calls))
        pressed = [args["element_id"] for _, tool, args, _, _ in d.calls if tool == "computer_use_press"]
        self.assertEqual(pressed, [3, 11, 20], "Settings, a tab, close — never a window control, never a toggle")
        self.assertNotIn(1, pressed)
        tools = {tool for _, tool, _, _, _ in d.calls}
        self.assertEqual(tools, {"computer_use_observe", "computer_use_press"})
        claims = e2e.control_claims({"readable": True, "actionable": True}, {"attempted": False},
                                    None, press=out, witness_ok_for_press=True, environment={"ok": True})
        self.assertEqual((claims["observe_proven"], claims["actionable"], claims["press_control_proven"],
                          claims["control_proven"], claims["background_noninterference_proven"]),
                         (True, True, True, True, True))
        self.assertFalse(claims["set_value_control_proven"])

    def test_no_settings_control_is_an_honest_gap_and_nothing_is_pressed(self):
        d = SettingsPressDriver()
        d.view = lambda element_filter="": _render_observation(claude_observation(), element_filter)
        out = e2e.run_press_control(d, CLAUDE)
        self.assertFalse(out["attempted"])
        self.assertEqual(out["reason"], "settings_control_not_found")
        self.assertNotIn("computer_use_press", [tool for _, tool, _, _, _ in d.calls])

    def test_ambiguous_settings_is_never_guessed(self):
        d = SettingsPressDriver(extra_settings=True)
        out = e2e.run_press_control(d, CLAUDE)
        # Three "Ajustes": one AXPopUpButton, two AXButtons -> ambiguous.
        self.assertFalse(out["attempted"])
        self.assertEqual(out["reason"], "settings_control_ambiguous")
        self.assertNotIn("computer_use_press", [tool for _, tool, _, _, _ in d.calls])

    def test_a_breach_stops_after_the_first_press(self):
        d = SettingsPressDriver(breach_on_settings=True)
        out = e2e.run_press_control(d, CLAUDE)
        self.assertTrue(out["breach"])
        self.assertEqual(out["reason"], "breach_stop")
        self.assertEqual([tool for _, tool, _, _, _ in d.calls][-1], "computer_use_press",
                         "nothing after the breach: no re-observe, no retry")
        claims = e2e.control_claims({"readable": True, "actionable": True}, {}, None, press=out,
                                    witness_ok_for_press=False, environment={"ok": True})
        self.assertFalse(claims["press_control_proven"])
        self.assertFalse(claims["background_noninterference_proven"])

    def test_a_press_that_opens_nothing_is_not_control(self):
        out = e2e.run_press_control(SettingsPressDriver(opens=False), CLAUDE)
        self.assertTrue(out["attempted"])
        self.assertFalse(out["settings_opened"])
        self.assertEqual(out["reason"], "settings_not_observed")
        claims = e2e.control_claims({"readable": True, "actionable": True}, {}, None, press=out,
                                    witness_ok_for_press=True, environment={"ok": True})
        self.assertFalse(claims["press_control_proven"])

    def test_no_close_button_leaves_settings_open_and_says_so(self):
        out = e2e.run_press_control(SettingsPressDriver(close_button=False), CLAUDE)
        self.assertIsNone(out["closed"])
        self.assertTrue(out["settings_opened"])

    def test_a_noisy_witness_withholds_press_control(self):
        out = e2e.run_press_control(SettingsPressDriver(), CLAUDE)
        claims = e2e.control_claims({"readable": True, "actionable": True}, {}, None, press=out,
                                    witness_ok_for_press=False, environment={"ok": True})
        self.assertFalse(claims["press_control_proven"])
        self.assertFalse(claims["control_proven"])
        self.assertFalse(claims["background_noninterference_proven"])


class LabelPickingTests(unittest.TestCase):
    def test_exact_label_and_window_controls_are_never_candidates(self):
        text = _render_observation(claude_view())
        element, status, _ = e2e.pick_labeled(text, e2e.SETTINGS_LABELS)
        self.assertEqual((element["id"], status), (3, "exact"))
        chrome_only = claude_view()
        chrome_only["elements"] = [dict(chrome_only["elements"][0], title="Ajustes")]
        self.assertEqual(e2e.pick_labeled(_render_observation(chrome_only), e2e.SETTINGS_LABELS)[1], "not_found")

    def test_semantic_match_only_when_unique(self):
        view = claude_view()
        view["elements"][2]["title"] = "Ajustes…"
        self.assertEqual(e2e.pick_labeled(_render_observation(view), e2e.SETTINGS_LABELS)[1], "exact")
        view["elements"][2]["title"] = "Abrir ajustes"
        self.assertEqual(e2e.pick_labeled(_render_observation(view), e2e.SETTINGS_LABELS)[1], "semantic")
        view["elements"][1]["title"] = "Ajustes de chat"
        self.assertEqual(e2e.pick_labeled(_render_observation(view), e2e.SETTINGS_LABELS)[1], "ambiguous")


class EnvironmentPreconditionTests(unittest.TestCase):
    PERSON = "com.apple.Terminal"

    def rows(self, front=None, move_at=None, n=160, now=100.0):
        return [{"t": now - 1.59 + i * 0.01, "front": front or self.PERSON, "top": self.PERSON,
                 "x": 10.0 + (5.0 if move_at is not None and i >= move_at else 0.0), "y": 10.0} for i in range(n)]

    def test_quiet_terminal_passes(self):
        v = e2e.environment_quiet(self.rows(), 100.0, self.PERSON)
        self.assertTrue(v["ok"])

    def test_the_last_run_state_fails_explicitly(self):
        v = e2e.environment_quiet(self.rows(front="com.apple.UserNotificationCenter"), 100.0, self.PERSON)
        self.assertEqual((v["ok"], v["reason"]), (False, "frontmost_not_person"))
        v = e2e.environment_quiet(self.rows(move_at=80), 100.0, self.PERSON)
        self.assertEqual((v["ok"], v["reason"]), (False, "cursor_moving"))
        v = e2e.environment_quiet(self.rows(n=10), 100.0, self.PERSON)
        self.assertEqual((v["ok"], v["reason"]), (False, "witness_samples_insufficient"))

    def test_waits_for_one_quiet_window_bounded(self):
        clock = {"now": 100.0}
        windows = [self.rows(front="com.apple.UserNotificationCenter", now=101.5), self.rows(now=103.0)]
        with mock.patch.object(e2e, "read_monitor", side_effect=windows), \
             mock.patch.object(e2e, "uptime", side_effect=[101.5, 103.0]), \
             mock.patch.object(e2e.time, "sleep", lambda s: clock.update(now=clock["now"] + s)):
            out = e2e.wait_for_quiet_environment("/m", self.PERSON)
        self.assertTrue(out["ok"])
        self.assertEqual(len(out["attempts"]), 2)
        noisy = [self.rows(move_at=10, now=101.5)] * 3
        with mock.patch.object(e2e, "read_monitor", side_effect=noisy), \
             mock.patch.object(e2e, "uptime", side_effect=[101.5, 101.5, 101.5]), \
             mock.patch.object(e2e.time, "sleep", lambda s: None):
            out = e2e.wait_for_quiet_environment("/m", self.PERSON)
        self.assertEqual((out["ok"], out["reason"], len(out["attempts"])), (False, "environment_not_quiet", 3))

    def test_environment_failure_blocks_the_control_claims(self):
        claims = e2e.control_claims({"readable": True, "actionable": True}, {}, None,
                                    press={"attempted": False, "reason": "environment_not_quiet"},
                                    environment={"ok": False})
        self.assertFalse(claims["control_proven"])
        self.assertEqual(claims["control_unproven_reason"], "environment_not_quiet")

    def test_main_checks_the_environment_before_the_first_claude_step(self):
        source = (VERIFY / "live_background_e2e.py").read_text()
        main = source[source.index("def main() -> int:"):]
        self.assertLess(main.index("wait_for_quiet_environment(args.monitor, args.person_app)"),
                        main.index('"7 electron observe"'))
        self.assertIn("if args.electron_app and args.electron_control and environment and environment[\"ok\"]:", main)
        self.assertIn('checks["electron_control_environment_quiet"] = environment["ok"]', main)


if __name__ == "__main__":
    unittest.main()
