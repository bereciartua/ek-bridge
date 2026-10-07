#!/bin/sh
set -eu

# Checks the version before a release. Info.plist is the one source of it:
# CFBundleShortVersionString is x.y.z and CFBundleVersion a whole number higher
# than in the newest earlier v* tag; a tag, if given, is v<x.y.z>;
# CHANGELOG.md has a "## [x.y.z]" section for the release notes; and
# server.json, the MCP Registry entry, has the same version.
#
# Usage: sh scripts/check_version.sh [TAG]
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
plist="$project_dir/Info.plist"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")

fail() { printf 'check_version: %s\n' "$*" >&2; exit 1; }

printf '%s\n' "$version" | grep -Eqx '[0-9]+\.[0-9]+\.[0-9]+' \
    || fail "CFBundleShortVersionString \"$version\" isn't x.y.z"
case "$build" in
    ''|*[!0-9]*) fail "CFBundleVersion \"$build\" isn't a whole number" ;;
esac
if [ "$#" -gt 0 ] && [ "$1" != "v$version" ]; then
    fail "tag $1 doesn't match Info.plist: expected v$version"
fi

previous=$(git -C "$project_dir" tag --list 'v*' --sort=-v:refname | grep -vx "v$version" | head -n 1 || true)
if [ -n "$previous" ]; then
    previous_build=$(git -C "$project_dir" show "$previous:Info.plist" \
        | plutil -extract CFBundleVersion raw -o - -)
    [ "$build" -gt "$previous_build" ] \
        || fail "CFBundleVersion $build isn't higher than $previous's $previous_build"
fi

grep -q "^## \[$version\]" "$project_dir/CHANGELOG.md" \
    || fail "CHANGELOG.md has no \"## [$version]\" section"
if [ -f "$project_dir/server.json" ]; then
    registry_version=$(plutil -extract version raw -o - "$project_dir/server.json" 2>/dev/null || true)
    [ "$registry_version" = "$version" ] \
        || fail "server.json has version \"$registry_version\", expected $version"
fi
printf 'check_version: %s (%s) passed%s\n' "$version" "$build" "${previous:+, after $previous}"
