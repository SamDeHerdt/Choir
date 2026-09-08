#!/bin/bash
# Turns icon.png (1024×1024) into AppIcon.icns, which build.sh bundles.
# Without an icon.png it renders the placeholder from tool/render-icon.swift.
set -euo pipefail
cd "$(dirname "$0")"
if [ ! -f icon.png ]; then
  echo "No icon.png — using the placeholder from tool/."
  cp tool/placeholder-icon.png icon.png
fi
ICONSET=$(mktemp -d)/AppIcon.iconset; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s*2)); sips -z $d $d icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o AppIcon.icns
echo "Wrote AppIcon.icns from icon.png"
