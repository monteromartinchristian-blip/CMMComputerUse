#!/bin/sh
# Supervisor for the CMM Computer Use LaunchAgent.
#
# WHY THIS EXISTS
#
# The job used to run `/usr/bin/open -n -W -g -a CMMComputerUse.app …` directly,
# with `KeepAlive: true`. That is correct while the instance `open` created is
# the one serving the socket. It stops being correct the moment a second
# instance exists — started by the person, by an installer, or by a race between
# two launches. The second instance sees "another helper already serves",
# exits 0, `open -W` returns, launchd restarts the job, a third instance exits,
# and so on: a restart loop that spawns processes and writes log lines while the
# Mac is already being served correctly. The helper log recorded 7390 of those
# benign exits over the job's life.
#
# WHAT THIS DOES, AND NOTHING ELSE
#
#   1. If something answers on the socket, the deployment is already served.
#      Wait for it to go away instead of spawning a duplicate. The job stays the
#      supervising process, so launchd has no reason to respawn it.
#   2. Otherwise launch through LaunchServices exactly as before. That is
#      load-bearing: ScreenCaptureKit attributes a capture to the RESPONSIBLE
#      app, and a helper started as a bare Contents/MacOS/<exe> has none, so
#      macOS attributes the capture to the system UI agent instead.
#
# It does not touch TCC, the policy file, the socket directory, the bundle or
# the code signature. It adds no privilege: it runs as the same user, with the
# same arguments the plist already carried.
#
# `--open` exists so the isolated verification can exercise this exact script
# with a stand-in launcher. The product plist always passes /usr/bin/open.

set -u

APP=""
SOCKET=""
POLICY="background"
LOG_FILE=""
POLICY_FILE=""
OPEN_BIN="/usr/bin/open"
POLL_SECONDS=2

usage() {
  echo "run-helper: --app <bundle> --socket <path> [--policy <mode>]" \
       "[--log-file <path>] [--policy-file <path>] [--open <launcher>]" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --app)         [ $# -ge 2 ] || usage; APP="$2"; shift 2 ;;
    --socket)      [ $# -ge 2 ] || usage; SOCKET="$2"; shift 2 ;;
    --policy)      [ $# -ge 2 ] || usage; POLICY="$2"; shift 2 ;;
    --log-file)    [ $# -ge 2 ] || usage; LOG_FILE="$2"; shift 2 ;;
    --policy-file) [ $# -ge 2 ] || usage; POLICY_FILE="$2"; shift 2 ;;
    --open)        [ $# -ge 2 ] || usage; OPEN_BIN="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[ -n "$APP" ] || usage
[ -n "$SOCKET" ] || usage
[ -d "$APP" ] || { echo "run-helper: missing $APP" >&2; exit 2; }
[ -x "$OPEN_BIN" ] || { echo "run-helper: missing launcher $OPEN_BIN" >&2; exit 2; }

# Can a connection be established right now? A stale socket FILE that nobody
# listens on is not "serving", and must not stop a relaunch.
serving() {
  [ -S "$SOCKET" ] || return 1
  if [ -x /usr/bin/nc ]; then
    # `-w` with an immediate EOF: BSD nc's `-z` scan is not reliable on a Unix
    # socket on this platform (it reports failure against a listener that
    # answers), so the probe is a real connect with a short bound.
    /usr/bin/nc -U -w 2 "$SOCKET" </dev/null >/dev/null 2>&1
    return $?
  fi
  # No probe available: assume served if the path exists. This is the
  # conservative direction (do not spawn a duplicate), and it is documented.
  return 0
}

if serving; then
  echo "run-helper: $(date +%H:%M:%S) a helper already serves $SOCKET; waiting instead of spawning a duplicate"
  while serving; do
    sleep "$POLL_SECONDS"
  done
  echo "run-helper: $(date +%H:%M:%S) the serving helper is gone; asking launchd to restart the job"
  exit 1
fi

# LaunchServices owns the process and its screen-capture attribution. `-g`
# keeps it in the background: this job must never bring anything to the front.
if [ -n "$POLICY_FILE" ]; then
  exec "$OPEN_BIN" -n -W -g -a "$APP" --args \
    --serve-socket "$SOCKET" \
    --policy "$POLICY" \
    --policy-file "$POLICY_FILE" \
    --log-file "$LOG_FILE"
fi
exec "$OPEN_BIN" -n -W -g -a "$APP" --args \
  --serve-socket "$SOCKET" \
  --policy "$POLICY" \
  --log-file "$LOG_FILE"
