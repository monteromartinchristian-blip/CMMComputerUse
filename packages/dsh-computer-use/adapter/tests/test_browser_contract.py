"""F-09 browser reliability and downloads: the adapter's side of the contract.

What the adapter SENDS (tab ids, op ids on every mutating action and on every
expectation), what it NEVER does (press twice when an answer was lost, call a
file downloaded without the helper's verification), and how it EXPLAINS a tab
switch or a navigation (not a disconnection). The helper side is pinned by
XCTest (BrowserTests, DownloadTests) and the live lane.
"""

from __future__ import annotations

import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tests"))

from fake_bridge import FakeBridge, default_responder, failure, ok  # noqa: E402

from cmm_computer_use.browser import FAILURE_MEANINGS, classify_failure, download_by_pressing  # noqa: E402
from cmm_computer_use.client import (  # noqa: E402
    ACTION_KINDS,
    BridgeClient,
    BridgeError,
    BridgeOutcomeUnknown,
    BridgeUnavailable,
    retry_class,
)
from cmm_computer_use.mcp_server import AUTO_INVOCATION_POLICY, ToolRegistry  # noqa: E402

CTX = "ctx_" + "c" * 32
TAB1 = "tab_" + "1" * 32
TAB2 = "tab_" + "2" * 32
DL = "dl_" + "d" * 32


def text_of(result):
    return "\n".join(b["text"] for b in result["content"] if b["type"] == "text")


class BrowserHelper:
    """Scripted helper for the F-09 operations. `download_states` is the
    sequence download.wait/status answers with; `press` scripts action.execute."""

    def __init__(self):
        self.instance = "ins_" + "9" * 32
        self.download_states = [{"state": "in_progress"}, {"state": "complete"}]
        self.press = "ok"
        self.dialog_open = False
        self.pdf = False
        self.outcome = None
        self.expect_drop_first = False

    def state(self, request):
        return ok(request, {
            "browser": {"app": "Google Chrome", "bundle": "com.google.Chrome", "family": "chromium",
                        "profile": "known"},
            "context_id": CTX, "context_label": "A",
            "transition": {"kind": "tab_switched",
                           "meaning": "another tab was selected; the connection is intact",
                           "context_survives": True, "handles_invalidated": True},
            "windows": [{
                "window_key": "win_1", "window_id": 77, "authorized": True, "title": "Docs",
                "focused": True, "followed_by_context": True, "tabs_exposed": True,
                "dialog_open": self.dialog_open,
                "tabs": [{"tab_id": TAB1, "index": 0, "title": "Inbox", "selected": False, "identity": "element"},
                         {"tab_id": TAB2, "index": 1, "title": "Docs", "selected": True, "identity": "element"}],
                "selected_tab": TAB2, "opened_tabs": [], "closed_tabs": [],
                "page": {"url": "https://example.com/docs", "load": "loaded", "web_area": True, "pdf": self.pdf},
            }, {"window_key": "win_2", "window_id": 78, "authorized": False}],
            "opened_windows": [], "closed_windows": [],
        })

    def download(self, request, state):
        result = {"download_id": DL, "state": state["state"], "terminal": state["state"] in ("complete", "failed"),
                  "directory": "/tmp/lane", "bytes": 1234, "renamed": False, "replaced_existing": False,
                  "resumable": state["state"] == "interrupted", "resumed": False, "elapsed_ms": 10,
                  "file_name": "report.pdf"}
        if state["state"] == "complete":
            result["path"] = "/tmp/lane/report.pdf"
        result.update(state.get("extra", {}))
        return ok(request, result)

    def __call__(self, request):
        op = request.get("operation")
        args = request.get("arguments") or {}
        if op == "browser.state":
            return self.state(request)
        if op == "browser.wait":
            return ok(request, {"transition": {"kind": "unchanged", "meaning": "nothing changed"},
                                "settled": True, "load": "loaded", "intermediate_documents": 0,
                                "url": "https://example.com/docs", "waited_ms": 5, "timed_out": False})
        if op == "download.expect":
            if self.expect_drop_first:
                self.expect_drop_first = False
                return None  # connection closed: the answer is lost
            return self.download(request, {"state": "not_started"})
        if op == "download.forget":
            return ok(request, {"forgotten": True, "download_id": args.get("download_id")})
        if op in ("download.wait", "download.status"):
            # "started" sees the first scripted state; the end (and a plain
            # status read) sees the last.
            current = self.download_states[0] if args.get("until") == "started" else self.download_states[-1]
            return self.download(request, current)
        if op == "action.execute":
            kind = args.get("kind")
            if self.press == "lost":
                return None
            if self.press == "refused":
                frame = failure(request, "APPROVAL_REJECTED", "not granted", "auth=app_not_granted")
                frame["error"]["execution"] = {"executed": False, "outcome": "not_executed", "op_id": args.get("op_id")}
                return frame
            if self.press == "document_changed":
                return failure(request, "ACTION_FAILED", "The document changed; observe again.",
                               "policy=background;reason=document_changed")
            if self.press == "name_conflict":
                return failure(request, "ACTION_FAILED", "A file with that name already exists.",
                               "policy=background;kind=browser.save_dialog;reason=name_conflict")
            result = {"ok": True, "message": "pressed" if kind == "ui.press" else "tab selected",
                      "execution": {"executed": True, "outcome": "succeeded", "op_id": args.get("op_id"),
                                    "instance_id": self.instance, "replayed": False}}
            if kind == "browser.save_dialog":
                result.update({"dialog": "closed", "filename_set": True, "confirmed": True, "replaced": False,
                               "closed": True, "message": "save dialog handled"})
            return ok(request, result)
        if op == "action.outcome":
            return ok(request, {"op_id": args.get("op_id"), "known": False, "outcome": "unknown",
                                "instance_id": self.instance})
        if op == "bridge.ping":
            result = default_responder(request)["result"]
            result["instance_id"] = self.instance
            return ok(request, result)
        return default_responder(request)


class Base(unittest.TestCase):
    def setUp(self):
        self.helper = BrowserHelper()
        self.bridge = FakeBridge(self.helper).start()
        self.addCleanup(self.bridge.stop)
        self.client = BridgeClient(self.bridge.socket_path, policy="background")
        self.client._sleep = lambda _seconds: None
        self.addCleanup(self.client.close)
        self.registry = ToolRegistry(self.client, "background")

    def frames(self, operation):
        return [f for f in self.bridge.frames if f.get("operation") == operation]

    def call(self, name, arguments):
        return self.registry.call(name, arguments)


class ContractTests(Base):
    def test_vocabulary_and_retry_classes(self):
        self.assertIn("browser.select_tab", ACTION_KINDS)
        self.assertIn("browser.save_dialog", ACTION_KINDS)
        self.assertEqual(retry_class("action.execute", "browser.select_tab"), "mutating")
        self.assertEqual(retry_class("action.execute", "browser.save_dialog"), "mutating")
        for read in ("browser.state", "browser.wait", "download.status", "download.wait", "download.list"):
            self.assertEqual(retry_class(read), "read", read)
        self.assertEqual(retry_class("download.expect"), "idempotent")

    def test_the_tools_exist_in_background_mode(self):
        names = {t["name"] for t in self.registry.tools()}
        for name in ("computer_use_browser_state", "computer_use_browser_wait", "computer_use_browser_select_tab",
                     "computer_use_download", "computer_use_download_expect", "computer_use_download_status",
                     "computer_use_save_dialog"):
            self.assertIn(name, names)

    def test_auto_invocation_covers_browsers_and_verified_downloads(self):
        self.assertIn("Web browsers are applications too", AUTO_INVOCATION_POLICY)
        self.assertIn("NOT a disconnection", AUTO_INVOCATION_POLICY)
        self.assertIn("never say a file was downloaded unless the helper verified it", AUTO_INVOCATION_POLICY)
        self.assertIn("overwrite=true", AUTO_INVOCATION_POLICY)


# 1. tab switching keeps the connection

class TabTests(Base):
    def test_browser_state_lists_stable_tabs_and_says_the_connection_is_intact(self):
        text = text_of(self.call("computer_use_browser_state", {"context": CTX}))
        self.assertEqual(self.frames("browser.state")[0]["arguments"]["context_id"], CTX)
        self.assertIn(TAB1, text)
        self.assertIn("* tab " + TAB2, text, "the selected tab is marked")
        self.assertIn("tab_switched", text)
        self.assertIn("connection is intact", text)
        self.assertIn("win_2: not authorized by the policy", text)
        self.assertNotIn("disconnected", text)

    def test_select_tab_is_one_mutating_action_then_reads(self):
        result = self.call("computer_use_browser_select_tab", {"context": CTX, "tab_id": TAB1})
        actions = self.frames("action.execute")
        self.assertEqual(len(actions), 1)
        self.assertEqual(actions[0]["arguments"]["kind"], "browser.select_tab")
        self.assertEqual(actions[0]["arguments"]["params"]["tab_id"], TAB1)
        self.assertTrue(actions[0]["arguments"]["op_id"].startswith("op_"))
        self.assertEqual(len(self.frames("browser.wait")), 1)
        self.assertEqual(len(self.frames("observation.describe")), 1)
        self.assertIn("connection is intact", text_of(result))

    def test_a_lost_tab_switch_answer_is_never_resent(self):
        self.helper.press = "lost"
        result = self.call("computer_use_browser_select_tab", {"context": CTX, "tab_id": TAB1})
        self.assertTrue(result.get("isError"))
        self.assertIn("OUTCOME_UNKNOWN", text_of(result))
        self.assertEqual(len(self.frames("action.execute")), 1)


# 2. navigation: the action is refused, the observation recovers, nothing is repeated

class NavigationTests(Base):
    def test_document_changed_appends_a_fresh_observation_and_does_not_repeat(self):
        self.helper.press = "document_changed"
        result = self.call("computer_use_press", {"context": CTX, "element_id": 7, "snapshot": 3})
        text = text_of(result)
        self.assertTrue(result.get("isError"), "the press did not happen")
        self.assertIn("RECOVERED (document_changed)", text)
        self.assertIn("NOT repeated", text)
        self.assertIn("connection and the context are intact", text)
        self.assertEqual(len(self.frames("action.execute")), 1)
        self.assertEqual(len(self.frames("observation.describe")), 1)

    def test_browser_wait_is_a_bounded_read(self):
        text = text_of(self.call("computer_use_browser_wait", {"context": CTX, "until": "loaded", "timeout": 500}))
        frame = self.frames("browser.wait")[0]["arguments"]
        self.assertEqual(frame["until"], "loaded")
        self.assertEqual(frame["timeout"], 120.0, "capped at the helper's bound")
        self.assertIn("settled=True", text)


# 4-11. downloads are verified, never assumed

class DownloadTests(Base):
    def test_a_download_is_reported_only_after_verification(self):
        result = self.call("computer_use_download", {"context": CTX, "element_id": 7, "snapshot": 3,
                                                     "name_hint": "report.pdf"})
        text = text_of(result)
        self.assertFalse(result.get("isError"))
        self.assertIn("VERIFIED verified: /tmp/lane/report.pdf", text)
        expect = self.frames("download.expect")[0]["arguments"]
        self.assertEqual(expect["context_id"], CTX)
        self.assertEqual(expect["name_hint"], "report.pdf")
        self.assertTrue(expect["op_id"].startswith("op_"))
        order = [f["operation"] for f in self.bridge.frames if f["operation"] != "bridge.ping"]
        self.assertLess(order.index("download.expect"), order.index("action.execute"),
                        "the expectation exists before the press")
        self.assertEqual(len(self.frames("action.execute")), 1)

    def test_a_lost_press_is_not_repeated_and_the_expectation_answers(self):
        self.helper.press = "lost"
        result = self.call("computer_use_download", {"context": CTX, "element_id": 7, "snapshot": 3})
        self.assertEqual(len(self.frames("action.execute")), 1, "never pressed twice")
        self.assertIn("press: unknown", text_of(result))
        self.assertIn("VERIFIED", text_of(result), "the file system, not the press, decides")

    def test_no_download_started_and_a_dialog_is_open(self):
        self.helper.download_states = [{"state": "not_started"}]
        self.helper.dialog_open = True
        result = self.call("computer_use_download", {"context": CTX, "element_id": 7, "snapshot": 3})
        self.assertTrue(result.get("isError"))
        self.assertIn("NOT VERIFIED", text_of(result))
        self.assertIn("save dialog is open", text_of(result))

    def test_the_browser_opened_a_pdf_viewer_instead(self):
        self.helper.download_states = [{"state": "not_started"}]
        self.helper.pdf = True
        text = text_of(self.call("computer_use_download", {"context": CTX, "element_id": 7, "snapshot": 3}))
        self.assertIn("viewer", text)

    def test_an_interrupted_download_says_how_to_resume(self):
        self.helper.download_states = [{"state": "in_progress"}, {"state": "interrupted"}]
        text = text_of(self.call("computer_use_download", {"context": CTX, "element_id": 7, "snapshot": 3}))
        self.assertIn("NOT VERIFIED", text)
        self.assertIn("Resume", text)

    def test_a_refused_press_forgets_the_expectation_and_does_not_wait(self):
        self.helper.press = "refused"
        text = text_of(self.call("computer_use_download", {"context": CTX, "element_id": 7, "snapshot": 3}))
        self.assertIn("refused before anything happened", text)
        self.assertEqual(len(self.frames("download.forget")), 1)
        self.assertEqual(len(self.frames("download.wait")), 0)

    def test_a_lost_expect_is_resent_with_the_same_operation_id(self):
        self.helper.expect_drop_first = True
        result = self.client.download_expect(CTX, name_hint="a.zip")
        self.assertEqual(result["download_id"], DL)
        sent = self.frames("download.expect")
        self.assertEqual(len(sent), 2)
        self.assertEqual(sent[0]["arguments"]["op_id"], sent[1]["arguments"]["op_id"])

    def test_a_known_size_and_checksum_travel_with_the_expectation(self):
        self.call("computer_use_download", {"context": CTX, "element_id": 7, "snapshot": 3,
                                            "expected_bytes": 2000000, "expected_sha256": "ab" * 32})
        expect = self.frames("download.expect")[0]["arguments"]
        self.assertEqual(expect["expected_bytes"], 2000000)
        self.assertEqual(expect["expected_sha256"], "ab" * 32)
        self.call("computer_use_download_expect", {"context": CTX})
        self.assertNotIn("expected_bytes", self.frames("download.expect")[1]["arguments"])

    def test_status_with_checksum_is_explicit(self):
        self.helper.download_states = [{"state": "complete", "extra": {"sha256": "ab" * 32}}]
        text = text_of(self.call("computer_use_download_status", {"download_id": DL, "checksum": True}))
        self.assertTrue(self.frames("download.status")[0]["arguments"]["checksum"])
        self.assertIn("sha256=" + "ab" * 32, text)
        self.call("computer_use_download_status", {"download_id": DL})
        self.assertNotIn("checksum", self.frames("download.status")[1]["arguments"])

    def test_a_declared_checksum_that_could_not_be_computed_is_not_verified(self):
        # Audit H2: the helper fails the download instead of leaving it complete.
        self.helper.download_states = [{"state": "in_progress"},
                                       {"state": "failed", "extra": {"reason": "checksum_unavailable"}}]
        result = self.call("computer_use_download", {"context": CTX, "element_id": 7, "snapshot": 3,
                                                     "expected_sha256": "ab" * 32})
        self.assertTrue(result.get("isError"))
        self.assertIn("NOT VERIFIED", text_of(result))
        self.assertIn("checksum_unavailable", text_of(result))

    def test_a_checksum_request_without_a_digest_says_so(self):
        self.helper.download_states = [{"state": "complete", "extra": {"checksum": "unavailable"}}]
        text = text_of(self.call("computer_use_download_status", {"download_id": DL, "checksum": True}))
        self.assertIn("checksum unavailable", text)
        self.assertNotIn("sha256=", text)


# 8. save dialogs and conflicts

class SaveDialogTests(Base):
    def test_the_save_dialog_is_an_ax_action_with_explicit_overwrite(self):
        text = text_of(self.call("computer_use_save_dialog", {"context": CTX, "filename": "report.pdf"}))
        params = self.frames("action.execute")[0]["arguments"]["params"]
        self.assertEqual(params, {"confirm": True, "overwrite": False, "cancel": False, "filename": "report.pdf"})
        self.assertIn("dialog=closed", text)

    def test_a_name_conflict_is_reported_not_overwritten(self):
        self.helper.press = "name_conflict"
        result = self.call("computer_use_save_dialog", {"context": CTX, "filename": "report.pdf"})
        self.assertTrue(result.get("isError"))
        self.assertIn("reason=name_conflict", text_of(result))
        self.assertEqual(len(self.frames("action.execute")), 1)


class ClassificationTests(unittest.TestCase):
    def test_failures_are_named_for_what_they_mean(self):
        self.assertEqual(classify_failure(BridgeError("x", code="ACTION_FAILED",
                                                     detail="policy=background;reason=document_changed")),
                         "document_changed")
        self.assertEqual(classify_failure(BridgeError("x", code="COMPUTER_TARGET_UNAVAILABLE",
                                                     detail="reason=app_closed;transition=app_closed")),
                         "app_closed")
        self.assertEqual(classify_failure(BridgeError("x", code="ACTION_FAILED",
                                                     detail="reason=window_changed")), "window_closed")
        self.assertEqual(classify_failure(BridgeError("x", code="TAB_UNKNOWN")), "tab_unknown")
        self.assertEqual(classify_failure(BridgeUnavailable("gone")), "connection_lost")
        self.assertEqual(classify_failure(BridgeUnavailable("gone"), instance_before="a", instance_now="b"),
                         "helper_restarted")
        self.assertEqual(classify_failure(BridgeOutcomeUnknown("x", op_id="op_1", reason="unreachable")),
                         "outcome_unknown")
        self.assertEqual(classify_failure(BridgeError("x", code="APPROVAL_REJECTED")), "refused")
        for meaning in ("tab_switched", "navigated", "document_changed"):
            self.assertIn("intact", FAILURE_MEANINGS[meaning], meaning)


class FlowTests(Base):
    def test_download_by_pressing_is_usable_without_mcp(self):
        outcome = download_by_pressing(self.client, element_id=7, snapshot=3, context_id=CTX)
        self.assertTrue(outcome["verified"])
        self.assertEqual(outcome["download"]["path"], "/tmp/lane/report.pdf")
        self.assertEqual(outcome["press"]["outcome"], "succeeded")


if __name__ == "__main__":
    unittest.main()
