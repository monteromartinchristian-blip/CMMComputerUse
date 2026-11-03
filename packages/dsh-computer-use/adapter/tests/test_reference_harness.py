"""Conformance of the public contract through a NON-DSH harness.

``examples/reference-harness/harness.py`` is a minimal MCP host that only knows
the public contract. It launches the real adapter as a subprocess over stdio
(the same way any harness would) against a scripted helper, so these tests
prove: the handshake carries the auto-invocation guidance, the catalog is
annotated, a two-context flow works end to end, and the invocation decision
lives in the harness (GUI task: yes; code task: no) — none of it needing DSH.
"""

from __future__ import annotations

import importlib.util
import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
REPO = ROOT.parents[2]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tests"))

from fake_bridge import FakeBridge  # noqa: E402
from test_workspace_contract import CTX_A, CTX_B, WorkspaceHelper  # noqa: E402

spec = importlib.util.spec_from_file_location("reference_harness", REPO / "examples/reference-harness/harness.py")
harness = importlib.util.module_from_spec(spec)
spec.loader.exec_module(harness)


class ReferenceHarnessTests(unittest.TestCase):
    def setUp(self):
        self.helper = WorkspaceHelper()
        self.bridge = FakeBridge(self.helper).start()
        self.addCleanup(self.bridge.stop)
        self.client = harness.McpStdioClient(self.bridge.socket_path)
        self.addCleanup(self.client.close)

    def test_handshake_carries_guidance_and_annotated_tools(self):
        hello = harness.handshake(self.client)
        self.assertEqual(hello["server"]["name"], "cmm-computer-use")
        self.assertIn("graphical application", hello["instructions"])
        self.assertIn("NEVER", hello["instructions"].upper())
        tools = {t["name"]: t for t in hello["tools"]}
        self.assertTrue(tools["computer_use_observe"]["annotations"]["readOnlyHint"])
        self.assertFalse(tools["computer_use_press"]["annotations"]["readOnlyHint"])
        self.assertIn("context", tools["computer_use_press"]["inputSchema"]["properties"])

    def test_the_invocation_decision_is_the_harness(self):
        hello = harness.handshake(self.client)
        instructions = hello["instructions"]
        self.assertTrue(harness.needs_computer_use("Press the Save button in Notes", instructions))
        self.assertTrue(harness.needs_computer_use("Compara qué muestran las dos ventanas", instructions))
        self.assertFalse(harness.needs_computer_use("Refactor the parser in client.py", instructions))
        self.assertFalse(harness.needs_computer_use("Press the Save button", "some other server"),
                         "no advertised GUI capability, no automatic use")

    def test_two_context_flow_end_to_end_over_stdio(self):
        harness.handshake(self.client)
        report = harness.two_app_flow(self.client, ["Safari", "Notes"])
        contexts = report["contexts"]
        self.assertEqual([c["label"] for c in contexts], ["A", "B"])
        self.assertEqual([c["context"] for c in contexts], [CTX_A, CTX_B])
        self.assertTrue(all(c["snapshot"] for c in contexts))
        describes = [f for f in self.bridge.frames if f["operation"] == "observation.describe"]
        self.assertEqual([f["arguments"]["context_id"] for f in describes], [CTX_A, CTX_B])
        closes = [f for f in self.bridge.frames if f["operation"] == "workspace.context_close"]
        self.assertEqual(len(closes), 2)
        executes = [f for f in self.bridge.frames if f["operation"] == "action.execute"]
        self.assertEqual(executes, [], "the read path changes no application")


if __name__ == "__main__":
    unittest.main()
