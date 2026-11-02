# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The helper and the plugin version independently; this file tracks the plugin
(`@cmm/dsh-computer-use`) and notes helper-visible changes explicitly.

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
- **A breach is fail-closed.** It returns `INTERFERENCE_BREACH` (never success
  with a warning), asks the person's previous app back, and latches the target
  in the helper until restart; DSH latches the session (stateVersion 10).
- PiP shows the observed application name (e.g. `Claude`), never the bundle
  id, for CMM Console grants without `name` (empty, NBSP, `windows=0`).
- `dist/client.js` was stale against `runtime.mjs` in the snapshot
  (`verify-manifest` failed); re-rendered.

### Added

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
