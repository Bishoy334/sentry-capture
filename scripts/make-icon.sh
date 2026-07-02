#!/bin/bash
# assets/icon-1024.png -> assets/AppIcon.icns
set -e
cd "$(dirname "$0")/.."
SRC=assets/icon-1024.png
SET=assets/AppIcon.iconset
rm -rf "$SET" && mkdir -p "$SET"
for s in 16 32 128 256 512; do
    sips -z $s $s "$SRC" --out "$SET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$SRC" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o assets/AppIcon.icns
rm -rf "$SET"
echo "wrote assets/AppIcon.icns"
