# Sourced by build.sh: sets sparkle_dir to an unpacked copy of the pinned
# Sparkle release (Sparkle.framework, bin/sign_update, bin/generate_keys,
# LICENSE), downloading and checking it on first use.
#
# The archive comes from Sparkle's GitHub release and must match the SHA-256
# below. EVENTKIT_SPARKLE_ARCHIVE names a local copy of the same archive, for
# builds without network access. To update Sparkle, change both values, run
# the update test in docs/TESTING.md, and note it in CHANGELOG.md.
sparkle_version=2.10.0
sparkle_sha256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c

sparkle_dir="$project_dir/build/vendor/Sparkle"
if [ "$(cat "$sparkle_dir/.version" 2>/dev/null)" != "$sparkle_version" ]; then
    vendor_dir="$project_dir/build/vendor"
    archive="$vendor_dir/Sparkle-$sparkle_version.tar.xz"
    mkdir -p "$vendor_dir"
    if [ -n "${EVENTKIT_SPARKLE_ARCHIVE:-}" ]; then
        cp "$EVENTKIT_SPARKLE_ARCHIVE" "$archive.part"
    else
        printf 'Downloading Sparkle %s\n' "$sparkle_version" >&2
        curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
            --output "$archive.part" \
            "https://github.com/sparkle-project/Sparkle/releases/download/$sparkle_version/Sparkle-$sparkle_version.tar.xz"
    fi
    actual=$(shasum -a 256 "$archive.part" | cut -d' ' -f1)
    if [ "$actual" != "$sparkle_sha256" ]; then
        rm -f "$archive.part"
        printf '%s\n' "error: Sparkle $sparkle_version archive has SHA-256 $actual, expected $sparkle_sha256" >&2
        exit 1
    fi
    mv "$archive.part" "$archive"
    rm -rf "$sparkle_dir" "$sparkle_dir.part"
    mkdir -p "$sparkle_dir.part"
    tar -xJf "$archive" -C "$sparkle_dir.part"
    printf '%s\n' "$sparkle_version" > "$sparkle_dir.part/.version"
    mv "$sparkle_dir.part" "$sparkle_dir"
fi
