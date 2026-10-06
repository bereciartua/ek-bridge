# Sourced by build.sh and test.sh: sets sdk_dir to the macOS SDK to compile with.
#
# EVENTKIT_SDK wins when set. Otherwise it's the SDK xcrun selects, except with
# Command Line Tools alone: from the macOS 27 SDK on, SwiftUI's @State is a macro
# whose compiler plugin only ships with Xcode, so use their macOS 26 SDK instead.
if [ -n "${EVENTKIT_SDK:-}" ]; then
    sdk_dir=$EVENTKIT_SDK
else
    sdk_dir=$(xcrun --sdk macosx --show-sdk-path)
    sdk_major=$(xcrun --sdk macosx --show-sdk-version | cut -d. -f1)
    case "$(xcode-select -p)" in
        */CommandLineTools)
            if [ "$sdk_major" -ge 27 ]; then
                if [ -d "$(dirname "$sdk_dir")/MacOSX26.sdk" ]; then
                    sdk_dir="$(dirname "$sdk_dir")/MacOSX26.sdk"
                else
                    printf '%s\n' "error: the macOS $sdk_major SDK needs Xcode for SwiftUI's macros." \
                        "Install Xcode, or set EVENTKIT_SDK to a macOS 26 SDK." >&2
                    exit 1
                fi
            fi
            ;;
    esac
fi
