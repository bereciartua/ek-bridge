import Foundation

// Which AI agents are installed on this Mac, for the Add a Connection sheet
// and setup (B04). Foundation-only: the probe is injected, so tests use fakes.

/// How detection looks at the Mac. The live probe asks LaunchServices for an
/// app by bundle ID and checks paths; tests pass closures over fixed data.
struct AgentProbe {
    /// Bundle ID → the app's URL (live: `NSWorkspace.urlForApplication(withBundleIdentifier:)`).
    var appURL: (String) -> URL?
    /// Whether an absolute path exists.
    var fileExists: (String) -> Bool
    /// The user's home folder, without a trailing slash.
    var home: String
    /// Finds a command-line tool (live: `ExecutableLocator`); nil when it isn't installed.
    var executable: (String) -> String? = { _ in nil }
}

enum AgentDetection {
    /// What marks an agent as installed: an app bundle ID (checked on a Mac
    /// with the app installed, October 2026), and paths as a fallback. Paths
    /// starting with "~/" are under the user's home.
    struct Signals {
        var bundleIDs: [String] = []
        var paths: [String] = []
        var executable: String? = nil
    }

    static func signals(_ agent: AgentKind) -> Signals? {
        switch agent {
        case .claudeCode: Signals(paths: ["~/.claude"], executable: "claude")
        case .claudeDesktop: Signals(bundleIDs: ["com.anthropic.claudefordesktop"],
                                     paths: ["/Applications/Claude.app", "~/Applications/Claude.app"])
        case .codex: Signals(paths: ["~/.codex"], executable: "codex")
        case .cursor: Signals(bundleIDs: ["com.todesktop.230313mzl4w4u92"],
                              paths: ["/Applications/Cursor.app", "~/Applications/Cursor.app", "~/.cursor"])
        case .vsCode: Signals(bundleIDs: ["com.microsoft.VSCode"],
                              paths: ["/Applications/Visual Studio Code.app",
                                      "~/Applications/Visual Studio Code.app"])
        case .geminiCLI: Signals(paths: ["~/.gemini"], executable: "gemini")
        // Devin Desktop's bundle ID isn't confirmed, so only its config folder counts.
        case .devinDesktop: Signals(paths: ["~/.config/devin"])
        case .zed: Signals(bundleIDs: ["dev.zed.Zed"],
                           paths: ["/Applications/Zed.app", "~/Applications/Zed.app", "~/.config/zed"])
        // Extensions inside other editors: never marked installed.
        case .cline, .jetBrains, .other: nil
        }
    }

    static func installed(_ probe: AgentProbe) -> Set<AgentKind> {
        Set(AgentKind.allCases.filter { isInstalled($0, probe) })
    }

    static func isInstalled(_ agent: AgentKind, _ probe: AgentProbe) -> Bool {
        guard let signals = signals(agent) else { return false }
        if signals.bundleIDs.contains(where: { probe.appURL($0) != nil }) { return true }
        if signals.paths.contains(where: { probe.fileExists(expand($0, home: probe.home)) }) { return true }
        if let tool = signals.executable, probe.executable(tool) != nil { return true }
        return false
    }

    static func expand(_ path: String, home: String) -> String {
        path.hasPrefix("~/") ? home + path.dropFirst(1) : path
    }
}

/// Each connection's agent (B04), kept in UserDefaults `ConnectionAgentKinds`
/// as [connection ID: AgentKind raw value]. Not in the registry, which is a
/// security file that older builds must still load.
enum ConnectionAgentKinds {
    static let key = "ConnectionAgentKinds"

    static func load(_ defaults: UserDefaults) -> [String: AgentKind] {
        let stored = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        return stored.compactMapValues(AgentKind.init(rawValue:))
    }

    static func save(_ kinds: [String: AgentKind], _ defaults: UserDefaults) {
        defaults.set(kinds.mapValues(\.rawValue), forKey: key)
    }

    /// Drops entries for connections that are gone or removed.
    static func pruned(_ kinds: [String: AgentKind], activeIDs: Set<String>) -> [String: AgentKind] {
        kinds.filter { activeIDs.contains($0.key) }
    }
}
