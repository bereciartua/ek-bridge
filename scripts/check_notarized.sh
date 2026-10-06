#!/bin/sh
set -eu

# Checks a release artifact the way Gatekeeper will: the signature verifies,
# it comes from a Developer ID identity with a secure timestamp, Gatekeeper
# accepts it as notarized, and the notarization ticket is stapled. With
# --signed-only (a rehearsal without Apple's notary service) only the
# signature, identity and timestamp are checked.
#
# Usage: sh scripts/check_notarized.sh PATH.app|PATH.dmg [--signed-only]
path=${1:?usage: check_notarized.sh PATH.app|PATH.dmg [--signed-only]}
signed_only=0
[ "${2:-}" = "--signed-only" ] && signed_only=1

fail() { printf 'check_notarized: %s\n' "$*" >&2; exit 1; }

case "$path" in
    *.app) kind=app ;;
    *.dmg) kind=dmg ;;
    *) fail "$path is neither an .app nor a .dmg" ;;
esac
[ -e "$path" ] || fail "$path doesn't exist"

codesign --verify --deep --strict "$path" || fail "the signature of $path doesn't verify"
details=$(codesign --display --verbose=2 "$path" 2>&1)
printf '%s\n' "$details" | grep -q '^Authority=Developer ID Application:' \
    || fail "$path isn't signed with a Developer ID Application identity"
printf '%s\n' "$details" | grep -q '^Timestamp=' \
    || fail "$path has no secure timestamp (sign with --timestamp)"
if [ "$kind" = app ]; then
    printf '%s\n' "$details" | grep -q 'flags=.*runtime' || fail "$path lacks the hardened runtime"
fi

if [ "$signed_only" = 1 ]; then
    printf 'check_notarized: %s is Developer ID signed with a timestamp (notarization not checked)\n' \
        "$(basename "$path")"
    exit 0
fi

# Gatekeeper's own verdict. "source=Notarized Developer ID" means the ticket
# was found (stapled or online); plain "Developer ID" means it wasn't notarized.
if [ "$kind" = app ]; then
    verdict=$(spctl --assess --type execute --verbose=2 "$path" 2>&1 || true)
else
    verdict=$(spctl --assess --type open --context context:primary-signature --verbose=2 "$path" 2>&1 || true)
fi
printf '%s\n' "$verdict" | grep -q 'source=Notarized Developer ID' \
    || fail "Gatekeeper doesn't see $path as notarized: $verdict"
xcrun stapler validate "$path" > /dev/null 2>&1 || fail "no notarization ticket is stapled to $path"
printf 'check_notarized: %s is notarized and stapled\n' "$(basename "$path")"
