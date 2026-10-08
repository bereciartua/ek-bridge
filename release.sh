#!/bin/sh
set -eu

# Builds a release: the offline tests, a universal Developer ID–signed build,
# notarization and stapling, a DMG (also as EKBridge.dmg, a name that never
# changes) and a zip, SHA-256 sums, the Sparkle appcast (when a Sparkle key is
# given), and a draft GitHub release for the maintainer to review and publish.
# The release workflow runs it on a v* tag; it also runs by hand on a Mac with
# the identity and the notary credentials.
#
# Usage: sh release.sh [--untagged] [--no-notarize] [--no-release] [--skip-tests]
#
#   --untagged     Build the commit at HEAD even though it isn't tagged
#                  v<version>; implies --no-release. For rehearsals.
#   --no-notarize  Skip notarization and stapling. The output is signed but
#                  Gatekeeper blocks it on other Macs; for rehearsals without
#                  Apple's notary service. Implies --no-release.
#   --no-release   Build everything in dist/ but create no GitHub release.
#   --skip-tests   Don't run test.sh first (only for repeated rehearsals).
#
# Environment:
#   EVENTKIT_SIGN_IDENTITY    The codesign identity. Default: the one
#                             "Developer ID Application" identity in the keychain.
#   EVENTKIT_NOTARY_PROFILE   A notarytool keychain profile (by hand), or
#   EVENTKIT_NOTARY_KEY, EVENTKIT_NOTARY_KEY_ID, EVENTKIT_NOTARY_ISSUER
#                             an App Store Connect API key (.p8 path, key ID,
#                             issuer ID; the issuer is empty for an individual key).
#   EVENTKIT_SPARKLE_KEY_FILE Sparkle's EdDSA private key (from generate_keys -x)
#                             to sign the zip and write appcast.xml. Required
#                             for a release once Info.plist has SUPublicEDKey:
#                             without an appcast, installed copies wouldn't
#                             see the release. Rehearsals may leave it out.
#   EVENTKIT_SPARKLE_KEYCHAIN=1  Instead of a key file, sign with the key
#                             generate_keys stored in the login keychain (a
#                             release by hand on the maintainer's Mac).
#   EVENTKIT_SPARKLE_BIN      Folder with Sparkle's sign_update. Default: the
#                             pinned Sparkle in build/vendor (downloaded by
#                             scripts/sparkle.sh), then PATH.
#   EVENTKIT_RELEASE_REPO     The GitHub repository. Default: GITHUB_REPOSITORY,
#                             else bereciartua/ek-bridge.
#   GH_TOKEN                  For gh in CI (the workflow passes github.token).

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
dist_dir="$project_dir/dist"
build_dir="$project_dir/build/release"
plist="$project_dir/Info.plist"
repo=${EVENTKIT_RELEASE_REPO:-${GITHUB_REPOSITORY:-bereciartua/ek-bridge}}

untagged=0 notarize=1 release=1 run_tests=1
for arg in "$@"; do
    case "$arg" in
        --untagged) untagged=1 release=0 ;;
        --no-notarize) notarize=0 release=0 ;;
        --no-release) release=0 ;;
        --skip-tests) run_tests=0 ;;
        -h|--help) sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'release: unknown option %s\n' "$arg" >&2; exit 2 ;;
    esac
done

fail() { printf 'release: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
build_number=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")
minimum_macos=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")
app_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")
display_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$plist")
public_key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$plist" 2>/dev/null || true)
tag="v$version"
app="$build_dir/$app_name.app"
dmg="$dist_dir/$app_name-$version.dmg"
stable_dmg="$dist_dir/$app_name.dmg"
zip="$dist_dir/$app_name-$version.zip"

# 1. A clean tree at a matching tag (or --untagged), and a consistent version.
step "Checking the tree and the version"
[ -z "$(git -C "$project_dir" status --porcelain)" ] \
    || fail "the working tree has uncommitted changes; commit or stash them first"
if [ "$untagged" = 1 ]; then
    printf 'Untagged rehearsal of %s (%s) at %s\n' "$version" "$build_number" \
        "$(git -C "$project_dir" rev-parse --short HEAD)"
    sh "$project_dir/scripts/check_version.sh"
else
    git -C "$project_dir" tag --points-at HEAD | grep -qx "$tag" \
        || fail "HEAD isn't tagged $tag (Info.plist says $version); tag it, or pass --untagged for a rehearsal"
    sh "$project_dir/scripts/check_version.sh" "$tag"
fi

# The signing identity: a Developer ID unless this is a rehearsal.
if [ -z "${EVENTKIT_SIGN_IDENTITY:-}" ]; then
    found=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | tr -d '"' || true)
    [ -n "$found" ] || fail "no \"Developer ID Application\" identity in the keychain; set EVENTKIT_SIGN_IDENTITY"
    [ "$(printf '%s\n' "$found" | wc -l)" -eq 1 ] \
        || fail "more than one Developer ID Application identity; set EVENTKIT_SIGN_IDENTITY to one of:
$found"
    EVENTKIT_SIGN_IDENTITY=$found
fi
security find-identity -v -p codesigning | grep -qF "\"$EVENTKIT_SIGN_IDENTITY\"" \
    || fail "the identity \"$EVENTKIT_SIGN_IDENTITY\" isn't a valid code-signing identity in the keychain"
if [ "$notarize" = 1 ]; then
    case "$EVENTKIT_SIGN_IDENTITY" in
        "Developer ID Application: "*) ;;
        *) fail "notarization needs a Developer ID Application identity, not \"$EVENTKIT_SIGN_IDENTITY\"" ;;
    esac
    if [ -n "${EVENTKIT_NOTARY_PROFILE:-}" ]; then
        :
    elif [ -n "${EVENTKIT_NOTARY_KEY:-}" ] && [ -n "${EVENTKIT_NOTARY_KEY_ID:-}" ]; then
        [ -f "$EVENTKIT_NOTARY_KEY" ] || fail "EVENTKIT_NOTARY_KEY $EVENTKIT_NOTARY_KEY isn't a file"
    else
        fail "set EVENTKIT_NOTARY_PROFILE, or EVENTKIT_NOTARY_KEY and EVENTKIT_NOTARY_KEY_ID (pass --no-notarize for a rehearsal)"
    fi
fi
sign_update=""
if [ -n "${EVENTKIT_SPARKLE_KEY_FILE:-}" ] || [ "${EVENTKIT_SPARKLE_KEYCHAIN:-0}" = 1 ]; then
    if [ -n "${EVENTKIT_SPARKLE_KEY_FILE:-}" ]; then
        [ -f "$EVENTKIT_SPARKLE_KEY_FILE" ] || fail "EVENTKIT_SPARKLE_KEY_FILE $EVENTKIT_SPARKLE_KEY_FILE isn't a file"
    fi
    [ -n "$public_key" ] || fail "a Sparkle key is set but Info.plist has no SUPublicEDKey for the app to check it with"
    if [ -z "${EVENTKIT_SPARKLE_BIN:-}" ] && [ -f "$project_dir/scripts/sparkle.sh" ]; then
        . "$project_dir/scripts/sparkle.sh"
    fi
    for candidate in "${EVENTKIT_SPARKLE_BIN:-$project_dir/build/vendor/Sparkle/bin}/sign_update" \
            "$(command -v sign_update 2>/dev/null || true)"; do
        if [ -n "$candidate" ] && [ -x "$candidate" ]; then sign_update=$candidate; break; fi
    done
    [ -n "$sign_update" ] || fail "a Sparkle key is set but sign_update wasn't found; set EVENTKIT_SPARKLE_BIN"
fi
if [ "$release" = 1 ] && [ -n "$public_key" ] && [ -z "$sign_update" ]; then
    fail "set EVENTKIT_SPARKLE_KEY_FILE (or EVENTKIT_SPARKLE_KEYCHAIN=1): without an appcast, installed copies won't see this release"
fi
if [ "$release" = 1 ]; then
    command -v gh > /dev/null || fail "gh (the GitHub CLI) is needed to create the draft release"
    gh auth status > /dev/null 2>&1 || fail "gh isn't signed in"
    ! gh release view "$tag" --repo "$repo" > /dev/null 2>&1 \
        || fail "a release $tag already exists in $repo; delete the draft first"
fi
export EVENTKIT_SIGN_IDENTITY
printf 'Signing as %s\n' "$EVENTKIT_SIGN_IDENTITY"

# With an API key file, the issuer is only passed when set (individual keys have none).
notarytool() {
    if [ -n "${EVENTKIT_NOTARY_PROFILE:-}" ]; then
        xcrun notarytool "$@" --keychain-profile "$EVENTKIT_NOTARY_PROFILE"
    elif [ -n "${EVENTKIT_NOTARY_ISSUER:-}" ]; then
        xcrun notarytool "$@" --key "$EVENTKIT_NOTARY_KEY" --key-id "$EVENTKIT_NOTARY_KEY_ID" \
            --issuer "$EVENTKIT_NOTARY_ISSUER"
    else
        xcrun notarytool "$@" --key "$EVENTKIT_NOTARY_KEY" --key-id "$EVENTKIT_NOTARY_KEY_ID"
    fi
}

# notarytool's JSON result (its last JSON object; warnings may precede it) as
# "<id> <status>", or nothing when there is no result.
notary_result() {
    python3 -c '
import json, re, sys
text = sys.stdin.read()
for match in reversed(list(re.finditer(r"^\{", text, re.M))):
    try:
        outcome = json.loads(text[match.start():])
    except ValueError:
        continue
    print(outcome.get("id", "?"), outcome.get("status", "?"))
    break
'
}

# Submits a file and waits. On anything but Accepted, prints Apple's log.
notarize_file() {
    result=$(notarytool submit "$1" --wait --timeout 45m --output-format json 2>&1) || true
    parsed=$(printf '%s\n' "$result" | notary_result)
    if [ -z "$parsed" ]; then
        printf '%s\n' "$result" >&2
        fail "notarytool returned no result for $(basename "$1")"
    fi
    submission_id=${parsed%% *}
    submission_status=${parsed#* }
    printf 'Submission %s: %s\n' "$submission_id" "$submission_status"
    [ "$submission_status" = "Accepted" ] && return 0
    printf 'Notarization log for %s:\n' "$submission_id" >&2
    notarytool log "$submission_id" >&2 || true
    fail "notarization of $(basename "$1") failed ($submission_status)"
}

# 2. Tests.
if [ "$run_tests" = 1 ]; then
    step "Running the offline tests"
    sh "$project_dir/test.sh"
else
    step "Skipping the offline tests (--skip-tests)"
fi

# 3. A universal, timestamped, Developer ID–signed build.
step "Building the universal app"
rm -rf "$build_dir" "$dist_dir"
mkdir -p "$build_dir" "$dist_dir"
# Never a test flavor, whatever the environment says.
env -u EVENTKIT_LIVE_TEST -u EVENTKIT_UI_REVIEW -u EVENTKIT_UPDATE_TEST -u EVENTKIT_SYNTHETIC_TEST \
    EVENTKIT_OUTPUT_DIR=$build_dir EVENTKIT_ARCHS="arm64 x86_64" sh "$project_dir/build.sh"
sh "$project_dir/scripts/check_bundle.sh" "$app" arm64 x86_64
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" = "$version" ] \
    || fail "the built app's version isn't $version"

# 4–5. Notarize the app and staple the ticket.
if [ "$notarize" = 1 ]; then
    step "Notarizing the app"
    ditto -c -k --keepParent "$app" "$build_dir/notarize-$app_name.zip"
    notarize_file "$build_dir/notarize-$app_name.zip"
    rm -f "$build_dir/notarize-$app_name.zip"
    xcrun stapler staple -q "$app"
    sh "$project_dir/scripts/check_notarized.sh" "$app"
else
    step "Skipping notarization (--no-notarize)"
    sh "$project_dir/scripts/check_notarized.sh" "$app" --signed-only
fi

# 6. The DMG (drag to Applications), signed, notarized and stapled; then the zip
# from the stapled app, which Sparkle installs from.
step "Building the disk image"
staging="$build_dir/dmg"
rm -rf "$staging"
mkdir -p "$staging"
ditto "$app" "$staging/$app_name.app"
ln -s /Applications "$staging/Applications"
hdiutil create -quiet -ov -volname "$display_name" -srcfolder "$staging" -fs HFS+ -format ULFO "$dmg"
rm -rf "$staging"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")
codesign --force --sign "$EVENTKIT_SIGN_IDENTITY" --timestamp --identifier "$bundle_id.dmg" "$dmg"
if [ "$notarize" = 1 ]; then
    step "Notarizing the disk image"
    notarize_file "$dmg"
    xcrun stapler staple -q "$dmg"
    sh "$project_dir/scripts/check_notarized.sh" "$dmg"
else
    sh "$project_dir/scripts/check_notarized.sh" "$dmg" --signed-only
fi

step "Building the zip"
ditto -c -k --keepParent "$app" "$zip"

# 7. Checksums, and the Sparkle appcast when a key is given.
step "Writing checksums and release notes"
# The same DMG as EKBridge.dmg, so releases/latest/download/EKBridge.dmg always
# works, and SHA256SUMS for all three downloads.
sh "$project_dir/scripts/release_assets.sh" "$dist_dir" "$app_name" "$version"
cat "$dist_dir/SHA256SUMS"
python3 "$project_dir/scripts/release_notes.py" "$version" --repo "$repo" --format markdown \
    > "$build_dir/notes-section.md"
python3 "$project_dir/scripts/release_notes.py" "$version" --repo "$repo" --format html \
    > "$build_dir/notes.html"
if [ -n "$sign_update" ]; then
    step "Signing the zip for Sparkle and writing the appcast"
    if [ -n "${EVENTKIT_SPARKLE_KEY_FILE:-}" ]; then
        signature_line=$("$sign_update" --ed-key-file "$EVENTKIT_SPARKLE_KEY_FILE" "$zip")
    else
        signature_line=$("$sign_update" "$zip")
    fi
    # The check installed copies will make: the signature against SUPublicEDKey.
    signature=$(printf '%s\n' "$signature_line" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
    xcrun swiftc -O -o "$build_dir/verify-update-signature" "$project_dir/scripts/verify_update_signature.swift"
    "$build_dir/verify-update-signature" "$public_key" "$zip" "$signature" \
        || fail "the Sparkle key doesn't match SUPublicEDKey in Info.plist"
    python3 "$project_dir/scripts/appcast.py" \
        --version "$version" --build "$build_number" --minimum-system-version "$minimum_macos" \
        --url "https://github.com/$repo/releases/download/$tag/$(basename "$zip")" \
        --signature-line "$signature_line" --notes-html "$build_dir/notes.html" \
        --title "$display_name $version" --link "https://github.com/$repo/releases/tag/$tag" \
        --output "$dist_dir/appcast.xml"
else
    printf 'No Sparkle key (EVENTKIT_SPARKLE_KEY_FILE): appcast.xml not written\n'
fi
# The notes for the GitHub release: the CHANGELOG section, then how to install
# and verify. Only claims that hold for this build are made (a rehearsal isn't
# notarized; only the workflow attests; only a release with an appcast updates).
{
    cat "$build_dir/notes-section.md"
    printf '\n## Install\n\n'
    printf 'Download `%s` (`%s` is the same file, under a name that stays the same in every release), open it and drag the app to **Applications**. It needs macOS %s or later, on Apple silicon or Intel. ' \
        "$(basename "$dmg")" "$(basename "$stable_dmg")" "$minimum_macos"
    printf 'The first start asks for Calendar and Reminders access ([Setup](https://github.com/%s/blob/%s/docs/SETUP.md)). ' "$repo" "$tag"
    printf 'Replacing an installed copy at the same path keeps its access, clients and agent setups.'
    # Only copies from an earlier release have the updater (0.8.0 is the first).
    earlier=$(git -C "$project_dir" tag --list 'v*' | grep -vx "$tag" | head -n 1 || true)
    if [ -f "$dist_dir/appcast.xml" ] && [ -n "$earlier" ]; then
        printf ' An installed copy offers this version from **Check for Updates…**.'
    fi
    printf '\n\n## Checksums (SHA-256)\n\n```\n'
    cat "$dist_dir/SHA256SUMS"
    printf '```\n\n'
    if [ "$notarize" = 1 ]; then
        printf 'The app and the disk image are signed with a Developer ID and notarized by Apple.'
    else
        printf '**Rehearsal build:** signed, but not notarized; Gatekeeper blocks it on other Macs.'
    fi
    if [ "${GITHUB_ACTIONS:-}" = true ]; then
        printf ' Built by the release workflow: `gh attestation verify %s --repo %s` checks the provenance of each download.' \
            "$(basename "$dmg")" "$repo"
    fi
    printf '\n'
} > "$dist_dir/RELEASE-NOTES.md"

# 8. A draft release for the maintainer to review and publish.
if [ "$release" = 1 ]; then
    step "Creating the draft release $tag in $repo"
    set -- "$dmg" "$stable_dmg" "$zip" "$dist_dir/SHA256SUMS"
    [ -f "$dist_dir/appcast.xml" ] && set -- "$@" "$dist_dir/appcast.xml"
    gh release create "$tag" --repo "$repo" --draft --verify-tag \
        --title "$display_name $version" --notes-file "$dist_dir/RELEASE-NOTES.md" "$@"
    printf 'Draft created: review it at https://github.com/%s/releases, then publish it.\n' "$repo"
else
    step "No GitHub release (rehearsal); the files are in dist/"
fi
ls -l "$dist_dir"
