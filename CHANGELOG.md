# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The helper and the plugin version independently; this file tracks the plugin
(`@cmm/dsh-computer-use`) and notes helper-visible changes explicitly.

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
