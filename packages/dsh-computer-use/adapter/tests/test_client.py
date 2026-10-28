"""Contract tests for the Computer Use transport client.

These run against a scripted NDJSON helper on a real Unix socket: they pin the
frames this client sends, how it proves the helper's identity, and how a
refusal, a timeout and a protocol violation are reported. No helper is
launched, no TCC permission is read and no desktop event is produced.
"""

from __future__ import annotations

import json
import pathlib
import sys
import threading
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tests"))

from fake_bridge import FakeBridge, failure, ok  # noqa: E402

from cmm_computer_use.client import (  # noqa: E402
    BridgeClient,
    BridgeError,
    BridgeProtocolError,
    BridgeUnavailable,
)


class ClientTestCase(unittest.TestCase):
    def bridge(self, responder=None):
        bridge = FakeBridge(responder).start()
        self.addCleanup(bridge.stop)
        return bridge

    def client(self, bridge, **kwargs):
        client = BridgeClient(bridge.socket_path, **kwargs)
        self.addCleanup(client.close)
        return client


class IdentityTests(ClientTestCase):
    def test_ping_proves_identity_and_reports_policy(self):
        bridge = self.bridge()
        result = self.client(bridge).ping()
        self.assertEqual(result["bridge"], "cmm-computer-use")
        self.assertEqual(result["protocol"], 1)
        self.assertEqual(result["bundle_id"], "com.cmm.chat.computer-use")
        self.assertEqual(result["policy"], "unrestricted")
        self.assertEqual(bridge.frames[0]["operation"], "bridge.ping")

    def test_foreign_bundle_is_not_the_product_helper(self):
        # A socket that speaks our protocol but is a different bundle is a
        # different process identity: grants bound to ours would not apply.
        def responder(request):
            return ok(
                request,
                {
                    "bridge": "cmm-computer-use",
                    "protocol": 1,
                    "pid": 1,
                    "bundle_id": "com.example.impostor",
                    "policy": "background",
                },
            )

        client = self.client(self.bridge(responder))
        with self.assertRaises(BridgeUnavailable) as caught:
            client.ping()
        self.assertIn("identity", caught.exception.message)

    def test_wrong_protocol_is_refused(self):
        def responder(request):
            return ok(
                request,
                {
                    "bridge": "cmm-computer-use",
                    "protocol": 2,
                    "pid": 1,
                    "bundle_id": "com.cmm.chat.computer-use",
                },
            )

        with self.assertRaises(BridgeUnavailable):
            self.client(self.bridge(responder)).ping()

    def test_ping_without_object_is_a_protocol_error(self):
        def responder(request):
            return ok(request, "not-an-object")

        with self.assertRaises(BridgeProtocolError):
            self.client(self.bridge(responder)).ping()


class RequestShapeTests(ClientTestCase):
    def test_action_carries_kind_params_and_policy(self):
        bridge = self.bridge()
        client = self.client(bridge, policy="background")
        client.act("ui.press", element_id=7, snapshot=3)
        frame = bridge.frames[0]
        self.assertEqual(frame["version"], 1)
        self.assertEqual(frame["operation"], "action.execute")
        self.assertEqual(frame["arguments"]["kind"], "ui.press")
        self.assertEqual(frame["arguments"]["params"], {"element_id": 7, "snapshot": 3})
        # The policy travels with the request: the helper applies the stricter
        # of this and its own launch policy.
        self.assertEqual(frame["arguments"]["policy"], "background")
        self.assertTrue(str(frame["id"]).startswith("py-"))

    def test_capture_window_names_one_window_and_the_policy(self):
        bridge = self.bridge()
        self.client(bridge, policy="background").capture_window("Finder", "Descargas")
        arguments = bridge.frames[0]["arguments"]
        self.assertEqual(bridge.frames[0]["operation"], "observation.capture_screen")
        self.assertEqual(arguments["app"], "Finder")
        self.assertEqual(arguments["window_title"], "Descargas")
        self.assertEqual(arguments["policy"], "background")

    def test_observe_targets_an_app_without_activating_it(self):
        bridge = self.bridge()
        self.client(bridge).observe(app="Finder", include_screenshot=False)
        arguments = bridge.frames[0]["arguments"]
        self.assertEqual(bridge.frames[0]["operation"], "observation.describe")
        self.assertEqual(arguments["app"], "Finder")
        self.assertFalse(arguments["include_screenshot"])
        # A stricter client narrows observation too: display capture must not
        # be reachable through describe against a permissive deployment.
        self.assertEqual(arguments["policy"], "background")

    def test_observe_without_app_sends_no_target(self):
        bridge = self.bridge()
        self.client(bridge).observe()
        self.assertNotIn("app", bridge.frames[0]["arguments"])

    def test_release_operation(self):
        bridge = self.bridge()
        result = self.client(bridge).release()
        self.assertEqual(result["released"], 1)
        self.assertEqual(bridge.frames[0]["operation"], "observation.release")

    def test_policy_operations(self):
        bridge = self.bridge()
        client = self.client(bridge)
        status = client.policy_status()
        self.assertEqual(status["effective_mode"], "background")
        self.assertEqual(bridge.frames[0]["operation"], "policy.status")
        client.reload_policy()
        self.assertEqual(bridge.frames[1]["operation"], "policy.reload")

    def test_unknown_kind_never_reaches_the_wire(self):
        bridge = self.bridge()
        client = self.client(bridge)
        with self.assertRaises(ValueError):
            client.act("shell.exec", command="rm -rf /")
        self.assertEqual(bridge.frames, [])

    def test_invalid_policy_is_refused_before_connecting(self):
        with self.assertRaises(ValueError):
            BridgeClient("/tmp/never.sock", policy="everything")

    def test_oversized_request_is_refused(self):
        bridge = self.bridge()
        client = self.client(bridge)
        with self.assertRaises(ValueError):
            client.act("keyboard.type", text="x" * 1_100_000)
        self.assertEqual(bridge.frames, [])


class RefusalTests(ClientTestCase):
    def test_helper_refusal_keeps_code_and_detail(self):
        def responder(request):
            return failure(
                request,
                "CAPABILITY_UNSUPPORTED",
                "The bridge runs in background mode: pointer.click posts a global pointer event, "
                "which moves the system cursor.",
                "policy=background;kind=pointer.click;requirement=global_pointer;needs=unrestricted",
            )

        client = self.client(self.bridge(responder))
        with self.assertRaises(BridgeError) as caught:
            client.act("ui.press", element_id=1, snapshot=1)
        error = caught.exception
        self.assertEqual(error.code, "CAPABILITY_UNSUPPORTED")
        self.assertIn("cursor", error.message)
        self.assertIn("requirement=global_pointer", error.detail)

    def test_unknown_error_code_collapses_to_action_failed(self):
        # The grammar is frozen; a helper that invents a code must not leak it
        # into callers that switch on the seven known ones.
        def responder(request):
            return failure(request, "POLICY_MADE_UP", "no")

        client = self.client(self.bridge(responder))
        with self.assertRaises(BridgeError) as caught:
            client.act("ui.press", element_id=1, snapshot=1)
        self.assertEqual(caught.exception.code, "ACTION_FAILED")


class TransportTests(ClientTestCase):
    def test_mismatched_id_is_a_protocol_violation(self):
        def responder(request):
            response = ok(request, {"ok": True})
            response["id"] = "someone-else"
            return response

        client = self.client(self.bridge(responder))
        with self.assertRaises(BridgeProtocolError):
            client.act("ui.press", element_id=1, snapshot=1)
        # A desynchronised stream is dropped, never reused.
        self.assertFalse(client.connected)

    def test_timeout_drops_the_connection(self):
        release = threading.Event()

        def responder(request):
            release.wait(2)
            return ok(request, {"ok": True})

        client = self.client(self.bridge(responder))
        with self.assertRaises(BridgeUnavailable) as caught:
            client.request(
                "action.execute", {"kind": "ui.press", "params": {}}, timeout=0.2
            )
        release.set()
        self.assertIn("did not answer", caught.exception.message)
        self.assertFalse(client.connected)

    def test_reconnects_after_an_explicit_close(self):
        bridge = self.bridge()
        client = self.client(bridge)
        client.ping()
        client.close()
        self.assertFalse(client.connected)
        client.ping()
        self.assertEqual(len(bridge.frames), 2)
        self.assertEqual(bridge.connections, 2)

    def test_missing_socket_is_unavailable_not_a_crash(self):
        client = BridgeClient("/nonexistent/cmm-cu-does-not-exist.sock")
        self.addCleanup(client.close)
        with self.assertRaises(BridgeUnavailable) as caught:
            client.ping()
        self.assertEqual(caught.exception.code, "COMPUTER_RUNTIME_UNAVAILABLE")

    def test_helper_that_closes_mid_stream_is_unavailable(self):
        def responder(request):
            return None  # close without answering

        client = self.client(self.bridge(responder))
        with self.assertRaises(BridgeUnavailable):
            client.ping()

    def test_malformed_frame_is_a_protocol_error(self):
        def responder(request):
            return "}not a frame{"

        client = self.client(self.bridge(responder))
        # A JSON scalar is not a protocol frame; the client must refuse it
        # rather than treat it as an answer.
        with self.assertRaises(BridgeProtocolError):
            client.ping()


if __name__ == "__main__":
    unittest.main()
