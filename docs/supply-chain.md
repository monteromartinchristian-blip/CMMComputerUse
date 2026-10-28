# Supply chain

## What ships

One npm package, `@cmm/dsh-computer-use`, and one macOS application built from
source in this repository. There is no binary blob without a source, and no
postinstall script.

## Package contents

`package.json` declares `files` explicitly — the published tarball is the list,
not "everything except .npmignore":

```
index.js  runtime.mjs  dist/client.js  cordis.patch.yml
locale/en.json  locale/es.json  icon.svg
adapter/serve.sh  adapter/cmm_computer_use/{__init__,client,mcp_server}.py
README.md  CHANGELOG.md  LICENSE
```

`npm pack --dry-run` is the authority; `scripts/verify-manifest.mjs` fails when a
`files` entry matches nothing, which is how a tarball loses a module that only
breaks at load time.

## Dependencies

**None.** The npm package has no `dependencies` and no `devDependencies`: the
Host/Client code uses only Node built-ins and the packages Harness already
ships (`@deepseek-ai/dsh-client-ui-layout`, `@deepseek-ai/dsh-client-ui-session`,
`@deepseek-ai/dsh-mcp-client`). The Python adapter is stdlib-only.

No lockfile is shipped because there is nothing to lock. If a future version
adds a dependency, it ships a lockfile and pinned ranges in the same release.

## Install-time behaviour

- **No `postinstall`.** Nothing runs when you install the package.
- **No downloads at runtime.** The adapter starts `python3` from the package's
  own `adapter/` directory; it fetches nothing.
- **No writes outside the profile.** The DSH plugin manager owns installation;
  this package never edits `cordis.patch.yml`, `package.json` or `$DSH_HOME`
  itself.
- **LaunchServices registration** happens only in `scripts/build-helper.sh
  --install`, on the app you just built, and is what makes TCC ask about the
  right name.

## Verifying what you got

```bash
# tarball integrity
npm pack --dry-run
shasum -a 256 cmm-dsh-computer-use-0.1.0.tgz

# the published files are the ones in the manifest
node packages/dsh-computer-use/scripts/verify-manifest.mjs

# the client is the render of the template it claims
node packages/dsh-computer-use/scripts/render-client.mjs --check

# helper signature: what identity, what flags, what requirement
codesign -dv --verbose=4 ~/Applications/CMMComputerUse.app
codesign -d --requirements - ~/Applications/CMMComputerUse.app
```

A `Developer ID Application` signature without notarization is still refused by
Gatekeeper on a machine that did not build it. `scripts/notarize-helper.sh`
performs the notarization and stapling when the credentials exist; until then,
the helper is a locally-built, locally-signed binary and the project says so
rather than pretending otherwise.

## Threat model, briefly

| Threat | What stops it |
|---|---|
| Another local process talks to the helper | The socket lives in a `0700` directory owned by the user |
| A malicious page reads the mirror | The mirror binds `127.0.0.1` and requires a fixed token; a page that cannot reach loopback cannot read it |
| A prompt-injected model touches an app you did not authorize | The allowlist is enforced by the helper, not by the plugin; the model cannot widen it |
| A capture of the wrong window is passed as evidence | Admission is by lineage (grant, bundle, pid, title, window id, monotonic snapshot), and the projection refuses the rest |
| A compromised npm dependency | There are no dependencies |
| A tampered helper binary | The code signature is the TCC designated requirement: a different signature means no grants |

Not protected: a user who grants Screen Recording and Accessibility to a
different application, or who authorizes an application they did not mean to.
Those are decisions the product lets people make.
