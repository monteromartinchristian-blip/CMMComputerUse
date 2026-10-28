# Contributing

## Before you start

This repository builds a macOS helper that holds Screen Recording and
Accessibility grants. A careless change to the policy or the authorization rules
is a security change, not a style change. Read
[docs/architecture.md](docs/architecture.md) first, then
[docs/computer-bridge-protocol.md](docs/computer-bridge-protocol.md).

## Ground rules

1. **One engine.** Do not add a second Swift helper, a second transport, or a
   daemon that wraps the existing one.
2. **Additive protocol changes only.** The socket speaks `version: 1`. New facts
   go in `detail`; new codes are not invented, because clients collapse unknown
   codes.
3. **A refusal is a result.** Refuse before executing, with a code the model can
   read. Never execute first and report after.
4. **No new personal data in the tree.** No absolute home paths, no machine
   names, no session identifiers, no logs, no captures.
5. **Do not weaken a test to make a change pass.** If a test pins a product
   claim, change the claim deliberately, in the same commit, with a reason.

## Building and testing

```bash
# Swift
cd apps/macos
xcodegen generate                       # project.yml is the source of truth
xcodebuild test -project CMMComputerUse.xcodeproj -scheme CMMComputerUse \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO

# Host/Client + PiP
cd packages/dsh-computer-use
node --test tests/*.test.mjs
node scripts/render-client.mjs --check   # dist/client.js must be current

# Adapter
cd packages/dsh-computer-use/adapter
python3 -m unittest discover -s tests

# Everything
scripts/verify-release.sh
```

`client.js` is generated: edit `client.template.js`, `runtime.mjs` or the locale
files, then run `node scripts/render-client.mjs` and commit both.

## What a change needs

- A test that fails before and passes after, for anything behavioural.
- For a policy change: a test that names the product claim it pins, in the same
  file that enforces it.
- For a protocol change: the version rule above, and an update to the protocol
  document.
- For a UI change: what the panel shows in the idle, waiting, live, paused and
  error states, because those are the states people actually see.

## Commits and pull requests

Conventional commit subjects (`fix:`, `feat:`, `docs:`, `test:`, `chore:`), one
logical change per commit, and a pull request that says what you verified and
how. Say plainly what you did *not* verify.

Signing: the helper keeps a stable TCC identity across rebuilds only if the
signing identity is stable. Do not commit a signing identity or a team id.

## Reporting

Security issues: see [SECURITY.md](SECURITY.md), not the issue tracker.
