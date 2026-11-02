#!/bin/bash
# live-background-e2e.sh — end-to-end LIVE check of background mode (macOS).
#
# Run it FROM THE APP YOU KEEP IN FRONT (Terminal, or DeepSeek Harness's own
# terminal): that app is "the person's frontmost application" the whole check
# protects. Do not touch the mouse or switch apps while it runs.
#
# Preconditions (the script checks what it can and stops otherwise):
#   - the signed helper is installed and serving ~/.cmm/computer-bridge/bridge.sock
#     in background mode (scripts/install-helper.sh);
#   - the CMM Console policy authorizes com.example.computer-use-fixture with
#     scopes observe,control (and, for the Electron step, the Electron app);
#   - Xcode command line tools (swiftc) for the fixture and the witness.
#
# Usage:
#   scripts/verification/live-background-e2e.sh [--electron-app <bundle>] [--breach-control]
#
# --breach-control presses the fixture's self-activating button. The helper then
# latches the fixture DURABLY (a restart does not clear it) until CMM Console
# rearms it with `breach.rearm` (docs/architecture/
# CMM-Console-Breach-Rearm-Cambio-Requerido-20261102.md). Run it last.
set -euo pipefail

[[ "$(uname -s)" == "Darwin" ]] || { echo "macOS only" >&2; exit 2; }
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${CMM_E2E_DIR:-$(mktemp -d -t cmm-cu-e2e)}"
SOCKET="${CMM_COMPUTER_BRIDGE_SOCKET:-$HOME/.cmm/computer-bridge/bridge.sock}"
[[ -S "$SOCKET" ]] || { echo "no helper socket at $SOCKET" >&2; exit 2; }
export CMM_CU_FIXTURE_STATE="$WORK/fixture-state.json"

echo "work dir: $WORK"

# Independent witness (read-only, own process, own run loop).
swiftc -O -framework AppKit "$REPO/scripts/verification/focus-monitor.swift" -o "$WORK/focus-monitor"

# Fixture app, launched WITHOUT taking focus.
APP="$WORK/CMM Computer Use Fixture.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -framework AppKit -framework Foundation "$REPO/examples/fixture/main.swift" -o "$APP/Contents/MacOS/Fixture"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.example.computer-use-fixture</string>
  <key>CFBundleExecutable</key><string>Fixture</string>
  <key>CFBundleName</key><string>CMM Computer Use Fixture</string>
  <key>CFBundleDisplayName</key><string>CMM Computer Use Fixture</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
pkill -f "CMM Computer Use Fixture.app/Contents/MacOS/Fixture" 2>/dev/null || true
open -g -n --env CMM_CU_FIXTURE_STATE="$CMM_CU_FIXTURE_STATE" "$APP"
for _ in $(seq 1 50); do [[ -s "$CMM_CU_FIXTURE_STATE" ]] && break; sleep 0.1; done
[[ -s "$CMM_CU_FIXTURE_STATE" ]] || { echo "fixture did not start" >&2; exit 2; }
sleep 1

"$WORK/focus-monitor" "$WORK/monitor.jsonl" 180 &
MONITOR=$!
trap 'kill $MONITOR 2>/dev/null || true' EXIT
sleep 0.5

set +e
# The isolated lane passes its own interpreter: the temporary policy pins the
# driver's code identity (cdhash) to it.
"${CMM_E2E_PYTHON:-python3}" -I "$REPO/scripts/verification/live_background_e2e.py" \
  --socket "$SOCKET" --fixture-state "$CMM_CU_FIXTURE_STATE" \
  --monitor "$WORK/monitor.jsonl" --report "$WORK/report.json" "$@"
STATUS=$?
set -e
echo "monitor samples: $(wc -l < "$WORK/monitor.jsonl")"
echo "evidence: $WORK/report.json  $WORK/monitor.jsonl  $CMM_CU_FIXTURE_STATE"
exit $STATUS
