# Sourced by build.sh and test.sh, after sdk.sh: builds BridgeKitCore, the MCP
# protocol and security core EK Bridge shares with Funes Vault
# (https://github.com/bereciartua/bridgekit), and BridgeKitRemote, its Remote
# Access tier, at the pinned version, as static libraries for the
# architectures in $bridgekit_archs. Sets bridgekit_lib_dir
# (libBridgeKitCore.a and libBridgeKitRemote.a, for swiftc's -L and
# -lBridgeKitRemote -lBridgeKitCore) and bridgekit_module_dir (their
# .swiftmodules, for -I).
#
# The checkout must be the tag below at the commit below. EVENTKIT_BRIDGEKIT_DIR
# names a local checkout instead, for work on BridgeKit itself. To update
# BridgeKit, change both values, run test.sh and the live check, and note it
# in CHANGELOG.md.
bridgekit_version=0.1.1
bridgekit_commit=d3360d3c894753de01ea999a62db5caa144b9030
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
for product in BridgeKitCore BridgeKitRemote; do
    SDKROOT="$sdk_dir" swift build --quiet --package-path "$bridgekit_source" \
        --scratch-path "$project_dir/build/bridgekit" -c release --product "$product" $bridgekit_arch_flags >&2
done
bridgekit_lib_dir=$(SDKROOT="$sdk_dir" swift build --package-path "$bridgekit_source" \
    --scratch-path "$project_dir/build/bridgekit" -c release $bridgekit_arch_flags --show-bin-path)
# SwiftPM's native build system (the default in Xcode 26) keeps modules in
# Modules/, where BridgeKitCore.swiftmodule is a file, not a folder.
bridgekit_module_dir=$bridgekit_lib_dir
if [ -e "$bridgekit_lib_dir/Modules/BridgeKitCore.swiftmodule" ]; then
    bridgekit_module_dir="$bridgekit_lib_dir/Modules"
fi
# Xcode 26's SwiftPM builds more than one architecture with XCBuild, which
# leaves each target's prelinked <target>_Module.o instead of the static
# library; archive them so -lBridgeKitRemote -lBridgeKitCore work the same
# everywhere.
if [ ! -e "$bridgekit_lib_dir/libBridgeKitCore.a" ] && [ -e "$bridgekit_lib_dir/BridgeKitCore_Module.o" ]; then
    mkdir -p "$project_dir/build/bridgekit/lib"
    for product in BridgeKitCore BridgeKitRemote; do
        rm -f "$project_dir/build/bridgekit/lib/lib$product.a"
        libtool -static -no_warning_for_no_symbols -o "$project_dir/build/bridgekit/lib/lib$product.a" \
            "$bridgekit_lib_dir/${product}_Module.o"
    done
    bridgekit_lib_dir="$project_dir/build/bridgekit/lib"
fi
