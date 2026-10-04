#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
app_dir="$project_dir/build/EventKitBridge.app"
contents_dir="$app_dir/Contents"
cache_dir="$project_dir/build/module-cache"
sdk_dir="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"

mkdir -p "$contents_dir/MacOS" "$cache_dir"
cp "$project_dir/Info.plist" "$contents_dir/Info.plist"
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    -Xcc "-fmodules-cache-path=$cache_dir" \
    -framework AppKit -framework EventKit \
    "$project_dir/Sources/main.swift" \
    -o "$contents_dir/MacOS/EventKitBridge"

# Default signing is ad hoc for build validation only. A stable, trusted signing
# identity is needed before permission and lock-screen tests on the user's Mac.
sign_identity=${EVENTKIT_SIGN_IDENTITY:--}
codesign --force --sign "$sign_identity" --options runtime \
    --entitlements "$project_dir/Entitlements.plist" "$app_dir"
printf '%s\n' "$app_dir"
