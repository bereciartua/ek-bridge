#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
output_dir=${EVENTKIT_OUTPUT_DIR:-"$project_dir/build"}
app_dir="$output_dir/EventKitBridge.app"
contents_dir="$app_dir/Contents"
cache_dir="$project_dir/build/module-cache"
sdk_dir="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
write_flag=""
if [ "${EVENTKIT_LIVE_WRITES:-0}" = "1" ]; then
    write_flag="-D EVENTKIT_LIVE_WRITES"
fi

mkdir -p "$contents_dir/MacOS" "$cache_dir"
cp "$project_dir/Info.plist" "$contents_dir/Info.plist"
xcrun swiftc -parse-as-library \
    $write_flag \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    -Xcc "-fmodules-cache-path=$cache_dir" \
    -framework AppKit -framework EventKit -framework Security -framework ServiceManagement \
    "$project_dir/Sources/main.swift" \
    "$project_dir/Sources/BridgeProtocol.swift" \
    "$project_dir/Sources/CommandPolicy.swift" \
    "$project_dir/Sources/MutationPolicy.swift" \
    "$project_dir/Sources/EventKitCommands.swift" \
    "$project_dir/Sources/WriteJournal.swift" \
    "$project_dir/Sources/LocalBridge.swift" \
    -o "$contents_dir/MacOS/EventKitBridge"

# Default signing is ad hoc for build validation only. A stable, trusted signing
# identity is needed before permission and lock-screen tests on the user's Mac.
sign_identity=${EVENTKIT_SIGN_IDENTITY:--}
codesign --force --sign "$sign_identity" --options runtime \
    --entitlements "$project_dir/Entitlements.plist" "$app_dir"
printf '%s\n' "$app_dir"
