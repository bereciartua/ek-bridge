#!/bin/sh
set -eu

# The live-test copy, "EK Bridge Test" (docs/TESTING.md ▸ Live-test copy): a
# separate app with its own bundle ID, data folder, /tmp folder, MCP and remote
# ports and MCP server key, built with EVENTKIT_LIVE_TEST=1. It runs next to an
# installed EK Bridge without touching it, and is driven through its
# automation channel (Sources/LiveTestAutomation.swift).
#
# Test data only: it creates, grants and removes calendars and lists named
# "EK Bridge Test · <purpose>", and nothing else. Clean up after every run.
#
# Usage: sh scripts/live_test.sh build          build and sign build/live-test/EK Bridge Test.app
#        sh scripts/live_test.sh start [ARGS]   open it through LaunchServices and wait for it
#        sh scripts/live_test.sh stop           quit it (only its bundle ID)
#        sh scripts/live_test.sh cmd 'JSON'     send one automation command, print the response
#        sh scripts/live_test.sh mcp CONNECTION TOOL ['JSON']
#                                               call a tool through its own bridge-mcp;
#                                               "@list:NAME" and "@calendar:NAME" in
#                                               JSON become those test collections' IDs
#        sh scripts/live_test.sh cli ARGS       run its own bridge-client
#        sh scripts/live_test.sh cleanup        remove test collections, quit, check none remain
#        sh scripts/live_test.sh reset          cleanup, then delete its data and settings
#
#   EVENTKIT_SIGN_IDENTITY  build: the codesign identity. Default: the first
#                           "Developer ID Application" identity in the keychain,
#                           so macOS keeps the copy's Calendar and Reminders
#                           permissions across rebuilds.
#   LIVE_TEST_APP           The copy to start and drive. Default:
#                           build/live-test/EK Bridge Test.app
#   LIVE_TEST_TIMEOUT       cmd: seconds to wait for a response. Default: 30.
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
bundle_id=io.github.bereciartua.ekbridge.livetest
app=${LIVE_TEST_APP:-"$project_dir/build/live-test/EK Bridge Test.app"}
data="$HOME/Library/Application Support/EKBridge Live Test"
automation="$data/automation"
prefix="EK Bridge Test · "

fail() { printf 'live_test: %s\n' "$*" >&2; exit 1; }

running() {
    [ "$(osascript -e "application id \"$bundle_id\" is running" 2>/dev/null)" = "true" ]
}

# cmd JSON: appends the command with an id and waits for its response line.
cmd() {
    mkdir -p "$automation"
    python3 - "$automation" "${LIVE_TEST_TIMEOUT:-30}" "$1" <<'PY'
import json, os, sys, time, uuid
folder, timeout, text = sys.argv[1], float(sys.argv[2]), sys.argv[3]
command = json.loads(text)
command.setdefault("id", str(uuid.uuid4()))
responses = os.path.join(folder, "responses.jsonl")
with open(os.path.join(folder, "commands.jsonl"), "a") as file:
    file.write(json.dumps(command) + "\n")
deadline = time.monotonic() + timeout
while time.monotonic() < deadline:
    try:
        with open(responses) as file:
            for line in file:
                reply = json.loads(line)
                if reply.get("id") == command["id"]:
                    print(json.dumps(reply, ensure_ascii=False, indent=1))
                    sys.exit(0 if reply.get("ok") else 1)
    except FileNotFoundError:
        pass
    time.sleep(0.1)
print(json.dumps({"id": command["id"], "ok": False, "error": "no response in time"}))
sys.exit(1)
PY
}

# connection_id NAME-OR-ID: from the app's state.
connection_id() {
    cmd '{"command": "state"}' | python3 -c '
import json, sys
state = json.load(sys.stdin)["result"]
for client in state["connections"]:
    if not client["revoked"] and sys.argv[1] in (client["id"], client["name"]):
        print(client["id"]); break
else:
    sys.exit("live_test: no connection " + sys.argv[1])' "$1"
}

# test_ids JSON: replaces "@calendar:NAME" and "@list:NAME" strings with the
# IDs of those test collections.
test_ids() {
    case "$1" in *'"@calendar:'*|*'"@list:'*) ;; *) printf '%s\n' "$1"; return ;; esac
    cmd '{"command": "state"}' | python3 -c '
import json, sys
ids = {}
for item in json.load(sys.stdin)["result"]["testCollections"]:
    kind = "calendar" if item["resource"] == "calendar" else "list"
    ids["@%s:%s" % (kind, item["name"])] = item["id"]
def swap(value):
    if isinstance(value, dict): return {k: swap(v) for k, v in value.items()}
    if isinstance(value, list): return [swap(v) for v in value]
    if isinstance(value, str) and value.startswith("@"):
        if value not in ids: sys.exit("live_test: no test collection " + value)
        return ids[value]
    return value
print(json.dumps(swap(json.loads(sys.argv[1])), ensure_ascii=False))' "$1"
}

stop() {
    running || return 0
    LIVE_TEST_TIMEOUT=5 cmd '{"command": "quit"}' > /dev/null 2>&1 \
        || osascript -e "tell application id \"$bundle_id\" to quit" > /dev/null 2>&1 || true
    tries=0
    while running; do
        tries=$((tries + 1))
        [ "$tries" -lt 100 ] || fail "EK Bridge Test didn't quit"
        sleep 0.1
    done
}

start() {
    [ -d "$app" ] || fail "no app at $app; run: sh scripts/live_test.sh build"
    if running; then printf 'live_test: already running\n'; return 0; fi
    mkdir -p "$automation"
    chmod 700 "$data" "$automation"
    rm -f "$automation/commands.jsonl" "$automation/responses.jsonl"
    # Through LaunchServices, so macOS treats the app (not this shell) as the
    # one asking for Calendar and Reminders access.
    open -n "$app" --args "$@"
    LIVE_TEST_TIMEOUT=20 cmd '{"command": "state"}' > /dev/null || fail "the app didn't answer"
    printf 'live_test: started %s\n' "$app"
}

cleanup() {
    running || start
    removed=$(cmd '{"command": "removeTestCollections"}') || { printf '%s\n' "$removed"; fail "cleanup failed"; }
    printf '%s\n' "$removed"
    left=$(cmd '{"command": "state"}' | python3 -c '
import json, sys
state = json.load(sys.stdin)["result"]
print(len(state["testCollections"]))
if state["calendarAccess"] != "fullAccess" or state["remindersAccess"] != "fullAccess":
    print("access", file=sys.stderr)')
    stop
    [ "$left" = "0" ] || fail "$left test collections remain (named \"$prefix…\")"
    printf 'live_test: cleaned up; no test collections remain\n'
}

command=${1:-}
[ "$#" -gt 0 ] && shift
case "$command" in
    build)
        identity=${EVENTKIT_SIGN_IDENTITY:-}
        if [ -z "$identity" ]; then
            identity=$(security find-identity -v -p codesigning \
                | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
            [ -n "$identity" ] || fail "no Developer ID identity; set EVENTKIT_SIGN_IDENTITY (ad hoc: -)"
        fi
        running && fail "EK Bridge Test is running; stop it first"
        EVENTKIT_LIVE_TEST=1 EVENTKIT_SIGN_IDENTITY="$identity" sh "$project_dir/build.sh"
        ;;
    start) start "$@" ;;
    stop) stop ;;
    cmd)
        [ "$#" -eq 1 ] || fail "usage: live_test.sh cmd 'JSON'"
        cmd "$1"
        ;;
    mcp)
        [ "$#" -ge 2 ] || fail "usage: live_test.sh mcp CONNECTION TOOL ['JSON']"
        id=$(connection_id "$1")
        tool=$2
        arguments=$(test_ids "${3:-{\}}")
        python3 "$project_dir/scripts/live_mcp_client.py" "$app/Contents/MacOS/bridge-mcp" "$id" "$tool" "$arguments"
        ;;
    cli) "$app/Contents/MacOS/bridge-client" "$@" ;;
    cleanup) cleanup ;;
    reset)
        cleanup
        rm -rf "$data" "/tmp/ek-bridge-live-test-$(id -u)"
        defaults delete "$bundle_id" > /dev/null 2>&1 || true
        printf 'live_test: removed its data folder and settings\n'
        ;;
    *)
        sed -n '/^# Usage/,/^#   LIVE_TEST_TIMEOUT/p' "$0" | sed 's/^# \{0,1\}//' >&2
        exit 2
        ;;
esac
