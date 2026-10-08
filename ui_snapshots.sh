#!/bin/sh
set -eu

# Writes PNGs of every screen, light and dark, from the UI-review build (fake
# clients, calendars and activity; never touches EventKit or starts a bridge).
# Requires a logged-in GUI session. The app pauses at each screen and this
# script captures the real window with screencapture, which needs Screen
# Recording permission for the terminal. Without it, pass --cache to use the
# app's own cacheDisplay renderer (no permission needed, but lists and tables
# come out blank).
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
output_dir="$project_dir/build/ui-review"
mode=external
if [ "${1:-}" = "--cache" ]; then mode=cache; shift; fi
snapshots=${1:-"$project_dir/build/snapshots"}
EVENTKIT_UI_REVIEW=1 EVENTKIT_OUTPUT_DIR="$output_dir" sh "$project_dir/build.sh" >/dev/null
mkdir -p "$snapshots"
python3 - "$output_dir/EKBridge.app/Contents/MacOS/EKBridge" "$snapshots" "$mode" <<'PY'
import json, os, subprocess, sys, time

app, folder, mode = sys.argv[1:4]
arguments = [app, "--ui-snapshots", folder]
if mode == "external":
    arguments.append("--ui-snapshots-external")
process = subprocess.Popen(arguments, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
for line in process.stdout:
    message = json.loads(line)
    if "ready" in message:
        path = os.path.join(folder, message["ready"] + ".png")
        # The app reports a window once its frame has settled; a short pause
        # lets the window server draw that last frame.
        time.sleep(0.3)
        subprocess.run(["screencapture", "-x", "-o", "-l", str(message["windowNumber"]), path],
                       check=True)
        process.stdin.write("\n")
        process.stdin.flush()
    elif message.get("outcome") != "passed":
        raise SystemExit("snapshot review failed: " + line)
    else:
        print(f"{len(message['files'])} snapshots in {folder}")
if process.wait() != 0:
    raise SystemExit("snapshot app exited with an error")
PY
# A capture taken while a window was still opening comes out tiny (174 x 220).
small=""
for file in "$snapshots"/*.png; do
    width=$(sips -g pixelWidth "$file" | awk '/pixelWidth/ { print $2 }')
    [ "$width" -ge 400 ] || small="$small $(basename "$file") ($width px)"
done
if [ -n "$small" ]; then
    printf 'ui_snapshots: captured before the window was ready:%s\n' "$small" >&2
    exit 1
fi
