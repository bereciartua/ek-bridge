import Foundation

enum AppIdentity {
    /// The product name in one place, so a rename is a one-line change.
    /// Bundle IDs, data paths and protocol prefixes are separate decisions.
    #if EVENTKIT_UPDATE_TEST
    // The update test's copy (scripts/update_test.sh) has its own name and
    // data, so it never touches an installed EK Bridge.
    static let displayName = "EK Bridge Update Test"
    static let dataFolderName = "EKBridge Update Test"
    static let mcpServerKey = ProductionIdentity.mcpServerKey
    static let bundleID = "io.github.bereciartua.ekbridge.updatetest"
    static let bundleFileName = ProductionIdentity.bundleFileName
    #elseif EVENTKIT_LIVE_TEST
    // The live-test copy (scripts/live_test.sh, docs/TESTING.md): its own
    // name, bundle ID, data, transport folder, ports and server key, so it
    // runs next to the owner's EK Bridge without touching it.
    static let displayName = "EK Bridge Test"
    static let dataFolderName = "EKBridge Live Test"
    static let mcpServerKey = "ek-bridge-test"
    static let bundleID = "io.github.bereciartua.ekbridge.livetest"
    static let bundleFileName = "EK Bridge Test.app"
    #else
    static let displayName = "EK Bridge"
    /// `~/Library/Application Support/EKBridge`.
    static let dataFolderName = ProductionIdentity.dataFolderName
    /// The key agents store this MCP server under. It becomes part of agents'
    /// tool names (`mcp__ek-bridge__read_events`), so renaming it later
    /// breaks users' allowlists. Keep it stable.
    static let mcpServerKey = ProductionIdentity.mcpServerKey
    static let bundleID = ProductionIdentity.bundleID
    /// The app bundle's folder name in Applications.
    static let bundleFileName = ProductionIdentity.bundleFileName
    #endif
    /// The stdio launcher inside the app bundle (`Contents/MacOS/bridge-mcp`).
    static let launcherName = "bridge-mcp"
    /// True only in the live-test copy, for the few places its UI differs.
    #if EVENTKIT_LIVE_TEST
    static let isLiveTest = true
    #else
    static let isLiveTest = false
    #endif

    /// The app's data folder. The app always uses this one: on first launch it
    /// moves the folder of the app's old name here (`RenameMigration`).
    static func dataFolder(inSupport support: URL) -> URL {
        support.appendingPathComponent(dataFolderName, isDirectory: true)
    }

    /// For bridge-client and bridge-mcp: the data folder, or the old name's
    /// folder while only that one exists (the renamed app hasn't run yet).
    static func toolDataFolder(inSupport support: URL) -> URL {
        let current = dataFolder(inSupport: support)
        #if EVENTKIT_LIVE_TEST || EVENTKIT_UPDATE_TEST
        // Test copies never fall back: the old name's folder is the installed
        // app's data (a link to it after the rename).
        return current
        #else
        let legacy = support.appendingPathComponent(LegacyIdentity.dataFolderName, isDirectory: true)
        var info = stat()
        if lstat(current.path, &info) != 0, stat(legacy.path, &info) == 0,
           info.st_mode & S_IFMT == S_IFDIR {
            return legacy
        }
        return current
        #endif
    }

    /// The folder in /tmp that the app and bridge-client exchange requests through.
    #if EVENTKIT_UPDATE_TEST
    static var bridgeRoot: String { "/tmp/ek-bridge-update-test-\(getuid())" }
    #elseif EVENTKIT_LIVE_TEST
    static var bridgeRoot: String { "/tmp/ek-bridge-live-test-\(getuid())" }
    #else
    static var bridgeRoot: String { ProductionIdentity.bridgeRoot }
    #endif

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
    }
}

/// Help menu and Settings ▸ About links, in their menu order. The
/// separators fall after `releaseNotes` and `reportIssue`.
enum AppLinks {
    struct Item: Equatable {
        let title: String
        let url: URL
    }

    private static let repository = "https://github.com/bereciartua/ek-bridge"

    static let help = Item(title: String(localized: "\(AppIdentity.displayName) Help"),
                           url: URL(string: repository + "/blob/main/docs/USAGE.md")!)
    static let setUpAgent = Item(title: String(localized: "Set Up an AI Agent"),
                                 url: URL(string: repository + "/blob/main/docs/MCP.md")!)
    static let releaseNotes = Item(title: String(localized: "Release Notes"),
                                   url: URL(string: repository + "/releases")!)
    static let askQuestion = Item(title: String(localized: "Ask a Question…"),
                                  url: URL(string: repository + "/discussions")!)
    static let reportIssue = Item(title: String(localized: "Report an Issue…"),
                                  url: URL(string: repository + "/issues/new/choose")!)

    static let documentation = [help, setUpAgent, releaseNotes]
    static let community = [askQuestion, reportIssue]
}

/// The installed app's values. Every test copy must differ from each of them
/// (`LiveTestIsolation`, Tests/LiveTestIsolationTests.swift).
enum ProductionIdentity {
    static let bundleID = "io.github.bereciartua.ekbridge"
    static let dataFolderName = "EKBridge"
    static let mcpServerKey = "ek-bridge"
    static let bundleFileName = "EKBridge.app"
    static let mcpPort = 47615
    static let remotePort = 47616
    static var bridgeRoot: String { "/tmp/ek-bridge-\(getuid())" }
}

enum MCPDefaults {
    #if EVENTKIT_LIVE_TEST
    static let port = 47625
    #else
    static let port = ProductionIdentity.mcpPort
    #endif
    static let validPorts = 1024...65535
}

enum RemoteDefaults {
    #if EVENTKIT_LIVE_TEST
    static let port = 47626
    #else
    static let port = ProductionIdentity.remotePort
    #endif
    /// Turn off automatically: never, 1 hour, 8 hours, 1 day.
    static let autoOffChoices: [TimeInterval] = [0, 3_600, 28_800, 86_400]
}

/// The live-test copy's safety checks: it refuses to start when any of its
/// identities equals the installed app's, and it never copies, moves, trashes
/// or deletes the installed app's bundle.
enum LiveTestIsolation {
    struct Values: Equatable {
        var bundleID: String
        var dataFolderName: String
        var bridgeRoot: String
        var mcpServerKey: String
        var bundleFileName: String
        var mcpPort: Int
        var remotePort: Int

        static var current: Values {
            Values(bundleID: AppIdentity.bundleID, dataFolderName: AppIdentity.dataFolderName,
                   bridgeRoot: AppIdentity.bridgeRoot, mcpServerKey: AppIdentity.mcpServerKey,
                   bundleFileName: AppIdentity.bundleFileName, mcpPort: MCPDefaults.port,
                   remotePort: RemoteDefaults.port)
        }

        static var production: Values {
            Values(bundleID: ProductionIdentity.bundleID, dataFolderName: ProductionIdentity.dataFolderName,
                   bridgeRoot: ProductionIdentity.bridgeRoot, mcpServerKey: ProductionIdentity.mcpServerKey,
                   bundleFileName: ProductionIdentity.bundleFileName, mcpPort: ProductionIdentity.mcpPort,
                   remotePort: ProductionIdentity.remotePort)
        }

        var lines: [String] {
            ["bundleID=\(bundleID)", "dataFolderName=\(dataFolderName)", "bridgeRoot=\(bridgeRoot)",
             "mcpServerKey=\(mcpServerKey)", "bundleFileName=\(bundleFileName)", "mcpPort=\(mcpPort)",
             "remotePort=\(remotePort)"]
        }
    }

    /// The names of the values that equal production's. `runningBundleID`
    /// is what Info.plist says, which build.sh sets separately.
    static func collisions(_ values: Values, runningBundleID: String?,
                           production: Values = .production) -> [String] {
        var result = [String]()
        if values.bundleID == production.bundleID || runningBundleID == production.bundleID {
            result.append("bundle ID")
        }
        if values.dataFolderName == production.dataFolderName { result.append("data folder") }
        if values.bridgeRoot == production.bridgeRoot { result.append("bridge folder") }
        if values.mcpServerKey == production.mcpServerKey { result.append("MCP server key") }
        if values.bundleFileName == production.bundleFileName { result.append("bundle name") }
        if values.mcpPort == production.mcpPort || values.mcpPort == production.remotePort {
            result.append("MCP port")
        }
        if values.remotePort == production.remotePort || values.remotePort == production.mcpPort {
            result.append("remote port")
        }
        return result
    }

    /// Whether code may copy, move, trash or delete the app bundle at `path`.
    /// The live-test copy never touches a bundle named like the installed app.
    static func mayModifyBundle(atPath path: String, liveTest: Bool = AppIdentity.isLiveTest) -> Bool {
        guard liveTest else { return true }
        let paths = [(path as NSString).standardizingPath, (path as NSString).resolvingSymlinksInPath]
        return !paths.contains { path in
            let name = path.split(separator: "/").last.map(String.init) ?? ""
            return [ProductionIdentity.bundleFileName, LegacyIdentity.bundleFileName].contains {
                name.caseInsensitiveCompare($0) == .orderedSame
            }
        }
    }
}

/// The app's identity up to 0.7.0, used only by the one-time migration and the
/// command-line tools' fallback. Nothing new should depend on it.
enum LegacyIdentity {
    static let displayName = "EventKit Bridge"
    static let bundleID = "dev.martin.dot.eventkitbridge"
    static let dataFolderName = "EventKitBridge"
    static let bundleFileName = "EventKitBridge.app"
}

/// Client names are unique among active clients, compared this way. Shared by
/// the registry, the app's copied commands and `client.py --client NAME`.
enum ClientNames {
    static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive], locale: nil)
    }
}
