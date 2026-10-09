#!/bin/sh
set -eu

# Builds the drag-to-install disk image: the app beside an Applications link
# over a background that says what to do, in a window without toolbar or
# sidebar, with the app icon as the volume icon. release.sh signs and
# notarizes the result. scripts/dmg_window.swift draws the background and
# writes the window's Finder settings; nothing scripts Finder, so it runs in CI.
#
# Usage: sh scripts/make_dmg.sh APP VOLUME_NAME OUTPUT.dmg
app=${1:?usage: make_dmg.sh APP VOLUME_NAME OUTPUT.dmg}
volume_name=${2:?usage: make_dmg.sh APP VOLUME_NAME OUTPUT.dmg}
output=${3:?usage: make_dmg.sh APP VOLUME_NAME OUTPUT.dmg}

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$project_dir/scripts/sdk.sh"
fail() { printf 'make_dmg: %s\n' "$*" >&2; exit 1; }
[ -d "$app" ] || fail "$app doesn't exist"
app_name=$(basename "$app")

work=$(mktemp -d "${TMPDIR:-/tmp}/make_dmg.XXXXXX")
device=
cleanup() {
    [ -z "$device" ] || hdiutil detach -quiet -force "$device" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

xcrun swiftc -sdk "$sdk_dir" "$project_dir/scripts/dmg_window.swift" -o "$work/dmg_window"
"$work/dmg_window" background "$work/background.png" 1
"$work/dmg_window" background "$work/background@2x.png" 2

# The image's contents. The background and volume icon start with a dot, so
# Finder doesn't show them.
staging="$work/staging"
mkdir -p "$staging"
ditto "$app" "$staging/$app_name"
ln -s /Applications "$staging/Applications"
tiffutil -cathidpicheck "$work/background.png" "$work/background@2x.png" -out "$staging/.background.tiff" \
    > /dev/null 2>&1 || fail "tiffutil couldn't combine the 1x and 2x backgrounds"
cp "$project_dir/Resources/AppIcon.icns" "$staging/.VolumeIcon.icns"

# A writable image with room for the .DS_Store, mounted where only we see it.
size_kb=$(( $(du -sk "$staging" | cut -f1) + 16384 ))
hdiutil create -quiet -ov -volname "$volume_name" -srcfolder "$staging" -fs HFS+ -format UDRW \
    -size "${size_kb}k" "$work/writable.dmg"
mount_point="$work/volume"
mkdir -p "$mount_point"
device=$(hdiutil attach -nobrowse -noautoopen -noverify -readwrite -mountpoint "$mount_point" \
    "$work/writable.dmg" | awk 'NR == 1 { print $1 }')
[ -n "$device" ] || fail "couldn't mount the writable image"

"$work/dmg_window" layout "$mount_point" "$mount_point/.background.tiff" "$app_name"
# The custom-icon flag on the volume's root makes Finder use .VolumeIcon.icns.
xcrun SetFile -a C "$mount_point"
rm -rf "$mount_point/.fseventsd" "$mount_point/.Trashes"

sync
attempt=1
until hdiutil detach -quiet "$device"; do
    [ "$attempt" -lt 5 ] || fail "couldn't detach $device"
    attempt=$((attempt + 1))
    sleep 2
done
device=

# Read-only and compressed (LZFSE), the image people download.
hdiutil convert -quiet -ov "$work/writable.dmg" -format ULFO -o "$output"
