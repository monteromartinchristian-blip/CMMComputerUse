# Permissions and authorization

Two different locks stand between the plugin and an application. Both must be
open, and neither can be opened by the plugin.

```
macOS TCC grant  ──▶  can the helper read the screen / drive the machine at all?
helper allowlist  ──▶  may THIS client touch THIS application, for THESE scopes?
```

## 1. The macOS grants

macOS grants permissions to a **process identity**, not to a feature. The helper
is the identity: `com.cmm.chat.computer-use`, visible as **CMM Computer Use**.

| Grant | Why it is needed | What it allows |
|---|---|---|
| **Screen & System Audio Recording** | `ScreenCaptureKit` capture of the authorized window, and the live mirror | Read the pixels of any window the helper is told to capture |
| **Accessibility** | The AX tree: element roles, titles, values, and `AXPress` / `AXSetValue` | Read and drive the UI of every application |

Neither grant can be narrowed by macOS to one application. That is not a bug in
this product; it is how TCC works. The allowlist below is the narrowing.

### Granting

1. Run the helper once (`scripts/install-helper.sh` does this).
2. System Settings → Privacy & Security → **Screen & System Audio Recording** →
   enable **CMM Computer Use**.
3. System Settings → Privacy & Security → **Accessibility** → enable
   **CMM Computer Use**.
4. Restart the job so the helper re-reads its permissions:

   ```bash
   launchctl kickstart -k gui/$(id -u)/com.cmm.chat.computer-use
   ```

The helper reports what it measured on every `status` call:

```
accessibility: True
screen_recording: True
```

`False` means the grant is missing or was revoked; the plugin will refuse work
rather than proceed blind.

### Revoking

Turn either switch off in the same panes. Work stops on the next call. To remove
the entries entirely, uninstall the helper first and then press `−` — macOS
keeps a list entry for a bundle id until a person removes it.

Nothing here is hidden: macOS shows its own Screen Recording indicator in the
menu bar while a capture stream is open, and this product does not — and cannot
— suppress it.

## 2. The helper's allowlist

The allowlist is a JSON file the helper reads at startup:

```
~/.cmm/computer-bridge/policy.json          # default
--policy-file <path>                        # or an explicit path, via the LaunchAgent
```

**Fail-closed rules.** No file, an unreadable file, a malformed file, an unknown
`version`, a `default` other than `deny`, an unknown scope, or a grant with
neither a bundle id nor a name: the whole document is rejected and the helper
authorizes nothing. A typo is never silently reinterpreted as permission.

### Format

```json
{
  "version": 1,
  "mode": "background",
  "default": "deny",
  "apps": [
    {
      "bundle_id": "com.apple.TextEdit",
      "name": "TextEdit",
      "scopes": ["observe", "control"],
      "windows": ["Untitled", "Notes"]
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `version` | Must be `1`. |
| `mode` | `background`, `focus` or `unrestricted`. The effective mode is the **stricter** of this and what the client asked for; a client can never widen it. |
| `default` | Only `deny` is accepted in version 1. |
| `apps[].bundle_id` | Exact bundle id, case-insensitive. Preferred over `name`. |
| `apps[].name` | Exact display name, as macOS reports it. Used when no bundle id is given. |
| `apps[].scopes` | `observe` (read the tree, capture the window) and/or `control` (press, set value). Observe never implies control. |
| `apps[].windows` | Title fragments this grant covers. Empty or absent means *any window of that app*; a named list means only those. An empty window title never matches a named list. |

### What each mode allows

| Action class | `background` | `focus` | `unrestricted` |
|---|---|---|---|
| Accessibility (`ui.press`, `ui.set_value`) | yes | yes | yes |
| Focus (`app.open`, `app.activate`, `window.focus`) | **refused** | yes | yes |
| Pointer (`pointer.click`, `pointer.scroll`) | **refused** | **refused** | refused under an allowlist |
| Global keyboard (`keyboard.type`, `keyboard.shortcut`) | **refused** | **refused** | refused under an allowlist |

Two entries deserve the emphasis: pointer and keyboard are *global* — a click at
a coordinate reaches whatever is on top, and a keystroke reaches whatever holds
focus. Under an allowlist they are refused even in `unrestricted`, because they
cannot be scoped to the application the user authorized.

The plugin always asks for `background`. The LaunchAgent also pins
`--policy background`. Widening either is a deliberate edit of two files, not a
setting you can flip by accident.

### Applying a change

The policy is read at startup. `policy.reload` re-reads it without restarting
the process, and it can only re-apply `min(launch flag, file mode)` — a reload
never widens what the process was launched with.

```bash
launchctl kickstart -k gui/$(id -u)/com.cmm.chat.computer-use    # or: policy.reload
```

Then confirm what the helper actually loaded:

```bash
# authorization.apps is the number of grants; authorization.loaded tells you
# whether a file was read at all
python3 - <<'PY'
import json, os, socket
path = os.path.expanduser("~/.cmm/computer-bridge/bridge.sock")
s = socket.socket(socket.AF_UNIX); s.connect(path)
s.sendall(json.dumps({"version": 1, "id": "1", "operation": "bridge.ping", "arguments": {}}).encode() + b"\n")
print(json.loads(s.makefile().readline())["authorization"])
PY
```

`authorization.apps` counts grants, not applications you have open. A grant for
an app that is not running still counts; it simply matches nothing yet.
