# Client authentication (protocol v2)

Status: implemented in the helper. Additive: a version-1 policy keeps working
exactly as before.

## The problem

Version 1 authorizes **applications**. It says nothing about **which program** may
connect, so the only boundary is the file system: the socket lives in
`~/.cmm/computer-bridge/`, mode `0700`, and any process running as that user can
connect. That is a defensible single-operator model and an unacceptable one as
soon as a machine runs more than one agent, because "agent A may read the
rehearsal app" is a different question from "the rehearsal app is authorized".

## What is trusted

A request field is never an identity. `"client_id": "cmm-console"` in a payload is
a string the caller invented. The identity is resolved from the kernel and the
peer's code signature:

| Step | Mechanism | Failure mode |
|---|---|---|
| Same user | `getpeereid` | not same user → no identity |
| Which process | `LOCAL_PEERTOKEN` (audit token); `LOCAL_PEERPID` only as fallback | no token and no pid → no identity |
| Its code object | `SecCodeCopyGuestWithAttributes` (audit token, not pid) | no `SecCode` → no identity |
| Signature valid | `SecCodeCheckValidity` | invalid signature → refused |
| Listed in the policy | `SecRequirementCreateWithString` + `SecCodeCheckValidity` per client | no match → refused |

The audit token is used rather than the pid because a pid can be recycled between
`accept()` and the lookup.

## Policy shape

```json
{
  "version": 2,
  "mode": "background",
  "default": "deny",
  "clients": [
    {
      "client_id": "cmm-console",
      "requirement": "identifier \"com.cmm.console\" and anchor apple generic and certificate leaf[subject.OU] = \"TEAMID\"",
      "apps": ["com.example.rehearsal"],
      "scopes": ["observe"]
    }
  ],
  "apps": [
    { "bundle_id": "com.example.rehearsal", "scopes": ["observe", "control"] }
  ]
}
```

| Field | Meaning |
|---|---|
| `client_id` | Diagnostic label. Never the decision. |
| `requirement` | Code-signing designated requirement. The only load-bearing field. |
| `apps` | Exact bundle ids or exact display names. **Empty means none.** |
| `scopes` | `observe` and/or `control`. |

Enforcement is the intersection:

```
allowed = application_grant(client's target) ∩ client_grant(peer identity)
```

Neither side implies the other. A client with `control` on an application the
deployment only grants `observe` is refused with `scope_not_granted`; the reverse
is refused with `client_scope_not_granted`.

## Which operations need a client

| Operation | Needs a client identity |
|---|---|
| `apps.list` | yes — the list of authorized applications is information |
| `observation.*` | yes, plus the application's `observe` |
| `action.execute` | yes, plus the application's `control` |
| `bridge.ping`, `policy.status`, `policy.reload`, `permissions.status` | no — diagnostics. `policy.status` reports whether the caller was identified |

An unauthenticated caller asking for `apps.list` receives a **refusal frame**, not
an empty array. An empty array would read as "this deployment grants nothing",
which is a different and untrue statement.

## Version 1 documents

`clients` absent ⇒ `client_authorization: "legacy_none"`. The app grant is the only
gate, exactly as in 0.1.0. `policy.status` reports it, so a host can tell
"authenticated" from "not authenticated" instead of assuming.

`clients` present in a version-1 document is a contradiction and refuses the whole
document, rather than being read as either meaning.

## Ordering, and why it matters

The client is checked **before** the application:

1. no client matched → `client_not_authorized`;
2. client lacks the scope → `client_scope_not_granted`;
3. application not granted by the deployment → `app_not_granted`;
4. client's `apps` does not cover that application → `client_app_not_granted`;
5. application grant lacks the scope → `scope_not_granted`;
6. window outside the authorized set → `window_not_granted`.

An unauthorized caller therefore learns only that it is unauthorized, not which
applications the deployment happens to grant. Step 4 compares against the
**resolved grant's** identifiers, so a caller that names an application by display
name is judged correctly.

## Requirements: guidance

`identifier "x"` alone is weak — two binaries can carry the same identifier. For a
real deployment name the anchor and team:

```
identifier "com.cmm.console" and anchor apple generic
  and certificate leaf[subject.OU] = "TEAMID"
```

An ad-hoc or development-signed client works too, as long as the requirement
describes it; the check is about matching what the policy demanded, not about
Apple's notarization.

## Limitations

- A requirement that fails to compile matches nothing (fail closed), but that is
  not currently distinguished from "valid, did not match" in `policy.status`.
- The pid fallback path is weaker than the audit token and should be removed once
  the token is confirmed everywhere.
- Requirements are compiled per connection; a malformed requirement is not yet a
  load-time refusal.
- A process running as the same user can still edit `policy.json` directly. Client
  authentication protects use of the bridge, not the file.

## Verifying it yourself

```
scripts/build-helper.sh
scripts/verify-client-identity.sh
```

The second script starts an isolated helper on a temporary socket with a
temporary version-2 policy and no permission bootstrap, signs two probe clients
with different identifiers, and asserts the whole matrix — including that a
self-declared `client_id` changes nothing and that a signed but unlisted process
is refused. It never touches the installed helper, the LaunchAgent, the production
socket, the production policy or TCC.
