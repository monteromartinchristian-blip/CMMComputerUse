"""Harness-neutral browser flows over :class:`BridgeClient` (F-09).

Two things every harness needs and none should re-invent:

* :func:`classify_failure` names what a refusal or transport error MEANS for a
  browser task — a tab switch or a navigation is not a disconnection, a lost
  answer is not a failure, a closed browser is not a dead helper — so the
  caller recovers the right way instead of restarting everything;
* :func:`download_by_pressing` is the only honest way to say "downloaded":
  declare the download, press once, then wait for the helper to VERIFY the
  finished file. A press whose answer was lost is never repeated: the
  expectation answers whether a download started.

Pure Python over the public client API; no harness, provider or product
integration. The MCP adapter and the reference harness both use it.
"""

from __future__ import annotations

import time
from typing import Any, Dict, Optional

from .client import HOST_BUDGET_SECONDS, BridgeClient, BridgeError, BridgeOutcomeUnknown, BridgeUnavailable

__all__ = [
    "FAILURE_MEANINGS",
    "classify_failure",
    "download_by_pressing",
    "recover_observation",
]

#: What each class means for the caller, in one sentence.
FAILURE_MEANINGS = {
    "connection_lost": "the connection to the helper was lost; reads may be retried, actions are never resent",
    "helper_restarted": "the helper restarted: contexts, tab ids and pending outcomes are gone",
    "outcome_unknown": "the action's answer was lost; do NOT repeat it, observe or check the download instead",
    "tab_switched": "another tab is selected; the connection and the context are intact",
    "navigated": "the page changed; the connection and the context are intact",
    "document_changed": "the page or tab changed; the connection and the context are intact",
    "window_closed": "the observed window was closed; the browser is still running",
    "app_closed": "the browser is not running",
    "tab_unknown": "that tab is gone; read the browser state again",
    "refused": "the policy or the helper refused it; nothing was done",
    "other": "the action failed",
}

#: Failures a fresh observation of the SAME context resolves. A closed window
#: is not one (observing would follow focus to another window), nor is a lost
#: answer (the caller must look and decide, not be handed a new target).
_RECOVERABLE_BY_OBSERVING = {"tab_switched", "navigated", "document_changed"}


def classify_failure(error: BaseException, *, instance_before: Optional[str] = None,
                     instance_now: Optional[str] = None) -> str:
    """One word for what went wrong (keys of :data:`FAILURE_MEANINGS`)."""

    if isinstance(error, BridgeOutcomeUnknown):
        return "helper_restarted" if "helper_restarted" in (error.detail or "") else "outcome_unknown"
    if isinstance(error, BridgeUnavailable):
        if instance_before and instance_now and instance_before != instance_now:
            return "helper_restarted"
        return "connection_lost"
    if not isinstance(error, BridgeError):
        return "other"
    detail = error.detail or ""
    if error.code == "TAB_UNKNOWN":
        return "tab_unknown"
    if "transition=app_closed" in detail or "reason=app_closed" in detail or "reason=pid_changed" in detail:
        return "app_closed"
    if error.code == "COMPUTER_TARGET_UNAVAILABLE" and "application not running" in (error.message or ""):
        return "app_closed"
    if "reason=window_changed" in detail or "reason=window_not_found" in detail:
        return "window_closed"
    if "reason=document_changed" in detail or "reason=document_unverified" in detail:
        return "document_changed"
    if error.code in {"APPROVAL_REJECTED", "CAPABILITY_UNSUPPORTED", "INTERFERENCE_BREACH",
                      "DOWNLOADS_NOT_ENABLED", "DOWNLOAD_ROOT_NOT_ALLOWED", "COMPUTER_PERMISSION_DENIED"}:
        return "refused"
    return "other"


def recover_observation(client: BridgeClient, context_id: Optional[str] = None,
                        app: Optional[str] = None) -> Dict[str, Any]:
    """Read where the browser is now and observe it again. Reads only.

    Used after a document/tab change or a lost answer: the caller gets a fresh
    snapshot to decide from, and nothing is pressed again.
    """

    state: Any = None
    try:
        state = client.browser_state(context_id)
    except BridgeError:
        state = None
    extra: Dict[str, Any] = {"context_id": context_id} if context_id else {}
    observation = client.observe(app=app, **extra)
    return {"browser": state, "observation": observation}


def download_by_pressing(
    client: BridgeClient,
    *,
    element_id: int,
    snapshot: int,
    context_id: Optional[str] = None,
    name_hint: Optional[str] = None,
    directory: Optional[str] = None,
    start_timeout: float = 15.0,
    finish_timeout: float = 120.0,
    expected_bytes: Optional[int] = None,
    expected_sha256: Optional[str] = None,
    budget: float = HOST_BUDGET_SECONDS,
) -> Dict[str, Any]:
    """Press a download control once and verify the finished file.

    Returns ``{"press": ..., "download": ..., "verified": bool, "next": str}``.
    ``verified`` is True only when the helper reports ``complete`` (file
    present, non-empty, stable, partial gone). ``next`` says what to do when
    it is not: look for a save dialog, a viewer, or report.

    The whole flow plans inside ``budget`` seconds (the host cuts a tool call
    at 70 s): a download that is still running when the budget ends is reported
    as in progress, never as verified, and is asked again with its id. Once the
    press ran, NO later failure hides that fact: the result always says the
    press happened and must not be repeated (audit X-07 / X-08).
    """

    started_at = time.monotonic()
    remaining = lambda: max(0.0, budget - (time.monotonic() - started_at))  # noqa: E731
    expectation = client.download_expect(context_id, directory=directory, name_hint=name_hint,
                                         expected_bytes=expected_bytes, expected_sha256=expected_sha256)
    download_id = expectation["download_id"]
    press: Dict[str, Any] = {"outcome": None}
    try:
        result = client.act("ui.press", **({"context_id": context_id} if context_id else {}),
                            element_id=element_id, snapshot=snapshot)
        press = {"outcome": "succeeded", "result": result}
    except BridgeOutcomeUnknown as lost:
        # The press may or may not have happened. Never press again: the
        # expectation below is what tells.
        press = {"outcome": "unknown", "detail": lost.detail}
    except BridgeError as refused:
        execution = getattr(refused, "execution", None) or {}
        press = {"outcome": execution.get("outcome") or "failed", "code": refused.code, "detail": refused.detail}
        if execution.get("outcome") == "not_executed":
            client.download_forget(download_id)
            return {"press": press, "download": None, "verified": False,
                    "next": "the press was refused before anything happened: %s" % refused.code}
    try:
        return _after_the_press(client, download_id, press, context_id, start_timeout, finish_timeout, remaining)
    except (BridgeError, BridgeUnavailable) as failure:
        # The press ran (or may have): the answer must say so, keep the
        # expectation (it is how to verify later) and forbid pressing again.
        return {"press": press, "download": None, "verified": False,
                "next": "the press already ran (outcome %s): do not press again. The download could "
                        "not be read (%s). Ask computer_use_download_status with download_id=%s"
                        % (press.get("outcome"), getattr(failure, "code", type(failure).__name__), download_id),
                "download_id": download_id}


def _after_the_press(client, download_id, press, context_id, start_timeout, finish_timeout, remaining):
    started = client.download_wait(download_id, until="started",
                                   timeout=max(0.5, min(start_timeout, remaining() - 5.0)))
    if started.get("state") == "not_started":
        state = None
        try:
            state = client.browser_state(context_id)
        except BridgeError:
            pass
        dialog = any(w.get("dialog_open") for w in (state or {}).get("windows", []) if isinstance(w, dict))
        pdf = any((w.get("page") or {}).get("pdf") for w in (state or {}).get("windows", [])
                  if isinstance(w, dict) and w.get("followed_by_context"))
        if dialog:
            hint = ("a save dialog is open: use computer_use_save_dialog (or "
                    "browser.save_dialog) and keep waiting on download %s" % download_id)
        elif pdf:
            hint = ("the browser opened the file in its viewer instead of downloading it: press the "
                    "viewer's download/save control, then wait on download %s" % download_id)
        else:
            hint = ("no download started in %s; the press outcome was %s. The browser may save to "
                    "another folder than this one (its own download setting, e.g. iCloud Drive) or be "
                    "asking for permission to download. Observe the page before deciding anything "
                    "(do not press again blindly)" % (started.get("directory"), press["outcome"]))
        return {"press": press, "download": started, "verified": False, "next": hint,
                "browser": state}
    wait = max(0.5, min(finish_timeout, remaining() - 2.0))
    final = client.download_wait(download_id, until="terminal", timeout=wait)
    verified = final.get("state") == "complete"
    if verified:
        hint = "verified: %s (%s bytes)" % (final.get("path"), final.get("bytes"))
    elif final.get("state") == "interrupted":
        hint = ("the download stalled; if the browser offers Resume, press it and wait on "
                "download %s again" % download_id)
    elif final.get("state") == "failed":
        hint = "the download failed (%s)" % final.get("reason")
    else:
        hint = ("still in progress (not complete, not verified) after %ss; wait on download %s again"
                % (int(wait), download_id))
    return {"press": press, "download": final, "verified": verified, "next": hint}


def needs_reobservation(kind: str) -> bool:
    """Whether a failure class is resolved by observing again (never by resending)."""

    return kind in _RECOVERABLE_BY_OBSERVING
