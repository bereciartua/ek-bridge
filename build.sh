#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
output_dir=${EVENTKIT_OUTPUT_DIR:-"$project_dir/build"}
app_dir="$output_dir/EventKitBridge.app"
contents_dir="$app_dir/Contents"
cache_dir="$project_dir/build/module-cache"
sdk_dir="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
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
xcrun swiftc -parse-as-library \
    $test_flag \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    -Xcc "-fmodules-cache-path=$cache_dir" \
    -target arm64-apple-macosx14.0 \
    -framework AppKit -framework EventKit -framework Security -framework ServiceManagement \
    -framework SwiftUI -framework Network \
    "$project_dir/Sources/main.swift" \
    "$project_dir/Sources/AppIdentity.swift" \
    "$project_dir/Sources/AppPresentation.swift" \
    "$project_dir/Sources/OutcomePresentation.swift" \
    "$project_dir/Sources/BridgeAppModel.swift" \
    "$project_dir/Sources/MainWindowController.swift" \
    "$project_dir/Sources/StatusMenuController.swift" \
    "$project_dir/Sources/UIComponents.swift" \
    "$project_dir/Sources/MainView.swift" \
    "$project_dir/Sources/OverviewView.swift" \
    "$project_dir/Sources/ClientDetailView.swift" \
    "$project_dir/Sources/ActivityView.swift" \
    "$project_dir/Sources/SettingsView.swift" \
    "$project_dir/Sources/UIReview.swift" \
    "$project_dir/Sources/BridgeProtocol.swift" \
    "$project_dir/Sources/BridgeEnablement.swift" \
    "$project_dir/Sources/ClientBridgeProtocol.swift" \
    "$project_dir/Sources/ClientRegistry.swift" \
    "$project_dir/Sources/ClientGrantEditing.swift" \
    "$project_dir/Sources/ClientCredentialFiles.swift" \
    "$project_dir/Sources/CommandPolicy.swift" \
    "$project_dir/Sources/EventCreation.swift" \
    "$project_dir/Sources/MutationPolicy.swift" \
    "$project_dir/Sources/ReminderDue.swift" \
    "$project_dir/Sources/ReminderRecurrence.swift" \
    "$project_dir/Sources/ReminderSchedule.swift" \
    "$project_dir/Sources/RecurringReminderCompletion.swift" \
    "$project_dir/Sources/TestCollections.swift" \
    "$project_dir/Sources/EventKitCommands.swift" \
    "$project_dir/Sources/WriteJournal.swift" \
    "$project_dir/Sources/WriteIdempotencyKey.swift" \
    "$project_dir/Sources/BridgePollingTimer.swift" \
    "$project_dir/Sources/LocalBridge.swift" \
    "$project_dir/Sources/SafePath.swift" \
    "$project_dir/Sources/RequestPipeline.swift" \
    "$project_dir/Sources/ApprovalCenter.swift" \
    "$project_dir/Sources/ApprovalPanel.swift" \
    "$project_dir/Sources/AgentSetup.swift" \
    "$project_dir/Sources/ConnectAgentView.swift" \
    "$project_dir/Sources/MCP/AgentOutcomeText.swift" \
    "$project_dir/Sources/MCP/HTTPMessage.swift" \
    "$project_dir/Sources/MCP/JSONRPC.swift" \
    "$project_dir/Sources/MCP/LoopbackHTTPServer.swift" \
    "$project_dir/Sources/MCP/MCPEndpointFile.swift" \
    "$project_dir/Sources/MCP/MCPServer.swift" \
    "$project_dir/Sources/MCP/MCPService.swift" \
    "$project_dir/Sources/MCP/MCPTime.swift" \
    "$project_dir/Sources/MCP/MCPToolCatalog.swift" \
    "$project_dir/Sources/MCP/MCPToolMapping.swift" \
    "$project_dir/Sources/MCP/RateLimiter.swift" \
    "$project_dir/Sources/SyntheticTestMode.swift" \
    "$project_dir/Sources/SyntheticRecurrenceProbe.swift" \
    "$project_dir/Sources/SyntheticPhoneSyncProbe.swift" \
    "$project_dir/Sources/SyntheticAllDayProbe.swift" \
    -o "$contents_dir/MacOS/EventKitBridge"

xcrun swiftc -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    "$project_dir/Sources/BridgeProtocol.swift" \
    "$project_dir/Sources/AppIdentity.swift" \
    "$project_dir/Sources/OutcomePresentation.swift" \
    "$project_dir/Sources/SafePath.swift" \
    "$project_dir/Sources/BridgeClient.swift" \
    -o "$output_dir/bridge-client"

# The MCP launcher agents run (Contents/MacOS/bridge-mcp): no AppKit or EventKit.
xcrun swiftc -parse-as-library -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    -target arm64-apple-macosx14.0 \
    "$project_dir/Sources/MCPLauncher.swift" \
    "$project_dir/Sources/SafePath.swift" \
    "$project_dir/Sources/AppIdentity.swift" \
    -o "$contents_dir/MacOS/bridge-mcp"

# Default signing is ad hoc for build validation only. Use the same approved
# identity for installed updates when testing permission-grant persistence.
# The launcher is signed first, then the app around it.
sign_identity=${EVENTKIT_SIGN_IDENTITY:--}
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$contents_dir/Info.plist")
codesign --force --sign "$sign_identity" --options runtime \
    --identifier "$bundle_id.bridge-mcp" "$contents_dir/MacOS/bridge-mcp"
codesign --force --sign "$sign_identity" --options runtime \
    --entitlements "$project_dir/Entitlements.plist" "$app_dir"
codesign --verify --deep --strict "$app_dir"
printf '%s\n' "$app_dir"
