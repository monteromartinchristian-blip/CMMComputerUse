"""Contract tests for the published Cordis patch.

The patch is the whole configuration surface of this package: two additive rows
that name packages DSH already ships. These tests parse it with a real YAML
parser (Psych, which macOS's Ruby ships) and assert the structure DSH will read,
because a regex over YAML proves nothing about how a loader will see it.
"""

from __future__ import annotations

import json
import re
import subprocess
import unittest
from pathlib import Path

PACKAGE = Path(__file__).resolve().parents[1]
PATCH = PACKAGE / "cordis.patch.yml"
MANIFEST = json.loads((PACKAGE / "package.json").read_text())
RUBY = "/usr/bin/ruby"

#: Exactly the keys `@deepseek-ai/dsh-mcp-client` accepts for a stdio server.
#: A key it does not know is not ignored: the plugin fails to load.
MCP_STDIO_KEYS = {
    "transport", "serverName", "command", "args", "env", "cwd",
    "toolCallTimeoutMs", "failOnStartupError", "maxInstructionBytes", "reconnect",
}


def parse_patch() -> list:
    out = subprocess.run(
        [RUBY, "-ryaml", "-rjson", "-e",
         "puts JSON.dump(YAML.load_file(ARGV[0]))", str(PATCH)],
        capture_output=True, text=True, check=True,
    )
    return json.loads(out.stdout)


class PatchContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.document = parse_patch()

    def rows(self) -> dict:
        rows = {}
        for layer in self.document:
            for row in layer.get("insert") or []:
                rows[row["id"]] = row
        return rows

    def test_patch_inserts_exactly_two_rows(self) -> None:
        rows = self.rows()
        self.assertEqual(sorted(rows), ["cmm-computer-use", "cmm-computer-use-panel"])

    def test_the_adapter_row_uses_the_shipped_mcp_client(self) -> None:
        row = self.rows()["cmm-computer-use"]
        self.assertEqual(row["name"], "@deepseek-ai/dsh-mcp-client")
        self.assertEqual(set(row["config"]), MCP_STDIO_KEYS & set(row["config"]))
        self.assertEqual(row["config"]["transport"], "stdio")
        self.assertEqual(row["config"]["serverName"], "cmm-computer-use")

    def test_server_name_fits_the_public_tool_name_budget(self) -> None:
        # publicToolName() composes mcp__<serverName>__<tool>; anything over 64
        # characters gains a hash and changes what the model sees.
        longest = max(
            len(f"mcp__{self.rows()['cmm-computer-use']['config']['serverName']}__{tool}")
            for tool in ("computer_use_status", "computer_use_list_apps",
                         "computer_use_observe", "computer_use_capture_window",
                         "computer_use_press", "computer_use_set_value",
                         "computer_use_release")
        )
        self.assertLessEqual(longest, 64)
        self.assertRegex(
            self.rows()["cmm-computer-use"]["config"]["serverName"],
            r"^[A-Za-z0-9_-]{1,32}$",
        )

    def test_the_mode_is_pinned_to_background(self) -> None:
        args = self.rows()["cmm-computer-use"]["config"]["args"]
        self.assertIn("--mode", args)
        self.assertEqual(args[args.index("--mode") + 1], "background")

    def test_the_timeout_exceeds_the_adapter_budget(self) -> None:
        config = self.rows()["cmm-computer-use"]["config"]
        self.assertGreater(config["toolCallTimeoutMs"], 60_000)
        self.assertIs(config["failOnStartupError"], True)

    def test_the_environment_stops_python_writing_into_the_package(self) -> None:
        env = self.rows()["cmm-computer-use"]["config"]["env"]
        self.assertEqual(env["PYTHONDONTWRITEBYTECODE"], "1")
        self.assertEqual(env["PYTHONNOUSERSITE"], "1")

    def test_every_resolved_path_comes_from_the_profile(self) -> None:
        text = PATCH.read_text()
        self.assertNotRegex(text, r"/Users/[^/\s]+", "no absolute personal path may be baked in")
        for expression in re.findall(r"!!js >-\n((?:\s{14,}.*\n)+)", text):
            # Package-relative paths resolve through the profile's own module
            # resolution; user-relative paths through homedir(). A literal home
            # directory would make the patch machine-specific.
            self.assertTrue(
                "createRequire(baseUrl)" in expression or "homedir()" in expression,
                f"expression resolves a path from neither the profile nor homedir: {expression!r}",
            )

    def test_the_panel_row_gets_the_same_socket(self) -> None:
        panel = self.rows()["cmm-computer-use-panel"]["config"]
        self.assertIn("CMM_COMPUTER_BRIDGE_SOCKET", panel["socket"])
        self.assertIn("bridge.sock", panel["socket"])

    def test_the_manifest_points_at_this_patch(self) -> None:
        self.assertEqual(MANIFEST["dsh"]["bundle"]["patch"], "./cordis.patch.yml")
        self.assertTrue(PATCH.is_file())


if __name__ == "__main__":
    unittest.main()
