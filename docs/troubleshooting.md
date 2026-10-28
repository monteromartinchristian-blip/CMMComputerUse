# Troubleshooting

## The first tool call is refused with `APP_NOT_AUTHORIZED`

**This is the designed first run.** The helper starts with zero authorized
applications. Write `~/.cmm/computer-bridge/policy.json` (format in
[permissions.md](permissions.md)) and restart the job:

```bash
launchctl kickstart -k gui/$(id -u)/com.cmm.chat.computer-use
```

Confirm it was read:

```bash
python3 - <<'PY'
import json, os, socket
s = socket.socket(socket.AF_UNIX); s.connect(os.path.expanduser("~/.cmm/computer-bridge/bridge.sock"))
s.sendall(json.dumps({"version":1,"id":"1","operation":"bridge.ping","arguments":{}}).encode()+b"\n")
print(json.loads(s.makefile().readline())["authorization"])
PY
# {'default': 'deny', 'apps': 1, 'loaded': True}
```

`loaded: false` means no file was found at the path the job was given. If you
passed `--policy-file` to `install-helper.sh`, check the path in the plist:

```bash
/usr/libexec/PlistBuddy -c "Print :ProgramArguments" ~/Library/LaunchAgents/com.cmm.chat.computer-use.plist
```

## The panel says "Permission not verified"

The helper measures its own TCC grants and reports them on `status`:

```
accessibility: False
screen_recording: False
```

Grant both in System Settings → Privacy & Security, then kickstart the job. If
the app does not appear in the list, run the helper once more — macOS adds the
entry after the first attempt, not before.

Two traps worth knowing:

- **Moving or rebuilding the app resets the grants.** The bundle path and the
  code signature are part of what macOS remembers. Rebuild in place, at the same
  path, with the same identity.
- **Ad-hoc signing means grants do not survive a rebuild at all.** The build
  script says so when it happens. Use a stable signing identity if you rebuild.

## "Computer bridge is not serving"

The adapter could not connect to the socket. Check, in this order:

```bash
launchctl print gui/$(id -u)/com.cmm.chat.computer-use | head -20
ls -l ~/.cmm/computer-bridge/bridge.sock
tail -20 ~/.cmm/computer-bridge/helper.log
```

- **No plist loaded** → run `scripts/install-helper.sh`.
- **Socket missing** → the helper exited at startup. The log says why; the most
  common cause is another process already serving that path (the helper refuses
  to share a socket).
- **Socket present but nobody answers** → a stale socket. Stop the job, remove
  the socket file, start the job again.

## The job restarts in a loop

Almost always a second helper holding the socket. `launchctl print` shows
`last exit status`; the log line is `another helper already serves …`.

```bash
pkill -f "CMMComputerUse.app/Contents/MacOS/CMMComputerUse"
launchctl kickstart -k gui/$(id -u)/com.cmm.chat.computer-use
```

## The mirror shows "View paused" over a still picture

By design, a frozen stream is labelled rather than presented as live. The
streamer publishes its own counters at
`http://127.0.0.1:47183/stream/status?token=cmm-cu-live`:

```bash
curl -s 'http://127.0.0.1:47183/stream/status?token=cmm-cu-live'
# {"ok":true,"frames":412,"lastFrameAt":…,"viewers":1,"mode":"live",…}
```

- `frames` advancing, `mode: "live"` → healthy; a paused label means the panel
  lost the stream and is re-arming.
- `mode: "fallback"` → the helper does not offer a live stream (older build), and
  the panel is capturing one frame at a time.
- Connection refused → the streamer child is not running. Restart Harness; if it
  persists, check that port 47183 is free:

  ```bash
  lsof -nP -iTCP:47183 -sTCP:LISTEN
  ```

  The streamer does not reclaim a busy port, so a leftover process from another
  render keeps the mirror dead until it is freed.

## "Target not in background"

`background` mode only works on a window that is **not** frontmost. An
`observe` that returns the target as `(frontmost)` is refused rather than
silently switching modes. Bring another application to the front, or target a
window of an app that is already behind.

## The observation list stops at 40 elements

The list is bounded. `computer_use_observe` accepts a `filter` (substring of
title, value or role, case-insensitive); when you pass one it shows **every**
match with its `element_id` instead of the first 40.

Tool schemas are read when the MCP server starts: after changing the plugin,
restart Harness so a new parameter is visible.

## A capture is refused as `UNVERIFIED_CAPTURE`

The frame reached the model without provenance the panel can check. The order
is `status → observe → capture`: a capture with no preceding observation has
snapshot generation `0` and is refused by design. If the panel shows this while
the mirror clearly works, the mirror is not the evidence — the admitted
attachment is.

## `plugin_is_trial` / bundle does not appear in Harness

Check that the profile actually declares the bundle:

```bash
dsh --profile <profile> --dump-config | grep -A6 cmm-computer-use
```

`dsh plugin remove` is a package-manager operation: it drops the dependency but
can leave the bundle selected in `dsh.profile.bundles`. If the row is missing
after a reinstall, the bundle is still listed but cannot load; deselect it in
the Plugins page (or with the plugin manager) before installing again.

## Nothing helps: collect the three facts

```bash
launchctl print gui/$(id -u)/com.cmm.chat.computer-use | head -30
tail -50 ~/.cmm/computer-bridge/helper.log
codesign -dv --verbose=4 ~/Applications/CMMComputerUse.app 2>&1 | head -12
```

Those three answer "is the job loaded", "what did the helper say", and "is this
the binary whose grants macOS remembers".
