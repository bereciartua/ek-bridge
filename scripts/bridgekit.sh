# Sourced by build.sh and test.sh, after sdk.sh: builds BridgeKitCore, the MCP
# protocol and security core EK Bridge shares with Funes Vault
# (https://github.com/bereciartua/bridgekit), at the pinned version, as a
# static library for the architectures in $bridgekit_archs. Sets
# bridgekit_lib_dir (libBridgeKitCore.a, for swiftc's -L and -lBridgeKitCore)
# and bridgekit_module_dir (BridgeKitCore.swiftmodule, for -I).
#
# The checkout must be the tag below at the commit below. EVENTKIT_BRIDGEKIT_DIR
# names a local checkout instead, for work on BridgeKit itself. To update
# BridgeKit, change both values, run test.sh and the live check, and note it
# in CHANGELOG.md.
bridgekit_version=0.1.0
bridgekit_commit=6fcf18e7f5d10fe974154a9385183044351bf564
bridgekit_repository=https://github.com/bereciartua/bridgekit.git

if [ -n "${EVENTKIT_BRIDGEKIT_DIR:-}" ]; then
    bridgekit_source=$EVENTKIT_BRIDGEKIT_DIR
else
    bridgekit_source="$project_dir/build/vendor/bridgekit"
    if [ "$(git -C "$bridgekit_source" rev-parse HEAD 2>/dev/null)" != "$bridgekit_commit" ]; then
        rm -rf "$bridgekit_source"
        mkdir -p "$project_dir/build/vendor"
        printf 'Fetching BridgeKit %s\n' "$bridgekit_version" >&2
        git clone --quiet --depth 1 --branch "$bridgekit_version" -c advice.detachedHead=false \
            "$bridgekit_repository" "$bridgekit_source"
        actual=$(git -C "$bridgekit_source" rev-parse HEAD)
        if [ "$actual" != "$bridgekit_commit" ]; then
            rm -rf "$bridgekit_source"
            printf '%s\n' "error: BridgeKit $bridgekit_version is at $actual, expected $bridgekit_commit" >&2
            exit 1
        fi
    fi
fi

bridgekit_arch_flags=""
for arch in ${bridgekit_archs:-$(uname -m)}; do bridgekit_arch_flags="$bridgekit_arch_flags --arch $arch"; done
# The same SDK as the app, so the module and the app agree on the system modules.
SDKROOT="$sdk_dir" swift build --quiet --package-path "$bridgekit_source" \
    --scratch-path "$project_dir/build/bridgekit" -c release --product BridgeKitCore $bridgekit_arch_flags >&2
bridgekit_lib_dir=$(SDKROOT="$sdk_dir" swift build --package-path "$bridgekit_source" \
    --scratch-path "$project_dir/build/bridgekit" -c release $bridgekit_arch_flags --show-bin-path)
# Xcode 26's SwiftPM (the native build system) keeps modules in Modules/.
bridgekit_module_dir=$bridgekit_lib_dir
if [ -d "$bridgekit_lib_dir/Modules/BridgeKitCore.swiftmodule" ]; then
    bridgekit_module_dir="$bridgekit_lib_dir/Modules"
fi
