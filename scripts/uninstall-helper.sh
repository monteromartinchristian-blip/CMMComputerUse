#!/bin/bash
# Stop and remove the helper.
#
#   scripts/uninstall-helper.sh [--purge] [--keep-policy]
#
# Default: unload the LaunchAgent, remove its plist and the socket, and delete
# the installed app. TCC grants are NOT removed by this script — macOS only lets
# the person revoke them (System Settings → Privacy & Security). `--purge` also
# removes ~/.cmm/computer-bridge, including the allowlist and the helper log.
set -euo pipefail

LABEL="com.cmm.chat.computer-use"
APP="${CMM_BRIDGE_APP:-$HOME/Applications/CMMComputerUse.app}"
SUPPORT_DIR="${CMM_BRIDGE_DIR:-$HOME/.cmm/computer-bridge}"
SUPERVISOR_DIR="$HOME/Library/Application Support/CMM Computer Use"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
PURGE=0
KEEP_POLICY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --purge) PURGE=1; shift ;;
    --keep-policy) KEEP_POLICY=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

echo "== unloading $LABEL"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
# A job started by LaunchServices can outlive its job definition; stop the app.
osascript -e 'tell application "CMM Computer Use" to quit' >/dev/null 2>&1 || true
pkill -f "CMMComputerUse.app/Contents/MacOS/CMMComputerUse" 2>/dev/null || true

if [ -f "$PLIST" ]; then
  echo "== removing $PLIST"
  rm -f "$PLIST"
fi

if [ -d "$APP" ]; then
  echo "== removing $APP"
  rm -rf "$APP"
fi

if [ -d "$SUPERVISOR_DIR" ]; then
  echo "== removing the job supervisor in $SUPERVISOR_DIR"
  rm -rf "$SUPERVISOR_DIR"
fi

if [ "$PURGE" -eq 1 ]; then
  echo "== removing $SUPPORT_DIR (allowlist, log, socket)"
  rm -rf "$SUPPORT_DIR"
elif [ "$KEEP_POLICY" -eq 0 ]; then
  rm -f "$SUPPORT_DIR/bridge.sock"
fi

cat <<'DONE'

Helper removed.

Still yours to do, and only you can do it:
  System Settings → Privacy & Security → Screen & System Audio Recording
  System Settings → Privacy & Security → Accessibility
  Select "CMM Computer Use" and press "−" to revoke the grants.

TCC keeps those entries pointing at a bundle id that no longer exists until you
remove them; leaving them in place is not a security hole, but it is untidy.
DONE
