#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cache_dir="$project_dir/build/module-cache"
. "$project_dir/scripts/sdk.sh"
mkdir -p "$project_dir/build" "$cache_dir"
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    "$project_dir/Sources/BridgeEnablement.swift" \
    "$project_dir/Tests/BridgeEnablementTests.swift" \
    -o "$project_dir/build/bridge-enablement-tests"
"$project_dir/build/bridge-enablement-tests"
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    "$project_dir/Sources/AppIdentity.swift" \
    "$project_dir/Sources/RenameMigration.swift" \
    "$project_dir/Tests/RenameMigrationTests.swift" \
    -o "$project_dir/build/rename-migration-tests"
"$project_dir/build/rename-migration-tests"
for flavor in production live-test; do
    flag=""
    [ "$flavor" = live-test ] && flag="-D EVENTKIT_LIVE_TEST"
    xcrun swiftc -parse-as-library \
        $flag \
        -sdk "$sdk_dir" \
        -module-cache-path "$cache_dir" \
        "$project_dir/Sources/AppIdentity.swift" \
        "$project_dir/Tests/LiveTestIsolationTests.swift" \
        -o "$project_dir/build/live-test-isolation-$flavor"
    "$project_dir/build/live-test-isolation-$flavor" "$project_dir/build/live-test-isolation-production.txt"
done
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    "$project_dir/Sources/InstallLocation.swift" \
    "$project_dir/Tests/InstallLocationTests.swift" \
    -o "$project_dir/build/install-location-tests"
"$project_dir/build/install-location-tests"
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    -framework EventKit \
    "$project_dir/Sources/BridgeProtocol.swift" \
    "$project_dir/Sources/ClientCredentialFiles.swift" \
    "$project_dir/Sources/ClientRegistry.swift" \
    "$project_dir/Sources/ActivityStore.swift" \
    "$project_dir/Sources/AccessRequests.swift" \
    "$project_dir/Sources/ClientGrantEditing.swift" \
    "$project_dir/Sources/AppIdentity.swift" \
    "$project_dir/Sources/OutcomePresentation.swift" \
    "$project_dir/Sources/AppPresentation.swift" \
    "$project_dir/Sources/AgentSetup.swift" \
    "$project_dir/Sources/AgentDetection.swift" \
    "$project_dir/Tests/AgentDetectionTests.swift" \
    -o "$project_dir/build/agent-detection-tests"
"$project_dir/build/agent-detection-tests"
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    -framework EventKit \
    "$project_dir/Sources/BridgeProtocol.swift" \
    "$project_dir/Sources/ClientCredentialFiles.swift" \
    "$project_dir/Sources/ClientRegistry.swift" \
    "$project_dir/Sources/ActivityStore.swift" \
    "$project_dir/Sources/AccessRequests.swift" \
    "$project_dir/Sources/ClientGrantEditing.swift" \
    "$project_dir/Sources/AppIdentity.swift" \
    "$project_dir/Sources/OutcomePresentation.swift" \
    "$project_dir/Sources/AppPresentation.swift" \
    "$project_dir/Sources/AgentSetup.swift" \
    "$project_dir/Sources/AgentConfigWriter.swift" \
    "$project_dir/Sources/ExecutableLocator.swift" \
    "$project_dir/Tests/AgentConfigWriterTests.swift" \
    -o "$project_dir/build/agent-config-writer-tests"
"$project_dir/build/agent-config-writer-tests" "$project_dir/Tests/agent-config"
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    -framework EventKit \
    "$project_dir/Sources/BridgeProtocol.swift" \
    "$project_dir/Sources/ClientCredentialFiles.swift" \
    "$project_dir/Sources/ClientRegistry.swift" \
    "$project_dir/Sources/ActivityStore.swift" \
    "$project_dir/Sources/AccessRequests.swift" \
    "$project_dir/Sources/ClientGrantEditing.swift" \
    "$project_dir/Sources/AppIdentity.swift" \
    "$project_dir/Sources/OutcomePresentation.swift" \
    "$project_dir/Sources/AppPresentation.swift" \
    "$project_dir/Sources/CollectionLabels.swift" \
    "$project_dir/Tests/CollectionLabelsTests.swift" \
    -o "$project_dir/build/collection-labels-tests"
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    "$project_dir/Sources/BridgeProtocol.swift" \
    "$project_dir/Sources/AppIdentity.swift" \
    "$project_dir/Sources/OutcomePresentation.swift" \
    "$project_dir/Sources/NotificationRules.swift" \
    "$project_dir/Tests/NotificationRulesTests.swift" \
    -o "$project_dir/build/notification-rules-tests"
"$project_dir/build/notification-rules-tests"
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    "$project_dir/Sources/BridgeProtocol.swift" \
    "$project_dir/Sources/ClientRegistry.swift" \
    "$project_dir/Sources/ActivityStore.swift" \
    "$project_dir/Sources/AccessRequests.swift" \
    "$project_dir/Sources/AppIdentity.swift" \
    "$project_dir/Sources/ClientCredentialFiles.swift" \
    "$project_dir/Tests/AccessRequestsTests.swift" \
    -o "$project_dir/build/access-requests-tests"
"$project_dir/build/access-requests-tests"
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    "$project_dir/Sources/BridgeProtocol.swift" \
    "$project_dir/Sources/ActivityStore.swift" \
    "$project_dir/Tests/ActivityStoreTests.swift" \
    -o "$project_dir/build/activity-store-tests"
"$project_dir/build/activity-store-tests"
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    "$project_dir/Sources/BridgeProtocol.swift" \
    "$project_dir/Sources/ActivityStore.swift" \
    "$project_dir/Sources/ActivityItems.swift" \
    "$project_dir/Tests/ActivityItemsTests.swift" \
    -o "$project_dir/build/activity-items-tests"
"$project_dir/build/activity-items-tests" "$project_dir/Tests/mcp-fixtures"
# Rollback: a data folder written by this code must still load in 0.8.2.
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    "$project_dir/Tests/rollback-0.8.2/AppIdentity.swift" \
    "$project_dir/Tests/rollback-0.8.2/BridgeProtocol.swift" \
    "$project_dir/Tests/rollback-0.8.2/ClientCredentialFiles.swift" \
    "$project_dir/Tests/rollback-0.8.2/ClientRegistry.swift" \
    "$project_dir/Tests/RollbackHarness.swift" \
    -o "$project_dir/build/rollback-harness"
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    "$project_dir/Sources/AppIdentity.swift" \
    "$project_dir/Sources/BridgeProtocol.swift" \
    "$project_dir/Sources/ClientCredentialFiles.swift" \
    "$project_dir/Sources/ClientRegistry.swift" \
    "$project_dir/Sources/ActivityStore.swift" \
    "$project_dir/Sources/AccessRequests.swift" \
    "$project_dir/Tests/RollbackWriter.swift" \
    -o "$project_dir/build/rollback-writer"
rollback_dir=$(mktemp -d "${TMPDIR:-/tmp}/ekb-rollback.XXXXXX")
written=$("$project_dir/build/rollback-writer" write "$rollback_dir/data")
loaded=$("$project_dir/build/rollback-harness" "$rollback_dir/data" --write)
python3 - "$written" "$loaded" <<'PY'
import json, sys
written, loaded = json.loads(sys.argv[1]), json.loads(sys.argv[2])
assert loaded["loaded"] is True, loaded
assert loaded["clientIDs"] == written["clientIDs"], (loaded, written)
assert loaded["active"] == 4 and loaded["grants"] == 8, loaded
assert loaded["ask"] == 1 and loaded["paused"] == 1 and loaded["mcp"] == 3, loaded
assert loaded["activityRows"] == 0 and loaded["wrote"] is True, loaded
PY
"$project_dir/build/rollback-writer" check "$rollback_dir/data" 1201
rm -rf "$rollback_dir"
echo "Rollback: 0.8.2 loads and writes a 0.10 data folder; its rows import once passed"
"$project_dir/build/collection-labels-tests"
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    "$project_dir/Sources/AppIdentity.swift" \
    "$project_dir/Sources/BridgeProtocol.swift" \
    "$project_dir/Sources/CommandPolicy.swift" \
    "$project_dir/Sources/ItemText.swift" \
    "$project_dir/Sources/ItemAlarms.swift" \
    "$project_dir/Sources/Recurrence.swift" \
    "$project_dir/Sources/RecurrenceText.swift" \
    "$project_dir/Sources/EventFields.swift" \
    "$project_dir/Sources/ReminderFields.swift" \
    "$project_dir/Sources/MutationPolicy.swift" \
    "$project_dir/Sources/ReminderDue.swift" \
    "$project_dir/Sources/WriteJournal.swift" \
    "$project_dir/Sources/WriteIdempotencyKey.swift" \
    "$project_dir/Tests/BridgeProtocolTests.swift" \
    -framework EventKit \
    -o "$project_dir/build/bridge-protocol-tests"
"$project_dir/build/bridge-protocol-tests"
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    "$project_dir/Sources/ReminderDue.swift" \
    "$project_dir/Tests/ReminderDueTests.swift" \
    -o "$project_dir/build/reminder-due-tests"
"$project_dir/build/reminder-due-tests"
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    -framework EventKit \
    "$project_dir/Sources/ReminderDue.swift" \
    "$project_dir/Sources/ItemText.swift" \
    "$project_dir/Sources/ItemAlarms.swift" \
    "$project_dir/Sources/Recurrence.swift" \
    "$project_dir/Sources/RecurrenceText.swift" \
    "$project_dir/Sources/EventFields.swift" \
    "$project_dir/Sources/ReminderFields.swift" \
    "$project_dir/Tests/RecurrenceTests.swift" \
    -o "$project_dir/build/recurrence-tests"
"$project_dir/build/recurrence-tests"
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    -framework EventKit \
    "$project_dir/Sources/ReminderDue.swift" \
    "$project_dir/Sources/ItemText.swift" \
    "$project_dir/Sources/ItemAlarms.swift" \
    "$project_dir/Sources/Recurrence.swift" \
    "$project_dir/Sources/RecurrenceText.swift" \
    "$project_dir/Sources/EventFields.swift" \
    "$project_dir/Sources/ReminderFields.swift" \
    "$project_dir/Tests/EventFieldsTests.swift" \
    -o "$project_dir/build/event-fields-tests"
"$project_dir/build/event-fields-tests"
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    -framework EventKit \
    "$project_dir/Sources/ReminderDue.swift" \
    "$project_dir/Sources/ItemText.swift" \
    "$project_dir/Sources/ItemAlarms.swift" \
    "$project_dir/Sources/Recurrence.swift" \
    "$project_dir/Sources/RecurrenceText.swift" \
    "$project_dir/Sources/EventFields.swift" \
    "$project_dir/Sources/ReminderFields.swift" \
    "$project_dir/Tests/ReminderFieldsTests.swift" \
    -o "$project_dir/build/reminder-fields-tests"
"$project_dir/build/reminder-fields-tests"
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    -framework EventKit \
    "$project_dir/Sources/ReminderDue.swift" \
    "$project_dir/Sources/ItemText.swift" \
    "$project_dir/Sources/ItemAlarms.swift" \
    "$project_dir/Sources/Recurrence.swift" \
    "$project_dir/Sources/RecurrenceText.swift" \
    "$project_dir/Sources/EventFields.swift" \
    "$project_dir/Sources/ReminderFields.swift" \
    "$project_dir/Sources/RecurringReminderCompletion.swift" \
    "$project_dir/Tests/RecurringReminderCompletionTests.swift" \
    -o "$project_dir/build/recurring-completion-tests"
"$project_dir/build/recurring-completion-tests"
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    -framework EventKit \
    "$project_dir/Sources/ReminderDue.swift" \
    "$project_dir/Sources/ItemText.swift" \
    "$project_dir/Sources/ItemAlarms.swift" \
    "$project_dir/Sources/Recurrence.swift" \
    "$project_dir/Sources/RecurrenceText.swift" \
    "$project_dir/Sources/EventFields.swift" \
    "$project_dir/Sources/ReminderFields.swift" \
    "$project_dir/Sources/ReminderSchedule.swift" \
    "$project_dir/Tests/ReminderScheduleTests.swift" \
    -o "$project_dir/build/reminder-schedule-tests"
"$project_dir/build/reminder-schedule-tests"
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    "$project_dir/Sources/AppIdentity.swift" \
    "$project_dir/Sources/BridgeProtocol.swift" \
    "$project_dir/Sources/WriteIdempotencyKey.swift" \
    "$project_dir/Sources/WriteJournal.swift" \
    "$project_dir/Tests/WriteJournalRetentionTests.swift" \
    -o "$project_dir/build/write-journal-retention-tests"
"$project_dir/build/write-journal-retention-tests"
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    "$project_dir/Sources/BridgeProtocol.swift" \
    "$project_dir/Sources/CommandPolicy.swift" \
    "$project_dir/Sources/ItemText.swift" \
    "$project_dir/Sources/ItemAlarms.swift" \
    "$project_dir/Sources/Recurrence.swift" \
    "$project_dir/Sources/RecurrenceText.swift" \
    "$project_dir/Sources/EventFields.swift" \
    "$project_dir/Sources/ReminderFields.swift" \
    "$project_dir/Sources/ReminderDue.swift" \
    "$project_dir/Sources/ClientBridgeProtocol.swift" \
    "$project_dir/Sources/ClientCredentialFiles.swift" \
    "$project_dir/Sources/ClientRegistry.swift" \
    "$project_dir/Sources/ActivityStore.swift" \
    "$project_dir/Sources/AccessRequests.swift" \
    "$project_dir/Sources/AppIdentity.swift" \
    "$project_dir/Sources/WriteIdempotencyKey.swift" \
    "$project_dir/Tests/ClientRegistryTests.swift" \
    -framework EventKit \
    -o "$project_dir/build/client-registry-tests"
"$project_dir/build/client-registry-tests"
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    "$project_dir/Sources/BridgeProtocol.swift" \
    "$project_dir/Sources/ClientCredentialFiles.swift" \
    "$project_dir/Sources/ClientRegistry.swift" \
    "$project_dir/Sources/ActivityStore.swift" \
    "$project_dir/Sources/AccessRequests.swift" \
    "$project_dir/Sources/AppIdentity.swift" \
    "$project_dir/Sources/ClientGrantEditing.swift" \
    "$project_dir/Tests/ClientGrantEditingTests.swift" \
    -o "$project_dir/build/client-grant-editing-tests"
"$project_dir/build/client-grant-editing-tests"
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    -framework EventKit \
    "$project_dir/Sources/BridgeProtocol.swift" \
    "$project_dir/Sources/ClientCredentialFiles.swift" \
    "$project_dir/Sources/ClientRegistry.swift" \
    "$project_dir/Sources/ActivityStore.swift" \
    "$project_dir/Sources/AccessRequests.swift" \
    "$project_dir/Sources/ClientGrantEditing.swift" \
    "$project_dir/Sources/AppIdentity.swift" \
    "$project_dir/Sources/OutcomePresentation.swift" \
    "$project_dir/Sources/AppPresentation.swift" \
    "$project_dir/Tests/AppPresentationTests.swift" \
    -o "$project_dir/build/app-presentation-tests"
"$project_dir/build/app-presentation-tests" "$project_dir/Sources"
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    "$project_dir/Sources/AppIdentity.swift" \
    "$project_dir/Sources/ClientCredentialFiles.swift" \
    "$project_dir/Tests/ClientCredentialFilesTests.swift" \
    -o "$project_dir/build/client-credential-files-tests"
"$project_dir/build/client-credential-files-tests"
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    "$project_dir/Sources/BridgePollingTimer.swift" \
    "$project_dir/Tests/BridgePollingTimerTests.swift" \
    -o "$project_dir/build/bridge-polling-timer-tests"
"$project_dir/build/bridge-polling-timer-tests"
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    "$project_dir/Sources/CommandLineTool.swift" \
    "$project_dir/Tests/CommandLineToolTests.swift" \
    -o "$project_dir/build/command-line-tool-tests"
"$project_dir/build/command-line-tool-tests"
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    "$project_dir/Sources/MCP/HTTPMessage.swift" \
    "$project_dir/Tests/HTTPMessageTests.swift" \
    -o "$project_dir/build/http-message-tests"
"$project_dir/build/http-message-tests"
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    "$project_dir/Sources/MCP/MCPTime.swift" \
    "$project_dir/Tests/MCPTimeTests.swift" \
    -o "$project_dir/build/mcp-time-tests"
"$project_dir/build/mcp-time-tests"
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    -framework EventKit \
    "$project_dir/Sources/BridgeProtocol.swift" \
    "$project_dir/Sources/ClientCredentialFiles.swift" \
    "$project_dir/Sources/ClientRegistry.swift" \
    "$project_dir/Sources/ActivityStore.swift" \
    "$project_dir/Sources/AccessRequests.swift" \
    "$project_dir/Sources/ClientGrantEditing.swift" \
    "$project_dir/Sources/AppIdentity.swift" \
    "$project_dir/Sources/OutcomePresentation.swift" \
    "$project_dir/Sources/AppPresentation.swift" \
    "$project_dir/Sources/AgentSetup.swift" \
    "$project_dir/Tests/AgentSetupTests.swift" \
    -o "$project_dir/build/agent-setup-tests"
"$project_dir/build/agent-setup-tests" "$project_dir/Tests/agent-setup"
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    -framework EventKit \
    "$project_dir/Sources/BridgeProtocol.swift" \
    "$project_dir/Sources/ClientCredentialFiles.swift" \
    "$project_dir/Sources/ClientRegistry.swift" \
    "$project_dir/Sources/ActivityStore.swift" \
    "$project_dir/Sources/AccessRequests.swift" \
    "$project_dir/Sources/ClientGrantEditing.swift" \
    "$project_dir/Sources/AppIdentity.swift" \
    "$project_dir/Sources/OutcomePresentation.swift" \
    "$project_dir/Sources/AppPresentation.swift" \
    "$project_dir/Sources/AgentSetup.swift" \
    "$project_dir/Sources/TunnelHealth.swift" \
    "$project_dir/Tests/TunnelHealthTests.swift" \
    -o "$project_dir/build/tunnel-health-tests"
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    -framework EventKit \
    "$project_dir/Sources/BridgeProtocol.swift" \
    "$project_dir/Sources/ClientCredentialFiles.swift" \
    "$project_dir/Sources/ClientRegistry.swift" \
    "$project_dir/Sources/ActivityStore.swift" \
    "$project_dir/Sources/AccessRequests.swift" \
    "$project_dir/Sources/ClientGrantEditing.swift" \
    "$project_dir/Sources/AppIdentity.swift" \
    "$project_dir/Sources/OutcomePresentation.swift" \
    "$project_dir/Sources/AppPresentation.swift" \
    "$project_dir/Sources/AgentSetup.swift" \
    "$project_dir/Sources/TunnelHealth.swift" \
    "$project_dir/Sources/TunnelSwitch.swift" \
    "$project_dir/Tests/TunnelSwitchTests.swift" \
    -o "$project_dir/build/tunnel-switch-tests"
"$project_dir/build/tunnel-switch-tests"
"$project_dir/build/tunnel-health-tests"
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    "$project_dir/Sources/AppIdentity.swift" \
    "$project_dir/Sources/BridgeProtocol.swift" \
    "$project_dir/Sources/ClientCredentialFiles.swift" \
    "$project_dir/Sources/ClientRegistry.swift" \
    "$project_dir/Sources/ActivityStore.swift" \
    "$project_dir/Sources/AccessRequests.swift" \
    "$project_dir/Tests/ClientRegistryV4Tests.swift" \
    -o "$project_dir/build/client-registry-v4-tests"
"$project_dir/build/client-registry-v4-tests"
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    -framework EventKit \
    "$project_dir/Sources/AppIdentity.swift" \
    "$project_dir/Sources/BridgeProtocol.swift" \
    "$project_dir/Sources/CommandPolicy.swift" \
    "$project_dir/Sources/ItemText.swift" \
    "$project_dir/Sources/ItemAlarms.swift" \
    "$project_dir/Sources/Recurrence.swift" \
    "$project_dir/Sources/RecurrenceText.swift" \
    "$project_dir/Sources/EventFields.swift" \
    "$project_dir/Sources/ReminderFields.swift" \
    "$project_dir/Sources/ReminderDue.swift" \
    "$project_dir/Sources/WriteIdempotencyKey.swift" \
    "$project_dir/Sources/ClientCredentialFiles.swift" \
    "$project_dir/Sources/ClientRegistry.swift" \
    "$project_dir/Sources/ActivityStore.swift" \
    "$project_dir/Sources/AccessRequests.swift" \
    "$project_dir/Sources/RequestPipeline.swift" \
    "$project_dir/Sources/ActivityItems.swift" \
    "$project_dir/Sources/MCP/RateLimiter.swift" \
    "$project_dir/Tests/RequestPipelineTests.swift" \
    -o "$project_dir/build/request-pipeline-tests"
"$project_dir/build/request-pipeline-tests"
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    "$project_dir/Sources/MCP/RateLimiter.swift" \
    "$project_dir/Tests/RateLimiterTests.swift" \
    -o "$project_dir/build/rate-limiter-tests"
"$project_dir/build/rate-limiter-tests"
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    "$project_dir/Sources/AppIdentity.swift" \
    "$project_dir/Sources/BridgeProtocol.swift" \
    "$project_dir/Sources/ClientCredentialFiles.swift" \
    "$project_dir/Sources/ClientRegistry.swift" \
    "$project_dir/Sources/ActivityStore.swift" \
    "$project_dir/Sources/AccessRequests.swift" \
    "$project_dir/Sources/MCP/MCPToolCatalog.swift" \
    "$project_dir/Tests/MCPToolCatalogTests.swift" \
    -o "$project_dir/build/mcp-tool-catalog-tests"
"$project_dir/build/mcp-tool-catalog-tests" "$project_dir/Tests/mcp-fixtures/tools.json"
# Also prints the median begin+finish time with 10,000 journal entries (§9.7).
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    "$project_dir/Sources/AppIdentity.swift" \
    "$project_dir/Sources/BridgeProtocol.swift" \
    "$project_dir/Sources/WriteIdempotencyKey.swift" \
    "$project_dir/Sources/WriteJournal.swift" \
    "$project_dir/Tests/WriteJournalQuotaTests.swift" \
    -o "$project_dir/build/write-journal-quota-tests"
"$project_dir/build/write-journal-quota-tests"
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    -framework EventKit \
    "$project_dir/Sources/AppIdentity.swift" \
    "$project_dir/Sources/BridgeProtocol.swift" \
    "$project_dir/Sources/CommandPolicy.swift" \
    "$project_dir/Sources/ItemText.swift" \
    "$project_dir/Sources/ItemAlarms.swift" \
    "$project_dir/Sources/Recurrence.swift" \
    "$project_dir/Sources/RecurrenceText.swift" \
    "$project_dir/Sources/EventFields.swift" \
    "$project_dir/Sources/ReminderFields.swift" \
    "$project_dir/Sources/ReminderDue.swift" \
    "$project_dir/Sources/WriteIdempotencyKey.swift" \
    "$project_dir/Sources/ClientCredentialFiles.swift" \
    "$project_dir/Sources/ClientRegistry.swift" \
    "$project_dir/Sources/ActivityStore.swift" \
    "$project_dir/Sources/AccessRequests.swift" \
    "$project_dir/Sources/ClientGrantEditing.swift" \
    "$project_dir/Sources/OutcomePresentation.swift" \
    "$project_dir/Sources/AppPresentation.swift" \
    "$project_dir/Sources/RequestPipeline.swift" \
    "$project_dir/Sources/ActivityItems.swift" \
    "$project_dir/Sources/MCP/RateLimiter.swift" \
    "$project_dir/Sources/ApprovalCenter.swift" \
    "$project_dir/Tests/ApprovalCenterTests.swift" \
    -o "$project_dir/build/approval-center-tests"
"$project_dir/build/approval-center-tests"
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    "$project_dir/Sources/Updates.swift" \
    "$project_dir/Tests/UpdateRelaunchGateTests.swift" \
    -o "$project_dir/build/update-relaunch-gate-tests"
"$project_dir/build/update-relaunch-gate-tests"
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    -framework EventKit \
    "$project_dir/Sources/AppIdentity.swift" \
    "$project_dir/Sources/BridgeProtocol.swift" \
    "$project_dir/Sources/CommandPolicy.swift" \
    "$project_dir/Sources/ItemText.swift" \
    "$project_dir/Sources/ItemAlarms.swift" \
    "$project_dir/Sources/Recurrence.swift" \
    "$project_dir/Sources/RecurrenceText.swift" \
    "$project_dir/Sources/EventFields.swift" \
    "$project_dir/Sources/ReminderFields.swift" \
    "$project_dir/Sources/ReminderDue.swift" \
    "$project_dir/Sources/ReminderSchedule.swift" \
    "$project_dir/Sources/WriteIdempotencyKey.swift" \
    "$project_dir/Sources/ClientCredentialFiles.swift" \
    "$project_dir/Sources/ClientRegistry.swift" \
    "$project_dir/Sources/ActivityStore.swift" \
    "$project_dir/Sources/AccessRequests.swift" \
    "$project_dir/Sources/ClientGrantEditing.swift" \
    "$project_dir/Sources/OutcomePresentation.swift" \
    "$project_dir/Sources/AppPresentation.swift" \
    "$project_dir/Sources/RequestPipeline.swift" \
    "$project_dir/Sources/ActivityItems.swift" \
    "$project_dir/Sources/MCP/RateLimiter.swift" \
    "$project_dir/Sources/ApprovalCenter.swift" \
    "$project_dir/Sources/ApprovalSummaries.swift" \
    "$project_dir/Tests/ApprovalSummariesTests.swift" \
    -o "$project_dir/build/approval-summaries-tests"
"$project_dir/build/approval-summaries-tests"
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    -framework EventKit \
    "$project_dir/Sources/AppIdentity.swift" \
    "$project_dir/Sources/BridgeProtocol.swift" \
    "$project_dir/Sources/CommandPolicy.swift" \
    "$project_dir/Sources/ItemText.swift" \
    "$project_dir/Sources/ItemAlarms.swift" \
    "$project_dir/Sources/Recurrence.swift" \
    "$project_dir/Sources/RecurrenceText.swift" \
    "$project_dir/Sources/EventFields.swift" \
    "$project_dir/Sources/ReminderFields.swift" \
    "$project_dir/Sources/ReminderDue.swift" \
    "$project_dir/Sources/WriteIdempotencyKey.swift" \
    "$project_dir/Sources/WriteJournal.swift" \
    "$project_dir/Sources/ClientCredentialFiles.swift" \
    "$project_dir/Sources/ClientRegistry.swift" \
    "$project_dir/Sources/ActivityStore.swift" \
    "$project_dir/Sources/AccessRequests.swift" \
    "$project_dir/Sources/SafePath.swift" \
    "$project_dir/Sources/RequestPipeline.swift" \
    "$project_dir/Sources/ActivityItems.swift" \
    "$project_dir/Sources/ClientGrantEditing.swift" \
    "$project_dir/Sources/OutcomePresentation.swift" \
    "$project_dir/Sources/AppPresentation.swift" \
    "$project_dir/Sources/AgentSetup.swift" \
    "$project_dir/Sources/MCP/"*.swift \
    "$project_dir/Tests/MCPGateTests.swift" \
    -o "$project_dir/build/mcp-gate-tests"
"$project_dir/build/mcp-gate-tests"
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    "$project_dir/Sources/AppIdentity.swift" \
    "$project_dir/Sources/SafePath.swift" \
    "$project_dir/Sources/MCP/HTTPMessage.swift" \
    "$project_dir/Sources/MCP/OAuthTypes.swift" \
    "$project_dir/Sources/MCP/OAuthStore.swift" \
    "$project_dir/Sources/MCP/OAuthPages.swift" \
    "$project_dir/Sources/MCP/OAuthServer.swift" \
    "$project_dir/Tests/OAuthServerTests.swift" \
    -o "$project_dir/build/oauth-server-tests"
"$project_dir/build/oauth-server-tests"
# -D EVENTKIT_MCP_TEST adds hooks that let a local HTTPS fixture through the
# fetcher's SSRF guard; normal builds can't disable it.
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" -D EVENTKIT_MCP_TEST \
    "$project_dir/Sources/AppIdentity.swift" \
    "$project_dir/Sources/MCP/OAuthTypes.swift" \
    "$project_dir/Sources/MCP/CIMDFetcher.swift" \
    "$project_dir/Tests/CIMDFetcherTests.swift" \
    -o "$project_dir/build/cimd-fetcher-tests"
"$project_dir/build/cimd-fetcher-tests"
# Test build only: -D EVENTKIT_CLIENT_TEST lets the CLI tests point it at a
# fake bridge and key files in temporary directories.
xcrun swiftc -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    -D EVENTKIT_CLIENT_TEST \
    "$project_dir/Sources/BridgeProtocol.swift" \
    "$project_dir/Sources/AppIdentity.swift" \
    "$project_dir/Sources/OutcomePresentation.swift" \
    "$project_dir/Sources/SafePath.swift" \
    "$project_dir/Sources/BridgeClient.swift" \
    -o "$project_dir/build/bridge-client-test"
PYTHONPYCACHEPREFIX="$project_dir/build/pycache" python3 "$project_dir/Tests/cli_test.py" \
    "$project_dir/build/bridge-client-test"
PYTHONPYCACHEPREFIX="$project_dir/build/pycache" python3 -m py_compile "$project_dir/client.py"
PYTHONPYCACHEPREFIX="$project_dir/build/pycache" python3 "$project_dir/Tests/check_version_test.py"
PYTHONPYCACHEPREFIX="$project_dir/build/pycache" python3 "$project_dir/Tests/release_test.py"
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    -framework EventKit \
    "$project_dir/Sources/AppIdentity.swift" \
    "$project_dir/Sources/BridgeProtocol.swift" \
    "$project_dir/Sources/CommandPolicy.swift" \
    "$project_dir/Sources/ItemText.swift" \
    "$project_dir/Sources/ItemAlarms.swift" \
    "$project_dir/Sources/Recurrence.swift" \
    "$project_dir/Sources/RecurrenceText.swift" \
    "$project_dir/Sources/EventFields.swift" \
    "$project_dir/Sources/ReminderFields.swift" \
    "$project_dir/Sources/ReminderDue.swift" \
    "$project_dir/Sources/WriteIdempotencyKey.swift" \
    "$project_dir/Sources/MCP/MCPTime.swift" \
    "$project_dir/Sources/MCP/AgentOutcomeText.swift" \
    "$project_dir/Sources/MCP/MCPToolMapping.swift" \
    "$project_dir/Tests/MCPToolMappingTests.swift" \
    -o "$project_dir/build/mcp-tool-mapping-tests"
"$project_dir/build/mcp-tool-mapping-tests" "$project_dir/Tests/mcp-fixtures"
# Test build only: -D EVENTKIT_MCP_TEST runs the real MCP server, pipeline,
# registry and journal with fake EventKit and approvals, over loopback.
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    -D EVENTKIT_MCP_TEST \
    -framework EventKit \
    "$project_dir/Sources/AppIdentity.swift" \
    "$project_dir/Sources/BridgeProtocol.swift" \
    "$project_dir/Sources/CommandPolicy.swift" \
    "$project_dir/Sources/ItemText.swift" \
    "$project_dir/Sources/ItemAlarms.swift" \
    "$project_dir/Sources/Recurrence.swift" \
    "$project_dir/Sources/RecurrenceText.swift" \
    "$project_dir/Sources/EventFields.swift" \
    "$project_dir/Sources/ReminderFields.swift" \
    "$project_dir/Sources/ReminderDue.swift" \
    "$project_dir/Sources/WriteIdempotencyKey.swift" \
    "$project_dir/Sources/WriteJournal.swift" \
    "$project_dir/Sources/ClientCredentialFiles.swift" \
    "$project_dir/Sources/ClientRegistry.swift" \
    "$project_dir/Sources/ActivityStore.swift" \
    "$project_dir/Sources/AccessRequests.swift" \
    "$project_dir/Sources/SafePath.swift" \
    "$project_dir/Sources/RequestPipeline.swift" \
    "$project_dir/Sources/ActivityItems.swift" \
    "$project_dir/Sources/ClientGrantEditing.swift" \
    "$project_dir/Sources/OutcomePresentation.swift" \
    "$project_dir/Sources/AppPresentation.swift" \
    "$project_dir/Sources/AgentSetup.swift" \
    "$project_dir/Sources/MCP/"*.swift \
    "$project_dir/Tests/MCPServerHarness.swift" \
    -o "$project_dir/build/mcp-server-test"
PYTHONPYCACHEPREFIX="$project_dir/build/pycache" python3 "$project_dir/Tests/mcp_test.py" \
    "$project_dir/build/mcp-server-test" "$project_dir/Tests/mcp-fixtures/tools.json"
xcrun swiftc -parse-as-library \
    -sdk "$sdk_dir" \
    -module-cache-path "$cache_dir" \
    -D EVENTKIT_MCP_TEST \
    "$project_dir/Sources/SafePath.swift" \
    "$project_dir/Sources/AppIdentity.swift" \
    "$project_dir/Sources/MCPLauncher.swift" \
    -o "$project_dir/build/bridge-mcp-test"
PYTHONPYCACHEPREFIX="$project_dir/build/pycache" python3 "$project_dir/Tests/launcher_test.py" \
    "$project_dir/build/bridge-mcp-test" "$project_dir/build/mcp-server-test"
