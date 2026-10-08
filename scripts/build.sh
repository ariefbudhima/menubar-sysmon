#!/usr/bin/env bash
#
# Builds SysMonBar and packages it as a normal .app bundle.
#
# The bundle matters: LSUIElement=true is what keeps the process out of the Dock
# and the app switcher, which a bare executable cannot express.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="SysMon"
BUNDLE_ID="com.arief.sysmonbar"
APP="$ROOT/dist/$APP_NAME.app"

echo "==> swift build -c release"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/SysMonBar"
if [ ! -x "$BIN" ]; then
    echo "error: executable not found at $BIN" >&2
    exit 1
fi

echo "==> packaging $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough for the system to trust the bundle locally.
if codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" 2>/dev/null; then
    echo "==> ad-hoc signed"
else
    echo "==> warning: ad-hoc codesign failed, the app still runs"
fi

echo "==> done: $APP"
