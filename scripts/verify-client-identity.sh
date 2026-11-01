#!/bin/bash
# Isolated end-to-end verification of per-client authorization.
#
#   scripts/verify-client-identity.sh
#
# What this proves, on THIS machine, without touching the deployment:
#
#   * a client's identity is its CODE SIGNATURE, resolved from the peer's audit
#     token — not a field in the request;
#   * two signed clients with different requirements cannot reach each other's
#     applications;
#   * an unsigned process is refused when the policy requires clients;
#   * a client that holds `control` cannot exceed the APPLICATION's own grant;
#   * a version-1 document still works and reports that it has no client
#     dimension, so an old policy is never silently upgraded or locked out.
#
# What it does NOT touch: the installed helper, the LaunchAgent, the production
# socket (~/.cmm/computer-bridge/bridge.sock), the production policy, or TCC.
# The helper runs from build/ with --policy-file and --serve-socket pointing into
# a temporary directory, and --no-permission-bootstrap so no TCC prompt can
# appear. Everything is removed on exit.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$REPO/build/CMMComputerUse.app/Contents/MacOS/CMMComputerUse"
PROBE_SRC="$REPO/scripts/verification/bridge-probe.swift"

[ -x "$HELPER" ] || { echo "build the helper first: scripts/build-helper.sh" >&2; exit 2; }
[ -f "$PROBE_SRC" ] || { echo "missing probe source" >&2; exit 2; }

WORK="$(mktemp -d /tmp/cmm-cu-verify.XXXXXX)"
SOCK="$WORK/bridge.sock"
POLICY="$WORK/policy.json"
HELPER_LOG="$WORK/helper.log"
HELPER_PID=""
FAILURES=0
CHECKS=0

cleanup() {
  if [ -n "$HELPER_PID" ] && kill -0 "$HELPER_PID" 2>/dev/null; then
    kill "$HELPER_PID" 2>/dev/null || true
    wait "$HELPER_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---- probes: one source, two signed identities --------------------------------

echo "== compiling probes"
swiftc -O -o "$WORK/probe-bare" "$PROBE_SRC"
cp "$WORK/probe-bare" "$WORK/probe-a"
cp "$WORK/probe-bare" "$WORK/probe-b"

identities=$(security find-identity -v -p codesigning 2>/dev/null || true)
IDENTITY=$(printf '%s\n' "$identities" | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(printf '%s\n' "$identities" | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
fi
if [ -z "$IDENTITY" ]; then
  echo "!! no signing identity; ad-hoc identities cannot prove requirement evaluation" >&2
  exit 2
fi
echo "== signing probes as $IDENTITY"
codesign --force --sign "$IDENTITY" --identifier com.cmm.cu.probe-a "$WORK/probe-a"
codesign --force --sign "$IDENTITY" --identifier com.cmm.cu.probe-b "$WORK/probe-b"
# On Apple Silicon arm64 a completely unsigned Mach-O cannot execute at all, so
# "an unsigned process" is not an observable state. The realistic adversary is a
# SIGNED process that no client entry lists: it presents a valid identity and
# must still be refused. probe-bare is that process.
codesign --force --sign "$IDENTITY" --identifier com.cmm.cu.probe-unlisted "$WORK/probe-bare"

# ---- policies ----------------------------------------------------------------

# mode=focus so activation kinds are reachable and the app-level scope gate can
# be observed independently of the mode gate.
cat > "$POLICY" <<'JSON'
{
  "version": 2,
  "mode": "focus",
  "default": "deny",
  "apps": [
    {"bundle_id": "com.apple.finder", "name": "Finder", "scopes": ["observe"]},
    {"bundle_id": "com.apple.Terminal", "name": "Terminal", "scopes": ["observe"]}
  ],
  "clients": [
    {"client_id": "probe-a",
     "requirement": "identifier \"com.cmm.cu.probe-a\"",
     "apps": ["com.apple.finder"], "scopes": ["observe"]},
    {"client_id": "probe-b",
     "requirement": "identifier \"com.cmm.cu.probe-b\"",
     "apps": ["com.apple.Terminal"], "scopes": ["observe", "control"]}
  ]
}
JSON

LEGACY_POLICY="$WORK/policy-v1.json"
cat > "$LEGACY_POLICY" <<'JSON'
{
  "version": 1,
  "mode": "focus",
  "default": "deny",
  "apps": [{"bundle_id": "com.apple.finder", "name": "Finder", "scopes": ["observe"]}]
}
JSON

# ---- isolated helper ---------------------------------------------------------

start_helper() {
  local policy="$1"
  rm -f "$SOCK"
  # --policy focus: the deployment mode defaults to `background`, and the design
  # is min(launch, file). Without this the activation kinds are refused by the
  # mode gate before the authorization gate, which would hide the scope test.
  "$HELPER" --serve-socket "$SOCK" --policy-file "$policy" --policy focus \
    --no-permission-bootstrap --log-file "$HELPER_LOG" &
  HELPER_PID=$!
  for _ in $(seq 1 100); do
    [ -S "$SOCK" ] && return 0
    sleep 0.05
  done
  echo "helper did not bind $SOCK" >&2
  sed -n '1,40p' "$HELPER_LOG" >&2 || true
  exit 2
}

stop_helper() {
  if [ -n "$HELPER_PID" ] && kill -0 "$HELPER_PID" 2>/dev/null; then
    kill "$HELPER_PID" 2>/dev/null || true
    wait "$HELPER_PID" 2>/dev/null || true
  fi
  HELPER_PID=""
}

# ---- assertions --------------------------------------------------------------

# check <description> <probe> <expected> <operation> [args]
# expected: "ok" | "code:<CODE>" | "detail:<substring>" | "not-code:<CODE>"
#           | "all-apps:<bundle>" | "no-apps"
check() {
  local description="$1" probe="$2" expected="$3" operation="$4" args="${5:-}"
  CHECKS=$((CHECKS + 1))
  local response
  if ! response=$("$WORK/$probe" "$SOCK" "$operation" "$args" 2>/dev/null); then
    echo "FAIL $description (probe could not run)"; FAILURES=$((FAILURES + 1)); return
  fi
  if ! python3 - "$expected" "$response" <<'PY'
import json, sys
expected, raw = sys.argv[1], sys.argv[2]
try:
    frame = json.loads(raw)
except Exception:
    print("unparseable frame"); sys.exit(1)
ok = frame.get("ok")
error = frame.get("error") or {}
code = error.get("code", "")
detail = error.get("detail", "")
result = frame.get("result") or {}

if expected == "ok":
    sys.exit(0 if ok else 1)
if expected.startswith("code:"):
    sys.exit(0 if (ok is False and code == expected[5:]) else 1)
if expected.startswith("not-code:"):
    sys.exit(0 if code != expected[9:] else 1)
if expected.startswith("detail:"):
    sys.exit(0 if expected[7:] in detail else 1)
if expected.startswith("all-apps:"):
    bundle = expected[9:]
    apps = result.get("apps") or []
    sys.exit(0 if ok and all(a.get("bundle_id") == bundle for a in apps) else 1)
if expected.startswith("none-of:"):
    bundle = expected[8:]
    apps = result.get("apps") or []
    sys.exit(0 if ok and all(a.get("bundle_id") != bundle for a in apps) else 1)
if expected == "no-apps":
    sys.exit(0 if ok and not (result.get("apps") or []) else 1)
if expected.startswith("field:"):
    _, key, value = expected.split(":", 2)
    node = result
    for part in key.split("."):
        node = (node or {}).get(part)
    sys.exit(0 if str(node) == value else 1)
print("unknown expectation"); sys.exit(1)
PY
  then
    echo "FAIL $description"
    echo "     expected=$expected"
    echo "     got=$(printf '%s' "$response" | python3 -c 'import json,sys;f=json.load(sys.stdin);print(json.dumps(f.get("error") or {"ok":f.get("ok"),"apps":len((f.get("result") or {}).get("apps") or [])},ensure_ascii=False))' 2>/dev/null || printf '%s' "$response")"
    FAILURES=$((FAILURES + 1))
  else
    echo "ok   $description"
  fi
}

# ---- scenario 1: version 2 with clients --------------------------------------

echo "== scenario: version 2, two signed clients"
start_helper "$POLICY"

check "diagnostics answer and report the client dimension" \
  probe-a "field:client_authorization:required" policy.status
check "probe-a is recognised as client probe-a" \
  probe-a "field:client.client_id:probe-a" policy.status
check "probe-a sees only its own application" \
  probe-a "all-apps:com.apple.finder" apps.list
check "probe-a's list contains no foreign application" \
  probe-a "none-of:com.apple.Terminal" apps.list
check "probe-b sees only its own application" \
  probe-b "all-apps:com.apple.Terminal" apps.list
check "probe-b cannot reach probe-a's application (observation)" \
  probe-b "detail:client_app_not_granted" observation.describe '{"app":"Finder"}'
check "probe-a cannot reach probe-b's application (observation)" \
  probe-a "detail:client_app_not_granted" observation.describe '{"app":"Terminal"}'
check "a self-declared client_id changes nothing" \
  probe-a "detail:client_app_not_granted" observation.describe \
  '{"app":"Terminal","client_id":"probe-b"}'
check "a signed process no client lists has no client identity" \
  probe-bare "code:APPROVAL_REJECTED" apps.list
check "such a process is refused with the exact missing fact" \
  probe-bare "detail:client_not_authorized" apps.list
# probe-b holds `control` for Terminal, but the APPLICATION only granted observe:
# the intersection is what applies, so activation must still be refused.
check "a client cannot exceed the application's own grant" \
  probe-b "detail:scope_not_granted" action.execute \
  '{"kind":"app.activate","params":{"app":"Terminal"}}'
# probe-a holds only observe on Finder, so control is refused at the client.
check "a client cannot exceed its own scopes" \
  probe-a "detail:client_scope_not_granted" action.execute \
  '{"kind":"app.activate","params":{"app":"Finder"}}'
check "an unlisted caller cannot enumerate authorized applications" \
  probe-bare "code:APPROVAL_REJECTED" apps.list

echo "-- helper log (client identity resolutions)"
grep -E "AUTHORIZATION|client peer" "$HELPER_LOG" | head -8 || true

stop_helper

# ---- scenario 2: version 1 document still works ------------------------------

echo "== scenario: version 1 keeps working and says it has no client dimension"
start_helper "$LEGACY_POLICY"
check "a v1 document reports legacy_none" \
  probe-a "field:client_authorization:legacy_none" policy.status
check "a v1 document has no client requirement" \
  probe-a "all-apps:com.apple.finder" apps.list
check "the application grant still applies in v1 (no client dimension)" \
  probe-a "not-code:APPROVAL_REJECTED" observation.describe '{"app":"Finder"}'
stop_helper

echo
echo "checks=$CHECKS failures=$FAILURES"
if [ "$FAILURES" -ne 0 ]; then
  echo "FAILED" >&2
  exit 1
fi
echo "PASS"
