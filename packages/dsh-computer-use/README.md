# @cmm/dsh-computer-use

Background computer use for DeepSeek Harness: observe and operate authorized
macOS applications while the user keeps focus and the cursor.

This package is the Harness side of [CMM Computer Use](https://github.com/monteromartinchristian-blip/CMMComputerUse).
It ships two additive rows — an MCP client pointed at its own stdio adapter, and
a Host plugin that renders the live window mirror — and it needs the
`CMM Computer Use.app` helper installed on the same Mac.

```
DeepSeek Harness → @cmm/dsh-computer-use → CMM Computer Use.app → authorized macOS apps
```

## Install

```bash
dsh plugin --profile <profile> add @cmm/dsh-computer-use
```

The helper is a separate install: build it from the repository above
(`scripts/build-helper.sh --install && scripts/install-helper.sh`) and grant it
Screen Recording and Accessibility in System Settings.

## First run

Zero applications are authorized until you write
`~/.cmm/computer-bridge/policy.json`. The first tool call is refused with
`APP_NOT_AUTHORIZED`; that is the designed fail-closed start, not a fault.
[The permissions guide](https://github.com/monteromartinchristian-blip/CMMComputerUse/blob/main/docs/permissions.md)
documents the file format and the two scopes.

## What it exposes

| Tool | Class | What it does |
|---|---|---|
| `computer_use_status` | read | helper identity, permissions, effective mode, allowlist summary |
| `computer_use_list_apps` | read | the applications this deployment authorized |
| `computer_use_observe` | read | the accessibility tree of one window, bounded, with a snapshot generation |
| `computer_use_capture_window` | read | a PNG of one authorized window, with its identity |
| `computer_use_press` | control | `AXPress` on one resolved element of the observed window |
| `computer_use_set_value` | control | `AXSetValue` on one resolved element |
| `computer_use_release` | control | drop an observation |

In `background` mode the catalog contains exactly those. `activate_app`,
`focus_window`, `click`, `type_text`, `shortcut` and `scroll` are **absent**, not
listed and refused.

## Configuration

The patch resolves its own adapter path from the profile, so no path needs to be
written by hand. The socket follows the same precedence as the adapter:
`CMM_COMPUTER_BRIDGE_SOCKET`, else `~/.cmm/computer-bridge/bridge.sock`.

## License

See `LICENSE`.
