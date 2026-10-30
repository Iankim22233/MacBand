#!/bin/bash
# Builds MacBand.app (release) next to this script.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/MacBand"
APP="MacBand.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacBand"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
echo -n "APPL????" > "$APP/Contents/PkgInfo"
# Ad-hoc signature, no hardened runtime: lets MacBand load plugins from any developer.
codesign --force --deep --sign - "$APP"
echo "Built $(pwd)/$APP"
