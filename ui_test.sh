#!/bin/sh
set -eu

# Requires a logged-in macOS GUI session. Uses fake collections and an isolated
# temporary client registry; it never asks for EventKit access or starts a bridge.
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
output_dir="$project_dir/build/window-lifecycle-review"
EVENTKIT_UI_REVIEW=1 EVENTKIT_OUTPUT_DIR="$output_dir" sh "$project_dir/build.sh" >/dev/null
app="$output_dir/EKBridge.app/Contents/MacOS/EKBridge"

# The main window and its sheets survive eight close and reopen cycles.
result=$("$app" --ui-window-lifecycle-test)
printf '%s\n' "$result"
printf '%s\n' "$result" | python3 -c '
import json, sys
value = json.load(sys.stdin)
if value.get("outcome") != "passed" or value.get("cycles") != 8:
    raise SystemExit("AppKit window lifecycle review failed")
'

# Undo, write implies Read, the unsaved-changes guard (close, navigation,
# bridge toggle, quit), rename, create, revoke and Activity deep links.
result=$("$app" --ui-behavior-test)
printf '%s\n' "$result"
printf '%s\n' "$result" | python3 -c '
import json, sys
value = json.load(sys.stdin)
if value.get("outcome") != "passed":
    raise SystemExit("UI behavior review failed at: " + str(value.get("failed")))
'
