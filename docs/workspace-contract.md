# CMM Computer Use — Workspace contract v1 (helper 0.3.3)

Contract name `cmm-computer-use/workspace`, version **1**. Harness-neutral: it is
what any host (DeepSeek Harness, a reference harness, another agent runtime)
integrates against, through the helper socket (protocol v1 frames, see
[computer-bridge-protocol.md](computer-bridge-protocol.md)) or through the MCP
adapter (`packages/dsh-computer-use/adapter`). Nothing here depends on DSH, on
a model provider or on a proprietary SDK.

A helper implements this contract when `bridge.ping` reports
`capabilities.workspace.contract == "cmm-computer-use/workspace"` and
`contract_version >= 1`. A host that does not see it must use 0.3.2 semantics
(one default context, one stream).

## 1. Principals

Every request is attributed to a **principal**, derived by the helper from the
kernel's view of the socket peer — never from a request field:

| Policy | Principal | `strength` |
|---|---|---|
| v2 with `clients`, peer matches one | `client:<client_id>` | `verified_client` |
| v1 (no clients), peer validly signed | `code:<signing identifier>@<team or ->` | `code_identity` |
| peer unsigned | `pid:<pid>` | `process` |
| stdio mode | `local` | `local` |

Contexts, streams and recorded outcomes belong to one principal. Another
principal gets **the same refusal as for an id that never existed**
(`CONTEXT_UNKNOWN`, `STREAM_UNKNOWN`), so ids are not an oracle.

Two processes with the same code identity are the same principal under a v1
policy (they share contexts and limits); under a v2 policy, two programs that
must be isolated from each other need two `clients` entries.

An id is **never an authorization**: every observation, capture, stream and
action is still decided by the application grant (`observe` / `control`, window
patterns, client scopes) at the moment it runs. Deny by default is unchanged.

## 2. Contexts

A context is ONE application (and the window/document observed in it):

- `context_id`: `ctx_` + 32 hex (128 random bits, `SecRandomCopyBytes`).
- `label`: `A`, `B` (explicit) or `default` (the 0.3.2 context).
- its own current generation (`snapshot`) — numbered from ONE workspace-wide
  counter, so a snapshot number names exactly one context and an action that
  cites another context's number (or none) is refused — observation clock (30 s in
  `background`/`focus`), released generations and element handles;
- identity: bundle, pid, app name, window id (when unique), window title,
  document identity (below);
- an optional bound stream.

Limits: **2 explicit contexts per principal**, 16 per helper; the `default`
context is extra and never counts. Idle contexts (30 min unused) are reaped
with their handles and streams.

Rules:

1. A handle resolves only in the context that produced it, for its principal,
   and only for that context's current generation.
2. Observing context B never changes context A's generation, clock or handles.
3. An explicit context is one application: observing another app through it is
   `CONTEXT_TARGET_MISMATCH`.
4. `release` and `USER_TAKEOVER` retire the generation of the AFFECTED context
   only.
5. A request without `context_id` uses the principal's default context, with
   exactly 0.3.2 semantics.

### Document identity (tabs)

The window is not the document: a browser tab switch keeps the window id and
changes what the handles describe. Identity comes only from supported AX
attributes — the window's `AXDocument`, else the first web area's `AXURL` —
and is published as a digest (`document.source`, `document.verified`,
`document.digest`), never the value. A handle is refused with
`reason=document_changed` when a verified identity changed, and in explicit
contexts also when a title-only identity's title changed
(`reason=document_unverified`) or a verified one became unverifiable. No tab id
is invented: an application that exposes neither attribute gets conservative
re-observation, which is the declared limitation.

## 3. Operations

All requests are protocol v1 frames: `{"version":1,"id":…,"operation":…,"arguments":{…}}`.

| Operation | Arguments | Result | Retry class |
|---|---|---|---|
| `workspace.status` | — | `contract`, `contract_version`, `instance_id`, `principal{strength,client_id}`, `limits`, `contexts[]`, `streams[]` | read |
| `workspace.context_create` | `app?` (bundle id or name; must be running and granted `observe` to this client) | context summary (`context_id`, `label`, `bound_bundle?`, `snapshot`, …), `instance_id` | mutating¹ |
| `workspace.context_list` | — | `contexts[]`, `limits`, `instance_id` | read |
| `workspace.context_status` | `context_id?` | context summary (+ `stream`) | read |
| `workspace.context_close` | `context_id` | `closed`, `already_closed`, `released_handles`, `stream_stopped` | idempotent |
| `observation.describe` | 0.3.2 args + `context_id?` | 0.3.2 result + `context_id`, `context_label`, `identity_changes[]`, `document{}`; `snapshot` is the context's | read |
| `observation.release` | `context_id?` | `released`, `invalidated_snapshot`, `snapshot`, `context_id` | idempotent |
| `observation.capture_screen` | 0.3.2 args + `context_id?` | 0.3.2 result; `view_identity.snapshot` is the context's | read |
| `observation.stream_start` | `app?`, `window_title?`, `window_id?`, `context_id?` \| `stream_key?`, `expected_bundle?`, `expected_pid?` | stream description (`stream_id`, `stream: started|existing`, `phase`, `view_identity`, …) | mutating¹ |
| `observation.stream_stop` | `stream_id?` \| `context_id?` | `stopped`, `already_stopped`, `stream_id` | idempotent |
| `observation.stream_frame` | `stream_id?` | `screenshot_base64` (JPEG), `stream_id`, `frame_index`, `frame_age_ms`, `phase`, `unchanged`, `stale`, `view_identity` | read |
| `observation.stream_status` | `stream_id?` \| `context_id?` | `streams[]`, `max_streams`, `max_per_client` | read |
| `observation.stream_recover` | `stream_id` \| `context_id` | stream description + `recovered`, `attempt` | mutating¹ |
| `action.execute` | 0.3.2 args + `context_id?` (top level or in `params`) + `op_id?` | 0.3.2 result + `execution{}` | **mutating** (except `wait`/`finish`) |
| `action.outcome` | `op_id` | `known`, `outcome`, `ok?`, `instance_id`, `reason?` | read |

¹ Changes only helper bookkeeping, but not idempotently; not retried
automatically.

`bridge.ping` additionally reports `instance_id` (random per helper process)
and `capabilities.workspace{contract, contract_version, max_contexts_per_client,
max_streams, document_identity, operation_ledger, stream_recovery}`.

### Execution facts

Every `action.execute` answer — success or error — carries:

```json
"execution": {"executed": true, "outcome": "succeeded", "op_id": "op_…",
              "context_id": "ctx_…", "instance_id": "ins_…", "replayed": false}
```

| `outcome` | Meaning | May the client send it again? |
|---|---|---|
| `not_executed` | refused before anything touched the machine | yes (it is a new attempt) |
| `succeeded` | handed to the machine; reported success | no |
| `failed` | handed to the machine; failed (incl. `INTERFERENCE_BREACH`) | no |
| `unknown` | the answer was lost and no ledger can say (client-side) | **never automatically** |

### Operation ids

- `op_id`: 8–80 chars of `[A-Za-z0-9_-]`; clients send a fresh random one with
  every mutating action.
- The helper records executed outcomes per principal (bounded, 256). Resending
  the SAME `op_id` for the SAME action returns the recorded answer with
  `replayed: true` — it is never executed twice. The same id for a different
  action is `OPERATION_ID_CONFLICT` (not executed). A resend while the first
  is still queued is `OPERATION_IN_PROGRESS` (not executed).
- The ledger lives in memory: a new `instance_id` means it is gone.

### Recovering a lost answer (client rule)

When the transport fails after a mutating action was sent (timeout, closed
socket, malformed frame, helper restart), the client MUST NOT resend it. It
may only read: `bridge.ping` (same `instance_id`?) and `action.outcome(op_id)`.
A recorded outcome is reported as recovered; anything else is `OUTCOME_UNKNOWN`
with a reason (`unreachable`, `helper_restarted`, `no_ledger`, `not_recorded`,
`in_progress`). The reference implementation is
`BridgeClient.act` in `adapter/cmm_computer_use/client.py`.

### Retry classes and timeouts

| Class | Operations | Automatic retry |
|---|---|---|
| read | ping, statuses, describe, capture, stream_frame/status, outcome | 2 retries, 0.25 s then 0.75 s |
| idempotent | release, stream_stop, context_close | 1 retry, 0.25 s |
| mutating | action.execute (except wait/finish), context_create, stream_start/recover, breach.rearm, unknown ops | **none** |

Client timeouts: 5 s for a frame, 10 s for bookkeeping, 20 s for describe and
stream start, 25 s for stream recovery, 30 s for a capture, 60 s for an action.
The Swift source of truth is `apps/macos/Shared/ComputerUseReliability.swift`;
the adapter's table is tested against it.

## 4. Streams

Up to **2 concurrent streams** per helper and per principal; the third is
`STREAM_LIMIT`. Each stream is bound to ONE window (by window id; a title
follows the active tab) and to the identity it was opened for, and has its own
`stream_id` (`str_` + 32 hex), sink, queue, frame index, heartbeat, health and
recovery budget.

- Slot: `context_id` (bound to the context; its identity is the expectation),
  or `stream_key` (a host label such as `A`/`B`), or neither (the principal's
  0.3.2 single stream, replaced by a new legacy start).
- Starting a slot on the same window is idempotent (`stream: "existing"`);
  starting it on another window replaces only that slot's own stream.
- `expected_bundle` / `expected_pid` are checked against the selected window
  before any surface opens (`STREAM_IDENTITY_MISMATCH`).
- Authorization: the selected window's `observe` grant **for this client**,
  before opening and again on every `policy.reload` (revoked → stopped).
- Frames are served only to the owning principal, outside the helper's
  dispatch lock.

### Phases

| `phase` | Meaning |
|---|---|
| `warming` | started, no frame yet (≤ 3 s) |
| `live` | a frame within 2 s, or idle buffers within 2 s (`unchanged: true`: alive, nothing changed) |
| `stale` | no frame and no idle buffer for 2 s (`frozen`), or no first frame after warm-up |
| `recovering` | a recovery is in progress |
| `error` | the system stopped it (`stopped_by_system`), its pid vanished (`pid_changed`), or recovery failed |
| `closed` | stopped |

**An old frame is never `live`.** `stream_recover` restarts one stream on the
same window id, keeps its `stream_id` and its monotonic `frame_index`, decides
authorization again, and is bounded (5 attempts; backoff 0.5, 1, 2, 4, 8 s,
enforced as `STREAM_RECOVERY_BACKOFF` with `retry_after_ms`). It never touches
another stream.

## 5. Errors (additions to the 0.3.2 grammar)

`CONTEXT_UNKNOWN`, `CONTEXT_CLOSED`, `CONTEXT_LIMIT`, `CONTEXT_TARGET_MISMATCH`,
`STREAM_UNKNOWN`, `STREAM_LIMIT`, `STREAM_IDENTITY_MISMATCH`,
`STREAM_RECOVERY_EXHAUSTED`, `STREAM_RECOVERY_BACKOFF`, `OPERATION_ID_CONFLICT`,
`OPERATION_IN_PROGRESS`; client-side `OUTCOME_UNKNOWN`. New `reason=` values:
`document_changed`, `document_unverified`, `context_unknown`, `context_closed`,
`context_limit`, `stream_limit`, `op_id_conflict`, `op_in_progress`.

`INTERFERENCE_BREACH`, the persistent latch, `USER_TAKEOVER` attribution, the
settle window and the window-chrome guard are unchanged.

## 6. MCP surface (adapter)

| Tool | New in 0.3.3 | Notes |
|---|---|---|
| `computer_use_observe`, `_capture_window`, `_press`, `_set_value`, `_scroll`, `_release` | optional `context` | absent → unchanged 0.3.2 frame |
| `computer_use_workspace_status` | yes | read-only |
| `computer_use_context_open` | yes | read-only annotation (observe-scoped; acts on no app) |
| `computer_use_context_close` | yes | |

Action results print `execution: executed=… outcome=… replayed=… op_id=…
context=…`. An observation prints `context: <label> <id>`, `cmm_view` with
`context_id`/`context_label`, `identity_changes`, `document`, and — before any
AX content — the helper facts and the target's grant (the lines
`computer_use_status` prints), so a host can verify and show the target without
a prior status call.

### Automatic invocation

The server `instructions` start with the invocation guidance: use the tools
automatically for tasks that need to see or operate a GUI, never for text- or
code-only work, open one context per application for two-app work. Whether a
host follows it is the host's (its model's or router's) decision; the helper
only enforces what is allowed. A host without the adapter enabled, or unable to
show the PiP, must say so instead of claiming visual activity.

## 7. What a host must show (visibility requirements)

For each stream a host displays: the application's human name (never the
bundle id), the window, the phase from the table above, and the age of the last
frame. It must never label an old or frozen frame as live, never show a panel
for a context it cannot verify, and must show a helper-wide failure or a
breach on every panel. Showing a mirror must not activate, raise or focus the
target, nor move the cursor.

## 8. Compatibility

0.3.2 clients keep working unchanged: requests without `context_id` /
`stream_id` behave as before for their principal. Behavioural tightenings that
are visible to them: another client's observation no longer replaces their
handles; a legacy `stream_start`/`stream_stop` affects only the caller's own
stream; a verified document change refuses an old handle (`document_changed`);
a timed-out or desynchronised MUTATING action is reported `OUTCOME_UNKNOWN`
instead of `COMPUTER_RUNTIME_UNAVAILABLE`.
