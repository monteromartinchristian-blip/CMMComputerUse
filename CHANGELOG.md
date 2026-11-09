# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The helper and the plugin version independently; this file tracks the plugin
(`@cmm/dsh-computer-use`) and notes helper-visible changes explicitly.

## Unreleased — F-09 Browser Reliability & Download Management (2026-11-04)

Branch `feature/computer-use-033-browser` (on top of 0.3.3); not integrated,
not deployed. Contract: [docs/browser-contract.md](docs/browser-contract.md).

### Added

- `browser.state` / `browser.wait`: windows and tabs with stable ids, redacted
  URL, load state, open dialogs, and the transition since the last look
  (`tab_switched`, `navigated`, `reloaded`, `tab_closed`, `window_closed`,
  `app_closed`): a tab switch is no longer reported as a lost connection.
- AX-only actions `browser.select_tab` and `browser.save_dialog` (name
  conflict stops; overwrite only on explicit request and a positively
  identified Replace button).
- Verified downloads: `download.expect` / `status` / `wait` / `list` /
  `forget` over directories the policy grant declares
  (`"downloads": {"roots": [...]}`); WebKit, Chromium and Gecko partial
  formats; a file is reported only when complete, non-empty and stable.
- Adapter `browser.py` (failure classification, `download_by_pressing` that
  never presses twice) and seven MCP tools; automatic re-observation after a
  page/tab change (read only).
- `observation.describe` takes `window_id`; explicit contexts keep their window.

- Downloads verified live in Chrome, Firefox and Safari. A ZIP that Safari
  unpacks is reported as `extracted_by_browser`. `expected_bytes` and
  `expected_sha256` catch truncated files a browser keeps as finished.

### Fixed

- Pre-integration audit H1: `download.status`, `download.wait` and
  `download.list` decide each expectation against the policy at every read.
  A revoked application, a lost `observe` scope or a root removed from the
  grant ends the expectation (`DOWNLOAD_ROOT_NOT_ALLOWED` with
  `reason=root_revoked`, or the policy's refusal) before the directory is
  scanned. Closing a context forgets its expectations
  (`downloads_forgotten` in the answer).
- Pre-integration audit H2: a declared `expected_sha256` that cannot be
  computed (a folder the browser unpacked, an unreadable file) is now `failed`
  with `reason=checksum_unavailable`, never a silent `complete`. A read error
  half-way gives no digest instead of the digest of a prefix; a plain
  `checksum` request without a digest answers `checksum: "unavailable"`.
  Likewise, a declared `expected_bytes` on an archive the browser unpacked is
  `failed` with `reason=size_unavailable;archive_unpacked_by_browser`.
- Independent audit N1: `download.list` applies the same integrity rule as
  `download.status`. A declared `expected_sha256` is never listed as
  `complete` with a path unless verified; without a declared checksum the
  list reads no file.
- Final audit A1: a `complete` download is re-checked with `lstat` at every
  read (`status`, `wait`, `list`). If its path is gone, or is no longer the
  same regular file (inode and size) or unpacked folder, it is `failed` with
  `file_missing` / `file_changed`, without a path, and nothing is read.
- Final audit A2 / R2: the checksum reader opens with `O_NOFOLLOW |
  O_NONBLOCK`, accepts only a regular file (checked with `fstat`, with the
  inode that was verified), reads exactly its size, and refuses files over
  2 GiB. A link (including one to `/dev/zero`), a FIFO or a device is refused
  without blocking. Digests are reused while the exact file is unchanged.
### Fixed — integral pre-integration audit (c877447), 2026-11-05

- **X-04 (regression of 0.3.3).** A snapshot number now names exactly ONE
  context: generations come from a single workspace-wide counter. With
  per-context numbering, an action citing the wrong context (or none) could
  resolve "snapshot 1, element 7" of another application. `release` and
  `USER_TAKEOVER` report the generation the context really holds.
- **X-03.** The interference sampler no longer lowers the accessibility
  messaging timeout of the whole process to 100 ms (it truncated trees and
  titles and made a press that ran look failed). There is ONE explicit timeout,
  2 s, set at start; the sampler's bound lives in a `BridgeBoundedReader`.
- **X-05.** A stream is judged again on the window's CURRENT title (at most
  twice a second) before any frame is served and on `policy.reload`. A window
  whose title leaves the grant stops streaming (`stream_authorization_revoked`);
  `view_identity.window` is kept current.
- **X-06.** `observation.capture_screen` and `observation.stream_start` select
  a window only among the windows the caller may observe: no `window_ambiguous`
  list with other applications' titles, an unauthorized window answers like a
  missing one, and a caller with no identity under a client-required policy
  never reaches selection. Policy and caller are captured by value before the
  asynchronous task.
- **X-10.** A context whose bound window is gone is refused when the
  application has several windows (it used to follow the focused window, so two
  contexts could swap); with a single window it is used and named
  (`window_follow: bound_window_replaced`).
- **X-07 / C-09.** Tool calls plan inside a 55 s budget (DSH cuts at 70 s):
  `browser.wait` / `download.wait` are capped at 45 s (the schema says so),
  never resent after a lost answer, and `computer_use_download` plans its whole
  flow from the time that has really passed.
- **X-08.** After the press ran, no later failure hides it: the answer says the
  press happened, keeps the expectation and forbids pressing again.
- **X-09.** `bridge.ping` reports `helper_version`, `helper_build` and
  `capabilities.scroll_reveal`. The adapter reads the helper's capabilities and
  refuses with `HELPER_TOO_OLD` (what still works, what to tell the person)
  what the helper cannot do; an explicit `context` is never sent to a helper
  that would ignore it. `computer_use_status` shows adapter and helper versions
  and features. The adapter and package version is `0.3.3`.
- **X-11.** The automatic re-observation after a page change and the one after
  `select_tab` observe the application that was being worked on; without a
  known one nothing is observed (the model is told to observe naming the app).
- **X-01 (streamer, web vector).** No wildcard CORS: only `dsh-app:` origins
  are granted; `Host` must be loopback with the streamer's port (DNS rebinding)
  and any other `Origin` is refused before the helper is reached. A closed
  panel never leaves its slot taken (the default panel plus A used to leave B at
  429 for ever), a replaced viewer leaving no longer stops the replacement's
  stream, `/frame.png` captures are coalesced per window, and a port that cannot
  be bound is a one-line `ERROR` instead of an unhandled exception.
  **Closed (second half):** the streamer's token is no longer a fixed literal.
  The Host draws a 256-bit random token at every start, gives it to the
  streamer child through its stdin (never argv or environment), and the
  renderer receives it in the session projection's *view* (the persisted state,
  checkpoint and log never hold it); the streamer compares it in constant time
  on `/stream.mjpg`, `/frame.png` and `/stream/status`, and refuses to start
  without a well formed one. A process that does not hold this run's token can
  no longer read any of the three endpoints.
- **M-01.** Several clients with open expectations in one folder: a file nobody
  named is nobody's (only a `name_hint` attributes it).
- **M-02.** A completed download whose file is replaced by another file is
  `failed` (`file_replaced`), never completed again.
- **M-03.** Reading a download (`status`, `wait`, `list`) keeps the context that
  declared it alive.
- **M-05.** A grant that declares a `bundle_id` is satisfied, for a running
  application, by that bundle id only (an impostor with the same visible name no
  longer finds the grant). A policy that relied on the name with a wrong
  `bundle_id` stops matching.
- **M-13.** An explicit context keeps the process it was bound to when several
  share a bundle id; a bound process that is gone is refused.
- **M-14.** `computer_use_observe` accepts `window_id`.
- **M-18.** A malformed argument or an unexpected exception inside a tool is an
  error answer (`-32602` / `-32603`), never the end of the server.

### Added — D5

- Acceptance finding D5: `ui.scroll` scrolls Firefox in the background. Its
  document area offers neither a page action nor an accessible scroll bar, so
  it used to be refused (`scroll_area_without_scrollbar`). A new last-resort
  route reveals the content beyond the visible edge with `AXScrollToVisible`.
  The first step uses the nearest content; later steps use where the browser
  landed it. It is capped at `pages` viewports, so nothing is skipped, and
  every step is measured on the revealed element. The content of nested
  scroll boxes is kept out of the document's targets. An element with nothing
  of its own to scroll scrolls the container that holds it. At the end of the
  document the answer is `reason=no_content_beyond`. Page actions and scroll
  bars keep priority, so Safari and Chrome routes are unchanged. Source guard
  F8. The adapter shows `moved_pt`, `container` and the steps.
- Acceptance finding D6: an observation now resolves its window with one
  bounded second look (100 ms) when the context's bound window is not matched
  or its title cannot be read, instead of deciding at once. Under load an
  authorized window was refused (`window_not_granted`). A window refusal now
  carries what it was decided on: `follow=…;title_len=…;title_ax_error=…`. A
  retry is logged as `WINDOW_RESOLVE_RETRY`.
- Final audit R1: an expectation past its maximum age stops answering on
  every read, and a context that expires by inactivity forgets its download
  expectations, as an explicit close does.
- The PiP restarted its live stream whenever the window title changed (every
  tab switch / navigation); a page change cleared the panel as if the window
  were lost.



Development branch `feature/computer-use-033`; not integrated, not deployed.
Contract: [docs/workspace-contract.md](docs/workspace-contract.md).

### Added

- Workspace contexts: two per client (plus the 0.3.2 default), each with its
  own generation, clock, released set and element handles, owned by the
  verified principal; opaque random ids; `workspace.*` operations.
- Two concurrent window streams, each with its own SCStream, sink, queue,
  frame index, health phase (`warming`/`live`/`stale`/`recovering`/`error`)
  and bounded recovery; third refused; frames served only to the owner.
- Document identity (window `AXDocument` / web-area `AXURL`, as a digest):
  a tab or document change refuses old handles.
- Reliability: `execution` facts on every action, operation-id ledger
  (replay, conflict, in-progress), `action.outcome`, helper `instance_id`;
  the adapter never resends a mutating action whose answer was lost
  (`OUTCOME_UNKNOWN`) and retries only reads.
- MCP: optional `context` on handle tools; `computer_use_workspace_status`,
  `computer_use_context_open`, `computer_use_context_close`; invocation
  guidance in the server instructions.
- DSH: split PiP (one panel per context, two at most), per-slot streamer,
  projection `stateVersion` 13 with validated lanes.
- `examples/reference-harness`: a non-DSH MCP host for conformance;
  `scripts/verification/workspace-lane.py`: isolated real-helper lane.

### Fixed

- Stream authorization ignored the client (`authorization.decision` without
  `client:`): under a client-required policy every stream was refused and the
  mirror fell back to capture polling.
- A legacy `stream_start`/`stream_stop` from any client replaced/stopped the
  one stream of every other client.
- DSH: a session that observed without a prior `computer_use_status` ended in
  `UNVERIFIED_TARGET` and the PiP never showed the window; observations now
  carry the helper facts and the target's grant before any AX content.

### Changed (visible to 0.3.2 callers)

- Another client's observation no longer replaces your element handles.
- A timed-out or desynchronised mutating action is `OUTCOME_UNKNOWN`, not
  `COMPUTER_RUNTIME_UNAVAILABLE`, and is never resent.
- A verified document change refuses an old handle (`reason=document_changed`).

## Unreleased — helper 0.3.2 build 5 (projection filter + release, 2026-11-02)

### Fixed

- `computer_use_observe(filter=…)` could not find a control the helper had
  cut off by its element budget (Claude "Inicio": 61 returned, 24 skipped,
  `filter="Configuración"` → 0). The filter is pushed down as
  `observation.describe.element_filter`: non-matching controls consume no
  budget; the budget bounds the matches. Blank filter = previous behaviour.
- `observation.release` left a zeroed timestamp, so an old handle was refused
  with `age=<seconds since 1970>`. It now retires the generation; old handles
  are refused with `reason=released` (others `reason=stale_snapshot`), and
  the result reports `invalidated_snapshot` and the new `snapshot`.
- DSH projection names `released` / `stale_snapshot` (stateVersion 12).
- `USER_TAKEOVER` zeroed the observation time, so the next action on an old
  handle reported `reason=expired;age=<seconds since 1970>`. It now retires
  the generation with the same operation as `observation.release`
  (`invalidateObservation` → Shared `bridgeRetireObservation`): tables
  emptied, generation N+1, time = now; old handles are refused with
  `reason=released`, no age. When a takeover is detected, attribution,
  breach, settle and latch are unchanged.
- PiP title showed the bundle id (`com.anthropic.claudefordesktop`) when the
  CMM Console grant has no human name, although the observe had verified
  `target.name = "Claude"`. `pipPresentation` now uses `displayAppName`:
  verified target name, then a human grant name; with neither, the model
  marks `appGeneric` and the client shows the localized `appGeneric` string
  (es "Aplicación", en "Application"; the runtime picks no language). A
  bundle id is never the title and stays in `technical.target.bundle`.
  Display only: verification, grants and stateVersion 12 unchanged.
- `--serve-socket` truncated the UNIX socket path to 103 bytes
  (`path.utf8.prefix(103)`), so a longer path (a 127-byte harness lane under
  iCloud Drive) was bound somewhere other than where `unlink`, the probe and
  the client looked: the helper stayed alive and the client waited. The path
  is now validated in UTF-8 bytes against the real `sun_path` capacity
  (Shared `bridgeUnixSocketPathBytes`); a path that does not fit is a FATAL
  exit 2 before socket/probe/unlink/bind, and the probe never connects to a
  truncated address. Valid paths, including the canonical
  `~/.cmm/computer-bridge/bridge.sock`, behave as before.

## Unreleased — helper 0.3.1 build 4 (focus attribution, 2026-11-02)

### Fixed

- **False breach when the person takes the focus.** A click on the target (or
  ⌘-Tab to it) while an AX action on it was settling was latched as
  `INTERFERENCE_BREACH`. The helper now reads a read-only HID witness
  (seconds since the last mouse-down / ⌘-key / ⌘-release, combined hardware
  state) and attributes the change: correlated input within 0.75 s before the
  first in-front sample ⇒ `user` (no breach, no latch, snapshot invalidated,
  re-observe required); within 60 ms after ⇒ `ambiguous_external` (same); none
  ⇒ `action` (breach, as before); no reliable reading ⇒ `unknown` (breach,
  fail closed). Mouse movement never counts.
- Adapter renders `attribution:` and `USER_TAKEOVER:`; DSH projection drops
  the target without a breach (stateVersion 11).

## Unreleased — helper 0.3.0 + plugin (background hardening, 2026-11-02)

Fixes found in a live DeepSeek Harness session against Claude Desktop
(Electron). See `docs/architecture/CMM-Computer-Use-Informe-20261102.md`.

### Fixed

- **Background focus breach went unrecorded.** `ui.press` on Claude's zoom
  button made Claude frontmost; the ledger said `verdict=untouched`,
  `breach=false`. The sampler stopped when `AXUIElementPerformAction` returned
  and read only the cached `NSWorkspace.frontmostApplication`. It now samples
  through a bounded post-action settle window (0.8–2 s) and reads the live AX
  focused application and the window server's front-most window too.
- **A breach is fail-closed and stops.** It returns `INTERFERENCE_BREACH`
  (never success with a warning) and does not re-activate anything. The target
  is latched durably (`breach-latch.json`, survives restart) and audited
  (`breach-audit.jsonl`); DSH latches the session (stateVersion 10).
- PiP shows the observed application name (e.g. `Claude`), never the bundle
  id, for CMM Console grants without `name` (empty, NBSP, `windows=0`).
- `dist/client.js` was stale against `runtime.mjs` in the snapshot
  (`verify-manifest` failed); re-rendered.

### Added

- `breach.status` and `breach.rearm`: the only unlock of a latched breach, for a
  v2 client granted `"admin": ["breach.rearm"]` (CMM Console), with a reason,
  never by the client that caused it. The Console side is not implemented yet.
- `ui.scroll` / `computer_use_scroll`: accessibility-only scrolling (page
  action or scroll-bar value) or `CAPABILITY_UNSUPPORTED`. The global wheel
  tool is renamed `computer_use_pointer_scroll` (unrestricted only).
- Window controls (close/minimize/zoom/full screen) are refused in
  `background`/`focus` before anything runs (`reason=window_chrome`).
- Electron/Chromium AX tree materialization via `AXManualAccessibility` from
  the helper, verified by node count; `ax_tree: chrome_only|empty` is surfaced
  as `AX_TREE_UNAVAILABLE`.
- No-bypass policy: MCP `instructions`, a line on every refusal, and a DSH tool
  guard that refuses osascript/JXA/AppleScript/System Events/CGEvent/AX/Quartz/
  cliclick/`open -a` routes in sessions that used Computer Use.
- `scripts/verification/live-background-e2e.sh`: LIVE end-to-end check with an
  independent focus/cursor witness and a controlled late-activation breach in
  the fixture.

## Helper 0.2.0 — 2026-11-01

Helper-visible changes that ship with CMM Console 0.2.0. The plugin version is
unchanged: the wire protocol is still version 1, and every addition is optional.

### Added

- `policy.requirements.check` (contract version 1): compile a client requirement
  with the same Security APIs the enforcement path uses, and evaluate it against
  the calling process or a named code object. Read-only; adds no authority over
  what `codesign` already shows.
- `policy.status` now reports `load_error`, `invalid_clients`,
  `requirement_contract`, the caller's `peer` identity, and — per client — the
  load-time `requirement_valid` verdict plus `requirement_sha256` and
  `apps_sha256`. The requirement text itself is never echoed.
- `bridge.ping` advertises `client_authentication` and
  `requirement_validation`, so a host can tell "this helper cannot identify
  clients" from "no policy is loaded yet".

### Changed

- A version-2 document whose client requirement does not compile is refused as a
  whole (`load_error:"client_requirement_invalid"`, deny-all) instead of loading
  and silently denying that one client.
- The LaunchAgent runs `scripts/run-helper.sh`, which waits when the socket is
  already served instead of spawning a duplicate. The job definition gains
  `ThrottleInterval`. LaunchServices still owns the process: `open -n -W -g -a`
  is unchanged, so bundle identity and TCC attribution are untouched.

## [0.1.0] — 2026-10-28

First public release.

### Added

- `@cmm/dsh-computer-use`, a DeepSeek Harness bundle that connects Harness to
  `CMM Computer Use.app` through a stdio MCP adapter and a versioned Unix-socket
  protocol.
- Background-only interaction: no activation, no pointer events, no global
  keyboard. In `background` mode those tools are absent from the catalog rather
  than listed and refused.
- Live PiP mirror in the Harness Web UI, fed by a loopback streamer that reads
  the helper's cached `SCStream` frame. A stalled stream is labelled paused
  instead of being presented as live.
- Per-application allowlist with separate `observe` and `control` scopes and
  optional window title patterns, enforced in the helper, deny by default.
- Frame admission by lineage: same grant, bundle, pid, title and window id, a
  monotonic snapshot, and a capture emitted against the current target.
- Interference ledger on every action, separating what changed in the
  environment from what is attributable to the action.
- Helper build, install, notarization and uninstall scripts; a LaunchAgent that
  starts the helper through LaunchServices so ScreenCaptureKit attributes
  captures to it.

### Known limitations

- The helper ships built from source and locally signed. A `Developer ID`
  signature and notarization are not part of this release; the pipeline exists
  (`scripts/notarize-helper.sh`) but the credentials are the maintainer's.
- Tested against DeepSeek Harness 0.2.1-rc.3 only.
- A minimized window cannot be captured: `SCContentFilter` needs a backing
  store.
- Applications without a useful accessibility tree can be observed but not
  meaningfully driven.
