#!/bin/bash
# Notarize and staple the helper. Requires a Developer ID Application identity
# and a notarytool keychain profile; neither is invented here.
#
#   scripts/notarize-helper.sh --profile <notarytool-profile> [--app <path>]
#
# Prepare the credentials once, interactively, with:
#
#   xcrun notarytool store-credentials <profile> \
#     --apple-id <apple-id> --team-id <TEAMID> --password <app-specific-password>
#
# That command needs the account password and an app-specific password: it is a
# human step and this script refuses to fake it.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${CMM_BRIDGE_APP:-$REPO/build/CMMComputerUse.app}"
PROFILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --app) APP="${2:-}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$PROFILE" ]; then
  echo "usage: scripts/notarize-helper.sh --profile <notarytool-profile>" >&2
  exit 2
fi
if [ ! -d "$APP" ]; then
  echo "missing $APP — run scripts/build-helper.sh first" >&2
  exit 1
fi

IDENTITY=$(codesign -dv --verbose=4 "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p' | head -1)
if [ -z "$IDENTITY" ]; then
  echo "refusing: $APP is not signed with a Developer ID Application identity" >&2
  echo "  found: $(codesign -dv --verbose=4 "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)" >&2
  exit 1
fi
if ! codesign -dv --verbose=4 "$APP" 2>&1 | grep -q 'flags=.*runtime'; then
  echo "refusing: $APP was signed without the Hardened Runtime" >&2
  exit 1
fi

ZIP="${APP%.app}-notarize.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "== submitting $ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "== stapling"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "== Gatekeeper assessment"
spctl --assess --type execute --verbose=4 "$APP"

rm -f "$ZIP"
echo "notarized and stapled: $APP"
