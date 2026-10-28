# Privacy

## What this product collects

Nothing.

There is no telemetry, no analytics, no crash reporting, no usage counter and no
update check. The plugin makes exactly one kind of network connection: none. It
talks to a Unix socket on the same machine.

## Where data goes

```
authorized app  ──AX/ScreenCaptureKit──▶  helper  ──Unix socket──▶  adapter
                                                                      │ stdio
                                                                      ▼
                                                            DeepSeek Harness
                                                                      │
                                                                      ▼
                                                     the model provider YOU configured
```

The last hop is the one to think about. A capture, an observation or a window
title becomes part of the conversation, and the conversation goes wherever your
Harness profile sends it. This plugin does not add a destination, does not
redact and does not cache anything outside your own machine.

## What stays on disk

| Path | Contents | Lifetime |
|---|---|---|
| `~/.cmm/computer-bridge/policy.json` | the allowlist you wrote | until you delete it |
| `~/.cmm/computer-bridge/bridge.sock` | the socket (mode `0700` directory) | until the job stops |
| `~/.cmm/computer-bridge/helper.log` | helper diagnostics: permission state, refusals, stream events. No pixels, no AX text, no secrets. | until you delete it |
| `~/Library/LaunchAgents/com.cmm.chat.computer-use.plist` | the job definition | until uninstall |

Captures are held in memory only: the helper's frame cache, the live mirror's
last frame, and the attachment the Harness store keeps according to its own
retention. Neither the helper nor this plugin writes an image to disk.

## What is never collected

- Keystrokes. The global keyboard tools are not advertised in the supported
  mode, and the helper refuses them under an allowlist.
- The contents of applications you did not authorize. The helper reads only the
  window it was told about, and refuses an application that is not in the
  allowlist before it touches anything.
- Credentials, tokens or environment variables. The MCP transport scrubs
  credential-shaped names from the inherited environment before the adapter
  runs.

## Revoking

Remove the grant in System Settings and the work stops. Remove the allowlist
entry and that application is invisible again. `scripts/uninstall-helper.sh
--purge` deletes the directory above, including the log.

Nothing here phones home to report that you did so.
