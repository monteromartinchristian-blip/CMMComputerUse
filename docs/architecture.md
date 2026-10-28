# Architecture

Four layers, each with one job. Nothing is duplicated across them: there is one
engine, one transport and one adapter.

```
┌──────────────────────────────┐
│ DeepSeek Harness             │  sessions, model, tools, UI
│  ├─ @deepseek-ai/dsh-mcp-client ──stdio──┐
│  └─ @cmm/dsh-computer-use (Host/Client)  │  projection + PiP
└──────────────────────────────┘           │
                                           ▼
                             ┌───────────────────────────────┐
                             │ adapter (Python, stdlib only) │
                             │  cmm_computer_use.mcp_server  │
                             └───────────────┬───────────────┘
                                             │ NDJSON over a Unix socket
                                             ▼
                             ┌───────────────────────────────┐
                             │ CMM Computer Use.app (Swift)  │
                             │  AX · ScreenCaptureKit · TCC  │
                             └───────────────┬───────────────┘
                                             ▼
                             one authorized window of one authorized app
```

## Why the helper exists

TCC grants permissions to a **process identity**, and a bare interpreter is not
a grantable identity: a helper spawned by `/usr/bin/python3` inherits an
ancestry whose decision subject is the interpreter, and grants bound to the
helper never apply. So the native primitives live in a small signed `.app` that
the person can see and grant, and everything else lives outside it.

The helper is deliberately narrow: `--serve-socket`, one JSON object per line,
no policy of its own beyond the shared interaction policy.

## The layers

### `apps/macos/` — the helper

| File | Responsibility |
|---|---|
| `CMMComputerUse/main.swift` | socket server, dispatch, AX observation, actions, interference ledger |
| `CMMComputerUse/WindowStream.swift` | the `SCStream` sink: a cached frame per authorized window |
| `Shared/ComputerUsePolicy.swift` | modes, action classes, targeting, window selection |
| `Shared/ComputerUseAuthorization.swift` | the per-application allowlist and scope rules |
| `Shared/BridgeTargeting.swift` | exact app/window resolution — never fuzzy |

Everything in `Shared/` is pure Foundation and compiled into **both** the helper
and the test bundle, so the tests pin the rules the helper executes. No test
touches the window server.

**TCC identity.** Bundle id `com.cmm.chat.computer-use`, display name
*CMM Computer Use*. Both are load-bearing; changing either voids existing
grants. The helper is `LSUIElement` (no Dock icon) but is launched through
LaunchServices, because ScreenCaptureKit attributes a capture to the
*responsible* app and a directly-executed `Contents/MacOS` binary has none.

**The ledger.** Every action is bracketed by samples of the environment: which
app is frontmost, where the cursor is. `verdict` says what changed; `breach` says
what is attributable to the action. An AX action emits no HID event, so a
cursor movement measured around it is `external_activity` — the user moving the
mouse — never `cursor_moved_by_action`. This is what makes "no focus theft"
measurable instead of a claim.

### `packages/dsh-computer-use/adapter/` — the MCP adapter

A stdlib-only Python package. `mcp_server.py` speaks MCP over stdio;
`client.py` speaks the NDJSON protocol over the socket. The adapter:

- publishes only the tools the effective mode allows (in `background`, there is
  no activate, no focus, no click, no type, no shortcut, no scroll);
- annotates read-only tools so a host can auto-approve them;
- turns every helper refusal into an `isError` result with the code and detail
  intact, and never retries a refusal;
- bounds what it shows a model (40 interactive elements, 60 content lines).

It is lazy by design: `initialize` and `tools/list` never touch the socket, so a
missing helper does not break installation — the first tool that needs it fails
with a diagnostic.

### `packages/dsh-computer-use/` — the DSH bundle

| File | Responsibility |
|---|---|
| `cordis.patch.yml` | two additive rows: the shipped MCP client, pointed at the adapter; and this package's Host plugin |
| `index.js` | session projection registration, tool guard, and the loopback mirror server |
| `runtime.mjs` | the pure projection: fold, phases, admission, freshness, overlay geometry |
| `client.template.js` → `dist/client.js` | the PiP, rendered at build time |
| `locale/{en,es}.json` | Plugin Manager metadata and every string the panel shows |

`runtime.mjs` is pure and has no React, no DOM and no timers: that is what lets
the projection be tested as a function, including the rules that matter —
stale and cross-target frames are refused, a `window_id` change is
`window_changed` rather than an implicit retarget, and a frame is admitted by
**lineage** (same grant, same bundle, same pid, same title, same window id,
monotonic snapshot) rather than by snapshot equality.

The PiP is a separate concern from admission: the mirror is fed by a loopback
streamer that reads the helper's cached `SCStream` frame, and the label follows
the pixels (`mirror-live`) without ever granting `canRead`. A stalled stream is
labelled paused, never presented as current.

### The socket protocol

Versioned, one JSON object per line, documented in
[computer-bridge-protocol.md](computer-bridge-protocol.md). It is a separate
contract from MCP on purpose: the adapter is replaceable, and a second client
does not need to reimplement the helper's rules — only to speak the protocol and
carry the same policy.

## Data flow of one action

```
model → tool call (mcp__cmm-computer-use__computer_use_press)
      → adapter: check mode, attach policy=background + snapshot generation
      → socket: {"version":1,"operation":"action.execute",...}
      → helper: authorize app+scope+window → policy gate → AX press
                → ledger samples → result + interference report
      → adapter: render a typed result (or a refusal) for the model
      → Host plugin: fold the tool result into the session projection
      → PiP: mirror frames + the admitted attachment
```

## Design decisions worth knowing

- **One engine.** No second Swift helper, no wrapper that replaces it, no daemon
  inside the client.
- **A socket, not a port.** No TCP listener, no HTTP server for the control path.
  The mirror is loopback HTTP for rendering only; it serves the one window the
  helper authorized and validates a fixed token.
- **Fail-closed everything.** No allowlist means no access; a malformed policy
  means no access; an unknown mode never falls back to a permissive one; a
  capture without provenance is not shown as evidence.
- **A refusal is a result, not an exception.** Every refusal carries a code the
  model can read and act on, and nothing is executed before the decision.
- **The mirror is not evidence.** Pixels prove what the user sees; the admitted
  attachment proves what the model received. The product keeps those separate.
