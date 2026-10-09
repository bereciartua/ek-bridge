import Foundation

enum AppIdentity {
    /// The product name in one place, so a rename is a one-line change.
    /// Bundle IDs, data paths and protocol prefixes are separate decisions.
    #if EVENTKIT_UPDATE_TEST
    // The update test's copy (scripts/update_test.sh) has its own name and
    // data, so it never touches an installed EK Bridge.
    static let displayName = "EK Bridge Update Test"
    static let dataFolderName = "EKBridge Update Test"
    #else
    static let displayName = "EK Bridge"
    /// `~/Library/Application Support/EKBridge`.
    static let dataFolderName = "EKBridge"
    #endif
    /// The key agents store this MCP server under. It becomes part of agents'
    /// tool names (`mcp__ek-bridge__read_events`), so renaming it later
    /// breaks users' allowlists. Keep it stable.
    static let mcpServerKey = "ek-bridge"
    /// The stdio launcher inside the app bundle (`Contents/MacOS/bridge-mcp`).
    static let launcherName = "bridge-mcp"

    /// The app's data folder. The app always uses this one: on first launch it
    /// moves the folder of the app's old name here (`RenameMigration`).
    static func dataFolder(inSupport support: URL) -> URL {
        support.appendingPathComponent(dataFolderName, isDirectory: true)
    }

    /// For bridge-client and bridge-mcp: the data folder, or the old name's
    /// folder while only that one exists (the renamed app hasn't run yet).
    static func toolDataFolder(inSupport support: URL) -> URL {
        let current = dataFolder(inSupport: support)
        let legacy = support.appendingPathComponent(LegacyIdentity.dataFolderName, isDirectory: true)
        var info = stat()
        if lstat(current.path, &info) != 0, stat(legacy.path, &info) == 0,
           info.st_mode & S_IFMT == S_IFDIR {
            return legacy
        }
        return current
    }

    /// The folder in /tmp that the app and bridge-client exchange requests through.
    #if EVENTKIT_UPDATE_TEST
    static var bridgeRoot: String { "/tmp/ek-bridge-update-test-\(getuid())" }
    #else
    static var bridgeRoot: String { "/tmp/ek-bridge-\(getuid())" }
    #endif

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
    }
}

/// The app's identity up to 0.7.0, used only by the one-time migration and the
/// command-line tools' fallback. Nothing new should depend on it.
enum LegacyIdentity {
    static let displayName = "EventKit Bridge"
    static let bundleID = "dev.martin.dot.eventkitbridge"
    static let dataFolderName = "EventKitBridge"
}

/// Client names are unique among active clients, compared this way. Shared by
/// the registry, the app's copied commands and `client.py --client NAME`.
enum ClientNames {
    static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive], locale: nil)
    }
}
