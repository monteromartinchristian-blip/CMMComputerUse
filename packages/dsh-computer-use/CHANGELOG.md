# Changelog — @cmm/dsh-computer-use

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
the package adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
The full project changelog, including the macOS helper, lives in the repository.

## Unreleased

- X-01: the live-mirror token is random per start (256 bits), handed to the streamer
  through stdin and to the renderer through the projection view; no fixed token
  ships in the package. See the repository CHANGELOG.

- Version 0.3.3 (package and adapter agree). `HELPER_TOO_OLD` refusals when the
  helper lacks a capability; `computer_use_status` shows adapter and helper
  versions and features. Tool budget of 55 s under DSH's 70 s cut; waits capped
  at 45 s and never resent. `computer_use_observe` takes `window_id`. The PiP
  streamer grants CORS only to `dsh-app:` origins and checks `Host`. See the
  repository changelog for the helper-side fixes of the 2026-11-05 audit.

- F-09 browser and downloads: `computer_use_browser_state`, `_browser_wait`,
  `_browser_select_tab`, `_download`, `_download_expect`, `_download_status`,
  `_save_dialog`. The PiP mirror keeps its stream across tab switches and
  navigation (same window id); page changes and download steps keep the panel.

- 0.3.3 Multi-App Workspace: optional `context` on observe / capture / press /
  set_value / scroll / release; `computer_use_workspace_status`,
  `computer_use_context_open`, `computer_use_context_close`; `execution` line on
  every action; `OUTCOME_UNKNOWN` (never resent) after a lost answer; reads
  retried with backoff. Split PiP (panels A/B) with a per-slot streamer;
  projection `stateVersion` 13. Observations carry the helper facts so the PiP
  shows a target observed without a prior status call.

- `computer_use_scroll` is now the accessibility-only scroll (all modes); the
  global wheel tool is `computer_use_pointer_scroll` (unrestricted only).
- `INTERFERENCE_BREACH`, window-raised breaches and the helper's breach latch
  all latch the session; projection `stateVersion` 10.
- Tool guard refuses scripting / synthetic-input bypasses in Computer Use
  sessions; MCP `instructions` state the no-bypass policy.
- Observation text reports `ax_enrichment`, `AX_TREE_UNAVAILABLE`, window
  controls and scrollability.

## [0.1.0] — 2026-10-28

First public release.

- Bundle with two additive rows: `@deepseek-ai/dsh-mcp-client` pointed at this
  package's stdio adapter, and a Host plugin that registers the session
  projection and the live window mirror.
- Adapter tools: `status`, `list_apps`, `observe`, `capture_window`, `press`,
  `set_value`, `release`. Fixed `background` mode: no activate, focus, pointer or
  global keyboard tool is advertised.
- Frame admission by lineage (grant, bundle, pid, title, window id, monotonic
  snapshot); stale, cross-target and cross-session frames are refused.
- Live PiP mirror with honest liveness: a stalled stream is labelled paused, and
  the label follows the pixels without ever granting read access.
- Fail-closed: the adapter reports what the helper measured and refuses to act
  on an application the helper did not authorize.
