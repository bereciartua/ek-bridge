#!/bin/sh
set -eu

# The Sparkle update test, without GitHub: builds two copies of a separate
# "EK Bridge Update Test" app (its own bundle ID, data folder and /tmp folder,
# so an installed EK Bridge is never touched), 0.0.1 and 0.0.2, signs 0.0.2's
# zip with a throwaway EdDSA key, serves the appcast and the zip on 127.0.0.1,
# and opens 0.0.1. You then install the update the way a user would; the
# script waits for 0.0.2 to be running and checks it.
#
# Usage: sh scripts/update_test.sh   (from a logged-in GUI session)
#        sh scripts/update_test.sh --clean   quits the test app and removes its
#                                            settings, caches and build folder
#
#   EVENTKIT_SIGN_IDENTITY  Sign both copies with this identity (a Developer ID
#                           checks Sparkle's same-team rule too). Default: ad hoc.
#   EVENTKIT_UPDATE_TEST_PORT  The local server's port. Default: 47690.
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work="$project_dir/build/update-test"
port=${EVENTKIT_UPDATE_TEST_PORT:-47690}
bundle_id=io.github.bereciartua.ekbridge.updatetest
installed="$work/install/EKBridge.app"

fail() { printf 'update_test: %s\n' "$*" >&2; exit 1; }

if [ "${1:-}" = "--clean" ]; then
    osascript -e "tell application id \"$bundle_id\" to quit" > /dev/null 2>&1 || true
    defaults delete "$bundle_id" > /dev/null 2>&1 || true
    for name in Preferences/$bundle_id.plist Caches/$bundle_id HTTPStorages/$bundle_id WebKit/$bundle_id \
        "Application Support/EKBridge Update Test"; do
        rm -rf "$HOME/Library/$name"
    done
    rm -rf "$work" "/tmp/ek-bridge-update-test-$(id -u)"
    printf 'update_test: removed the test app and its traces\n'
    exit 0
fi
step() { printf '\n==> %s\n' "$*"; }

server_pid=""
cleanup() {
    [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

pgrep -f "$installed/Contents/MacOS/EKBridge" > /dev/null && fail "the test app is still running; quit it first"
rm -rf "$work"
mkdir -p "$work/feed" "$work/install"

step "A throwaway EdDSA key pair"
cat > "$work/keygen.swift" <<'SWIFT'
import CryptoKit
let key = Curve25519.Signing.PrivateKey()
print(key.rawRepresentation.base64EncodedString())
print(key.publicKey.rawRepresentation.base64EncodedString())
SWIFT
xcrun swiftc -o "$work/keygen" "$work/keygen.swift"
keys=$("$work/keygen")
printf '%s' "$(printf '%s\n' "$keys" | sed -n 1p)" > "$work/throwaway.key"
public_key=$(printf '%s\n' "$keys" | sed -n 2p)

feed="http://127.0.0.1:$port/appcast.xml"
build() {
    step "Building $1 ($2)"
    EVENTKIT_UPDATE_TEST=1 EVENTKIT_UPDATE_TEST_VERSION=$1 EVENTKIT_UPDATE_TEST_BUILD=$2 \
        EVENTKIT_UPDATE_TEST_FEED=$feed EVENTKIT_UPDATE_TEST_PUBLIC_KEY=$public_key \
        EVENTKIT_OUTPUT_DIR="$work/build-$1" sh "$project_dir/build.sh" > "$work/build-$1.log" 2>&1 \
        || { tail -20 "$work/build-$1.log" >&2; fail "the $1 build failed"; }
    sh "$project_dir/scripts/check_bundle.sh" "$work/build-$1/EKBridge.app"
}
build 0.0.1 1
build 0.0.2 2

step "The feed: 0.0.2's zip, signed with the throwaway key"
ditto -c -k --keepParent "$work/build-0.0.2/EKBridge.app" "$work/feed/EKBridge-0.0.2.zip"
signature_line=$("$project_dir/build/vendor/Sparkle/bin/sign_update" --ed-key-file "$work/throwaway.key" \
    "$work/feed/EKBridge-0.0.2.zip")
printf '<p>Update test build. Nothing changed but the version.</p>\n' > "$work/notes.html"
python3 "$project_dir/scripts/appcast.py" --version 0.0.2 --build 2 --minimum-system-version 14.0 \
    --url "http://127.0.0.1:$port/EKBridge-0.0.2.zip" --signature-line "$signature_line" \
    --notes-html "$work/notes.html" --title "EK Bridge Update Test 0.0.2" --output "$work/feed/appcast.xml" \
    --allow-local-http
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$work/feed" > "$work/server.log" 2>&1 &
server_pid=$!
sleep 1
curl --fail --silent --output /dev/null "$feed" || fail "the local feed isn't reachable at $feed"

step "Opening 0.0.1"
ditto "$work/build-0.0.1/EKBridge.app" "$installed"
open "$installed"
cat <<EOF

Now, as a user would:
  1. Choose Check for Updates… in the menu bar menu (the calendar icon of
     "EK Bridge Update Test"). Sparkle's window shows 0.0.2. If a scheduled
     check finds it first while the app is in the background, the menu shows
     "Update Available: 0.0.2…" and Overview shows the card instead.
  2. Click it (or Install Update… on the card), read the notes, and click
     Install Update, then Install and Relaunch.
  3. The app restarts as 0.0.2. This script is waiting for it (10 minutes).
EOF

deadline=$(( $(date +%s) + 600 ))
while :; do
    version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$installed/Contents/Info.plist" 2>/dev/null || true)
    if [ "$version" = "0.0.2" ] && pgrep -f "$installed/Contents/MacOS/EKBridge" > /dev/null; then break; fi
    [ "$(date +%s)" -lt "$deadline" ] || fail "0.0.2 wasn't installed and running within 10 minutes (installed: ${version:-none})"
    sleep 2
done

step "Checking the updated app"
sh "$project_dir/scripts/check_bundle.sh" "$installed"
grep -q 'GET /EKBridge-0.0.2.zip' "$work/server.log" || fail "the zip was never downloaded from the feed"
[ "$(xattr -p com.apple.quarantine "$installed" 2>/dev/null || true)" = "" ] \
    || printf 'note: the updated app carries a quarantine flag\n'
printf '\nupdate_test: 0.0.1 updated itself to 0.0.2 through Sparkle and is running.\n'
printf 'Remove the test app and its traces with: sh scripts/update_test.sh --clean\n'
