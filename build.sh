#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
output_dir=${EVENTKIT_OUTPUT_DIR:-"$project_dir/build"}
# The app and its executable are named after CFBundleExecutable (EKBridge.app).
app_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$project_dir/Info.plist")
app_dir="$output_dir/$app_name.app"
contents_dir="$app_dir/Contents"
cache_dir="$project_dir/build/module-cache"
. "$project_dir/scripts/sdk.sh"
# This Mac's architecture by default, for fast development builds. Releases set
# EVENTKIT_ARCHS="arm64 x86_64" for a universal app.
archs=${EVENTKIT_ARCHS:-$(uname -m)}
minimum_macos=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$project_dir/Info.plist")
slices_dir="$output_dir/slices"
test_flag=""
if [ "${EVENTKIT_SYNTHETIC_TEST:-0}" = "1" ]; then
    test_flag="-D EVENTKIT_SYNTHETIC_TEST"
fi
if [ "${EVENTKIT_UI_REVIEW:-0}" = "1" ]; then
    test_flag="-D EVENTKIT_UI_REVIEW"
fi

mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources" "$cache_dir"
cp "$project_dir/Info.plist" "$contents_dir/Info.plist"
cp "$project_dir/Resources/AppIcon.icns" "$contents_dir/Resources/AppIcon.icns"
cp "$project_dir/LICENSE" "$project_dir/NOTICE" "$contents_dir/Resources/"

# The app is every Swift file in Sources/ except the two command-line tools.
# Test-only routes (UIReview, Synthetic*) compile to nothing without their -D flag.
set --
for file in "$project_dir"/Sources/*.swift "$project_dir"/Sources/MCP/*.swift; do
    case "$file" in
        */BridgeClient.swift|*/MCPLauncher.swift) ;;
        *) set -- "$@" "$file" ;;
    esac
done

rm -rf "$slices_dir"
for arch in $archs; do
    slice="$slices_dir/$arch"
    target="$arch-apple-macosx$minimum_macos"
    mkdir -p "$slice"
    xcrun swiftc -parse-as-library \
        $test_flag \
        -sdk "$sdk_dir" \
        -module-cache-path "$cache_dir" \
        -Xcc "-fmodules-cache-path=$cache_dir" \
        -target "$target" \
        -framework AppKit -framework EventKit -framework Security -framework ServiceManagement \
        -framework SwiftUI -framework Network -framework IOKit \
        "$@" \
        -o "$slice/$app_name"

    # The command-line client (Contents/MacOS/bridge-client): no AppKit or EventKit.
    xcrun swiftc -sdk "$sdk_dir" \
        -module-cache-path "$cache_dir" \
        -target "$target" \
        "$project_dir/Sources/BridgeProtocol.swift" \
        "$project_dir/Sources/AppIdentity.swift" \
        "$project_dir/Sources/OutcomePresentation.swift" \
        "$project_dir/Sources/SafePath.swift" \
        "$project_dir/Sources/BridgeClient.swift" \
        -o "$slice/bridge-client"

    # The MCP launcher agents run (Contents/MacOS/bridge-mcp): no AppKit or EventKit.
    xcrun swiftc -parse-as-library -sdk "$sdk_dir" \
        -module-cache-path "$cache_dir" \
        -target "$target" \
        "$project_dir/Sources/MCPLauncher.swift" \
        "$project_dir/Sources/SafePath.swift" \
        "$project_dir/Sources/AppIdentity.swift" \
        -o "$slice/bridge-mcp"
done

for name in "$app_name" bridge-client bridge-mcp; do
    set --
    for arch in $archs; do set -- "$@" "$slices_dir/$arch/$name"; done
    rm -f "$contents_dir/MacOS/$name"
    lipo -create "$@" -output "$contents_dir/MacOS/$name"
done
rm -rf "$slices_dir"

# Scripts and client.py still find the client at build/bridge-client.
rm -f "$output_dir/bridge-client"
ln -s "$app_name.app/Contents/MacOS/bridge-client" "$output_dir/bridge-client"

# Default signing is ad hoc for build validation only. Use the same approved
# identity for installed updates when testing permission-grant persistence.
# The command-line tools are signed first, then the app around them.
sign_identity=${EVENTKIT_SIGN_IDENTITY:--}
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$contents_dir/Info.plist")
# A real identity gets a secure timestamp, which notarization requires (it
# contacts Apple's timestamp server). Ad hoc signatures can't carry one.
if [ "$sign_identity" = "-" ]; then
    timestamp="--timestamp=none"
else
    timestamp="--timestamp"
fi
for tool in bridge-mcp bridge-client; do
    codesign --force --sign "$sign_identity" --options runtime "$timestamp" \
        --identifier "$bundle_id.$tool" "$contents_dir/MacOS/$tool"
done
codesign --force --sign "$sign_identity" --options runtime "$timestamp" \
    --entitlements "$project_dir/Entitlements.plist" "$app_dir"
codesign --verify --deep --strict "$app_dir"
printf '%s\n' "$app_dir"
