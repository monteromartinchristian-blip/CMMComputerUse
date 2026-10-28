# Security policy

## Reporting a vulnerability

Open a private security advisory on the GitHub repository, or email the
maintainer listed in `package.json`. Do not open a public issue for a
vulnerability that lets someone read a window, act on an application, or bypass
the allowlist.

Expect an acknowledgement within a few days. There is no bug bounty.

## What this product can do, and to what

`CMM Computer Use.app` is granted **Screen Recording** and **Accessibility** by
a person. With those grants, the helper process can read and drive every
application on the machine. That is the platform's granularity, not a design
choice of this product.

Everything below is about narrowing that to what a caller actually asked for.

| Control | Where it is enforced |
|---|---|
| Per-application allowlist, deny by default | `apps/macos/Shared/ComputerUseAuthorization.swift` |
| Scope separation (`observe` ≠ `control`) | same file |
| Window title patterns per grant | same file |
| Interaction mode, `min(requested, launch)` | `apps/macos/Shared/ComputerUsePolicy.swift` |
| No pointer / global keyboard under an allowlist, even in `unrestricted` | `ComputerUsePolicy.swift` |
| No focus, pointer or keyboard tools advertised in `background` | `packages/dsh-computer-use/adapter/cmm_computer_use/mcp_server.py` |
| Frame provenance (bundle, pid, title, window id, snapshot lineage) | `packages/dsh-computer-use/runtime.mjs` |
| Bounded payloads (1 MiB, 4096 per side, 8 Mpx) | `runtime.mjs` |
| Socket in a `0700` directory, no TCP control path | `apps/macos/CMMComputerUse/main.swift`, `scripts/install-helper.sh` |

## Fail-closed behaviour, by construction

These are the states that look like breakage and are actually the product
working:

- **No `policy.json`** → zero authorized applications.
- **Malformed `policy.json`** → the whole document is rejected; no partial grants.
- **Unknown `mode`**, **unknown scope**, **`default` other than `deny`** →
  rejected.
- **Unknown tool name** in an action → refused, never coerced into something
  close.
- **Capture without a preceding observation** → snapshot generation 0, refused by
  the projection.
- **A frame from another window, app, pid or session** → refused; a changed
  `window_id` is `window_changed`, never an implicit retarget.
- **A verified interference breach** → further Computer Use calls are denied for
  the rest of that session.

## What is deliberately not protected

- **A person who authorizes an application they did not intend to.** The product
  shows what is authorized on every `status`; it cannot know intent.
- **A model that asks for something harmful inside an authorized app.** The
  allowlist decides *which* applications; it does not review *what* is done
  inside them. Read what the agent did in the transcript.
- **Another process running as the same user.** It can read the socket path and
  connect. The helper answers it with the same policy; it cannot tell "your"
  adapter from "your" other program.
- **The mirror against a local attacker who can bind ports.** The token is fixed
  and published in the docs; it keeps a random web page out, not a local process
  that can already read your files.

## Operational guidance

- Keep the helper's bundle path and signing identity stable; TCC remembers both.
- Prefer `background` mode and a narrow allowlist with explicit window patterns.
- Read `helper.log` after unusual behaviour: refusals are recorded with their
  code and the requirement that was missing.
- Revoke the grants in System Settings when you stop using the product; uninstall
  does not and cannot do it for you.
