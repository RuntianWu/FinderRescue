#!/bin/bash
# Renders the icon with Core Graphics (scripts/render_icon.swift) and rebuilds
# Resources/FinderRescue_icon.png (1024 px, also used by software.runtian.uk) and Resources/AppIcon.icns.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="Resources/FinderRescue_icon.png"
swift scripts/render_icon.swift "$SRC"

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$SRC" --out "$ICONSET/icon_${size}x${size}.png" > /dev/null
    double=$((size * 2))
    sips -z $double $double "$SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" > /dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
rm -rf "$(dirname "$ICONSET")"

echo "Wrote $SRC and Resources/AppIcon.icns"
