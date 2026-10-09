import AppKit

// One-click agent setup (B07, D3): the live preview, apply and restart behind
// Add to <Agent>…. The model reaches them through `AgentSetupControls`, so the
// UI-review build fakes them. Nothing runs without a click, every change is
// shown first, files are backed up, and no token is written anywhere.

/// What the preview sheet shows before Add.
enum OneClickPreview: Equatable {
    case file(agent: AgentKind, change: ConfigChange)
    /// The agent's own command (`claude`, `codex`) with these arguments;
    /// `replacing` when it already has the server.
    case command(agent: AgentKind, executable: String, arguments: [String], key: String, replacing: Bool)

    var agent: AgentKind {
        switch self {
        case .file(let agent, _), .command(let agent, _, _, _, _): agent
        }
    }
}

struct OneClickResult: Equatable {
    let agent: AgentKind
    /// The backup of the changed file (file agents).
    var backup: URL?
    /// The command's output, last 20 lines (Claude Code).
    var output: String?
    var alreadySetUp = false
}

struct OneClickFailure: Error, Equatable {
    let message: String
    var output: String? = nil
    /// Offer Copy the Setup Instead (invalid file, tool not found).
    var copyInstead = true
}

@MainActor
struct AgentSetupControls {
    var preview: (AgentKind, SetupContext, @escaping (Result<OneClickPreview, OneClickFailure>) -> Void) -> Void
    var apply: (OneClickPreview, @escaping (Result<OneClickResult, OneClickFailure>) -> Void) -> Void
    /// Quits the agent's app and opens it again; false when it didn't quit in 5 s.
    var restart: (AgentKind, @escaping (Bool) -> Void) -> Void

    static func refusing(_ message: String) -> AgentSetupControls {
        AgentSetupControls(
            preview: { _, _, done in done(.failure(OneClickFailure(message: message, copyInstead: false))) },
            apply: { _, done in done(.failure(OneClickFailure(message: message, copyInstead: false))) },
            restart: { _, done in done(false) })
    }

    static let unavailable = AgentSetupControls(
        preview: { _, _, done in done(.failure(OneClickFailure(message: ""))) },
        apply: { _, done in done(.failure(OneClickFailure(message: ""))) },
        restart: { _, done in done(false) })
}

enum OneClickAgents {
    /// The app an agent runs in, for Restart.
    static func bundleID(_ agent: AgentKind) -> String? {
        AgentDetection.signals(agent)?.bundleIDs.first
    }

    /// The live controls. `home` is the user's home (a scratch HOME in tests).
    static func live(home: String = NSHomeDirectory(), locator: ExecutableLocator = .live) -> AgentSetupControls {
        AgentSetupControls(
            preview: { agent, context, done in
                guard let setup = agent.oneClickSetup(context) else {
                    return done(.failure(OneClickFailure(message: String(localized: "There's no one-click setup for \(agent.displayName)."))))
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = preview(agent, setup, home: home, locator: locator)
                    DispatchQueue.main.async { done(result) }
                }
            },
            apply: { preview, done in
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = apply(preview)
                    DispatchQueue.main.async { done(result) }
                }
            },
            restart: { agent, done in
                guard let bundleID = bundleID(agent),
                      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                    return done(false)
                }
                let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                running.forEach { $0.terminate() }
                func reopen(_ waited: Double) {
                    if running.allSatisfy(\.isTerminated) {
                        let configuration = NSWorkspace.OpenConfiguration()
                        configuration.activates = true
                        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                            DispatchQueue.main.async { done(error == nil) }
                        }
                    } else if waited >= 5 {
                        done(false)
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { reopen(waited + 0.25) }
                    }
                }
                reopen(0)
            })
    }

    nonisolated static func expand(_ path: String, home: String) -> URL {
        URL(fileURLWithPath: path.hasPrefix("~/") ? home + path.dropFirst(1) : path)
    }

    nonisolated static func preview(_ agent: AgentKind, _ setup: OneClickSetup, home: String,
                                    locator: ExecutableLocator) -> Result<OneClickPreview, OneClickFailure> {
        switch setup {
        case .jsonMerge(let file, let root, let key, let entry):
            do {
                let change = try AgentConfigWriter.preview(fileURL: expand(file, home: home), root: root,
                                                           key: key, entry: entry)
                return .success(.file(agent: agent, change: change))
            } catch let error as ConfigWriteError {
                return .failure(OneClickFailure(message: error.message))
            } catch {
                return .failure(OneClickFailure(message: error.localizedDescription))
            }
        case .claudeCode(let key, let arguments):
            guard let claude = locator.locate("claude", home: home) else {
                return .failure(OneClickFailure(message: String(localized: "Claude Code's claude command wasn't found on this Mac.")))
            }
            let existing = ProcessRunner.run(claude, ["mcp", "get", key], timeout: 20, environment: environment(claude))
            return .success(.command(agent: agent, executable: claude, arguments: arguments, key: key,
                                     replacing: existing?.exitCode == 0))
        case .codex(let key, let arguments, let file, let table):
            // Codex's own command when it's installed; its config file otherwise.
            if let codex = locator.locate("codex", home: home) {
                let existing = ProcessRunner.run(codex, ["mcp", "get", key], timeout: 20, environment: environment(codex))
                return .success(.command(agent: agent, executable: codex, arguments: arguments, key: key,
                                         replacing: existing?.exitCode == 0))
            }
            do {
                let change = try AgentConfigWriter.previewTOML(fileURL: codexConfig(file, home: home), key: key,
                                                               table: table)
                return .success(.file(agent: agent, change: change))
            } catch let error as ConfigWriteError {
                return .failure(OneClickFailure(message: error.message))
            } catch {
                return .failure(OneClickFailure(message: error.localizedDescription))
            }
        }
    }

    /// Codex keeps its config in CODEX_HOME when that's set.
    nonisolated static func codexConfig(_ file: String, home: String) -> URL {
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"], codexHome.hasPrefix("/") {
            return URL(fileURLWithPath: codexHome).appendingPathComponent("config.toml")
        }
        return expand(file, home: home)
    }

    /// How each agent's command removes a server before it's added again.
    nonisolated static func removeArguments(_ agent: AgentKind, key: String) -> [String] {
        agent == .codex ? ["mcp", "remove", key] : ["mcp", "remove", "--scope", "user", key]
    }

    nonisolated static func apply(_ preview: OneClickPreview) -> Result<OneClickResult, OneClickFailure> {
        switch preview {
        case .file(let agent, let change):
            if change.outcome == .unchanged { return .success(OneClickResult(agent: agent, alreadySetUp: true)) }
            do {
                let backup = try AgentConfigWriter.apply(change, backupSuffix: AgentConfigWriter.backupSuffix())
                return .success(OneClickResult(agent: agent, backup: backup))
            } catch let error as ConfigWriteError {
                return .failure(OneClickFailure(message: error.message, copyInstead: error != .changedSinceReading))
            } catch {
                return .failure(OneClickFailure(message: error.localizedDescription))
            }
        case .command(let agent, let tool, let arguments, let key, let replacing):
            var log = ""
            let name = agent.displayName
            if replacing {
                let removed = ProcessRunner.run(tool, removeArguments(agent, key: key), timeout: 20,
                                                environment: environment(tool))
                log += removed?.output ?? ""
            }
            guard let added = ProcessRunner.run(tool, arguments, timeout: 20, environment: environment(tool)) else {
                return .failure(OneClickFailure(message: String(localized: "\(name) couldn't be started.")))
            }
            log += added.output
            let tail = lastLines(log, 20)
            if added.timedOut {
                return .failure(OneClickFailure(message: String(localized: "\(name) didn't finish within 20 seconds."),
                                                output: tail))
            }
            guard added.exitCode == 0 else {
                return .failure(OneClickFailure(message: String(localized: "\(name) reported an error (exit code \(added.exitCode))."),
                                                output: tail))
            }
            return .success(OneClickResult(agent: agent, output: tail))
        }
    }

    /// A GUI app's PATH is minimal; `claude` may be a Node script, so its own
    /// folder and the usual tool folders come first.
    nonisolated static func environment(_ executable: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let folder = (executable as NSString).deletingLastPathComponent
        let path = [folder, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        environment["PATH"] = (path + [environment["PATH"] ?? ""]).filter { !$0.isEmpty }.joined(separator: ":")
        return environment
    }

    nonisolated static func lastLines(_ text: String, _ count: Int) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).suffix(count)
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
