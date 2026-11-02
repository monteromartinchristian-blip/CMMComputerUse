"""Tests for the isolated live lane and the rearm probe. Run anywhere:

    python3 -m unittest discover -s scripts/verification/tests

The lane itself needs macOS; these pin its decisions (exact requirements,
unprivileged probe, isolation guards, production diff) and, statically, what
its sources may and may not do.
"""

from __future__ import annotations

import ast
import pathlib
import re
import sys
import unittest

HERE = pathlib.Path(__file__).resolve().parent
VERIFY = HERE.parent
sys.path.insert(0, str(VERIFY))

import isolated_live_lib as lib  # noqa: E402

ORCHESTRATOR = (VERIFY / "isolated-live.py").read_text()
PROBE = (VERIFY / "rearm-probe" / "main.swift").read_text()

DEV_DISPLAY = """Executable=/tmp/lane/rearm-probe
Identifier=com.cmm.computer-use.test-rearm
Format=Mach-O thin (arm64)
CodeDirectory v=20500 size=900 flags=0x10000(runtime) hashes=17+7 location=embedded
Hash type=sha256 size=32
CandidateCDHash sha256=0123456789abcdef0123456789abcdef01234567
CDHash=0123456789abcdef0123456789abcdef01234567
Signature size=4790
Authority=Apple Development: Someone (ABCDE12345)
Authority=Apple Worldwide Developer Relations Certification Authority
Authority=Apple Root CA
TeamIdentifier=7NH822RKEQ
"""
PLATFORM_DISPLAY = """Executable=/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python
Identifier=com.apple.python3
CDHash=fedcba9876543210fedcba9876543210fedcba98
Authority=Software Signing
Authority=Apple Code Signing Certification Authority
Authority=Apple Root CA
TeamIdentifier=not set
"""
ADHOC_DISPLAY = """Identifier=python3
CDHash=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
Signature=adhoc
TeamIdentifier=not set
"""


class RequirementTests(unittest.TestCase):
    def test_developer_signed_probe_gets_an_exact_requirement(self):
        facts = lib.parse_codesign_display(DEV_DISPLAY)
        self.assertEqual(facts["identifier"], lib.PROBE_IDENTIFIER)
        self.assertEqual(facts["team_id"], "7NH822RKEQ")
        self.assertEqual(
            lib.compose_requirement(facts),
            'identifier "com.cmm.computer-use.test-rearm" and anchor apple generic and '
            'certificate leaf[subject.OU] = "7NH822RKEQ" and '
            'cdhash H"0123456789abcdef0123456789abcdef01234567"')

    def test_apple_platform_and_adhoc_interpreters(self):
        self.assertEqual(
            lib.compose_requirement(lib.parse_codesign_display(PLATFORM_DISPLAY)),
            'identifier "com.apple.python3" and anchor apple and '
            'cdhash H"fedcba9876543210fedcba9876543210fedcba98"')
        self.assertEqual(
            lib.compose_requirement(lib.parse_codesign_display(ADHOC_DISPLAY)),
            'identifier "python3" and cdhash H"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"')

    def test_no_requirement_without_identifier_and_cdhash(self):
        for broken in (DEV_DISPLAY.replace("CDHash=", "XCDHash="),
                       DEV_DISPLAY.replace("Identifier=", "XIdentifier="),
                       DEV_DISPLAY.replace("TeamIdentifier=7NH822RKEQ", "TeamIdentifier=not set")
                       .replace("Authority=Apple Development", "Authority=Somebody Else")):
            with self.assertRaises(ValueError):
                lib.compose_requirement(lib.parse_codesign_display(broken))

    def test_requirements_are_never_wildcards(self):
        for display in (DEV_DISPLAY, PLATFORM_DISPLAY, ADHOC_DISPLAY):
            requirement = lib.compose_requirement(lib.parse_codesign_display(display))
            self.assertNotIn("*", requirement)
            self.assertIn("cdhash H\"", requirement)
            self.assertTrue(requirement.startswith('identifier "'))

    def test_designated_requirement_line(self):
        self.assertEqual(lib.designated_requirement('Executable=/x\ndesignated => identifier "a" and anchor apple generic\n'),
                         'identifier "a" and anchor apple generic')
        self.assertIsNone(lib.designated_requirement("nothing"))


class PolicyTests(unittest.TestCase):
    def policy(self, admin, driver="DRV", electron=""):
        return lib.build_policy("PRB", driver, probe_admin=admin, electron_bundle=electron)

    def test_probe_has_no_apps_no_scopes_and_admin_only_when_asked(self):
        for admin in (False, True):
            probe = self.policy(admin)["clients"][0]
            self.assertEqual(probe["client_id"], lib.PROBE_CLIENT_ID)
            self.assertEqual(probe["apps"], [])
            self.assertEqual(probe["scopes"], [])
            self.assertEqual(probe.get("admin"), ["breach.rearm"] if admin else None)

    def test_driver_never_has_admin_and_electron_is_observe_only(self):
        policy = self.policy(True, electron="com.anthropic.claudefordesktop")
        driver = [c for c in policy["clients"] if c["client_id"] == lib.DRIVER_CLIENT_ID][0]
        self.assertNotIn("admin", driver)
        self.assertEqual(driver["requirement"], "DRV")
        electron = [a for a in policy["apps"] if a["bundle_id"] == "com.anthropic.claudefordesktop"][0]
        self.assertEqual(electron["scopes"], ["observe"])
        self.assertEqual(policy["version"], 2)
        self.assertEqual(policy["mode"], "background")
        self.assertEqual(policy["default"], "deny")

    def test_bootstrap_policy_has_only_the_probe(self):
        self.assertEqual([c["client_id"] for c in self.policy(False, driver=None)["clients"]],
                         [lib.PROBE_CLIENT_ID])

    def test_seeded_latch_covers_self_and_other_on_fake_targets(self):
        seed = lib.seeded_latch(1.0)
        by_id = {b["id"]: b for b in seed["breaches"]}
        self.assertEqual(by_id[lib.SEED_SELF_ID]["client_id"], lib.PROBE_CLIENT_ID)
        self.assertEqual(by_id[lib.SEED_OTHER_ID]["client_id"], lib.DRIVER_CLIENT_ID)
        for breach in seed["breaches"]:
            self.assertTrue(breach["target_bundle"].startswith("com.example.seeded."))
            self.assertNotEqual(breach["target_bundle"], lib.FIXTURE_BUNDLE_ID)


class IsolationTests(unittest.TestCase):
    HOME = "/Users/tester"

    def test_production_locations_are_refused(self):
        P = lib.production_paths(self.HOME)
        for path in list(P.values()) + [P["support_dir"] + "/sub", self.HOME,
                                        self.HOME + "/Library/LaunchAgents/other.plist"]:
            with self.assertRaises(RuntimeError, msg=path):
                lib.assert_isolated(path, self.HOME)

    def test_temporary_lane_is_accepted(self):
        self.assertTrue(lib.assert_isolated("/tmp/cmm-cu-isolated-abc", self.HOME).endswith("cmm-cu-isolated-abc"))


class SnapshotTests(unittest.TestCase):
    def test_identical_snapshots_have_no_diff(self):
        snap = {"support_dir": {"policy.json": {"sha256": "a", "mode": "0o600"}}, "launchctl": {"pid": "1"}}
        self.assertEqual(lib.diff_snapshots(snap, dict(snap)), [])

    def test_every_kind_of_change_is_reported(self):
        before = {"support_dir": {"policy.json": {"sha256": "a"}, "bridge.sock": {"inode": 1}},
                  "launchctl": {"pid": "10"}}
        after = {"support_dir": {"policy.json": {"sha256": "b"}, "breach-latch.json": {"sha256": "c"}},
                 "launchctl": {"pid": "11"}}
        diff = "\n".join(lib.diff_snapshots(before, after))
        self.assertIn("changed support_dir/policy.json/sha256", diff)
        self.assertIn("removed support_dir/bridge.sock", diff)
        self.assertIn("added   support_dir/breach-latch.json", diff)
        self.assertIn("changed launchctl/pid", diff)

    def test_launchctl_facts(self):
        text = """gui/501/com.cmm.chat.computer-use = {
\tactive count = 1
\tstate = running
\tprogram = /bin/sh
\targuments = {
\t\t/bin/sh
\t\t/Users/t/run-helper.sh
\t}
\tpid = 4321
\truns = 7
}"""
        facts = lib.launchctl_facts(text)
        self.assertEqual(facts["state"], "running")
        self.assertEqual(facts["pid"], "4321")
        self.assertEqual(facts["arguments"], ["/bin/sh", "/Users/t/run-helper.sh"])
        self.assertNotIn("runs", facts)

    def test_tcc_ready(self):
        self.assertTrue(lib.tcc_ready({"accessibility": True, "screen_recording": True})[0])
        self.assertFalse(lib.tcc_ready({"accessibility": True, "screen_recording": False})[0])
        self.assertFalse(lib.tcc_ready({})[0])


class OrchestratorSourceTests(unittest.TestCase):
    """What the lane may not do, pinned on its source."""

    def code(self):
        # Code only: the module docstring (which says what the lane does NOT
        # do) and comments are stripped.
        body = ORCHESTRATOR.split('"""', 2)[2]
        return "\n".join(l.split("#", 1)[0] for l in body.splitlines())

    def test_never_touches_tcc_or_the_launch_agent(self):
        code = self.code()
        self.assertNotIn("tccutil", code)
        self.assertNotIn("permissions.request", code)
        self.assertNotRegex(code, r'"launchctl",\s*"(bootout|bootstrap|kickstart|load|unload|enable|disable|kill)"')
        self.assertIn('"--no-permission-bootstrap"', code)

    def test_launches_through_launchservices_never_the_bare_executable(self):
        code = self.code()
        self.assertIn('["/usr/bin/open", "-n", "-g", "-a", lane.path("CMMComputerUse.app")', code)
        self.assertNotRegex(code, r"Contents/MacOS/CMMComputerUse\"?\s*[,\]]")

    def test_production_paths_are_only_read(self):
        code = self.code()
        # The production socket is only handed to the probe to prove the refusal,
        # and to pgrep/ps for the snapshot; nothing writes there.
        for line in code.splitlines():
            if "production_paths(" in line and ("write" in line or "unlink" in line or "rmtree" in line):
                self.fail("writes a production path: " + line.strip())
        self.assertIn("lib.assert_isolated(work, HOME)", code)

    def test_teardown_kills_only_processes_running_from_the_lane(self):
        code = self.code()
        teardown = code[code.index("def phase_teardown"):code.index("def phase_verify_production")]
        self.assertIn('if exe.startswith(lane.work + "/"):', teardown)
        self.assertNotIn("pkill", code)

    def test_sources_parse_as_python_39(self):
        for path in (VERIFY / "isolated-live.py", VERIFY / "isolated_live_lib.py",
                     VERIFY / "live_background_e2e.py", VERIFY / "check-helper-source.py"):
            ast.parse(path.read_text(), filename=str(path), feature_version=(3, 9))


class ProbeSourceTests(unittest.TestCase):
    def test_only_breach_operations_can_be_sent(self):
        operations = set(re.findall(r'operation = "([^"]+)"', PROBE))
        self.assertEqual(operations, {"breach.status", "breach.rearm"})
        self.assertNotRegex(PROBE, r'"(observation|action|apps|policy|permissions)\.')

    def test_reason_is_mandatory_and_bounded(self):
        self.assertIn('fail("a reason is required")', PROBE)
        self.assertIn("maxReason = 500", PROBE)

    def test_refuses_production_and_unmarked_sockets(self):
        self.assertIn('fail("refusing the production socket")', PROBE)
        self.assertIn('let markerName = "%s"' % lib.MARKER, PROBE)


if __name__ == "__main__":
    unittest.main()
