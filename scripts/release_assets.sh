#!/bin/sh
set -eu

# Gives a release's disk image a second name that never changes, and writes
# SHA256SUMS. release.sh runs it once the DMG is notarized and stapled and the
# zip is built:
#
#   sh scripts/release_assets.sh DIST APP_NAME VERSION
#
# DIST/APP_NAME-VERSION.dmg is copied to DIST/APP_NAME.dmg (EKBridge.dmg), so
# https://github.com/<repo>/releases/latest/download/EKBridge.dmg always fetches
# the newest published release: GitHub keeps asset names as uploaded and
# redirects latest/download/<name> to the latest release's asset of that name.
# The versioned name stays too: the Homebrew cask, the release notes and older
# links use it. SHA256SUMS lists the versioned DMG, the stable one and the zip.
dist=${1:?usage: release_assets.sh DIST APP_NAME VERSION}
app_name=${2:?usage: release_assets.sh DIST APP_NAME VERSION}
version=${3:?usage: release_assets.sh DIST APP_NAME VERSION}

fail() { printf 'release_assets: %s\n' "$*" >&2; exit 1; }

versioned="$app_name-$version.dmg"
stable="$app_name.dmg"
zip="$app_name-$version.zip"
[ -f "$dist/$versioned" ] || fail "$dist/$versioned doesn't exist"
[ -f "$dist/$zip" ] || fail "$dist/$zip doesn't exist"

rm -f "$dist/$stable"
cp "$dist/$versioned" "$dist/$stable"
cmp -s "$dist/$versioned" "$dist/$stable" || fail "$stable isn't an exact copy of $versioned"
(cd "$dist" && shasum -a 256 "$versioned" "$stable" "$zip" > SHA256SUMS)
