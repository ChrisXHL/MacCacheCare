#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
ICONSET="$PWD/build/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" Assets/Logo-master.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    /usr/bin/sips -z "$double" "$double" Assets/Logo-master.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$ICONSET" -o Assets/AppIcon.icns
/usr/bin/sips -z 256 256 Assets/Logo-master.png --out Assets/BrandIcon.png >/dev/null
