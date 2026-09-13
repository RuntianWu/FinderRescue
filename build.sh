#!/bin/bash
# Builds "Finder Rescue.app" (universal: Apple silicon + Intel) in the project root.
# Pass --install to also copy it to /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"

if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

echo "Building Finder Rescue (release, universal)…"
swift build -c release --arch arm64 --arch x86_64
BIN_PATH="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/FinderRescue"

APP="Finder Rescue.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/FinderRescue"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x FinderRescue 2>/dev/null || true
    rm -rf "/Applications/Finder Rescue.app"
    ditto "$APP" "/Applications/Finder Rescue.app"
    open "/Applications/Finder Rescue.app"
    echo "Installed to /Applications and launched"
else
    echo "Run it with: open \"$(pwd)/$APP\""
fi
