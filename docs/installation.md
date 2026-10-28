# Installation

Three things get installed, in this order: the macOS helper, the two
permissions it needs, and the Harness plugin.

```
CMM Computer Use.app  ── serves ──▶  ~/.cmm/computer-bridge/bridge.sock
                                          ▲
                    @cmm/dsh-computer-use ┘  (stdio MCP adapter)
```

## 1. The helper

### From source (the supported path for 0.1.0)

```bash
git clone https://github.com/monteromartinchristian-blip/CMMComputerUse.git
cd CMMComputerUse
scripts/build-helper.sh            # compiles and signs into build/
scripts/build-helper.sh --install  # copies to ~/Applications and refreshes LaunchServices
scripts/install-helper.sh          # writes the LaunchAgent and waits for the socket
```

`build-helper.sh` signs with, in order of preference: `$CMM_BRIDGE_SIGN_IDENTITY`,
a `Developer ID Application` identity in your keychain, an `Apple Development`
identity, or ad-hoc. Ad-hoc is loud on purpose: those grants do not survive a
rebuild, because the code signature is part of what macOS remembers.

Override the install location with `CMM_BRIDGE_INSTALL_DIR`. Keep it stable:
the bundle **path** is part of the TCC identity, so moving the app after
granting permissions makes macOS ask again.

### What `install-helper.sh` writes

`~/Library/LaunchAgents/com.cmm.chat.computer-use.plist`, a LaunchAgent whose
program arguments are:

```
/usr/bin/open -n -W -g -a ~/Applications/CMMComputerUse.app
  --args --serve-socket ~/.cmm/computer-bridge/bridge.sock
         --policy background
         --log-file ~/.cmm/computer-bridge/helper.log
```

`open -n -W -g` is not decoration. ScreenCaptureKit attributes a capture to the
*responsible* application of the process; a helper executed directly as
`Contents/MacOS/CMMComputerUse` has no responsible app and macOS attributes the
capture to the system UI agent instead. Launching through LaunchServices is
what makes the capture, the TCC prompt and the Control Center indicator all
name **CMM Computer Use**.

The script does **not** create a policy file. Until you write one, the helper
authorizes zero applications — that is the intended first state.

### Uninstall

```bash
scripts/uninstall-helper.sh           # job, plist, socket, app
scripts/uninstall-helper.sh --purge   # also ~/.cmm/computer-bridge (allowlist + log)
```

## 2. Permissions

Grant both, in System Settings → Privacy & Security, to **CMM Computer Use**:

- **Screen & System Audio Recording** — to capture the authorized window.
- **Accessibility** — to read the window's elements and act on them.

macOS shows the prompts the first time the helper tries. If you dismissed them,
open the panes manually; the app appears in the list after its first attempt.
Full detail, including how to authorize individual applications and how to
revoke, is in [permissions.md](permissions.md).

## 3. The plugin

### From the registry

```bash
dsh plugin --profile <profile> add @cmm/dsh-computer-use
```

### From a tarball

```bash
npm pack @cmm/dsh-computer-use           # or: npm pack ./packages/dsh-computer-use
dsh plugin --profile <profile> add "$PWD/cmm-dsh-computer-use-0.1.0.tgz"
```

### From a checkout

```bash
dsh plugin --profile <profile> add "$PWD/packages/dsh-computer-use"
```

A directory install is a `link:`: the profile keeps pointing at that path, so
do not move or delete the checkout while the profile uses it.

### What the install changes

Two additive rows in the profile's bundle layer:

| Row | Package | What it does |
|---|---|---|
| `cmm-computer-use` | `@deepseek-ai/dsh-mcp-client` | launches this package's stdio adapter with `--mode background` |
| `cmm-computer-use-panel` | `@cmm/dsh-computer-use` | session projection + the live PiP |

Nothing else in the profile is edited. The plugin does not write
`cordis.patch.yml` by hand, does not create files under `$DSH_HOME`, and does
not run a package manager behind your back — the DSH plugin manager does all
three.

## 4. First run

1. Open a conversation in Harness.
2. Ask for something that reads an authorized app, for example *"list the
   buttons in the TextEdit window named Untitled"*.
3. The first call is refused with `APP_NOT_AUTHORIZED`. That is the designed
   fail-closed start.
4. Write the allowlist (see [permissions.md](permissions.md)), restart the
   LaunchAgent, and ask again.

## Verifying the install

```bash
# the job is loaded and running
launchctl print gui/$(id -u)/com.cmm.chat.computer-use

# the helper answers, and says what it is allowed to touch
python3 - <<'PY'
import json, socket
s = socket.socket(socket.AF_UNIX); s.connect(f"{__import__('os').path.expanduser('~')}/.cmm/computer-bridge/bridge.sock")
s.sendall(json.dumps({"version":1,"id":"1","operation":"bridge.ping","arguments":{}}).encode()+b"\n")
print(json.dumps(json.loads(s.makefile().readline()), indent=2))
PY
```

`authorization.apps` is the number of authorized applications. `loaded: false`
means no policy file was found — fail-closed, and the reason the first tool call
is refused.
