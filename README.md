# CMM Computer Use for DeepSeek Harness

**DeepSeek Harness can observe and operate authorized macOS applications in the
background while you keep the focus and the cursor.**

Most computer-use integrations work by taking over: they activate the app,
move the pointer, and type into whatever is in front. That makes the machine
unusable while an agent works, and it makes every action ambiguous — you can
never tell whether a click came from you or from the model.

This plugin takes the other route. It talks to a small, signed macOS helper
that reads one authorized window through the Accessibility API and
ScreenCaptureKit, and acts on that window's elements directly. Nothing is
brought to the front, nothing is posted to the pointer, and no global keystroke
is ever synthesised.

```
DeepSeek Harness → @cmm/dsh-computer-use → CMM Computer Use.app → authorized macOS apps
```

## What is different

| Property | What it means in practice |
|---|---|
| **Background computer use** | Actions target a specific window, not "whatever is frontmost". You keep working in another app. |
| **No cursor hijacking** | The adapter never posts pointer events. In `background` mode it does not even advertise a click or drag tool. |
| **No focus stealing** | No `activate`, no `focus`, no window raising. The helper's ledger records what the environment did versus what the action did. |
| **Live PiP mirror** | A floating panel shows the authorized window as the agent works. A frozen stream is labelled as paused, never presented as live. |
| **Window-scoped capture** | Capture is bound to one window id, so a tab change does not silently retarget the mirror. |
| **Semantic Accessibility actions** | `press` and `set_value` on resolved elements, not pixel coordinates. |
| **Attachment provenance** | A capture only reaches the model with the identity of the window it came from, its pid and its snapshot generation. |
| **Fail-closed authorization** | Zero apps are authorized until you write an allowlist. A missing, unreadable or malformed policy means "no access", never "allow everything". |

## Requirements

- macOS 15 (Sequoia) or later, Apple silicon.
- DeepSeek Harness 0.2.1-rc.3 (the only version this release was tested
  against — see [docs/compatibility.md](docs/compatibility.md)).
- Xcode Command Line Tools (`xcode-select --install`) for `python3`, or any
  Python 3.9+ reachable as `python3`.
- Screen Recording and Accessibility grants for **CMM Computer Use** — macOS
  asks once, in System Settings.

## Install

Three steps. None of them touches your Harness profile by hand.

```bash
# 1. Build and install the helper (compiles from source, signs locally)
git clone https://github.com/monteromartinchristian-blip/CMMComputerUse.git
cd CMMComputerUse
scripts/build-helper.sh --install
scripts/install-helper.sh

# 2. Grant the two permissions when macOS asks (see docs/permissions.md)

# 3. Install the plugin into a Harness profile
dsh plugin --profile <profile> add @cmm/dsh-computer-use
```

Then open a conversation in Harness and ask it to look at an app you have
authorized. The first tool call is refused until you write the allowlist —
that is the designed first run, not a failure.

Full instructions, including the from-tarball and from-checkout paths, are in
[docs/installation.md](docs/installation.md).

## Permissions, in one paragraph

The helper needs **Screen Recording** (Screen & System Audio Recording) to
capture the window it is told to capture, and **Accessibility** to read and act
on that window's elements. Both are granted to the app, by you, in System
Settings; the plugin cannot grant them and does not try. Neither grant is
scoped by macOS to a single application — which is exactly why the helper
carries its own per-app allowlist on top. Revoking either grant stops all work
immediately. Details, including how to authorize and revoke individual apps,
are in [docs/permissions.md](docs/permissions.md).

## Security model

- **Deny by default.** No allowlist, no access. The helper starts with zero
  authorized applications.
- **Separate scopes.** `observe` (read the tree, capture the window) does not
  imply `control` (press, set value).
- **A local socket, not a port.** The helper serves a Unix socket in a `0700`
  directory. There is no TCP listener, no HTTP endpoint and no FIFO.
- **No ambient elevation.** The plugin does not write `launchctl setenv`, does
  not install a global allowlist and does not modify your profile.
- **Bounded results.** Captures are capped in size, observations are bounded in
  element count, and the projection refuses a frame whose attachment does not
  match its declared media type and dimensions.

The threat model, the exact bounds and what is deliberately *not* protected are
in [SECURITY.md](SECURITY.md).

## Privacy

The plugin collects nothing and sends nothing anywhere. There is no telemetry,
no analytics and no update check. Captures stay on the machine and are handed
to the model you configured in Harness. See [docs/privacy.md](docs/privacy.md).

## Troubleshooting

The two failures people actually hit — "no authorized applications" and
"permission not verified" — and their fixes are in
[docs/troubleshooting.md](docs/troubleshooting.md).

## Uninstall

```bash
dsh plugin --profile <profile> remove @cmm/dsh-computer-use
scripts/uninstall-helper.sh            # add --purge to drop the allowlist too
```

Then revoke the two grants in System Settings. The plugin never removes them
for you; macOS only lets a person do that.

## Compatibility

| Component | Tested |
|---|---|
| DeepSeek Harness | 0.2.1-rc.3 |
| macOS | 26.7.1 (Tahoe) on Apple silicon |
| Python (adapter) | 3.9 (system `/usr/bin/python3`) |
| Node (Host/Client) | the runtime shipped inside Harness |

A version that is not in this table is not supported, whatever it does. See
[docs/compatibility.md](docs/compatibility.md) for what "tested" covered.

## Development

```bash
# Swift: the policy, targeting and authorization rules
cd apps/macos && xcodegen generate
xcodebuild test -project CMMComputerUse.xcodeproj -scheme CMMComputerUse \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO

# Host/Client projection and PiP
cd packages/dsh-computer-use && node --test tests/*.test.mjs

# Adapter (real NDJSON over a real Unix socket, scripted helper)
cd packages/dsh-computer-use/adapter && python3 -m unittest discover -s tests

# Everything, including the manifest and the rendered client
scripts/verify-release.sh
```

Architecture, module map and the reason for each layer:
[docs/architecture.md](docs/architecture.md). The wire protocol is a separate,
versioned contract: [docs/computer-bridge-protocol.md](docs/computer-bridge-protocol.md).

## License

MIT. See [LICENSE](LICENSE).
