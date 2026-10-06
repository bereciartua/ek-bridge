#!/bin/sh
set -eu

# Checks a built app's layout: every executable has each architecture asked for
# and the app's minimum macOS, the command-line tools are signed with the
# hardened runtime and their own identifiers, the license files are inside, and
# the whole bundle verifies. Used by CI and the release script.
#
# Usage: sh scripts/check_bundle.sh APP [ARCH...]   (default: this Mac's arch)
app=${1:?usage: check_bundle.sh APP [ARCH...]}
shift
[ "$#" -gt 0 ] || set -- "$(uname -m)"
contents="$app/Contents"
plist="$contents/Info.plist"
minimum=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")
executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")

fail() { printf 'check_bundle: %s\n' "$*" >&2; exit 1; }

for name in "$executable" bridge-mcp bridge-client; do
    file="$contents/MacOS/$name"
    [ -f "$file" ] && [ -x "$file" ] || fail "$name is missing"
    present=$(lipo -archs "$file")
    for arch in "$@"; do
        case " $present " in *" $arch "*) ;; *) fail "$name lacks $arch (has: $present)" ;; esac
        minos=$(vtool -arch "$arch" -show-build "$file" | awk '$1 == "minos" { print $2 }')
        [ "$minos" = "$minimum" ] || fail "$name ($arch) needs macOS $minos, not $minimum"
    done
done

for tool in bridge-mcp bridge-client; do
    details=$(codesign --display --verbose=2 "$contents/MacOS/$tool" 2>&1)
    printf '%s\n' "$details" | grep -qx "Identifier=$bundle_id.$tool" \
        || fail "$tool isn't signed as $bundle_id.$tool"
    printf '%s\n' "$details" | grep -q 'flags=.*runtime' || fail "$tool lacks the hardened runtime"
done

for file in LICENSE NOTICE; do
    [ -s "$contents/Resources/$file" ] || fail "Resources/$file is missing"
done
codesign --verify --deep --strict "$app" || fail "the signature doesn't verify"
printf 'check_bundle: %s passed (%s)\n' "$(basename "$app")" "$*"
