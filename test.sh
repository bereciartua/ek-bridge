#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cache_dir="$project_dir/build/module-cache"
mkdir -p "$project_dir/build" "$cache_dir"
xcrun swiftc -parse-as-library \
    -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
    -module-cache-path "$cache_dir" \
    "$project_dir/Sources/BridgeProtocol.swift" \
    "$project_dir/Sources/CommandPolicy.swift" \
    "$project_dir/Sources/MutationPolicy.swift" \
    "$project_dir/Sources/WriteJournal.swift" \
    "$project_dir/Tests/BridgeProtocolTests.swift" \
    -o "$project_dir/build/bridge-protocol-tests"
"$project_dir/build/bridge-protocol-tests"
PYTHONPYCACHEPREFIX="$project_dir/build/pycache" python3 -m py_compile "$project_dir/client.py"
PYTHONPYCACHEPREFIX="$project_dir/build/pycache" python3 "$project_dir/Tests/test_client.py"
