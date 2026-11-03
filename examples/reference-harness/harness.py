#!/usr/bin/env python3
"""Reference harness for the CMM Computer Use contract — no DeepSeek Harness.

A minimal MCP host over stdio, written only against the PUBLIC contract
(docs/workspace-contract.md): it launches the adapter as a subprocess, reads
the server's ``instructions`` and tool annotations, and drives a two-context
flow. It exists to prove that a harness other than DSH can integrate CMM
Computer Use without touching the core and without DSH internals, and to give
a new harness's adapter something to compare against.

The automatic-invocation decision belongs to the HARNESS (here
``needs_computer_use``): a deliberately simple, transparent rule standing in
for whatever a real harness uses (a model's tool choice, a router). The core
decides nothing about when it is called; it only enforces what is allowed.

    python3 harness.py --socket <helper socket> [--app Safari --app Notes]
"""

from __future__ import annotations

import argparse
import itertools
import json
import os
import pathlib
import re
import subprocess
import sys
from typing import Any, Dict, List, Optional

ADAPTER = pathlib.Path(__file__).resolve().parents[2] / "packages/dsh-computer-use/adapter"

#: What makes a task GUI work. A harness with a model would let the model
#: choose from the tool descriptions and the server instructions; this rule is
#: the reference's explicit, testable stand-in.
GUI_SIGNALS = re.compile(
    r"\b(windows?|buttons?|screens?|click|press|apps?|applications?|ventanas?|bot[oó]n(es)?|pantallas?|pulsa|"
    r"what does .* show|qu[eé] muestra|compare .* (apps?|windows?)|safari|finder|notes|claude desktop)\b",
    re.I)


def needs_computer_use(task: str, instructions: str) -> bool:
    """True when the task needs to see or operate a GUI and the server says
    its tools are the way to do that."""

    advertised = "graphical application" in instructions
    return advertised and bool(GUI_SIGNALS.search(task))


class McpStdioClient:
    """JSON-RPC 2.0 over the adapter's stdio, one request at a time."""

    def __init__(self, socket_path: str, mode: str = "background", python: Optional[str] = None) -> None:
        env = dict(os.environ, PYTHONPATH=str(ADAPTER))
        self.process = subprocess.Popen(
            [python or sys.executable, "-B", "-m", "cmm_computer_use.mcp_server",
             "--socket", socket_path, "--mode", mode],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env, cwd=str(ADAPTER))
        self._ids = itertools.count(1)

    def request(self, method: str, params: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        rid = next(self._ids)
        assert self.process.stdin and self.process.stdout
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": rid, "method": method,
                                             "params": params or {}}) + "\n")
        self.process.stdin.flush()
        reply = json.loads(self.process.stdout.readline())
        assert reply.get("id") == rid, "answer for another request"
        return reply

    def call(self, name: str, arguments: Dict[str, Any]) -> Dict[str, Any]:
        reply = self.request("tools/call", {"name": name, "arguments": arguments})
        if "error" in reply:
            raise ValueError(reply["error"]["message"])
        return reply["result"]

    def close(self) -> None:
        if self.process.stdin:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)
        if self.process.stdout:
            self.process.stdout.close()


def text(result: Dict[str, Any]) -> str:
    return "\n".join(b.get("text", "") for b in result.get("content", []) if b.get("type") == "text")


def handshake(client: McpStdioClient) -> Dict[str, Any]:
    init = client.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                         "clientInfo": {"name": "cmm-reference-harness", "version": "1"}})
    tools = client.request("tools/list")["result"]["tools"]
    return {"instructions": init["result"].get("instructions", ""),
            "server": init["result"]["serverInfo"], "tools": tools}


def two_app_flow(client: McpStdioClient, apps: List[str]) -> Dict[str, Any]:
    """Open one context per app, observe each, report, close. No action that
    changes an application is taken: this is the contract's read path."""

    report: Dict[str, Any] = {"contexts": []}
    contexts = []
    for app in apps[:2]:
        opened = text(client.call("computer_use_context_open", {"app": app}))
        match = re.search(r"context opened: ([A-D]) (ctx_[0-9a-f]{32})", opened)
        if not match:
            report["contexts"].append({"app": app, "error": opened.splitlines()[0] if opened else "no answer"})
            continue
        contexts.append((app, match.group(1), match.group(2)))
    for app, label, context in contexts:
        observed = client.call("computer_use_observe", {"app": app, "context": context})
        body = text(observed)
        snapshot = re.search(r"^snapshot: (\d+)", body, re.M)
        report["contexts"].append({"app": app, "label": label, "context": context,
                                   "snapshot": int(snapshot.group(1)) if snapshot else None,
                                   "error": body.splitlines()[0] if observed.get("isError") else None})
    report["workspace"] = text(client.call("computer_use_workspace_status", {})).splitlines()[:6]
    for _app, _label, context in contexts:
        client.call("computer_use_context_close", {"context": context})
    return report


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="cmm-reference-harness")
    parser.add_argument("--socket", required=True)
    parser.add_argument("--app", action="append", default=[])
    parser.add_argument("--task", default="Compare what the two windows show.")
    args = parser.parse_args(argv)
    client = McpStdioClient(args.socket)
    try:
        hello = handshake(client)
        decision = needs_computer_use(args.task, hello["instructions"])
        out: Dict[str, Any] = {"server": hello["server"], "tools": [t["name"] for t in hello["tools"]],
                               "task": args.task, "uses_computer_use": decision}
        if decision and args.app:
            out["flow"] = two_app_flow(client, args.app)
        print(json.dumps(out, indent=2))
    finally:
        client.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
