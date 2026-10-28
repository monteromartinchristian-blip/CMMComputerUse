# Changelog — @cmm/dsh-computer-use

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
the package adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
The full project changelog, including the macOS helper, lives in the repository.

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
