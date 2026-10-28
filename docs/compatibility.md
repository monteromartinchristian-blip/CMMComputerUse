# Compatibility

## Supported

| Component | Version | How it was verified |
|---|---|---|
| DeepSeek Harness | **0.2.1-rc.3** | plugin installed into a clean profile with `dsh plugin add`, composed, activated, and its tool catalog exercised |
| macOS | **26.7.1** (Tahoe), Apple silicon | helper built, signed, launched through LaunchServices, captured and driven |
| Python (adapter) | **3.9** (`/usr/bin/python3`) | the full adapter test suite runs on it |
| Node (Host/Client) | the runtime inside Harness | `official-host.cjs` loads `dist/client.js` against the installed host registry |

That is the whole list. A build that is not in this table has not been tested,
whatever it does.

## Declared range

`package.json` declares:

```json
"engines": { "dsh": ">=0.2.1-rc.3 <0.3.0" }
```

The upper bound is honest rather than aspirational: DSH's plugin API is young,
and the next minor line may change the Host contracts this package uses
(`sessionProjections`, `tools.guard`, `shell.overlay`). Harness enforces this
range at install time and refuses a build outside it, unless you grant an
explicit per-version exemption.

## What "tested" covers

- Bundle installation, composition and activation in a profile that started
  without it.
- The MCP row launching the adapter with the paths the patch resolves.
- The tool catalog in `background` mode: no focus, pointer or global keyboard
  tool is advertised.
- A helper that is absent, and a helper that is present but authorizes nothing:
  both produce a typed tool error, not a host failure.
- The PiP projection, checkpoint round-trip and client registration against the
  installed host code.
- Fail-closed refusal of an unauthorized application, from the adapter to the
  model.

## What "tested" does not cover

- Any Harness build other than 0.2.1-rc.3.
- Intel Macs. The build script targets `arm64` only.
- macOS 15 (Sequoia) at runtime. The deployment target is 15.0 and the code uses
  no Tahoe-only API, but the shipped verification ran on 26.7.1.
- A window that is minimized: `SCContentFilter(desktopIndependentWindow:)` has
  no backing store for it, so capture is not promised.
- Applications that expose no useful accessibility tree (some Electron apps
  return an empty AX tree). `observe` reports what exists; it does not invent
  elements.

## Helper version vs plugin version

They move independently. The helper reports its identity on every `status`:

```
helper: cmm-computer-use protocol=1
bundle: com.cmm.chat.computer-use
deployment_policy: background
effective_mode: background
```

The bundle id is deliberately unchanged from earlier internal builds: it **is**
the TCC designated requirement, and renaming it would silently void every grant
the person already made.

## Upgrading

The helper and the plugin can be upgraded separately, but not in any order:

1. Upgrade the helper first (`scripts/build-helper.sh --install`). It speaks the
   same `protocol=1`, so an older plugin keeps working.
2. Upgrade the plugin.
3. If the policy format ever changes, `version` in `policy.json` changes with it,
   and an old file is rejected whole rather than partially honoured.
