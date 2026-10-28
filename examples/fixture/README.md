# Rehearsal fixture

A deliberately boring macOS app for checking the pipeline on something whose
whole state is knowable: one window, a counter, a text field and a button that
recreates the window. It holds no data and touches no personal application.

It writes its own state to a JSON file after every change, so a test can verify
the **effect** independently of the accessibility tree it is reading: the same
fact seen through two channels is evidence; seen through one, it is a loop.

## Build it

```bash
cd examples/fixture
mkdir -p "CMM Computer Use Fixture.app/Contents/MacOS"
swiftc -O -target arm64-apple-macosx15.0 -framework AppKit -framework Foundation \
  main.swift -o "CMM Computer Use Fixture.app/Contents/MacOS/Fixture"
cat > "CMM Computer Use Fixture.app/Contents/Info.plist" <<'PLIST'
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
codesign --force --sign - "CMM Computer Use Fixture.app"
```

`CFBundleExecutable` must match the file name in `Contents/MacOS` exactly; a
mismatch produces a "damaged app" dialog that costs a round trip.

## Use it

```bash
export CMM_CU_FIXTURE_STATE="$HOME/.cmm/fixture-state.json"
open -g -n "CMM Computer Use Fixture.app"      # -g: no focus change
cat "$CMM_CU_FIXTURE_STATE"
```

Authorize `com.example.computer-use-fixture` in the helper's allowlist with
`scopes: ["observe", "control"]`. Then drive it through the plugin and compare
the state file with what the agent claims it did.
