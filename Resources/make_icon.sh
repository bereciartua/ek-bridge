#!/bin/sh
set -eu

# Regenerates Resources/AppIcon.icns from make_icon.swift. The .icns is
# committed, so build.sh doesn't need to run this.
resources=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
xcrun swiftc -sdk "$(xcrun --show-sdk-path)" "$resources/make_icon.swift" -o "$work/make_icon"
"$work/make_icon" "$work/icon-1024.png"
iconset="$work/AppIcon.iconset"
mkdir "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$work/icon-1024.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$work/icon-1024.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$resources/AppIcon.icns"
cp "$work/icon-1024.png" "$resources/AppIcon-1024.png"
printf '%s\n' "$resources/AppIcon.icns"
