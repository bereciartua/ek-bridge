import Foundation

// One-click agent setup (B07): the JSON merge keeps every other key and the
// user's formatting (goldens in Tests/agent-config, UPDATE_GOLDENS=1 rewrites
// them), refuses what it can't read, never writes a token, and `apply`
// backs up, writes atomically and refuses a file that changed. Also
// ExecutableLocator with a fake file system.
@main
struct AgentConfigWriterTests {
    static var goldens = URL(fileURLWithPath: "Tests/agent-config")
    static let update = ProcessInfo.processInfo.environment["UPDATE_GOLDENS"] == "1"
    static var rewritten = 0

    static func main() throws {
        if CommandLine.arguments.count > 1 { goldens = URL(fileURLWithPath: CommandLine.arguments[1]) }
        let context = SetupContext(url: "http://127.0.0.1:47615/mcp",
                                   launcherPath: "/Applications/EKBridge.app/Contents/MacOS/bridge-mcp",
                                   clientID: "3f2a9c1e-7b4d-4e8a-9c21-5d6f0a1b2c3d",
                                   tokenPath: "/Users/tester/Library/Application Support/EKBridge/client-credentials/x.mcp-token")
        guard case .jsonMerge(let desktopFile, let root, let key, let desktop)? = AgentKind.claudeDesktop.oneClickSetup(context),
              case .jsonMerge(let cursorFile, _, _, let cursor)? = AgentKind.cursor.oneClickSetup(context),
              case .claudeCode(_, let arguments)? = AgentKind.claudeCode.oneClickSetup(context) else {
            preconditionFailure("one-click setups")
        }
        precondition(desktopFile == "~/Library/Application Support/Claude/claude_desktop_config.json" &&
                     cursorFile == "~/.cursor/mcp.json" && root == "mcpServers" && key == "ek-bridge")
        precondition(arguments.prefix(5) == ["mcp", "add-json", "--scope", "user", "ek-bridge"] && arguments.count == 6)
        precondition(AgentKind.vsCode.oneClickSetup(context) == nil && AgentKind.codex.oneClickSetup(context) == nil)
        // The one-click entries are the snippets' own entries.
        let desktopSnippet = AgentKind.claudeDesktop.snippet(.launcher, context).text
        precondition(desktopSnippet == SetupJSON.object([(root, .object([(key, desktop)]))]).text)
        let cursorSnippet = AgentKind.cursor.snippet(.launcher, context).text
        precondition(cursorSnippet == SetupJSON.object([(root, .object([(key, cursor)]))]).text)
        precondition(AgentKind.claudeCode.snippet(.directHTTP, context).text.contains(arguments[5].replacingOccurrences(of: "'", with: "'\\''")))

        func merged(_ name: String, _ input: String?, entry: SetupJSON = desktop,
                    expect outcome: ConfigChange.Outcome) throws {
            let result = try AgentConfigWriter.merge(current: input.map { Data($0.utf8) }, key: key, entry: entry)
            precondition(result.outcome == outcome, "\(name): \(result.outcome)")
            let text = String(decoding: result.after, as: UTF8.self)
            precondition(!text.contains("ekb_mcp_v1_"), "\(name) holds no token")
            golden(name, text)
        }
        try merged("missing-file", nil, expect: .created)
        try merged("empty-file", "", expect: .added)
        try merged("empty-object", "{}\n", expect: .added)
        try merged("pretty-sorted", """
            {
              "globalShortcut": "",
              "mcpServers": {
                "filesystem": {
                  "args": ["-y", "@modelcontextprotocol/server-filesystem", "/Users/tester/Desktop"],
                  "command": "npx"
                }
              }
            }

            """, expect: .added)
        try merged("compact", #"{"mcpServers":{"filesystem":{"command":"npx","args":["-y","x"]}},"theme":"dark"}"#,
                   expect: .added)
        try merged("unsorted-tabs", "{\n\t\"zeta\": 1,\n\t\"mcpServers\": {\n\t\t\"b\": {\"command\": \"b\"},\n\t\t\"a\": {\"command\": \"a\"}\n\t},\n\t\"alpha\": [1, 2]\n}\n",
                   entry: cursor, expect: .added)
        try merged("no-servers-key", "{\n    \"preferences\": {\"quickEntry\": true}\n}\n", expect: .added)
        try merged("empty-servers", "{\n  \"mcpServers\": {}\n}\n", entry: cursor, expect: .added)
        try merged("unicode-and-slashes",
                   "{\n  \"note\": \"caf\\u00e9 · ünïcode · https:\\/\\/example.com/path\",\n  \"mcpServers\": {\n    \"x\": {\"url\": \"https:\\/\\/a.example\"}\n  }\n}\n",
                   expect: .added)
        try merged("replace-different", """
            {
              "mcpServers": {
                "ek-bridge": {
                  "command": "/Users/tester/Downloads/EKBridge.app/Contents/MacOS/bridge-mcp",
                  "args": ["--client", "old"]
                },
                "other": {"command": "x"}
              }
            }

            """, expect: .replaced)
        // Identical entry: nothing to write, the bytes stay as they are.
        let identical = "{\n  \"mcpServers\": {\"ek-bridge\": \(desktop.text)}\n}\n"
        let same = try AgentConfigWriter.merge(current: Data(identical.utf8), key: key, entry: desktop)
        precondition(same.outcome == .unchanged && same.after == Data(identical.utf8))

        // Refusals.
        func refuses(_ input: String, _ expected: (ConfigWriteError) -> Bool, _ name: String) {
            do {
                _ = try AgentConfigWriter.merge(current: Data(input.utf8), key: key, entry: desktop)
                preconditionFailure("\(name) should be refused")
            } catch let error as ConfigWriteError {
                precondition(expected(error), "\(name): \(error)")
                precondition(!error.message.isEmpty)
            } catch {
                preconditionFailure("\(name): \(error)")
            }
        }
        refuses("{\"mcpServers\": {,}", { if case .invalidJSON = $0 { true } else { false } }, "invalid JSON")
        refuses("// comment\n{}", { if case .invalidJSON = $0 { true } else { false } }, "comments")
        refuses("[1, 2]", { $0 == .notAnObject }, "top-level array")
        refuses("\"text\"", { if case .invalidJSON = $0 { true } else { $0 == .notAnObject } }, "fragment")
        refuses("{\"mcpServers\": [1]}", { $0 == .rootNotAnObject("mcpServers") }, "servers not an object")
        refuses("{\"a\": \"" + String(repeating: "x", count: 1_000_001) + "\"}", { $0 == .tooLarge }, "over 1 MB")

        // Diff lines: the added entry, with context.
        let before = Data("{\n  \"a\": 1\n}\n".utf8)
        let after = try AgentConfigWriter.merge(current: before, key: key, entry: desktop).after
        let lines = AgentConfigWriter.diff(before, after)
        precondition(lines.contains { $0.kind == .added && $0.text.contains("\"ek-bridge\"") })
        precondition(lines.contains { $0.kind == .removed && $0.text == "  \"a\": 1" })
        precondition(lines.first?.kind == .context && !lines.contains { $0.text.contains("ekb_mcp_v1_") })

        try applyChecks(key: key, entry: desktop)
        locatorChecks()
        print("Agent config writer: \(rewritten > 0 ? "\(rewritten) goldens rewritten, " : "")merges keep every key and the file's formatting, refusals, no tokens, diff, backups, atomic writes, changed-file refusal, symlinks and the executable locator passed")
    }

    static func golden(_ name: String, _ text: String) {
        let url = goldens.appendingPathComponent("\(name).json")
        if update {
            if (try? String(contentsOf: url, encoding: .utf8)) != text {
                try! FileManager.default.createDirectory(at: goldens, withIntermediateDirectories: true)
                try! text.write(to: url, atomically: true, encoding: .utf8)
                rewritten += 1
            }
            return
        }
        guard let expected = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("missing golden \(name).json; run with UPDATE_GOLDENS=1")
        }
        precondition(expected == text, "\(name).json differs; run with UPDATE_GOLDENS=1 if intended")
    }

    static func applyChecks(key: String, entry: SetupJSON) throws {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory.appendingPathComponent("agent-config-tests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: folder) }

        // A new file in a new folder: the folder is private, no backup.
        let fresh = folder.appendingPathComponent("Claude/claude_desktop_config.json")
        let created = try AgentConfigWriter.preview(fileURL: fresh, key: key, entry: entry)
        precondition(created.outcome == .created && created.before == nil)
        let createdBackup = try AgentConfigWriter.apply(created, backupSuffix: "20261008-120000")
        precondition(createdBackup == nil)
        precondition(fileManager.contents(atPath: fresh.path) == created.after)
        let folderMode = try fileManager.attributesOfItem(atPath: fresh.deletingLastPathComponent().path)[.posixPermissions] as? Int
        precondition(folderMode == 0o700)

        // An existing file keeps its permissions and gets a private backup.
        let existing = folder.appendingPathComponent("mcp.json")
        let original = Data("{\n  \"mcpServers\": {\"x\": {\"command\": \"x\"}}\n}\n".utf8)
        fileManager.createFile(atPath: existing.path, contents: original, attributes: [.posixPermissions: 0o644])
        let change = try AgentConfigWriter.preview(fileURL: existing, key: key, entry: entry)
        guard let backup = try AgentConfigWriter.apply(change, backupSuffix: "20261008-120000") else {
            preconditionFailure("backup expected")
        }
        precondition(backup.lastPathComponent == "mcp.json.ekbridge-backup-20261008-120000")
        precondition(fileManager.contents(atPath: backup.path) == original)
        let backupMode = try fileManager.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int
        precondition(backupMode == 0o600)
        precondition(fileManager.contents(atPath: existing.path) == change.after)
        let fileMode = try fileManager.attributesOfItem(atPath: existing.path)[.posixPermissions] as? Int
        precondition(fileMode == 0o644)
        let leftovers = try fileManager.contentsOfDirectory(atPath: folder.path).filter { $0.contains(".ekbridge-") && !$0.contains("backup") }
        precondition(leftovers.isEmpty, "no temporary files left: \(leftovers)")
        // Applying again is "already set up": nothing written.
        let again = try AgentConfigWriter.preview(fileURL: existing, key: key, entry: entry)
        let againBackup = try AgentConfigWriter.apply(again, backupSuffix: "x")
        precondition(again.outcome == .unchanged && againBackup == nil)

        // The file changed between preview and Add: nothing is written.
        let racing = folder.appendingPathComponent("racing.json")
        fileManager.createFile(atPath: racing.path, contents: Data("{}".utf8))
        let stale = try AgentConfigWriter.preview(fileURL: racing, key: key, entry: entry)
        fileManager.createFile(atPath: racing.path, contents: Data("{\"edited\": true}".utf8))
        do {
            try AgentConfigWriter.apply(stale, backupSuffix: "x")
            preconditionFailure("a changed file must be refused")
        } catch let error as ConfigWriteError {
            precondition(error == .changedSinceReading)
        }
        precondition(fileManager.contents(atPath: racing.path) == Data("{\"edited\": true}".utf8))
        precondition(!fileManager.fileExists(atPath: racing.path + ".ekbridge-backup-x"))

        // A symbolic link (dotfiles) is followed: the link stays, its target changes.
        let target = folder.appendingPathComponent("dotfiles-mcp.json")
        fileManager.createFile(atPath: target.path, contents: Data("{}\n".utf8))
        let link = folder.appendingPathComponent("linked.json")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
        let linked = try AgentConfigWriter.preview(fileURL: link, key: key, entry: entry)
        try AgentConfigWriter.apply(linked, backupSuffix: "y")
        precondition((try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil, "the link stays a link")
        precondition(fileManager.contents(atPath: target.path) == linked.after)
        precondition(AgentConfigWriter.backupSuffix(Date(timeIntervalSince1970: 1_791_475_330),
                                                    timeZone: TimeZone(identifier: "UTC")!) == "20261008-160210")
    }

    static func locatorChecks() {
        let home = "/Users/tester"
        var files: Set<String> = []
        var shell: String? = nil
        let locator = ExecutableLocator(isExecutable: { files.contains($0) }, loginShellLookup: { _ in shell })
        precondition(locator.locate("claude", home: home) == nil)
        files = ["/opt/homebrew/bin/claude", home + "/.claude/local/claude"]
        precondition(locator.locate("claude", home: home) == home + "/.claude/local/claude", "the native install first")
        files = ["/opt/homebrew/bin/claude"]
        precondition(locator.locate("claude", home: home) == "/opt/homebrew/bin/claude")
        files = ["/Users/tester/.nvm/versions/node/v22/bin/claude"]
        shell = "/Users/tester/.nvm/versions/node/v22/bin/claude\n"
        precondition(locator.locate("claude", home: home) == "/Users/tester/.nvm/versions/node/v22/bin/claude")
        shell = "claude: aliased to something"
        precondition(locator.locate("claude", home: home) == nil, "only absolute paths")
        shell = "/missing/claude"
        precondition(locator.locate("claude", home: home) == nil, "only files that exist and run")
        precondition(!ExecutableLocator.candidates("codex", home: home).contains(home + "/.claude/local/codex"))
        // The real runner: an argument array, output and exit code, and the timeout.
        let echo = ProcessRunner.run("/bin/echo", ["a b", "c"], timeout: 5)
        precondition(echo?.exitCode == 0 && echo?.output == "a b c\n")
        let slow = ProcessRunner.run("/bin/sleep", ["5"], timeout: 0.3)
        precondition(slow?.timedOut == true)
    }
}
