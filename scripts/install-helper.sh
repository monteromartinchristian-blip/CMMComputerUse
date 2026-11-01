#!/bin/bash
# Install the LaunchAgent that keeps CMM Computer Use serving its socket.
#
#   scripts/install-helper.sh [--policy-file <path>] [--plist-output <path>]
#
# --plist-output writes the job definition to <path> and exits WITHOUT
# installing anything: no supervisor, no plist in ~/Library/LaunchAgents, no
# launchctl call. It exists so a private update can ship and diff the exact
# definition it will install.
#
# What it does, and nothing else:
#   1. creates ~/.cmm/computer-bridge (0700),
#   2. installs the job's supervisor (scripts/run-helper.sh) under
#      ~/Library/Application Support/CMM Computer Use (0700),
#   3. writes ~/Library/LaunchAgents/com.cmm.chat.computer-use.plist, keeping a
#      timestamped copy of whatever was there before,
#   4. bootstraps that job in the GUI session,
#   5. waits for the socket to answer.
#
# What it deliberately does NOT do:
#   * write a policy file. There is no allowlist until the person writes one:
#     the helper starts fail-closed with zero authorized applications.
#   * launch the executable directly. The job goes through LaunchServices
#     (`open -n -W -g -a`), because ScreenCaptureKit attributes a capture to the
#     *responsible* app; a helper started as Contents/MacOS/<exe> has none and
#     macOS attributes the capture to the system UI agent instead. The
#     supervisor only decides WHETHER to launch, never HOW.
#   * grant any TCC permission. Screen Recording and Accessibility are granted
#     by the person in System Settings, once, to "CMM Computer Use".
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${CMM_BRIDGE_APP:-$HOME/Applications/CMMComputerUse.app}"
BUNDLE_ID="com.cmm.chat.computer-use"
LABEL="com.cmm.chat.computer-use"
SUPPORT_DIR="${CMM_BRIDGE_DIR:-$HOME/.cmm/computer-bridge}"
SOCKET="$SUPPORT_DIR/bridge.sock"
LOG_FILE="$SUPPORT_DIR/helper.log"
AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST="$AGENTS_DIR/$LABEL.plist"
SUPERVISOR_DIR="$HOME/Library/Application Support/CMM Computer Use"
SUPERVISOR="$SUPERVISOR_DIR/run-helper.sh"
POLICY_FILE=""
PLIST_OUTPUT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --policy-file) POLICY_FILE="${2:-}"; shift 2 ;;
    --plist-output) PLIST_OUTPUT="${2:-}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ ! -d "$APP" ]; then
  echo "missing $APP — run scripts/build-helper.sh --install first" >&2
  exit 1
fi
ACTUAL_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist" 2>/dev/null || true)
if [ "$ACTUAL_ID" != "$BUNDLE_ID" ]; then
  echo "refusing: $APP reports bundle id '$ACTUAL_ID', expected '$BUNDLE_ID'" >&2
  exit 1
fi
if ! codesign --verify --strict "$APP" 2>/dev/null; then
  echo "refusing: $APP does not pass codesign verification" >&2
  exit 1
fi

if [ -z "$PLIST_OUTPUT" ]; then
  mkdir -p "$SUPPORT_DIR" "$AGENTS_DIR"
  chmod 700 "$SUPPORT_DIR"
fi

xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

POLICY_ARGS=""
if [ -n "$POLICY_FILE" ]; then
  POLICY_ARGS="		<string>--policy-file</string>
		<string>$(xml_escape "$POLICY_FILE")</string>"
fi
if [ -n "$POLICY_ARGS" ]; then POLICY_ARGS="
$POLICY_ARGS"; fi

SUPERVISOR_SOURCE="$REPO/scripts/run-helper.sh"
if [ ! -f "$SUPERVISOR_SOURCE" ]; then
  echo "refusing: missing $SUPERVISOR_SOURCE" >&2
  exit 1
fi
sh -n "$SUPERVISOR_SOURCE"
if [ -z "$PLIST_OUTPUT" ]; then
  mkdir -p "$SUPERVISOR_DIR"
  chmod 700 "$SUPERVISOR_DIR"
  install -m 700 "$SUPERVISOR_SOURCE" "$SUPERVISOR"
fi

if [ -z "$PLIST_OUTPUT" ] && [ -f "$PLIST" ]; then
  STAMP=$(date +%Y%m%dT%H%M%SZ)
  BACKUP_PLIST="$PLIST.bak-$STAMP"
  cp "$PLIST" "$BACKUP_PLIST"
  echo "== previous job definition kept at $BACKUP_PLIST"
fi

# The job definition is written from literals, never from expansion of a
# template that could change shape. `Interactive` + `Aqua` are load-bearing: a
# job launched as a Background task gets no window-server connection.
TARGET_PLIST="$PLIST"
if [ -n "$PLIST_OUTPUT" ]; then
  TARGET_PLIST="$PLIST_OUTPUT"
  mkdir -p "$(dirname "$PLIST_OUTPUT")"
fi

cat > "$TARGET_PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>KeepAlive</key>
	<true/>
	<key>Label</key>
	<string>$LABEL</string>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/sh</string>
		<string>$(xml_escape "$SUPERVISOR")</string>
		<string>--app</string>
		<string>$(xml_escape "$APP")</string>
		<string>--socket</string>
		<string>$(xml_escape "$SOCKET")</string>
		<string>--policy</string>
		<string>background</string>
		<string>--log-file</string>
		<string>$(xml_escape "$LOG_FILE")</string>$POLICY_ARGS
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>10</integer>
	<key>StandardOutPath</key>
	<string>/tmp/cmm-computer-use.log</string>
	<key>StandardErrorPath</key>
	<string>/tmp/cmm-computer-use.err</string>
</dict>
</plist>
PLIST_EOF

plutil -lint "$TARGET_PLIST" >/dev/null

if [ -n "$PLIST_OUTPUT" ]; then
  echo "wrote $TARGET_PLIST"
  echo "(nothing installed: no supervisor, no launchctl, no live plist touched)"
  exit 0
fi

# A stale socket from a previous install makes the new helper refuse to start
# (it will not serve a socket someone else may be holding).
if [ -S "$SOCKET" ]; then
  if ! /usr/bin/nc -U -z "$SOCKET" 2>/dev/null; then
    echo "== removing stale socket"
    rm -f "$SOCKET"
  fi
fi

DOMAIN="gui/$(id -u)"
echo "== loading $LABEL"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl enable "$DOMAIN/$LABEL" 2>/dev/null || true

echo "== waiting for the socket"
for _ in $(seq 1 40); do
  if [ -S "$SOCKET" ]; then
    if /usr/bin/nc -U -z "$SOCKET" 2>/dev/null; then
      echo "socket ready: $SOCKET"
      echo
      echo "next steps:"
      echo "  1. Grant Screen Recording (Screen & System Audio) and Accessibility"
      echo "     to \"CMM Computer Use\" in System Settings → Privacy & Security."
      echo "  2. Write an explicit allowlist (see docs/permissions.md) and restart"
      echo "     the job. Until then it authorizes zero applications."
      exit 0
    fi
  fi
  sleep 0.5
done

echo "socket did not answer within 20s; inspect: launchctl print $DOMAIN/$LABEL" >&2
exit 1
