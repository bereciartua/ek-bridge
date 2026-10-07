#!/bin/sh
set -eu

# Regenerates Resources/AppIcon.icns and AppIcon-1024.png from make_icon.swift.
# The .icns is committed, so build.sh doesn't need to run this. Each size is
# drawn at its own pixel size; 32 px and below get the simpler small drawing.
resources=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
xcrun swiftc -sdk "$(xcrun --show-sdk-path)" "$resources/make_icon.swift" -o "$work/make_icon"
iconset="$work/AppIcon.iconset"
mkdir "$iconset"
for size in 16 32 128 256 512; do
    "$work/make_icon" "$iconset/icon_${size}x${size}.png" "$size"
    "$work/make_icon" "$iconset/icon_${size}x${size}@2x.png" $((size * 2))
done
iconutil -c icns "$iconset" -o "$resources/AppIcon.icns"
cp "$iconset/icon_512x512@2x.png" "$resources/AppIcon-1024.png"
printf '%s\n' "$resources/AppIcon.icns"
