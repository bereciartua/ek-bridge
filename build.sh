#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
live_test=${EVENTKIT_LIVE_TEST:-0}
if [ "$live_test" = "1" ]; then
    output_dir=${EVENTKIT_OUTPUT_DIR:-"$project_dir/build/live-test"}
else
    output_dir=${EVENTKIT_OUTPUT_DIR:-"$project_dir/build"}
fi
# The app and its executable are named after CFBundleExecutable (EKBridge.app).
# The live-test copy keeps the executable's name in a bundle of its own name.
app_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$project_dir/Info.plist")
bundle_name=$app_name
[ "$live_test" = "1" ] && bundle_name="EK Bridge Test"
app_dir="$output_dir/$bundle_name.app"
contents_dir="$app_dir/Contents"
cache_dir="$project_dir/build/module-cache"
. "$project_dir/scripts/sdk.sh"
. "$project_dir/scripts/sparkle.sh"
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
if [ "${EVENTKIT_UPDATE_TEST:-0}" = "1" ]; then
    test_flag="-D EVENTKIT_UPDATE_TEST"
fi
# The live-test copy (scripts/live_test.sh): the app and both tools use its
# identity, so bridge-mcp and bridge-client find its data and transport only.
tool_flag=""
if [ "$live_test" = "1" ]; then
    test_flag="-D EVENTKIT_LIVE_TEST"
    tool_flag="-D EVENTKIT_LIVE_TEST"
fi

mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources" "$cache_dir"
cp "$project_dir/Info.plist" "$contents_dir/Info.plist"
# Default signing is ad hoc for build validation only. Use the same approved
# identity for installed updates when testing permission-grant persistence.
sign_identity=${EVENTKIT_SIGN_IDENTITY:--}
if [ "$sign_identity" = "-" ]; then
    # Without Sparkle's public key the app never checks for updates: an ad hoc
    # build from source shouldn't offer to replace itself with a release.
    /usr/libexec/PlistBuddy -c 'Set :SUPublicEDKey ""' "$contents_dir/Info.plist"
fi
if [ "${EVENTKIT_UPDATE_TEST:-0}" = "1" ]; then
    # scripts/update_test.sh: a separate app with its own identity, version,
    # local feed and throwaway key, so it can't touch an installed EK Bridge.
    # Plain HTTP is allowed only to this Mac (App Transport Security).
    for entry in "CFBundleIdentifier io.github.bereciartua.ekbridge.updatetest" \
        "CFBundleName EK Bridge Update Test" "CFBundleDisplayName EK Bridge Update Test" \
        "CFBundleShortVersionString $EVENTKIT_UPDATE_TEST_VERSION" "CFBundleVersion $EVENTKIT_UPDATE_TEST_BUILD" \
        "SUFeedURL $EVENTKIT_UPDATE_TEST_FEED" "SUPublicEDKey $EVENTKIT_UPDATE_TEST_PUBLIC_KEY"; do
        /usr/libexec/PlistBuddy -c "Set :${entry%% *} ${entry#* }" "$contents_dir/Info.plist"
    done
    /usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true' \
        "$contents_dir/Info.plist"
fi
if [ "$live_test" = "1" ]; then
    # Its own bundle ID (and so its own settings and macOS permissions), and
    # no update feed.
    for entry in "CFBundleIdentifier io.github.bereciartua.ekbridge.livetest" \
        "CFBundleName EK Bridge Test" "CFBundleDisplayName EK Bridge Test"; do
        /usr/libexec/PlistBuddy -c "Set :${entry%% *} ${entry#* }" "$contents_dir/Info.plist"
    done
    /usr/libexec/PlistBuddy -c 'Set :SUFeedURL ""' -c 'Set :SUPublicEDKey ""' \
        -c 'Set :SUEnableAutomaticChecks false' "$contents_dir/Info.plist"
fi
# The icon: AppIcon.icns for macOS 14 and 15, drawn by Resources/make_icon.swift.
# On macOS 26 and later the system draws it from the Icon Composer document
# instead (Liquid Glass, Dark, Clear and Tinted), compiled into Assets.car.
# actool comes with Xcode, not the Command Line Tools; without it the app uses
# the .icns everywhere.
cp "$project_dir/Resources/AppIcon.icns" "$contents_dir/Resources/AppIcon.icns"
rm -f "$contents_dir/Resources/Assets.car"
if xcrun --find actool > /dev/null 2>&1; then
    icon_dir=$(mktemp -d)
    xcrun actool "$project_dir/Resources/AppIcon.icon" --compile "$icon_dir" --platform macosx \
        --minimum-deployment-target "$minimum_macos" --app-icon AppIcon \
        --output-partial-info-plist "$icon_dir/partial.plist" --errors --warnings > "$icon_dir/actool.log" 2>&1 \
        || { cat "$icon_dir/actool.log" >&2; exit 1; }
    cp "$icon_dir/Assets.car" "$contents_dir/Resources/Assets.car"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIconName string AppIcon' "$contents_dir/Info.plist"
    rm -rf "$icon_dir"
else
    printf 'build.sh: actool not found (it comes with Xcode); the app uses AppIcon.icns only\n' >&2
fi
cp "$project_dir/LICENSE" "$project_dir/NOTICE" "$contents_dir/Resources/"
# Sparkle's MIT license must travel with the copy of it inside the app.
cp "$sparkle_dir/LICENSE" "$contents_dir/Resources/Sparkle-LICENSE.txt"

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
        -F "$sparkle_dir" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
        "$@" \
        -o "$slice/$app_name"

    # The command-line client (Contents/MacOS/bridge-client): no AppKit or EventKit.
    xcrun swiftc -sdk "$sdk_dir" \
        $tool_flag \
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
        $tool_flag \
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

# Sparkle, the updater (Contents/Frameworks/Sparkle.framework). Its XPC services
# exist for sandboxed apps only; this app isn't sandboxed, so they're removed,
# along with the headers, which only the compiler needs.
frameworks_dir="$contents_dir/Frameworks"
sparkle_framework="$frameworks_dir/Sparkle.framework"
rm -rf "$frameworks_dir"
mkdir -p "$frameworks_dir"
ditto "$sparkle_dir/Sparkle.framework" "$sparkle_framework"
for part in XPCServices Headers PrivateHeaders Modules; do
    rm -rf "$sparkle_framework/$part" "$sparkle_framework/Versions/B/$part"
done

# Scripts and client.py still find the client at build/bridge-client.
rm -f "$output_dir/bridge-client"
ln -s "$bundle_name.app/Contents/MacOS/bridge-client" "$output_dir/bridge-client"

bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$contents_dir/Info.plist")
# A real identity gets a secure timestamp, which notarization requires (it
# contacts Apple's timestamp server). Ad hoc signatures can't carry one.
if [ "$sign_identity" = "-" ]; then
    timestamp="--timestamp=none"
else
    timestamp="--timestamp"
fi
# Inside out: Sparkle's helpers, then Sparkle, then the command-line tools, then
# the app around them all.
for part in "$sparkle_framework/Versions/B/Autoupdate" "$sparkle_framework/Versions/B/Updater.app" \
    "$sparkle_framework"; do
    codesign --force --sign "$sign_identity" --options runtime "$timestamp" "$part"
done
for tool in bridge-mcp bridge-client; do
    codesign --force --sign "$sign_identity" --options runtime "$timestamp" \
        --identifier "$bundle_id.$tool" "$contents_dir/MacOS/$tool"
done
# Under the hardened runtime, the app loads only frameworks signed by its own
# team. Ad hoc signatures have no team, so an ad hoc build (development, CI,
# UI review) may load Sparkle without that check. A Developer ID build keeps it;
# scripts/check_bundle.sh fails one that doesn't.
entitlements="$project_dir/Entitlements.plist"
if [ "$sign_identity" = "-" ]; then
    entitlements="$output_dir/adhoc-entitlements.plist"
    cp "$project_dir/Entitlements.plist" "$entitlements"
    /usr/libexec/PlistBuddy -c 'Add :com.apple.security.cs.disable-library-validation bool true' "$entitlements"
fi
codesign --force --sign "$sign_identity" --options runtime "$timestamp" \
    --entitlements "$entitlements" "$app_dir"
codesign --verify --deep --strict "$app_dir"
printf '%s\n' "$app_dir"
