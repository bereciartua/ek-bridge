#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cache_dir="$project_dir/build/module-cache"
mkdir -p "$project_dir/build" "$cache_dir"
xcrun swiftc -parse-as-library \
    -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
    -module-cache-path "$cache_dir" \
    "$project_dir/Sources/BridgeEnablement.swift" \
    "$project_dir/Tests/BridgeEnablementTests.swift" \
    -o "$project_dir/build/bridge-enablement-tests"
"$project_dir/build/bridge-enablement-tests"
xcrun swiftc -parse-as-library \
    -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
    -module-cache-path "$cache_dir" \
    "$project_dir/Sources/BridgeProtocol.swift" \
    "$project_dir/Sources/CommandPolicy.swift" \
    "$project_dir/Sources/EventCreation.swift" \
    "$project_dir/Sources/MutationPolicy.swift" \
    "$project_dir/Sources/ReminderDue.swift" \
    "$project_dir/Sources/ReminderRecurrence.swift" \
    "$project_dir/Sources/WriteJournal.swift" \
    "$project_dir/Sources/WriteIdempotencyKey.swift" \
    "$project_dir/Tests/BridgeProtocolTests.swift" \
    -framework EventKit \
    -o "$project_dir/build/bridge-protocol-tests"
"$project_dir/build/bridge-protocol-tests"
xcrun swiftc -parse-as-library \
    -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
    -module-cache-path "$cache_dir" \
    "$project_dir/Sources/ReminderDue.swift" \
    "$project_dir/Tests/ReminderDueTests.swift" \
    -o "$project_dir/build/reminder-due-tests"
"$project_dir/build/reminder-due-tests"
xcrun swiftc -parse-as-library \
    -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
    -module-cache-path "$cache_dir" \
    -framework EventKit \
    "$project_dir/Sources/ReminderRecurrence.swift" \
    "$project_dir/Tests/ReminderRecurrenceTests.swift" \
    -o "$project_dir/build/reminder-recurrence-tests"
"$project_dir/build/reminder-recurrence-tests"
xcrun swiftc -parse-as-library \
    -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
    -module-cache-path "$cache_dir" \
    -framework EventKit \
    "$project_dir/Sources/ReminderDue.swift" \
    "$project_dir/Sources/RecurringReminderCompletion.swift" \
    "$project_dir/Tests/RecurringReminderCompletionTests.swift" \
    -o "$project_dir/build/recurring-completion-tests"
"$project_dir/build/recurring-completion-tests"
xcrun swiftc -parse-as-library \
    -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
    -module-cache-path "$cache_dir" \
    -framework EventKit \
    "$project_dir/Sources/ReminderDue.swift" \
    "$project_dir/Sources/ReminderRecurrence.swift" \
    "$project_dir/Sources/ReminderSchedule.swift" \
    "$project_dir/Tests/ReminderScheduleTests.swift" \
    -o "$project_dir/build/reminder-schedule-tests"
"$project_dir/build/reminder-schedule-tests"
xcrun swiftc -parse-as-library \
    -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
    -module-cache-path "$cache_dir" \
    "$project_dir/Sources/BridgeProtocol.swift" \
    "$project_dir/Sources/WriteIdempotencyKey.swift" \
    "$project_dir/Sources/WriteJournal.swift" \
    "$project_dir/Tests/WriteJournalRetentionTests.swift" \
    -o "$project_dir/build/write-journal-retention-tests"
"$project_dir/build/write-journal-retention-tests"
xcrun swiftc -parse-as-library \
    -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
    -module-cache-path "$cache_dir" \
    "$project_dir/Sources/BridgeProtocol.swift" \
    "$project_dir/Sources/CommandPolicy.swift" \
    "$project_dir/Sources/EventCreation.swift" \
    "$project_dir/Sources/ReminderDue.swift" \
    "$project_dir/Sources/ReminderRecurrence.swift" \
    "$project_dir/Sources/ClientBridgeProtocol.swift" \
    "$project_dir/Sources/ClientRegistry.swift" \
    "$project_dir/Sources/WriteIdempotencyKey.swift" \
    "$project_dir/Tests/ClientRegistryTests.swift" \
    -framework EventKit \
    -o "$project_dir/build/client-registry-tests"
"$project_dir/build/client-registry-tests"
xcrun swiftc -parse-as-library \
    -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
    -module-cache-path "$cache_dir" \
    "$project_dir/Sources/BridgeProtocol.swift" \
    "$project_dir/Sources/ClientRegistry.swift" \
    "$project_dir/Sources/ClientGrantEditing.swift" \
    "$project_dir/Tests/ClientGrantEditingTests.swift" \
    -o "$project_dir/build/client-grant-editing-tests"
"$project_dir/build/client-grant-editing-tests"
xcrun swiftc -parse-as-library \
    -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
    -module-cache-path "$cache_dir" \
    "$project_dir/Sources/ClientCredentialFiles.swift" \
    "$project_dir/Tests/ClientCredentialFilesTests.swift" \
    -o "$project_dir/build/client-credential-files-tests"
"$project_dir/build/client-credential-files-tests"
xcrun swiftc -parse-as-library \
    -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
    -module-cache-path "$cache_dir" \
    "$project_dir/Sources/BridgePollingTimer.swift" \
    "$project_dir/Tests/BridgePollingTimerTests.swift" \
    -o "$project_dir/build/bridge-polling-timer-tests"
"$project_dir/build/bridge-polling-timer-tests"
xcrun swiftc -parse-as-library \
    -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
    -module-cache-path "$cache_dir" \
    "$project_dir/Candidate/SignedXPCBoundary.swift" \
    "$project_dir/Tests/SignedXPCBoundaryTests.swift" \
    -o "$project_dir/build/signed-xpc-boundary-tests"
printf 'int main(void) { return 0; }\n' > "$project_dir/build/test-peer.c"
xcrun clang "$project_dir/build/test-peer.c" -o "$project_dir/build/test-peer-good"
cp "$project_dir/build/test-peer-good" "$project_dir/build/test-peer-bad"
codesign --force --sign - --identifier dev.martin.dot.eventkitbridge.client \
    "$project_dir/build/test-peer-good"
codesign --force --sign - --identifier dev.martin.dot.eventkitbridge.impostor \
    "$project_dir/build/test-peer-bad"
"$project_dir/build/signed-xpc-boundary-tests" \
    "$project_dir/build/test-peer-good" "$project_dir/build/test-peer-bad"
PYTHONPYCACHEPREFIX="$project_dir/build/pycache" python3 -m py_compile "$project_dir/client.py"
