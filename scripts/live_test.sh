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
#        sh scripts/live_test.sh trash PATH     move a copy of the test app (Move to Applications
#                                               tests) to the Trash; nothing else is accepted
#        sh scripts/live_test.sh cleanup        remove test collections, quit, check none remain
#        sh scripts/live_test.sh reset          cleanup, then delete its data and settings
#        sh scripts/live_test.sh rollback       load a copy of its data folder with the frozen
#                                               0.8.2 registry (Tests/rollback-0.8.2); the copy
#                                               is made in a temp folder and deleted after
#        sh scripts/live_test.sh quicktunnel start NAME [--keep-host] [--port 47626]
#                                               start a Cloudflare quick tunnel to the copy's
#                                               remote port (no other port is accepted) and
#                                               print its address; --keep-host leaves Host as
#                                               the tunnel sends it (no --http-host-header)
#        sh scripts/live_test.sh quicktunnel stop NAME|stop-all|status
#                                               stop one (only the PID this helper started),
#                                               all of them, or list them; cleanup stops all
#
#   EVENTKIT_SIGN_IDENTITY  build: the codesign identity. Default: the first
#                           "Developer ID Application" identity in the keychain,
#                           so macOS keeps the copy's Calendar and Reminders
#                           permissions across rebuilds.
#   LIVE_TEST_APP           The copy to start and drive. Default:
#                           build/live-test/EK Bridge Test.app
#   LIVE_TEST_TIMEOUT       cmd: seconds to wait for a response. Default: 30.
#   LIVE_TEST_AGENT_HOME    start: a scratch folder that stands in for the home
#                           folder in one-click setup ({"command": "oneClick"}).
#                           Without it, one-click setup refuses in the test copy.
#   LIVE_TEST_CLAUDE_CONFIG_DIR
#                           start: CLAUDE_CONFIG_DIR for the claude command, so
#                           one-click setup never touches the real ~/.claude.json.
#   LIVE_TEST_CODEX_HOME    start: CODEX_HOME for the codex command and Codex's
#                           config.toml; must be inside LIVE_TEST_AGENT_HOME.
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
bundle_id=io.github.bereciartua.ekbridge.livetest
app=${LIVE_TEST_APP:-"$project_dir/build/live-test/EK Bridge Test.app"}
data="$HOME/Library/Application Support/EKBridge Live Test"
automation="$data/automation"
prefix="EK Bridge Test · "
# The test copy's remote port (RemoteDefaults.port in the flavor). Quick
# tunnels go only here, never to the installed app's 47615 or 47616.
remote_port=47626
tunnels="$project_dir/build/live-test/quicktunnels"

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
    # One-click setup writes only into a scratch home (LIVE_TEST_AGENT_HOME), and
    # Claude Code runs only with its own config folder (LIVE_TEST_CLAUDE_CONFIG_DIR).
    set -- "$app" --args "$@"
    if [ -n "${LIVE_TEST_CLAUDE_CONFIG_DIR:-}" ]; then
        set -- --env "CLAUDE_CONFIG_DIR=$LIVE_TEST_CLAUDE_CONFIG_DIR" "$@"
    fi
    if [ -n "${LIVE_TEST_CODEX_HOME:-}" ]; then
        set -- --env "CODEX_HOME=$LIVE_TEST_CODEX_HOME" "$@"
    fi
    if [ -n "${LIVE_TEST_AGENT_HOME:-}" ]; then
        set -- --env "EKB_AGENT_HOME=$LIVE_TEST_AGENT_HOME" "$@"
    fi
    open -n "$@"
    LIVE_TEST_TIMEOUT=20 cmd '{"command": "state"}' > /dev/null || fail "the app didn't answer"
    printf 'live_test: started %s\n' "$app"
}

# Quick tunnels (plan 08): a throwaway trycloudflare.com address in front of
# the copy's remote port. No account and nothing in ~/.cloudflared: each one
# runs with an empty config file of its own, and its PID, log and address
# are kept in build/live-test/quicktunnels.
tunnel_alive() {
    [ -f "$tunnels/$1.pid" ] || return 1
    pid=$(cat "$tunnels/$1.pid")
    ps -o command= -p "$pid" 2>/dev/null | grep -q "cloudflared tunnel .*--config $tunnels/empty.yml"
}

quicktunnel_start() {
    name=${1:-}
    case "$name" in ''|*[!A-Za-z0-9_-]*) fail "usage: live_test.sh quicktunnel start NAME [--keep-host]" ;; esac
    shift
    keep_host=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --keep-host) keep_host=1 ;;
            --port)
                [ "${2:-}" = "$remote_port" ] || fail "quick tunnels go only to the test copy's port $remote_port"
                shift ;;
            *) fail "unknown option $1" ;;
        esac
        shift
    done
    command -v cloudflared > /dev/null || fail "cloudflared isn't installed (brew install cloudflared)"
    tunnel_alive "$name" && fail "quick tunnel $name is already running; stop it first"
    mkdir -p "$tunnels"
    : > "$tunnels/empty.yml"
    rm -f "$tunnels/$name.log" "$tunnels/$name.host" "$tunnels/$name.metrics"
    set -- tunnel --no-autoupdate --config "$tunnels/empty.yml" --url "http://127.0.0.1:$remote_port"
    [ "$keep_host" -eq 1 ] || set -- "$@" --http-host-header "127.0.0.1:$remote_port"
    nohup cloudflared "$@" > "$tunnels/$name.log" 2>&1 < /dev/null &
    printf '%s\n' "$!" > "$tunnels/$name.pid"
    tries=0
    host=
    while [ "$tries" -lt 600 ]; do
        tunnel_alive "$name" || { tail -5 "$tunnels/$name.log" >&2; rm -f "$tunnels/$name.pid"; fail "cloudflared stopped"; }
        metrics=$(sed -n 's/.*metrics server on \(127\.0\.0\.1:[0-9]*\)\/metrics.*/\1/p' "$tunnels/$name.log" | head -1)
        if [ -n "$metrics" ]; then
            host=$(curl -s --max-time 1 "http://$metrics/quicktunnel" \
                | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("hostname") or "")
except Exception: print("")' 2>/dev/null || true)
            [ -n "$host" ] && break
        fi
        tries=$((tries + 1))
        sleep 0.1
    done
    if [ -z "$host" ]; then
        quicktunnel_stop "$name"
        fail "no quick tunnel address within 60 seconds (Cloudflare rate limit or no network?)"
    fi
    printf '%s\n' "$metrics" > "$tunnels/$name.metrics"
    printf 'https://%s\n' "$host" > "$tunnels/$name.host"
    printf 'https://%s\n' "$host"
}

quicktunnel_stop() {
    name=$1
    if tunnel_alive "$name"; then
        pid=$(cat "$tunnels/$name.pid")
        kill "$pid" 2>/dev/null || true
        tries=0
        while kill -0 "$pid" 2>/dev/null; do
            tries=$((tries + 1))
            [ "$tries" -lt 50 ] || { kill -9 "$pid" 2>/dev/null || true; break; }
            sleep 0.1
        done
        printf 'live_test: stopped quick tunnel %s\n' "$name"
    fi
    rm -f "$tunnels/$name.pid" "$tunnels/$name.host" "$tunnels/$name.metrics"
}

quicktunnel_stop_all() {
    [ -d "$tunnels" ] || return 0
    for file in "$tunnels"/*.pid; do
        [ -e "$file" ] || continue
        quicktunnel_stop "$(basename "$file" .pid)"
    done
    # Anything still running with the helper's config file is one of ours.
    if pgrep -f "cloudflared tunnel .*--config $tunnels/empty.yml" > /dev/null; then
        pkill -f "cloudflared tunnel .*--config $tunnels/empty.yml" || true
        sleep 0.5
        pgrep -f "cloudflared tunnel .*--config $tunnels/empty.yml" > /dev/null \
            && fail "a quick tunnel from this helper is still running"
    fi
    return 0
}

quicktunnel() {
    action=${1:-}
    [ "$#" -gt 0 ] && shift
    case "$action" in
        start) quicktunnel_start "$@" ;;
        stop)
            [ "$#" -eq 1 ] || fail "usage: live_test.sh quicktunnel stop NAME"
            quicktunnel_stop "$1" ;;
        stop-all) quicktunnel_stop_all ;;
        status)
            found=0
            for file in "$tunnels"/*.pid; do
                [ -e "$file" ] || continue
                name=$(basename "$file" .pid)
                found=1
                if tunnel_alive "$name"; then
                    printf '%s running %s metrics %s\n' "$name" "$(cat "$tunnels/$name.host" 2>/dev/null)" \
                        "$(cat "$tunnels/$name.metrics" 2>/dev/null)"
                else
                    printf '%s not running\n' "$name"
                fi
            done
            [ "$found" -eq 1 ] || printf 'live_test: no quick tunnels\n'
            ;;
        *) fail "usage: live_test.sh quicktunnel start NAME [--keep-host] | stop NAME | stop-all | status" ;;
    esac
}

cleanup() {
    quicktunnel_stop_all
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
        arguments=${3:-}
        [ -n "$arguments" ] || arguments='{}'
        arguments=$(test_ids "$arguments")
        python3 "$project_dir/scripts/live_mcp_client.py" "$app/Contents/MacOS/bridge-mcp" "$id" "$tool" "$arguments"
        ;;
    cli) "$app/Contents/MacOS/bridge-client" "$@" ;;
    trash)
        [ "$#" -eq 1 ] || fail "usage: live_test.sh trash PATH"
        target=$1
        [ "$(basename "$target")" = "EK Bridge Test.app" ] || fail "only copies named EK Bridge Test.app"
        [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target/Contents/Info.plist" 2>/dev/null)" \
            = "$bundle_id" ] || fail "$target isn't the live-test copy"
        xcrun swift -e 'import Foundation
try FileManager.default.trashItem(at: URL(fileURLWithPath: CommandLine.arguments[1]), resultingItemURL: nil)' \
            "$target" || fail "couldn't move $target to the Trash"
        printf 'live_test: moved %s to the Trash\n' "$target"
        ;;
    cleanup) cleanup ;;
    quicktunnel) quicktunnel "$@" ;;
    rollback)
        # Never the installed app's folder: always a copy of the test copy's.
        [ -f "$data/client-registry.json" ] || fail "no registry in $data yet"
        . "$project_dir/scripts/sdk.sh"
        mkdir -p "$project_dir/build/module-cache"
        xcrun swiftc -parse-as-library -sdk "$sdk_dir" -module-cache-path "$project_dir/build/module-cache" \
            "$project_dir/Tests/rollback-0.8.2/AppIdentity.swift" \
            "$project_dir/Tests/rollback-0.8.2/BridgeProtocol.swift" \
            "$project_dir/Tests/rollback-0.8.2/ClientCredentialFiles.swift" \
            "$project_dir/Tests/rollback-0.8.2/ClientRegistry.swift" \
            "$project_dir/Tests/RollbackHarness.swift" \
            -o "$project_dir/build/rollback-harness"
        scratch=$(mktemp -d "${TMPDIR:-/tmp}/ekb-rollback.XXXXXX")
        ditto "$data" "$scratch/data"
        chmod 700 "$scratch/data"
        status=0
        "$project_dir/build/rollback-harness" "$scratch/data" --write || status=$?
        rm -rf "$scratch"
        [ "$status" -eq 0 ] || fail "0.8.2 couldn't load a copy of the test data folder"
        printf 'live_test: 0.8.2 loads a copy of the test data folder\n'
        ;;
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
