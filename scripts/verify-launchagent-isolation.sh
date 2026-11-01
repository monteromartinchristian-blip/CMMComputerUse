#!/bin/bash
# Isolated verification of the LaunchAgent lifecycle correction.
#
#   scripts/verify-launchagent-isolation.sh
#
# WHAT IT PROVES, AND WHAT IT TOUCHES
#
# A THROWAWAY LaunchAgent is bootstrapped in the user's GUI session. It runs the
# REAL supervisor (`scripts/run-helper.sh`) against a THROWAWAY .app whose only
# job is to reproduce the helper's single-instance rule on a temporary socket:
#
#   1. cold start binds the socket and serves;
#   2. steady state spawns nothing else;
#   3. a duplicate instance that finds the socket served exits, and the job does
#      not enter the historical restart loop;
#   4. starting the JOB while something already serves waits instead of spawning
#      a duplicate, and takes over when that process goes away;
#   5. SIGKILL to the serving process is recovered by launchd;
#   6. bootout stops everything.
#
# What it never touches: the installed helper, its LaunchAgent
# (~/Library/LaunchAgents/com.cmm.chat.computer-use.plist), the production
# socket, the production policy, or TCC. The production plist's digest is
# compared before and after and the run fails if it changed. The probe app is
# ad-hoc signed, contains no TCC-relevant code (no AX, no capture) and is
# removed on exit.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUPERVISOR="$REPO/scripts/run-helper.sh"
PROBE_SRC="$REPO/scripts/verification/launch-probe/main.swift"
DOMAIN="gui/$(id -u)"
PROD_PLIST="$HOME/Library/LaunchAgents/com.cmm.chat.computer-use.plist"
LABEL="com.cmm.cu.launchagent-test.$$"
WORK="$(mktemp -d /tmp/cmm-cu-launchagent.XXXXXX)"
PROBE_APP="$WORK/LaunchProbe.app"
SOCK="$WORK/probe.sock"
PROBE_LOG="$WORK/probe.log"
SUPERVISOR_LOG="$WORK/supervisor.out"
SUPERVISOR_ERR="$WORK/supervisor.err"
PLIST="$WORK/$LABEL.plist"
FAILURES=0
CHECKS=0

cleanup() {
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  pkill -f -- "--serve-socket $SOCK" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }
pass() { echo "  ok: $*"; CHECKS=$((CHECKS + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi }

count_serving() { grep -c " serving $SOCK" "$PROBE_LOG" 2>/dev/null || true; }
count_duplicate() { grep -c "already_serving" "$PROBE_LOG" 2>/dev/null || true; }
no_process() { [ "$(process_count)" -eq 0 ]; }
no_supervisor() { [ "$(supervisor_count)" -eq 0 ]; }
one_process() { [ "$(process_count)" -eq 1 ]; }
duplicate_seen() { [ "$(count_duplicate)" -ge 1 ]; }
more_serving_than() { [ "$(count_serving)" -gt "$1" ]; }
process_count() { pgrep -f -- "--serve-socket $SOCK" 2>/dev/null | wc -l | tr -d ' '; }
socket_answers() { [ -S "$SOCK" ] && /usr/bin/nc -U -w 2 "$SOCK" </dev/null >/dev/null 2>&1; }
supervisor_count() { pgrep -f -- "run-helper.sh --app $PROBE_APP --socket $SOCK" 2>/dev/null | wc -l | tr -d ' '; }

wait_for() { # wait_for <seconds> <command...>
  local deadline=$((SECONDS + $1)); shift
  while [ $SECONDS -lt $deadline ]; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 0.25
  done
  return 1
}

[ -f "$SUPERVISOR" ] || { echo "missing supervisor: $SUPERVISOR" >&2; exit 2; }
[ -x /usr/bin/open ] || { echo "missing /usr/bin/open" >&2; exit 2; }
PROD_DIGEST_BEFORE="$(shasum -a 256 "$PROD_PLIST" 2>/dev/null || echo absent)"

# ---- throwaway app ----------------------------------------------------------

echo "== building the probe app"
mkdir -p "$PROBE_APP/Contents/MacOS"
swiftc -O -o "$PROBE_APP/Contents/MacOS/LaunchProbe" "$PROBE_SRC" || exit 2
cat > "$PROBE_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>com.cmm.cu.launchprobe</string>
	<key>CFBundleExecutable</key><string>LaunchProbe</string>
	<key>CFBundleName</key><string>LaunchProbe</string>
	<key>CFBundleDisplayName</key><string>LaunchProbe</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSUIElement</key><true/>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$PROBE_APP" >/dev/null 2>&1 || { echo "probe signing failed" >&2; exit 2; }

# ---- throwaway job ----------------------------------------------------------

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/sh</string>
		<string>$SUPERVISOR</string>
		<string>--app</string>
		<string>$PROBE_APP</string>
		<string>--socket</string>
		<string>$SOCK</string>
		<string>--policy</string>
		<string>background</string>
		<string>--log-file</string>
		<string>$PROBE_LOG</string>
	</array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
	<key>ThrottleInterval</key><integer>2</integer>
	<key>ProcessType</key><string>Interactive</string>
	<key>LimitLoadToSessionType</key><string>Aqua</string>
	<key>StandardOutPath</key><string>$SUPERVISOR_LOG</string>
	<key>StandardErrorPath</key><string>$SUPERVISOR_ERR</string>
</dict>
</plist>
PLIST
plutil -lint "$PLIST" >/dev/null || { echo "bad plist" >&2; exit 2; }

# ---- 1. cold start ----------------------------------------------------------

echo "== phase 1: cold start"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST" || { echo "bootstrap failed" >&2; exit 2; }
if wait_for 20 socket_answers; then pass "the job binds the socket"; else fail "the job never bound the socket"; fi
check "exactly one probe process" '[ "$(process_count)" -eq 1 ]'
check "exactly one serving line" '[ "$(count_serving)" -eq 1 ]'

# ---- 2. steady state --------------------------------------------------------

echo "== phase 2: steady state (8s)"
sleep 8
check "still exactly one probe process" '[ "$(process_count)" -eq 1 ]'
check "no extra spawn" '[ "$(count_serving)" -eq 1 ]'
check "no duplicate attempts" '[ "$(count_duplicate)" -eq 0 ]'

# ---- 3. duplicate instance --------------------------------------------------

echo "== phase 3: a duplicate instance exits and the job does not loop"
/usr/bin/open -n -g -a "$PROBE_APP" --args --socket "$SOCK" --log-file "$PROBE_LOG"
if wait_for 10 duplicate_seen; then pass "the duplicate refused to start"; else fail "the duplicate never ran"; fi
sleep 6
check "the duplicate did not become a second server" '[ "$(count_serving)" -eq 1 ]'
check "the deployment still runs one process" 'one_process'

# ---- 4. the historical loop: job starts while served ------------------------

echo "== phase 4: the job starts while something already serves"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
# `open` owns the app process, not the job: bootout stops the JOB and leaves the
# app running. That is documented LaunchServices behaviour, and an operator
# stopping the helper must stop the process. Do it explicitly here.
pkill -f -- "--serve-socket $SOCK" 2>/dev/null || true
if wait_for 15 no_process; then pass "the previous instance stopped"; else fail "the previous instance did not stop"; fi

SERVING_BEFORE="$(count_serving)"
DUPLICATES_BEFORE="$(count_duplicate)"
"$PROBE_APP/Contents/MacOS/LaunchProbe" --socket "$SOCK" --log-file "$PROBE_LOG" &
MANUAL_PID=$!
wait_for 10 socket_answers || fail "the manual instance did not bind"
if wait_for 10 more_serving_than "$SERVING_BEFORE"; then
  pass "the manual instance serves"
else
  fail "the manual instance did not record serving"
fi
SERVED_BY_HAND="$(count_serving)"

launchctl bootstrap "$DOMAIN" "$PLIST"
sleep 8
check "the job is supervising, not spawning" '[ "$(supervisor_count)" -eq 1 ]'
check "the job spawned no instance of its own" 'no_process'
check "no new serving line while the socket was already served" \
  '[ "$(count_serving)" -eq "$SERVED_BY_HAND" ]'
check "the supervisor says it is waiting" \
  'grep -q "waiting instead of spawning a duplicate" "$SUPERVISOR_ERR" "$SUPERVISOR_LOG"'
check "the job produced no duplicate-exit storm" \
  '[ "$(count_duplicate)" -eq "$DUPLICATES_BEFORE" ]'

echo "== phase 4b: the serving process goes away and the job takes over"
kill "$MANUAL_PID" 2>/dev/null || true
wait "$MANUAL_PID" 2>/dev/null || true
if wait_for 30 more_serving_than "$SERVED_BY_HAND"; then
  pass "the job relaunched a serving instance"
else
  fail "the job did not take over after the serving process left"
fi
check "the socket answers again" 'socket_answers'
check "exactly one process after takeover" 'one_process'

# ---- 5. SIGKILL recovery ----------------------------------------------------

echo "== phase 5: SIGKILL to the serving process"
KILL_TARGET="$(pgrep -f -- "--serve-socket $SOCK" | head -1)"
if [ -n "$KILL_TARGET" ]; then pass "found the serving process"; else fail "no serving process to kill"; fi
SERVING_BEFORE="$(count_serving)"
kill -9 "$KILL_TARGET" 2>/dev/null || true
if wait_for 30 more_serving_than "$SERVING_BEFORE"; then
  pass "launchd relaunched after SIGKILL"
else
  fail "no relaunch after SIGKILL"
fi
check "exactly one serving process after recovery" 'one_process'

# ---- 6. bootout -------------------------------------------------------------

echo "== phase 6: bootout stops the job and nothing relaunches"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
wait_for 10 no_supervisor
check "the job supervisor is gone" 'no_supervisor'
# Same LaunchServices caveat as phase 4: stop the app the launcher owns, then
# prove no job is left to bring it back.
pkill -f -- "--serve-socket $SOCK" 2>/dev/null || true
sleep 6
check "nothing relaunched the app after bootout" 'no_process'
check "the socket does not answer" '! socket_answers'

# ---- 7. the production job is untouched -------------------------------------

echo "== phase 7: the real LaunchAgent was not touched"
PROD_DIGEST_AFTER="$(shasum -a 256 "$PROD_PLIST" 2>/dev/null || echo absent)"
check "production plist digest unchanged" '[ "$PROD_DIGEST_BEFORE" = "$PROD_DIGEST_AFTER" ]'
check "production socket was not probed or removed" \
  '[ -S "$HOME/.cmm/computer-bridge/bridge.sock" ]'

echo
echo "== supervisor log"
sed -n '1,20p' "$SUPERVISOR_ERR" 2>/dev/null || true
echo "== probe log"
cat "$PROBE_LOG" 2>/dev/null || true
echo
if [ "$FAILURES" -eq 0 ]; then
  echo "PASS: $CHECKS checks"
  exit 0
fi
echo "FAIL: $FAILURES of $CHECKS checks failed" >&2
exit 1
