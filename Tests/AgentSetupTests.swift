import Foundation

@main
struct AgentSetupTests {
    static let clientID = "3f1c2b7e-8a41-4d0c-9a8e-5b6f1d2e9a1c"
    static let url = "http://127.0.0.1:47615/mcp"
    static let tokenPath =
        "/Users/you/Library/Application Support/EventKitBridge/client-credentials/\(clientID).mcp-token"
    static let placeholders = SetupContext(
        url: url, launcherPath: "/Applications/EventKit Bridge.app/Contents/MacOS/bridge-mcp",
        clientID: clientID, tokenPath: tokenPath)
    static let apostrophe = SetupContext(
        url: url, launcherPath: "/Users/o'brien/Apps/EventKit Bridge.app/Contents/MacOS/bridge-mcp",
        clientID: clientID, tokenPath: tokenPath)

    static func main() throws {
        let count = try goldens(URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
        catalog()
        noSecrets()
        identity()
        syntax()
        installLinks()
        try shellRoundTrip()
        print("Agent setup: \(count) goldens, catalog, no secrets, identity, JSON/TOML syntax, "
              + "install links, shell round trip passed")
    }

    static func all(_ context: SetupContext) -> [(AgentKind, SetupMethod, SetupSnippet)] {
        AgentKind.allCases.flatMap { agent in
            agent.methods.map { (agent, $0, agent.snippet($0, context)) }
        }
    }

    static func slug(_ agent: AgentKind) -> String {
        switch agent {
        case .jetBrains: return "jetbrains"
        case .geminiCLI: return "gemini-cli"
        case .vsCode: return "vs-code"
        default:
            return agent.rawValue.replacingOccurrences(
                of: "([a-z])([A-Z])", with: "$1-$2", options: .regularExpression).lowercased()
        }
    }

    static func slug(_ method: SetupMethod) -> String { method == .launcher ? "launcher" : "direct-http" }

    // Every agent × method, byte for byte. UPDATE_GOLDENS=1 rewrites them.
    static func goldens(_ dir: URL) throws -> Int {
        var expected: [String: String] = [:]
        for (agent, method, snippet) in all(placeholders) {
            let base = "\(slug(agent)).\(slug(method))"
            expected["\(base).txt"] = snippet.text
            for (index, extra) in snippet.extraSnippets.enumerated() {
                expected["\(base).extra\(index + 1).txt"] = extra.text
            }
            if let link = snippet.installURL { expected["\(base).install-url.txt"] = link.absoluteString }
        }
        expected["claude-code.direct-http.apostrophe.txt"] =
            AgentKind.claudeCode.snippet(.directHTTP, apostrophe).text
        expected["claude-code.launcher.apostrophe.txt"] =
            AgentKind.claudeCode.snippet(.launcher, apostrophe).text

        let files = FileManager.default
        if ProcessInfo.processInfo.environment["UPDATE_GOLDENS"] == "1" {
            try files.createDirectory(at: dir, withIntermediateDirectories: true)
            for name in try files.contentsOfDirectory(atPath: dir.path) where expected[name] == nil {
                try files.removeItem(at: dir.appendingPathComponent(name))
            }
            for (name, text) in expected {
                try Data((text + "\n").utf8).write(to: dir.appendingPathComponent(name))
            }
        }
        let present = Set(try files.contentsOfDirectory(atPath: dir.path).filter { !$0.hasPrefix(".") })
        precondition(present == Set(expected.keys),
                     "goldens differ: missing \(Set(expected.keys).subtracting(present).sorted()), "
                     + "stale \(present.subtracting(expected.keys).sorted()); run with UPDATE_GOLDENS=1")
        for (name, text) in expected {
            let golden = try Data(contentsOf: dir.appendingPathComponent(name))
            precondition(golden == Data((text + "\n").utf8),
                         "\(name) differs from the generated snippet; run with UPDATE_GOLDENS=1")
        }
        return expected.count
    }

    static func catalog() {
        precondition(AgentKind.allCases.count == 11)
        for agent in AgentKind.allCases {
            precondition(agent.methods.contains(agent.recommended), "\(agent)")
            precondition(Set(agent.methods).count == agent.methods.count, "\(agent)")
            precondition(!agent.displayName.isEmpty)
        }
        precondition(AgentKind.claudeCode.recommended == .directHTTP)
        precondition(AgentKind.codex.recommended == .launcher)
        precondition(AgentKind.claudeDesktop.methods == [.launcher])
        precondition(AgentKind.other.methods == [.directHTTP, .launcher])
        precondition(AgentKind.other.snippet(.launcher, placeholders).text
                     == AgentKind.other.snippet(.directHTTP, placeholders).text)
        precondition(AgentKind.claudeDesktop.footnote != nil && AgentKind.claudeCode.footnote == nil)
        precondition(AgentSetup.cloudFootnote.contains("can't reach"))
        // A method the agent doesn't offer falls back to the recommended one.
        precondition(AgentKind.zed.snippet(.directHTTP, placeholders).text
                     == AgentKind.zed.snippet(.launcher, placeholders).text)

        let literal: Set<String> = ["codex.directHTTP", "cursor.directHTTP", "vsCode.directHTTP",
                                    "geminiCLI.directHTTP", "other.directHTTP", "other.launcher"]
        let unverified = literal.union(["devinDesktop.directHTTP"])
        for (agent, method, snippet) in all(placeholders) {
            let key = "\(agent.rawValue).\(method.rawValue)"
            precondition(snippet.needsLiteralToken == literal.contains(key), key)
            precondition(snippet.skipsListenerCheck == unverified.contains(key), key)
            precondition(!snippet.steps.isEmpty, key)
            if let folder = snippet.destinationFolder {
                precondition(snippet.destination?.hasPrefix(folder + "/") == true, key)
            }
            for path in [snippet.destination, snippet.destinationFolder].compactMap({ $0 }) {
                precondition(path.hasPrefix("~/"), key)
            }
        }
    }

    static func noSecrets() {
        for context in [placeholders, apostrophe] {
            for (agent, method, snippet) in all(context) {
                let texts = [snippet.text] + snippet.steps + snippet.extraSnippets.map(\.text)
                    + [snippet.installURL?.absoluteString ?? ""]
                for text in texts {
                    precondition(!text.contains("ekb_mcp_v1_"), "\(agent) \(method)")
                }
                precondition(!snippet.containsSecret, "\(agent) \(method)")
            }
        }
    }

    // Every snippet follows the context: the server key always, and the client UUID unless the
    // method carries the token itself. The context has no client name, so none can leak in.
    static func identity() {
        let other = SetupContext(
            serverKey: "test-key", url: "http://127.0.0.1:50001/mcp",
            launcherPath: "/tmp/Other Place/bridge-mcp", clientID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            tokenPath: "/tmp/Other Place/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.mcp-token")
        for context in [placeholders, other] {
            for (agent, method, snippet) in all(context) {
                let key = "\(agent) \(method)"
                let texts = [snippet.text] + snippet.extraSnippets.map(\.text)
                for text in texts {
                    precondition(text.contains(context.serverKey), key)
                    precondition(snippet.needsLiteralToken && agent != .other
                                 || text.contains(context.clientID), key)
                    if context.serverKey != AppIdentity.mcpServerKey {
                        for stale in [AppIdentity.mcpServerKey, clientID, "47615", "/Applications/"] {
                            precondition(!text.contains(stale), "\(key) contains \(stale)")
                        }
                    }
                }
            }
        }
    }

    static func syntax() {
        let tricky = SetupContext(
            url: url, launcherPath: #"/Users/o'brien/we "quote" $HOME `x` back\slash!/bridge-mcp"#,
            clientID: clientID, tokenPath: #"/Users/o'brien/we "quote"/t.mcp-token"#)
        var counts = (json: 0, toml: 0)
        for context in [placeholders, apostrophe, tricky] {
            for (agent, method, snippet) in all(context) {
                let pieces = [(snippet.kind, snippet.text)] + snippet.extraSnippets.map { ($0.kind, $0.text) }
                for (kind, text) in pieces {
                    switch kind {
                    case .json:
                        let object = parseJSON(text, "\(agent) \(method)")
                        if method == .launcher, agent != .vsCode {
                            let root = object[agent == .zed ? "context_servers" : "mcpServers"]
                            let entry = (root as! [String: Any])[context.serverKey] as! [String: Any]
                            precondition(entry["command"] as? String == context.launcherPath)
                            precondition(entry["args"] as? [String] == ["--client", context.clientID])
                        }
                        counts.json += 1
                    case .toml:
                        let table = parseTOML(text)
                        precondition(table.keys.sorted() == ["mcp_servers.\(context.serverKey)"])
                        let entry = table.values.first!
                        if method == .launcher {
                            precondition(entry["command"] as? String == context.launcherPath)
                            precondition(entry["args"] as? [String] == ["--client", context.clientID])
                        } else {
                            precondition(entry["url"] as? String == context.url)
                            precondition(entry["bearer_token_env_var"] as? String == "EVENTKIT_BRIDGE_TOKEN")
                        }
                        counts.toml += 1
                    case .shellCommand, .values:
                        break
                    }
                }
            }
        }
        let devin = parseJSON(AgentKind.devinDesktop.snippet(.directHTTP, tricky).text, "devin")
        let entry = (devin["mcpServers"] as! [String: Any])["eventkit-bridge"] as! [String: Any]
        let headers = entry["headers"] as! [String: String]
        precondition(headers["Authorization"] == "Bearer ${file:\(tricky.tokenPath)}")
        precondition(counts.json > 30 && counts.toml == 6)

        // The checker itself rejects what it should.
        for bad in ["[a b]", "key = bare", "key = [\"a\" \"b\"]", "[t]\nk = \"a\"\nk = \"b\"", "k = \"a\""] {
            precondition(tomlProblem(bad) != nil, bad)
        }
    }

    static func installLinks() {
        for (agent, method, snippet) in all(placeholders) {
            precondition((snippet.installURL != nil) == (agent == .vsCode && method == .launcher))
        }
        let snippet = AgentKind.vsCode.snippet(.launcher, apostrophe)
        let link = snippet.installURL!.absoluteString
        precondition(link.hasPrefix("vscode:mcp/install?"))
        let encoded = String(link.dropFirst("vscode:mcp/install?".count))
        precondition(!encoded.contains(" ") && !encoded.contains("'") && !encoded.contains("\""))
        let json = parseJSON(encoded.removingPercentEncoding!, "install link")
        precondition(json["name"] as? String == "eventkit-bridge")
        precondition(json["command"] as? String == apostrophe.launcherPath)
        precondition(json["args"] as? [String] == ["--client", clientID])
    }

    // Runs each shell snippet through /bin/sh with stub `claude`/`codex`/`code` commands and a stub
    // launcher at a real path with spaces, quotes and an apostrophe, then runs the headersHelper the
    // agent would run. Every argv must come back exactly.
    static func shellRoundTrip() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("agent-setup-\(UUID().uuidString)")
        defer { try? files.removeItem(at: root) }
        let stub = "#!/bin/sh\nprintf '%s\\0' \"$0\" \"$@\"\n"
        let bin = root.appendingPathComponent("bin")
        try files.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["claude", "codex", "code"] {
            try install(stub, at: bin.appendingPathComponent(name))
        }
        let folders = ["o'brien/Apps/EventKit Bridge.app/Contents/MacOS",
                       #"we "quote" $HOME `x` back\slash!/o'brien"#]
        for folder in folders {
            let launcher = root.appendingPathComponent(folder).appendingPathComponent("bridge-mcp")
            try files.createDirectory(at: launcher.deletingLastPathComponent(),
                                      withIntermediateDirectories: true)
            try install(stub, at: launcher)
            let context = SetupContext(url: url, launcherPath: launcher.path, clientID: clientID,
                                       tokenPath: tokenPath)
            let path = launcher.path
            let key = context.serverKey

            var argv = try run(AgentKind.claudeCode.snippet(.launcher, context).text, bin)
            precondition(argv.dropFirst() == ["mcp", "add", "--scope", "user", key, "--", path,
                                              "--client", clientID], "\(argv)")

            argv = try run(AgentKind.codex.snippet(.launcher, context).text, bin)
            precondition(argv.dropFirst() == ["mcp", "add", key, "--", path, "--client", clientID])

            argv = try run(AgentKind.vsCode.snippet(.launcher, context).text, bin)
            precondition(argv.count == 3 && argv[1] == "--add-mcp")
            let vsCode = parseJSON(argv[2], "code --add-mcp")
            precondition(vsCode["command"] as? String == path)

            argv = try run(AgentKind.claudeCode.snippet(.directHTTP, context).text, bin)
            precondition(Array(argv[1...5]) == ["mcp", "add-json", "--scope", "user", key] && argv.count == 7)
            let config = parseJSON(argv[6], "add-json")
            precondition(config.count == 3 && config["type"] as? String == "http"
                         && config["url"] as? String == url)
            argv = try run(config["headersHelper"] as! String, bin)
            precondition(argv == [path, "headers", "--client", clientID, "--url", url], "\(argv)")
        }
    }

    static func install(_ script: String, at file: URL) throws {
        try Data(script.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    static func run(_ command: String, _ bin: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["PATH": "\(bin.path):/usr/bin:/bin", "HOME": "/nonexistent"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0, "sh failed: \(command)")
        var parts = String(decoding: data, as: UTF8.self).components(separatedBy: "\0")
        precondition(parts.removeLast().isEmpty)
        return parts
    }

    static func parseJSON(_ text: String, _ label: String) -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            preconditionFailure("\(label): not a JSON object: \(text)")
        }
        return object
    }

    // A tiny TOML subset: `[a.b-c]` headers, then `key = "string"` or `key = ["a", "b"]`.
    // Our strings only use escapes that TOML and JSON share, so JSON parses the values.
    static func parseTOML(_ text: String) -> [String: [String: Any]] {
        var tables: [String: [String: Any]] = [:]
        if let problem = tomlProblem(text, into: &tables) { preconditionFailure("\(problem): \(text)") }
        return tables
    }

    static func tomlProblem(_ text: String) -> String? {
        var tables: [String: [String: Any]] = [:]
        return tomlProblem(text, into: &tables)
    }

    static func tomlProblem(_ text: String, into tables: inout [String: [String: Any]]) -> String? {
        let header = try! NSRegularExpression(pattern: #"^\[([A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*)\]$"#)
        let pair = try! NSRegularExpression(pattern: #"^([A-Za-z0-9_-]+) = (".*"|\[.*\])$"#)
        var table: String?
        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            let range = NSRange(line.startIndex..., in: line)
            if let match = header.firstMatch(in: line, range: range) {
                let name = String(line[Range(match.range(at: 1), in: line)!])
                guard tables[name] == nil else { return "duplicate table \(name)" }
                tables[name] = [:]
                table = name
            } else if let match = pair.firstMatch(in: line, range: range) {
                guard let name = table else { return "key outside a table" }
                let key = String(line[Range(match.range(at: 1), in: line)!])
                let raw = String(line[Range(match.range(at: 2), in: line)!])
                guard tables[name]![key] == nil else { return "duplicate key \(key)" }
                let value = try? JSONSerialization.jsonObject(
                    with: Data(raw.utf8), options: .fragmentsAllowed)
                guard let value, value is String || value is [String] else { return "bad value \(raw)" }
                if let items = value as? [String],
                   raw != "[" + items.map(json).joined(separator: ", ") + "]" {
                    return "unexpected array spacing \(raw)"
                }
                tables[name]![key] = value
            } else {
                return "bad line \(line)"
            }
        }
        return nil
    }

    static func json(_ string: String) -> String {
        let data = try! JSONSerialization.data(
            withJSONObject: string, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}
