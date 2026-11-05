# CMM Computer Use — Bridge Protocol v1

Status: product contract. Changes require a protocol version bump and a
matching update in the client (`packages/dsh-computer-use/adapter/cmm_computer_use/client.py`)
and in the helper (`apps/macos/CMMComputerUse/main.swift`).

## Architecture

```
DeepSeek Harness → @cmm/dsh-computer-use → CMM Computer Use.app → authorized macOS apps
```

The client remains the orchestrator. The helper is ONLY the platform execution
bridge: a grantable macOS process identity (`com.cmm.chat.computer-use`,
LSUIElement, no Dock icon) for the observation/action primitives that a bare
Python interpreter cannot be granted.

## Transport (product: app-served Unix socket)

- The installed LaunchAgent launches the helper with `--serve-socket <path>`
  through LaunchServices and supervises it (relaunch on exit).
- Clients only ever CONNECT to that Unix-domain socket
  (default `~/.cmm/computer-bridge/bridge.sock`, override
  `CMM_COMPUTER_BRIDGE_SOCKET`). The private socket is the local transport
  boundary: no TCP port, no HTTP server, no `open`, no FIFOs.
- Socket and stdio modes speak the identical NDJSON protocol over one JSON
  object per line; only the rendezvous differs.
- The socket path must fit COMPLETELY in `sockaddr_un.sun_path` (Darwin: at
  most 103 UTF-8 bytes plus the NUL; capacity derived from the struct). A
  longer path is never truncated: `--serve-socket` logs `FATAL: socket path
  does not fit in sockaddr_un …` and exits 2 before probing, unlinking or
  binding anything, and the single-instance probe treats it as "nobody
  there". Since helper 0.3.2 build 5; earlier builds truncated to 103 bytes.

Why the app launches the helper (TCC ancestry rule, proven live 2026-10-02
via the TCC log): on current macOS a helper spawned by an unbundled client
interpreter inherits an unusable ancestry — the decision subject becomes the
bare interpreter (`AUTHREQ_SUBJECT` = uv `python3.13`, `authValue=0`), never
the helper identity, so grants bound to the helper never apply no matter
which process spawns it that way. A helper launched by the bundled app
keeps a grantable ancestry (the same reason direct probes attributed to a
bundled responsible app evaluate true). A client must therefore never spawn
the helper in the product path.
- Stdout carries ONLY protocol frames. Diagnostics go to stderr (secret-free
  by construction; nothing secret ever crosses this boundary).
- Requests are bounded to 1 MiB; responses to ~32 MB (one PNG frame as
  base64). Timeouts are per-operation (10–60 s). A timeout drops the
  connection; the next request reconnects (socket) or relaunches (stdio
  child), so a late answer can never be mistaken for a later request's
  response.
- The helper is long-lived and stateful across requests within one process:
  Accessibility element references from `observation.describe` are held in a
  process-local table and resolved by numeric id in `action.execute`.

## Frames

Request:

```json
{"version": 1, "id": "...", "operation": "...", "arguments": {...}}
```

Response (success):

```json
{"version": 1, "id": "...", "ok": true, "result": {...}}
```

Response (failure):

```json
{"version": 1, "id": "...", "ok": false,
 "error": {"code": "COMPUTER_RUNTIME_UNAVAILABLE", "message": "...", "detail": "..."}}
```

`version` must be `1`. `arguments` must be an object. Unknown operations are
rejected with `CAPABILITY_UNSUPPORTED`. Error codes are the frozen Computer
Use grammar (`COMPUTER_RUNTIME_UNAVAILABLE`, `COMPUTER_PERMISSION_DENIED`,
`COMPUTER_TARGET_UNAVAILABLE`, `ACTION_FAILED`, `APPROVAL_REJECTED`,
`CAPABILITY_UNSUPPORTED`, `CANCELLED`, and — helper 0.3.0 — `INTERFERENCE_BREACH`).

## Operations (allowlist — nothing else exists)

| Operation | Arguments | Result |
|---|---|---|
| `bridge.ping` | `{}` | `{bridge, protocol, pid, bundle_id, helper_version, helper_build, policy, authorization, capabilities}` — identity proof; `helper_version`/`helper_build` say which build this is and `capabilities` (`workspace`, `browser`, `downloads`, `scroll_reveal`, …) what it can do: an adapter negotiates with them and refuses what an older helper lacks |
| `permissions.status` | `{}` | `{accessibility, screen_recording, detail}` measured on the helper |
| `permissions.request_accessibility` | `{}` | canonical AX prompt, then status |
| `permissions.request_screen_recording` | `{}` | canonical SC request, then status |
| `apps.list` | `{}` | `{apps: [{name, bundle_id, pid, is_active, hidden}]}` — no activation |
| `observation.describe` | `{include_screenshot, app?, policy?}` | `{frontmost_app, frontmost_bundle, target_app, target_bundle, target_is_frontmost, windows[], elements[], content[], screenshot_base64\|null, screenshot_scope, screenshot_error?, snapshot, captured_at}` |
| `observation.capture_screen` | `{app?, window_title?, policy?}` | `{screenshot_base64, screenshot_scope}` (bounded PNG) |
| `observation.stream_start` | `{app?, window_title?, window_id?, policy?}` | `{stream: "started", view_identity}` — opens ONE ScreenCaptureKit stream on the authorized window |
| `observation.stream_frame` | `{policy?}` | `{screenshot_base64, media_type: "image/jpeg", frame_index, frame_age_ms, stale, view_identity}` — the last cached frame, never a new capture |
| `observation.stream_stop` | `{}` | `{stopped, active, window_id?, frames, encode_failures}` — idempotent |
| `observation.release` | `{}` | `{released, snapshot}` — drops every element handle |
| `policy.status` | `{}` | `{loaded, source, policy_mode, launch_mode, effective_mode, default, load_error, invalid_clients[], requirement_contract, client, peer, clients[], apps[]}` — `clients[]` carries `requirement_valid`, `requirement_sha256` and `apps_sha256`, never the requirement text |
| `policy.reload` | `{}` | re-reads the allowlist and returns the same shape |
| `policy.requirements.check` | `{requirements:[{client_id?, requirement}], evaluate_path?}` | `{contract, contract_version, peer, evaluated_path, requirements:[{client_id?, compiles, status, message, requirement_sha256, matches_peer, matches_evaluated_path?}]}` — read-only; see below |
| `action.execute` | `{kind, params, policy?}` | `{ok, message, interference}` for kinds in the allowlist below |

Action kinds (parity with `ACTION_KINDS`): `app.open`, `app.activate`,
`window.focus`, `ui.press`, `ui.set_value`, `ui.scroll`, `keyboard.type`,
`keyboard.shortcut`, `pointer.click`, `pointer.scroll`, `wait`, `finish`.
There is deliberately NO shell execution, NO AppleScript passthrough, NO
executable launch by path, NO filesystem API. `app.open` resolves by
application name through `NSWorkspace` only.

These additions are additive within protocol version 1: every new argument is
optional, every new result field is extra, and a v1 client that ignores them
behaves exactly as before.

### `policy.requirements.check` (contract version 1)

Compiles code-signing designated requirements with the same Security APIs the
enforcement path uses, and optionally evaluates them. It writes nothing, reloads
nothing, grants nothing, and needs no client identity — the moment it matters
most is before any client is declared.

- `compiles` — `SecRequirementCreateWithString` succeeded. `status` is the raw
  `OSStatus`; `message` is a symbolic code (`ok`, `invalid_requirement`,
  `unsupported_requirement`), never a localized string.
- `matches_peer` — the requirement describes the process on the other end of
  this socket, resolved from the kernel's audit token and its code signature.
- `matches_evaluated_path` — present only when `evaluate_path` was supplied and
  the code object there could be read. Absent means "not asked"; `false` means
  "asked and did not match". A path that cannot be read yields
  `evaluated_path.available: false` and no per-requirement value.
- `requirement_sha256` — `hex(SHA256(utf8(trimmed requirement)))`, so a host can
  prove the helper compiled the exact string it wrote without policy text
  travelling back over the socket.

The information exposed is what any process running as the same user already
gets from `codesign -d -r- <path>`; no administrative authority is added.

### Load-time requirement audit

A version-2 document whose client requirement does not compile is **refused as a
whole**: `loaded:false`, `load_error:"client_requirement_invalid"`,
`invalid_clients:[…]`, every application denied. A requirement that cannot
compile is not a strict client — it is a client that can never authenticate while
the file claims it exists, which reads on screen as an authorization that does
not work.

### Live window stream (`observation.stream_*`)

The mirror used to cost one `SCScreenshotManager` capture per frame, which
measured ~4 fps on a real window. `stream_start` opens ONE ScreenCaptureKit
stream (`SCContentFilter(desktopIndependentWindow:)`, `minimumFrameInterval`
1/15 s, `queueDepth` 3, no cursor), converts each delivered surface to JPEG on
the stream's own queue and keeps only the last one; `stream_frame` returns that
cached buffer and never captures. `stream_stop` is idempotent and a second
`stream_start` replaces the first, so a client cannot leave orphan captures
running.

Identity is the one the helper already publishes: `window_id`, `pid`, `bundle`.
`window_id` is preferred over `window_title` because a title follows the active
tab: a mirror keyed on it dies the moment the person navigates. `window_title`
remains accepted (and is what `capture_screen` still takes) so a client that
has no id keeps working.

A stream is a capture that keeps happening, so the gate is the same: policy
first, then one authorized window, then the owner's `.observe` grant, all
decided before any surface is opened. `bridge.ping` gains
`capabilities.window_stream` and a `window_stream` diagnostic block (no pixels)
so a host can tell "supported" from "not supported" instead of discovering it
by failing; `capture_screen` stays as the fallback.

### Multi-App Workspace (helper 0.3.3)

Additive operations, all on the same v1 frames: `workspace.status`,
`workspace.context_create|list|status|close`, `observation.stream_status`,
`observation.stream_recover`, `action.outcome`; and optional `context_id`,
`stream_id`, `stream_key`, `expected_bundle`, `expected_pid`, `op_id` on the
existing ones. The element table, generation and released set are per
**context** of the caller's **principal** (no longer process-wide); up to two
window streams run at once, each owned by its principal; every action answer
carries `execution {executed, outcome, op_id, instance_id, replayed}`.
`bridge.ping` adds `instance_id` and `capabilities.workspace`. The full,
harness-neutral contract — schemas, limits, phases, errors, retry classes and
compatibility — is [workspace-contract.md](workspace-contract.md).

## Interaction policy (what the helper is allowed to do to the machine)

Not every kind in the allowlist has the same physical effect.
`ui.press`/`ui.set_value` ask an application's own accessibility layer to act
on one element; `pointer.click` posts a global HID event at absolute
coordinates (it moves the system cursor and lands on whatever is topmost);
`keyboard.type`/`keyboard.shortcut` post global key events into whichever
application holds the keyboard focus, and `keyboard.type` also rewrites the
pasteboard on the way.

The policy is therefore explicit, declared at launch, and enforced before any
input is posted:

| Mode | Allows | Refuses |
|---|---|---|
| `background` (default when `--policy` is absent) | `ui.press` (not on window controls), `ui.set_value`, `ui.scroll`, `wait`, `finish`, observation, single-window capture | activation, pointer (incl. `pointer.scroll`), global keyboard, display captures, window controls |
| `focus` | the above plus `app.open`, `app.activate`, `window.focus` | pointer, global keyboard, display captures |
| `unrestricted` | the full legacy allowlist | nothing extra |

- A request may carry `"policy"` in `action.execute` / `observation.describe` /
  `observation.capture_screen` arguments. The helper applies the STRICTER of
  that and its launch policy (`bridgeEffectiveMode`), so a client can narrow
  what it may do and can never widen it. A `policy` value that is present but
  not one of the three modes is REFUSED (`CAPABILITY_UNSUPPORTED`, detail
  `policy=invalid;…`), never ignored: a misspelled mode must not silently
  receive the deployment's more permissive one.
- `--policy <background|focus|unrestricted>` is the launch flag. An unknown
  value is a startup failure, never a silent fallback. The product LaunchAgent
  writes `--policy unrestricted` explicitly to preserve today's planner
  behaviour; a new client asks for stricter.
- A refused kind answers `CAPABILITY_UNSUPPORTED` with
  `detail = "policy=<mode>;kind=<kind>;requirement=<activation|global_pointer|global_keyboard>;needs=<mode>"`
  and a message that names the physical consequence.
- In restricted modes the element table expires after 30 s: an element action
  then answers `ACTION_FAILED` ("The observation this element belongs to has
  expired; observe again") and element actions must carry the `snapshot`
  generation that produced them.
- Every executed action returns `interference`:
  `{verdict, frontmost_before, frontmost_after, cursor_moved, cursor_dx,
  cursor_dy, action_class, policy, attributed, breach}`. `verdict` is one of
  `untouched`, `focus_changed`, `cursor_moved`, `focus_and_cursor_changed`;
  `attributed` is always `false` because a delta between two samples is
  evidence, not proof of who caused it; `breach` is true when an
  accessibility-only action changed focus or the cursor in a mode that
  promised it would not.
- In `background` mode `observation.describe` with `include_screenshot`
  requires `app` and captures that application's window; the display is never
  captured. If the window cannot be resolved the observation is still
  returned, with `screenshot_base64 = null` and `screenshot_error` set.

### Background hardening (helper 0.3.0, 2026-11-02)

Found live: `ui.press` on an Electron window's zoom button made the target
frontmost while the ledger said `verdict=untouched`, `breach=false`. Fixed by:

- **Settle window.** The ledger keeps sampling after `AXUIElementPerformAction`
  returns — at least 0.8 s, extended while readings still change (quiet
  0.25 s), never past 2 s (`bridgeSettleWindow`). Before, sampling stopped at
  return, ~300 ms after the press; the activation it triggered landed later.
- **Three readings per sample** instead of the cached
  `NSWorkspace.frontmostApplication`: the system-wide AX
  `AXFocusedApplication` (synchronous) and the owner of the front-most layer-0
  window (`CGWindowListCopyWindowInfo`, no title or pixels). Any reading that
  names the target counts. An unreadable reading is "unknown", never a
  transition.
- **Fail closed and stop.** A breach turns the call into
  `INTERFERENCE_BREACH`
  (`detail=policy=…;reason=breach;kind=…;action_ok=…;breach_id=<uuid>`, ledger
  in `error.interference`), even when the action itself "succeeded". The
  helper does **not** re-activate the person's previous application: that
  would be a second interference caused by Computer Use. It **latches** the
  target durably (see "Breach latch" below): later control actions on it
  answer `ACTION_FAILED`
  `detail=policy=…;reason=breach;target=<bundle>;breach_id=<uuid>` until CMM
  Console rearms it. A restart does not clear it.
- **Window controls refused up front.** `ui.press` on an element whose subrole
  is `AXCloseButton`, `AXMinimizeButton`, `AXZoomButton` or
  `AXFullScreenButton` answers `CAPABILITY_UNSUPPORTED`
  `detail=policy=…;kind=ui.press;reason=window_chrome;subrole=…` in
  `background` and `focus`. Zoom/full screen order the window front (full
  screen also moves Spaces); close/minimize change the person's desktop; none
  of them is "the app acting on its content". Elements carry `subrole` and
  `window_chrome: true` in `observation.describe`.
- **`ui.scroll`** `{element_id, snapshot, direction: up|down|left|right,
  pages?: 1…10}`: the element's own `AXScroll<Dir>ByPage` action, else its
  scroll bar's `AXValue`, else — added 2026-11-04 for Firefox, whose document
  area has neither (acceptance finding D5) — the **reveal** route:
  - **How it scrolls.** It performs `AXScrollToVisible` on the descendant
    beyond the visible edge. The browser then scrolls the document, or the
    inner box that holds that descendant.
  - **The first step** reveals the nearest content beyond the edge. That never
    skips content, whatever the browser's alignment.
  - **Later steps** use where the browser landed that element (Firefox centres
    it) to choose the next one.
  - **Hard cap:** `pages` viewports per call, so content is never skipped. A
    browser that centres moves about half a viewport per page; an
    edge-aligned one about 0.9.
  - **Nested boxes.** The content of a nested scroll box (children overflowing
    its frame) belongs to that box, never to the document.
  - **Elements with nothing of their own to scroll.** An element such as a
    line or a button inside a box scrolls the container that holds it.
    `scroll.container` names it.
  - **Measurement.** Every step is measured on the revealed element's own
    position: `scroll.moved_pt`, plus `steps`, `goal_pt` and `cap_pt` in the
    attempt.
  - **At the end.** Nothing beyond the edge → `ACTION_FAILED`
    `detail=…;reason=no_content_beyond;candidates=…`.
  - **What it never does.** No wheel event, no cursor, no focus, no
    activation, no window raise.

  No route at all → `CAPABILITY_UNSUPPORTED`
  `detail=…;reason=scroll_area_without_scrollbar|scrollbar_not_settable|not_scrollable|invalid_direction;role=…`.
  `AXScrollArea` elements are listed with `scrollable` / `scroll_unsupported`.
  **Verified postcondition** (2026-11-02, after a live run where
  `AXScrollDownByPage` returned -25205 although the content had moved): the
  AX return code is not the outcome. The helper measures the scroll bar value
  (preferred) or the content's first child position before and after. Moved
  in the requested direction = success, any AX error kept as
  `scroll.ax_error`; no effect after the page action = the AX-only scroll bar
  fallback, measured again; no verifiable effect = `ACTION_FAILED`
  `detail=…;reason=no_effect|wrong_direction|scroll_unverifiable;routes=…;ax_error=…`.
  Success and failure carry `scroll = {route, effect, ax_error?, before,
  after, attempts[]}` (`result.scroll` / `error.scroll`). Element-action
  `ACTION_FAILED` frames now carry the helper's `detail`.
- **Accessibility tree materialization.** When the observed window has fewer
  than 24 AX nodes, the helper sets `AXManualAccessibility=true` on the
  (already `observe`-authorized) application element — the attribute Electron
  documents for third-party assistive clients — polls up to 2 s, and reports
  `ax_enrichment = {mechanism, state: not_needed|already_enabled|enabled|enabled_still_sparse|unsupported|failed|not_trusted, nodes_before, nodes_after, ax_error?}`.
  `AXEnhancedUserInterface` is NOT used (it changes window management).
  **Since 2026-11-02 the decision is taken after a first walk**
  (`bridgeEnrichmentTrigger`): `sparse` (< 24 nodes), `unavailable`, or
  `readable_not_actionable` — the Claude Desktop state that the old node-count
  rule never caught. After enrichment the window is walked again;
  `ax_enrichment` reports `trigger`, `access_before/after`,
  `actionable_before/after`, `grew`, `enhanced_user_interface` (read only), and
  is always rendered (also `not_needed`). The walk goes to depth 40 (was 12),
  text inputs have their own budget (20), and `ax_counts.limits` reports
  visited/deepest/depth_cutoffs/children_cutoffs/budget_skipped_controls.
  `include_ax_diagnostics: true` (adapter: `ax_diagnostics`) adds a read-only
  deep scan before and after: roles, depth, truncation and every node that
  looks like a control (role, actions, AXValue settable, ancestor path).
  A text input is `actionable` only when its AXValue is settable
  (`value_settable`). **`ui.set_value`**: an element whose AXValue is not
  settable is `CAPABILITY_UNSUPPORTED reason=value_not_settable` before
  anything is touched; after setting, the value is read back
  (`bridgeSetValueCheck`) — mismatch is `ACTION_FAILED
  reason=value_not_applied|value_unreadable`; success and failure carry
  `set_value {check, requested_length, read_back_length, previous_length,
  ax_error?}` (lengths only, never the previous content). Every
  observation states `ax_tree: ok|chrome_only|empty` and — readable is not
  actionable — `ax_access: actionable|readable|unavailable` with
  `ax_counts {content, elements, actionable, window_controls}`; each element
  carries `actionable` (non-window-control and pressable, a text input, or
  verified scrollable). The adapter prints `ax_access: …` and renders only
  `unavailable` as `AX_TREE_UNAVAILABLE`; `readable` (e.g. Claude/Electron's
  AXWebArea and headings, no control) can be observed and is not evidence of
  control.
- New ledger fields: `window_raised_over_person`, `target_front_at_ms`
  (offset of the first sample with the target in front), `observed_for_ms`.
  New `bridge.ping` capabilities: `post_action_settle`, `breach_fail_closed`,
  `window_chrome_guard`, `ax_scroll`, `ax_tree_enrichment`,
  `breach_latch: "persistent"`, `breach_rearm`.

### Filtered projection and release (helper 0.3.2)

- **`observation.describe` accepts `element_filter?`** (string, ≤ 200 chars;
  additive within protocol v1). The adapter filter is pushed down to the
  helper so a named control is not lost only because unrelated controls
  filled the ordinary projection budget. Semantics: case-insensitive
  substring over role, title/label, value, description, help, role
  description, identifier, placeholder and subrole (a superset of the
  adapter's title/value/role). Absent or blank = exactly the previous
  behaviour. Present: non-matching controls consume no element budget and the
  walk still descends into them; the budgets (60 regular / 20 text inputs)
  bound the MATCHES returned. Depth (40), visited nodes (6 000), children per
  node (200) and the content budget are unchanged. Authorization is decided
  before the walk exactly as before; a filter never widens apps or scopes and
  never searches another application. Matched elements carry
  `filter_match: true`; the observation carries
  `ax_filter {text, matched, skipped_non_matching, non_matching_actionable}`.
  Controls the filter left out still count for `ax_access` and for the
  enrichment decision, so filtering never changes what the window is said to
  offer. The adapter still post-filters (title/value/role or `filter_match`).
- **`observation.release`** now retires the generation: it clears the element
  tables, records the old generation as released, increments the generation
  and stamps the observation time. Result: `{released, invalidated_snapshot,
  snapshot}` — `snapshot` is the NEW generation (after the invalidation).
  An element action with a released snapshot is refused before any UI with
  `ACTION_FAILED detail=policy=…;reason=released;snapshot=<old>;current=<new>`
  (no `age`). Any other old snapshot is refused with
  `reason=stale_snapshot;snapshot=…;current=…`. A new observation works as
  usual. Idempotent: each call retires the then-current generation.
- Not changed: interference accounting, attribution, HID witness, settle
  window, breach/latch/rearm, window-chrome guard, set_value, scroll.
- `USER_TAKEOVER` invalidates with the SAME rule as `observation.release`
  (one helper operation, `invalidateObservation(reason:)`, over the pure
  Shared rule `bridgeRetireObservation`): the four handle tables are emptied,
  the current generation N is remembered as released, the generation becomes
  N+1 and the observation time is set to now (never 0). A handle from N is
  refused with `reason=released` before any UI is touched, with no `age`; a
  fresh `observation.describe` works as usual. This replaces the old zeroed
  timestamp, which produced `reason=expired` with an epoch-sized `age`.
  WHEN a takeover is reported (`requiresReobserve`: attribution `user` or
  `ambiguous_external`), the attribution, witness, settle window, breach and
  latch are unchanged; the action is still never retried. Wire, adapter and
  DSH projection are unchanged (`released` was already a known reason,
  stateVersion 12).

### Who moved the focus: action vs person (helper 0.3.1)

Bug fixed: the person clicked the target while an AX action on it was
settling; the ledger saw the target come to the front and latched a breach.
`focus_became_target` and `window_raised_over_person` stay the observed
FACTS; the breach now also needs the change to be attributable to the action.

- **Witness (read-only).** Every sample queries the combined hardware HID
  state (`CGEventSource.secondsSinceLastEventType(.hidSystemState, …)` for
  left/right/other mouse-down, key-down and flags-changed, plus
  `CGEventSource.flagsState(.hidSystemState)` for ⌘). Nothing is created,
  posted or tapped; mouse MOVEMENT is not read. Focus-capable inputs: a mouse
  button down; a key down while ⌘ is held (⌘-Tab — plain typing does not
  switch apps); ⌘ released (⌘-Tab activates on release).
- **Correlation.** With `f` = first sample that saw the target active or on
  top (`target_front_at_ms`): an input in `[f − 0.75 s, f]` ⇒ `user`; in
  `(f, f + 0.06 s]` (sampling resolution) ⇒ `ambiguous_external`; nothing ⇒
  `action`; any sample without a reliable reading ⇒ `unknown`.
- **Breach** only for `action` or `unknown` (fail closed without telemetry).
  `user` / `ambiguous_external`: `external_activity=true`, `breach=false`, no
  latch, no audit entry, and the helper invalidates the element handles: the
  next element action on an old handle answers `ACTION_FAILED reason=released`
  (since 0.3.2; 0.3.1 answered `reason=expired` with an epoch-sized `age`)
  until a fresh `observation.describe`. Nothing is retried.
- New ledger keys (old ones unchanged): `focus_change_attribution`
  (`none|action|user|ambiguous_external|unknown`), `human_witness_available`,
  `human_input_detected`, `human_input_kind`
  (`mouse_down|command_key_down|command_release`), `human_input_age_ms`
  (input → first in-front sample), `requires_reobserve`.
- The adapter prints an `attribution:` line and, for a takeover, a
  `USER_TAKEOVER:` line and an error result (never a silent success, never a
  STOP line); the DSH projection drops the target (`USER_TAKEOVER`) without
  setting `breach` (stateVersion 11).

### Breach latch and `breach.rearm`

State lives next to the policy file (so `--policy-file` lanes are isolated):

- `breach-latch.json` (0600): `{"version":1,"breaches":[{id, target_bundle,
  target_name, client_id, kind, policy, at, verdict, focus_became_target,
  window_raised_over_person, target_front_at_ms?}]}`. No window titles, no
  element text. Missing file = nothing latched. **Unreadable or malformed =
  every control action refused** (`reason=breach_latch_invalid;cause=…`).
- `breach-audit.jsonl` (0600, append-only): one line per `latched`,
  `latch_write_failed`, `rearmed`, `rearm_refused`, `reset_invalid`,
  `cleared_outside_console` (a breach that vanished from the file without a
  rearm, detected on `policy.reload`). Lines carry `actor_client_id` and
  `actor_signing_id` (the peer's code-signing identifier) and the reason.

| Operation | Arguments | Result |
|---|---|---|
| `breach.status` | `{}` | `{state: ok\|invalid, invalid_reason?, breaches[], latch_path, audit_path, rearm}` — diagnostics, no client needed (like `policy.status`) |
| `breach.rearm` | `{breach_id, reason}` or `{reset_invalid_state: true, reason}` | `{rearmed, audit}` / `{reset, audit}` |

`breach.rearm` is accepted only when ALL hold, else `APPROVAL_REJECTED` /
`ACTION_FAILED` with the `detail` shown:

1. the policy is version 2 (`auth=rearm_requires_client_identity`);
2. the peer matched a client by code signature (`auth=client_not_authorized`);
3. that client's entry has `"admin": ["breach.rearm"]` (`auth=rearm_not_granted`);
4. it is not the client whose action caused the breach (`auth=self_rearm_not_permitted`);
5. `reason` is non-empty after sanitizing, ≤ 500 chars (`reason=rearm_reason_missing`);
6. `breach_id` names an open breach (`reason=breach_id_missing|unknown_breach`);
   `reset_invalid_state` only when the file is invalid (`reason=latch_state_valid`).

The rearm is written to disk BEFORE it takes effect; if the write fails the
breach stays latched (`reason=latch_write_failed`). The MCP adapter has no
tool and no client method that issues `breach.rearm`; `computer_use_status`
only lists open latches. A DSH session that recorded a breach stays denied
for that session even after a rearm; a new session starts clean.

## Per-application authorization (deny by default)

Accessibility is granted to the HELPER process by macOS, not to an application:
once `CMMComputerUse.app` is trusted it can read and drive everything. The
bridge therefore carries its own allowlist, in a file the person owns:

`~/.cmm/computer-bridge/policy.json` (override `CMM_COMPUTER_USE_POLICY_FILE`),
mode `0600`, directory `0700`.

```json
{
  "version": 1,
  "mode": "background",
  "default": "deny",
  "apps": [
    {"bundle_id": "com.cmm.cu.fixture", "name": "CMM CU Fixture",
     "scopes": ["observe", "control"], "windows": ["CMM CU Fixture"]}
  ]
}
```

- **No file, unreadable file, malformed file, or an app that is not listed all
  mean no access.** There is no permissive fallback and no implicit "all apps".
- `scopes` are separate: `observe` (read the AX tree, capture that app's
  window) and `control` (press / set value). Observe never implies control.
- `windows` limits a grant to title fragments; an empty list means any window
  of that app. An empty title cannot satisfy a named list.
- The file's `mode` is a second ceiling: the helper applies
  `min(launch --policy, file mode)`.
- A refusal is `APPROVAL_REJECTED` with `detail = auth=app_not_granted |
  scope_not_granted | window_not_granted | display_capture_not_permitted;…`.
- `apps.list` returns only authorized applications. `observation.describe`
  refuses an unauthorized target before reading a single AX attribute, and the
  `windows[]` it returns is filtered to authorized applications.
- Under authorization, a **display capture is refused**: it would include
  windows the deployment never authorized. `observation.describe` with
  `include_screenshot` and `observation.capture_screen` both capture one
  authorized window (`SCContentFilter(desktopIndependentWindow:)`).

### Element handles are bound to a process and a window

An `element_id` is not a portable reference. When the observation walks a
window, each handle records the owning PID, bundle id and AX window element.
Before an element action runs, the helper re-checks that:

- the element still belongs to the same live process and bundle (otherwise
  `ACTION_FAILED`, `reason=pid_changed`),
- the element's AX window is still the same window element (otherwise
  `ACTION_FAILED`, `reason=window_changed`),
- the policy still grants `control` for that app **and the window's current
  title** (otherwise `APPROVAL_REJECTED`),
- the observation is inside its mode's lifetime and belongs to the current
  snapshot generation.

### The interference ledger covers failures, and samples during the action

Every executed action — successful or not — reports `interference`. On success
it rides in `result.interference`; on failure it rides in `error.interference`
(a key clients ignore, because they read only `code`/`message`/`detail`).

The helper samples the frontmost application (three readings, see above) and
the cursor every ~5 ms while the action runs AND through the post-action settle
window, and the report folds those samples in:

| Field | Meaning |
|---|---|
| `verdict` | what the ENVIRONMENT did: `untouched` / `focus_changed` / `cursor_moved` / `focus_and_cursor_changed`, over before → samples → after |
| `transient_focus_changes` | frontmost transitions observed across that sequence |
| `transient_cursor_max_delta` | largest cursor displacement from the pre-action position, in points |
| `sampled` | number of samples taken during the action |
| `restored` | a change was observed and the endpoints agree — the shape a before/after pair cannot see |
| `cursor_events_posted` | did this action's code path post global HID input at all? False for `ui.press` / `ui.set_value` / `wait` / `finish`, true for `pointer.*` and `keyboard.*` |
| `cursor_moved_by_action` | the measured cursor delta belongs to an input path that could have produced it (`cursor_events_posted && cursorMoved`) |
| `focus_became_target` | the frontmost application became the action's own target — the one focus change an AX action can plausibly cause |
| `external_activity` | something changed that this action cannot explain: the person moved the pointer, or switched to an unrelated application |
| `breach` | an accessibility-only action made its own target frontmost, or ordered its window over the person's, in a mode that promised no interference |
| `window_raised_over_person` | the target's window became the front-most normal window without having been before |
| `target_front_at_ms` | ms after the first sample at which the target was first seen in front (absent when never) |
| `observed_for_ms` | how long the measurement covered, settle window included |

**`verdict` describes the environment; `breach` describes responsibility.** The
person may use the machine while an action runs. An accessibility action posts
no HID event and requests no activation, so a cursor delta measured around it is
`external_activity`, never `cursor_moved_by_action`, and never a breach. This is
what makes the no-interference claim independent of what the person is doing
with the mouse.

Sampling has a resolution: a change shorter than the interval can still be
missed, so a live claim also needs an independent observer. `attributed` stays
`false` for the same reason — a delta is evidence, not proof of who caused it.

## Targeting & supervision (behavioral notes; wire format unchanged)

- `app.activate` resolves by exact localized name OR exact bundle id
  (case-insensitive); unknown stays unknown, never a guess.
- `window.focus` searches every running app (active first), activates the
  owning app when it is not frontmost, then raises the window. A missing
  title is a truthful `ACTION_FAILED`, never an arbitrary window.
- A helper whose window-server view freezes on its launch snapshot reports
  honest-looking but wrong activation failures. The app's supervisor audits
  `frontmost_app` against its own live `NSWorkspace` every 10 s. A sustained,
  stable disagreement is LOGGED only, deliberately: production proved either
  side of the comparison can be stale, so relaunching on disagreement killed
  healthy helpers and opened unavailable windows for in-flight runs. A dead
  helper is unambiguous and still relaunches through the termination handler.

## Security boundary

- Local invocation only; the pipe is the boundary.
- Explicit operation allowlist; unknown operations rejected.
- Schema validation on every frame (version, id match, object arguments).
- Bounded request/response sizes and timeouts; supervised server lifecycle
  (the LaunchAgent relaunches a dead helper; the client reconnects).
- No secrets cross the boundary; no secrets are logged.
- Permission grants happen only through macOS; privacy settings are never
  mutated programmatically.

## Product vs development runtimes

- Product: `BridgeComputerRuntime` over the app-served socket (default). If
  nobody serves the socket (Mac app closed), availability is `false` —
  never silently substituted. If the server misidentifies itself, likewise.
- Development only, two explicit escapes (never fallbacks):
  `CMM_COMPUTER_BRIDGE_DIRECT=1` (spawn the helper as our own stdio child)
  and `CMM_COMPUTER_MODE=direct` (direct PyObjC `MacComputerRuntime`). A
  bare interpreter has no grantable ancestry, so neither is the product.
