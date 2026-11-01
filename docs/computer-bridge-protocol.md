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
`CAPABILITY_UNSUPPORTED`, `CANCELLED`).

## Operations (allowlist — nothing else exists)

| Operation | Arguments | Result |
|---|---|---|
| `bridge.ping` | `{}` | `{bridge, protocol, pid, bundle_id, policy, authorization, capabilities}` — identity proof |
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
`window.focus`, `ui.press`, `ui.set_value`, `keyboard.type`,
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
| `background` (default when `--policy` is absent) | `ui.press`, `ui.set_value`, `wait`, `finish`, observation, single-window capture | activation, pointer, global keyboard, display captures |
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

The helper samples the frontmost application and the cursor every ~2 ms while
the action runs, and the report folds those samples in:

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
| `breach` | an accessibility-only action made the frontmost application its own target, in a mode that promised no interference |

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
