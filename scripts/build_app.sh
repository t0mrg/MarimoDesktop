#!/bin/bash
# Builds a release binary and assembles an ad-hoc signed MarimoDesktop.app in build/.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN="$(swift build -c release --show-bin-path)/MarimoDesktop"
APP="build/MarimoDesktop.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MarimoDesktop"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --options runtime --entitlements Resources/MarimoDesktop.entitlements --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $(pwd)/$APP"
