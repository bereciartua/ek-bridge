#!/bin/sh
set -eu

# Regenerates docs/images/social-preview.png from make_social_preview.swift,
# the app icon and the Overview screenshot. Upload the result in the
# repository's Settings ▸ General ▸ Social preview.
resources=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(dirname "$resources")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
xcrun swiftc -sdk "$(xcrun --show-sdk-path)" "$resources/make_social_preview.swift" -o "$work/make_social_preview"
"$work/make_social_preview" "$resources/AppIcon-1024.png" "$project_dir/docs/images/overview-light.png" \
    "$project_dir/docs/images/social-preview.png"
printf '%s\n' "$project_dir/docs/images/social-preview.png"
