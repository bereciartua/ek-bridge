import Foundation

enum AppIdentity {
    /// The product name in one place, so a rename is a one-line change.
    /// Bundle IDs, data paths and protocol prefixes are separate decisions.
    static let displayName = "EventKit Bridge"
    static let dataFolderName = "EventKitBridge"
    /// The key agents store this MCP server under. It becomes part of agents'
    /// tool names (`mcp__eventkit-bridge__read_events`), so renaming it later
    /// breaks users' allowlists. Keep it stable.
    static let mcpServerKey = "eventkit-bridge"
    /// The stdio launcher inside the app bundle (`Contents/MacOS/bridge-mcp`).
    static let launcherName = "bridge-mcp"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
    }
}

/// Client names are unique among active clients, compared this way. Shared by
/// the registry, the app's copied commands and `client.py --client NAME`.
enum ClientNames {
    static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive], locale: nil)
    }
}
