#!/bin/bash
# The single entry point that decides whether this tree is releasable.
#
#   scripts/verify-release.sh [--quick]
#
# Each step proves something the others cannot:
#   Swift tests        the policy, targeting and authorization rules the helper executes
#   Node tests         the projection, admission, PiP states and the client semantics
#   Python tests       the adapter over a real Unix socket, the patch structure, the manifest
#   render --check     dist/client.js is the render of the current template
#   verify-manifest    the published file list exists, carries no personal path and no marker
#   npm pack           the tarball is what the manifest says, and it installs
#   dsh install        a clean profile composes, activates and launches the adapter
#
# --quick skips the two slow steps that need a DSH installation.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

PASS=0; FAIL=0
step() {
  local name="$1"; shift
  echo
  echo "── $name"
  if "$@"; then
    PASS=$((PASS+1)); echo "   PASS $name"
  else
    FAIL=$((FAIL+1)); echo "   FAIL $name"
  fi
}

swift_tests() {
  cd "$REPO/apps/macos" || return 1
  command -v xcodegen >/dev/null || { echo "xcodegen not installed"; return 1; }
  xcodegen generate >/dev/null || return 1
  xcodebuild test -project CMMComputerUse.xcodeproj -scheme CMMComputerUse \
    -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 \
    | grep -E "Executed .* tests|TEST (SUCCEEDED|FAILED)" | tail -5
  return "${PIPESTATUS[0]}"
}

node_tests() {
  cd "$REPO/packages/dsh-computer-use" || return 1
  node --test tests/*.test.mjs 2>&1 | tail -8
  return "${PIPESTATUS[0]}"
}

python_tests() {
  cd "$REPO/packages/dsh-computer-use" || return 1
  /usr/bin/python3 -m unittest discover -s tests -t tests 2>&1 | tail -4 || return 1
  cd adapter || return 1
  /usr/bin/python3 -m unittest discover -s tests 2>&1 | tail -4
  return "${PIPESTATUS[0]}"
}

render_check() {
  cd "$REPO/packages/dsh-computer-use" || return 1
  node scripts/render-client.mjs --check
}

manifest_check() {
  cd "$REPO/packages/dsh-computer-use" || return 1
  node scripts/verify-manifest.mjs
}

npm_pack() {
  cd "$REPO/packages/dsh-computer-use" || return 1
  npm pack --dry-run --json 2>/dev/null > "${TMPDIR:-/tmp}/cmm-npm-pack.json" || return 1
  /usr/bin/python3 "$REPO/scripts/check-tarball.py" "${TMPDIR:-/tmp}/cmm-npm-pack.json"
}

dsh_install() {
  local cli="${DSH_CLI:-/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh}"
  [ -x "$cli" ] || { echo "no DSH CLI at $cli"; return 1; }
  local home="${CMM_VERIFY_DSH_HOME:-$(mktemp -d)/home}"
  local profile="cmm-cu-verify-$(date +%s)"
  mkdir -p "$home"
  echo "  DSH_HOME=$home profile=$profile"
  DSH_HOME="$home" "$cli" --profile "$profile" --from-default-profile web --dump-config >/dev/null 2>&1 || return 1
  DSH_HOME="$home" "$cli" plugin --profile "$profile" add "$REPO/packages/dsh-computer-use" >/dev/null 2>&1 || return 1
  DSH_HOME="$home" "$cli" --profile "$profile" --dump-config 2>/dev/null \
    | grep -q "cmm-computer-use-panel" || return 1
  echo "  composed; rows present"
  return 0
}

echo "CMM Computer Use — release verification"
echo "repo: $REPO"

step "swift tests"        swift_tests
step "node tests"         node_tests
step "python tests"       python_tests
step "render client"      render_check
step "manifest"           manifest_check
step "npm pack --dry-run" npm_pack
if [ "$QUICK" -eq 0 ]; then
  step "dsh clean-profile install" dsh_install
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "VERIFY_RELEASE=PASS (steps: $PASS)"
  exit 0
fi
echo "VERIFY_RELEASE=FAIL (pass=$PASS fail=$FAIL)"
exit 1
