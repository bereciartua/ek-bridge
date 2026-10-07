#!/bin/sh
set -eu

# Checks a built app's layout: every executable has each architecture asked for
# and the app's minimum macOS, the command-line tools are signed with the
# hardened runtime and their own identifiers, Sparkle is embedded without its
# XPC services and signed like the app, the app finds it through its rpath and
# knows its feed, both forms of the icon and the license files are inside, and
# the whole bundle verifies.
# Used by CI and the release script.
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

# The updater: Sparkle in Contents/Frameworks, every part signed with the
# hardened runtime and by the app's team (none for ad hoc), and only an ad hoc
# build may skip library validation.
sparkle="$contents/Frameworks/Sparkle.framework"
[ -f "$sparkle/Versions/B/Sparkle" ] || fail "Frameworks/Sparkle.framework is missing"
present=$(lipo -archs "$sparkle/Versions/B/Sparkle")
for arch in "$@"; do
    case " $present " in *" $arch "*) ;; *) fail "Sparkle lacks $arch (has: $present)" ;; esac
done
[ ! -e "$sparkle/Versions/B/XPCServices" ] || fail "Sparkle's XPC services are inside (they're for sandboxed apps)"
otool -l "$contents/MacOS/$executable" | grep -q 'path @executable_path/../Frameworks ' \
    || fail "$executable has no rpath to Contents/Frameworks"
team() { codesign --display --verbose=2 "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p'; }
app_team=$(team "$app")
for part in "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app" "$sparkle"; do
    details=$(codesign --display --verbose=2 "$part" 2>&1)
    printf '%s\n' "$details" | grep -q 'flags=.*runtime' || fail "$part lacks the hardened runtime"
    [ "$(team "$part")" = "$app_team" ] || fail "$part isn't signed by the app's team ($app_team)"
done
if codesign --display --entitlements - --xml "$app" 2>/dev/null | grep -q 'disable-library-validation'; then
    [ "$app_team" = "not set" ] || fail "a team-signed app must keep library validation"
fi
for key in SUFeedURL SUPublicEDKey; do
    /usr/libexec/PlistBuddy -c "Print :$key" "$plist" > /dev/null 2>&1 || fail "Info.plist has no $key"
done
[ -s "$contents/Resources/Sparkle-LICENSE.txt" ] || fail "Resources/Sparkle-LICENSE.txt is missing"

# The icon: the .icns for macOS 14 and 15, and the compiled Icon Composer
# document for macOS 26 and later (CI and releases build with Xcode).
[ -s "$contents/Resources/AppIcon.icns" ] || fail "Resources/AppIcon.icns is missing"
[ -s "$contents/Resources/Assets.car" ] || fail "Resources/Assets.car is missing (build with Xcode for actool)"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$plist" 2>/dev/null)" = AppIcon ] \
    || fail "Info.plist has no CFBundleIconName AppIcon"

for file in LICENSE NOTICE; do
    [ -s "$contents/Resources/$file" ] || fail "Resources/$file is missing"
done
codesign --verify --deep --strict "$app" || fail "the signature doesn't verify"
printf 'check_bundle: %s passed (%s)\n' "$(basename "$app")" "$*"
