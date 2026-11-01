#!/bin/bash
# Build (and optionally install) the CMM Computer Use.app macOS helper.
#
#   scripts/build-helper.sh [--install]
#
# The helper is a small LSUIElement Swift application whose only job is the
# native macOS observation/action primitives that require a grantable TCC
# application identity. It contains no policy of its own beyond the shared
# interaction policy in apps/macos/Shared: the deployment names the mode and the
# allowlist, and the helper enforces the stricter of the two.
#
# Identity (both are load-bearing):
#   Display name: CMM Computer Use
#   Bundle ID:    com.cmm.chat.computer-use   (the TCC designated requirement)
#
# Signing, in order of preference:
#   1. $CMM_BRIDGE_SIGN_IDENTITY if set
#   2. "Developer ID Application" from the login keychain (distribution)
#   3. "Apple Development" from the login keychain (local development)
#   4. ad-hoc, with an explicit warning: TCC grants will NOT survive a rebuild
#
# A Developer ID signature without notarization is still refused by Gatekeeper
# on another Mac; scripts/notarize-helper.sh performs that step when the
# credentials exist. This script never claims notarization.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SRC="$REPO/apps/macos"
SRC="$APP_SRC/CMMComputerUse/main.swift"
SRC_STREAM="$APP_SRC/CMMComputerUse/WindowStream.swift"
SHARED="$APP_SRC/Shared/BridgeTargeting.swift"
SHARED_POLICY="$APP_SRC/Shared/ComputerUsePolicy.swift"
SHARED_AUTHZ="$APP_SRC/Shared/ComputerUseAuthorization.swift"
SHARED_CLIENT="$APP_SRC/Shared/ComputerUseClientIdentity.swift"
PLIST="$APP_SRC/CMMComputerUse/Info.plist"
APP_NAME="CMMComputerUse.app"
APP_DISPLAY_NAME="CMM Computer Use"
BUNDLE_ID="com.cmm.chat.computer-use"
VERSION="${CMM_HELPER_VERSION:-0.1.0}"
INSTALL_DIR="${CMM_BRIDGE_INSTALL_DIR:-$HOME/Applications}"
APP="$INSTALL_DIR/$APP_NAME"
BUILD_DIR="${CMM_HELPER_BUILD_DIR:-$REPO/build}"

for required in "$SRC" "$SRC_STREAM" "$SHARED" "$SHARED_POLICY" "$SHARED_AUTHZ" "$SHARED_CLIENT" "$PLIST"; do
  if [ ! -f "$required" ]; then
    echo "missing source: $required" >&2; exit 1
  fi
done

mkdir -p "$BUILD_DIR"
STAGE="$BUILD_DIR/$APP_NAME"
rm -rf "$STAGE"

echo "== compiling CMMComputerUse"
swiftc -O -target arm64-apple-macosx15.0 \
  -framework ApplicationServices -framework AppKit -framework CoreGraphics -framework Foundation \
  -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo -framework CoreImage -framework ImageIO \
  -framework Security \
  "$SHARED" "$SHARED_POLICY" "$SHARED_AUTHZ" "$SHARED_CLIENT" "$SRC_STREAM" "$SRC" \
  -o "$BUILD_DIR/CMMComputerUse"

echo "== assembling $APP_NAME"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BUILD_DIR/CMMComputerUse" "$STAGE/Contents/MacOS/CMMComputerUse"
cp "$PLIST" "$STAGE/Contents/Info.plist"
chmod +x "$STAGE/Contents/MacOS/CMMComputerUse"

# The bundle identity IS the TCC identity: expand the build variables the
# source plist carries so a regenerated project can never ship a placeholder.
STAGED_PLIST="$STAGE/Contents/Info.plist"
plist_set() {
  /usr/libexec/PlistBuddy -c "Set :$1 $2" "$STAGED_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :$1 string $2" "$STAGED_PLIST"
}
plist_set CFBundleIdentifier "$BUNDLE_ID"
plist_set CFBundleExecutable CMMComputerUse
plist_set CFBundleName "$APP_DISPLAY_NAME"
plist_set CFBundleDisplayName "$APP_DISPLAY_NAME"
plist_set CFBundleShortVersionString "$VERSION"
plist_set CFBundleDevelopmentRegion en

# A staged bundle whose visible name or identity regressed must not be shipped.
STAGED_NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleName" "$STAGED_PLIST")
STAGED_DISPLAY=$(/usr/libexec/PlistBuddy -c "Print :CFBundleDisplayName" "$STAGED_PLIST")
if [ "$STAGED_NAME" != "$APP_DISPLAY_NAME" ] || [ "$STAGED_DISPLAY" != "$APP_DISPLAY_NAME" ]; then
  echo "refusing: staged visible name is '$STAGED_NAME' / '$STAGED_DISPLAY', expected '$APP_DISPLAY_NAME'" >&2
  exit 1
fi
if ! grep -q "<string>$BUNDLE_ID</string>" "$STAGED_PLIST"; then
  echo "refusing: staged Info.plist lacks the literal bundle id" >&2; exit 1
fi
if grep -q '\$(PRODUCT' "$STAGED_PLIST"; then
  echo "refusing: staged Info.plist holds unexpanded build variables" >&2; exit 1
fi

identities=$(security find-identity -v -p codesigning 2>/dev/null || true)
pick_identity() {
  if [ -n "${CMM_BRIDGE_SIGN_IDENTITY:-}" ]; then printf '%s' "$CMM_BRIDGE_SIGN_IDENTITY"; return; fi
  local devid
  devid=$(printf '%s\n' "$identities" | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
  if [ -n "$devid" ]; then printf '%s' "$devid"; return; fi
  local dev
  dev=$(printf '%s\n' "$identities" | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)
  printf '%s' "$dev"
}
IDENTITY="$(pick_identity)"
SIGNED_WITH="ad-hoc"
if [ -n "$IDENTITY" ]; then
  echo "== signing with: $IDENTITY"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$STAGE"
  SIGNED_WITH="$IDENTITY"
else
  echo "!! no signing identity found; ad-hoc signing (TCC grants will NOT survive rebuilds)"
  codesign --force --sign - "$STAGE"
fi

echo "== verifying"
codesign --verify --deep --strict "$STAGE"
codesign -dv --verbose=4 "$STAGE" 2>&1 | sed -n '1,10p'

if [ "${1:-}" = "--install" ]; then
  echo "== installing to $APP"
  mkdir -p "$INSTALL_DIR"
  if [ -d "$APP" ]; then rm -rf "$APP"; fi
  cp -R "$STAGE" "$APP"
  # LaunchServices caches the app's name and is what TCC prompts and Control
  # Center resolve for this bundle id. Refresh the record on every install so a
  # renamed bundle never keeps showing the previous build's name.
  LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -f "$APP" || echo "warning: lsregister refresh failed" >&2
  fi
  echo "installed: $APP"
  echo "signed_with: $SIGNED_WITH"
  echo "next: scripts/install-helper.sh"
else
  echo "staged: $STAGE"
  echo "signed_with: $SIGNED_WITH"
  echo "next: scripts/build-helper.sh --install"
fi
