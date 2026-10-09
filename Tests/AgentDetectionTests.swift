import Foundation

// Agent detection (B04) with fake probes: bundle IDs, path fallbacks, the
// home folder, command-line tools, agents never marked installed, and the
// stored agent kind per connection.
@main
struct AgentDetectionTests {
    static func main() {
        let home = "/Users/tester"
        func probe(apps: [String: String] = [:], files: Set<String> = [], tools: Set<String> = []) -> AgentProbe {
            AgentProbe(appURL: { id in apps[id].map { URL(fileURLWithPath: $0) } },
                       fileExists: { files.contains($0) }, home: home,
                       executable: { tools.contains($0) ? "/opt/homebrew/bin/\($0)" : nil })
        }
        precondition(AgentDetection.installed(probe()).isEmpty, "nothing installed")
        // Apps by bundle ID, wherever LaunchServices finds them.
        let apps = probe(apps: ["com.anthropic.claudefordesktop": "/Volumes/Apps/Claude.app",
                                "com.todesktop.230313mzl4w4u92": "/Applications/Cursor.app",
                                "com.microsoft.VSCode": "/Applications/Visual Studio Code.app",
                                "dev.zed.Zed": "/Applications/Zed.app"])
        precondition(AgentDetection.installed(apps) == [.claudeDesktop, .cursor, .vsCode, .zed])
        // Path fallbacks, with ~ expanded to the home folder.
        let folders = probe(files: [home + "/.claude", home + "/.codex", home + "/.gemini",
                                    home + "/.config/devin", home + "/.cursor"])
        precondition(AgentDetection.installed(folders) == [.claudeCode, .codex, .geminiCLI, .devinDesktop, .cursor])
        precondition(AgentDetection.installed(probe(files: ["/Applications/Claude.app"])) == [.claudeDesktop])
        precondition(AgentDetection.installed(probe(files: [home + "/Applications/Zed.app"])) == [.zed])
        // A folder with the right name elsewhere doesn't count.
        precondition(AgentDetection.installed(probe(files: ["/Users/other/.claude", "/.codex"])).isEmpty)
        // Command-line tools on the PATH a login shell sees.
        precondition(AgentDetection.installed(probe(tools: ["claude", "codex", "gemini"]))
                     == [.claudeCode, .codex, .geminiCLI])
        // Extensions inside other apps and "Other agent" are never marked installed.
        let everything = probe(files: Set(["/Applications/Cline.app", home + "/.cline", home + "/.jetbrains"]),
                               tools: ["cline", "other"])
        for agent in [AgentKind.cline, .jetBrains, .other] {
            precondition(!AgentDetection.isInstalled(agent, everything), "\(agent) is never detected")
        }
        precondition(AgentDetection.expand("~/.claude", home: home) == home + "/.claude")
        precondition(AgentDetection.expand("/Applications/Zed.app", home: home) == "/Applications/Zed.app")

        // Stored agent kinds: round trip, unknown raw values dropped, pruning.
        let suite = "agent-detection-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(ConnectionAgentKinds.load(defaults).isEmpty)
        ConnectionAgentKinds.save(["a": .claudeDesktop, "b": .cursor], defaults)
        precondition(ConnectionAgentKinds.load(defaults) == ["a": .claudeDesktop, "b": .cursor])
        defaults.set(["a": "claudeDesktop", "c": "someFutureAgent"], forKey: ConnectionAgentKinds.key)
        precondition(ConnectionAgentKinds.load(defaults) == ["a": .claudeDesktop])
        precondition(ConnectionAgentKinds.pruned(["a": .codex, "gone": .zed], activeIDs: ["a"]) == ["a": .codex])
        print("Agent detection: bundle IDs, path fallbacks, home expansion, tools, never-detected agents and stored kinds passed")
    }
}
