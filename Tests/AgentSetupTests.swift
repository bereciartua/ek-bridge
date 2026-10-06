import Foundation

@main
struct AgentSetupTests {
    static let clientID = "3f1c2b7e-8a41-4d0c-9a8e-5b6f1d2e9a1c"
    static let url = "http://127.0.0.1:47615/mcp"
    static let tokenPath =
        "/Users/you/Library/Application Support/EKBridge/client-credentials/\(clientID).mcp-token"
    static let placeholders = SetupContext(
        url: url, launcherPath: "/Applications/EKBridge.app/Contents/MacOS/bridge-mcp",
        clientID: clientID, tokenPath: tokenPath)
    static let apostrophe = SetupContext(
        url: url, launcherPath: "/Users/o'brien/Apps/EK Bridge.app/Contents/MacOS/bridge-mcp",
        clientID: clientID, tokenPath: tokenPath)

    static func main() throws {
        let count = try goldens(URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
        catalog()
        noSecrets()
        identity()
        syntax()
        installLinks()
        try shellRoundTrip()
        cloudCatalog()
        cloudSyntax()
        try cloudShellRoundTrip()
        tunnels()
        print("Agent setup: \(count) goldens, catalog, no secrets, identity, JSON/TOML syntax, "
              + "install links, shell round trip, cloud catalog, cloud shell round trip, tunnels passed")
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
        for agent in CloudAgentKind.allCases {
            expected["cloud-\(slug(agent)).txt"] = render(agent, cloud)
        }
        for provider in TunnelProvider.allCases {
            expected["tunnel-\(slug(provider)).txt"] = render(provider)
        }

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
                            precondition(entry["bearer_token_env_var"] as? String == "EK_BRIDGE_TOKEN")
                        }
                        counts.toml += 1
                    case .shellCommand, .values:
                        break
                    }
                }
            }
        }
        let devin = parseJSON(AgentKind.devinDesktop.snippet(.directHTTP, tricky).text, "devin")
        let entry = (devin["mcpServers"] as! [String: Any])["ek-bridge"] as! [String: Any]
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
        precondition(json["name"] as? String == "ek-bridge")
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
        let folders = ["o'brien/Apps/EK Bridge.app/Contents/MacOS",
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

    // MARK: Cloud agents and tunnels (§22)

    static let cloudURL = "https://my-mac.tail1234.ts.net/r/q7Zk2vN4bXwP9sL1mT6hYa/mcp"
    static let cloud = CloudSetupContext(mcpURL: cloudURL, clientName: "claude.ai")
    static let cloudTricky = CloudSetupContext(
        mcpURL: cloudURL, clientName: #"O'Brien's "cloud" $HOME `x` \ bot"#)
    static let cloudOther = CloudSetupContext(
        serverKey: "test-key", mcpURL: "https://other.example.net/r/AAAAAAAAAAAAAAAAAAAAAA/mcp",
        clientName: "Other")
    static let remotePort = TunnelProvider.defaultRemotePort
    static let tunnelHost = "my-mac.tail1234.ts.net"
    static let secretPrefixes = ["ekb_mcp_v1_", "ekb_mcpr_v1_", "ekb_oat_v1_", "ekb_ort_v1_"]

    static func slug(_ agent: CloudAgentKind) -> String {
        switch agent {
        case .anthropicAPI: return "anthropic-api"
        case .openAIResponses: return "openai-responses"
        case .claudeAI: return "claude-ai"
        case .chatGPT: return "chatgpt"
        default: return kebab(agent.rawValue)
        }
    }

    static func slug(_ provider: TunnelProvider) -> String { kebab(provider.rawValue) }

    static func kebab(_ name: String) -> String {
        name.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1-$2", options: .regularExpression)
            .lowercased()
    }

    // Everything the user reads for one agent, so wording changes show up in review.
    static func render(_ agent: CloudAgentKind, _ context: CloudSetupContext) -> String {
        let snippet = agent.snippet(context)
        var lines = ["\(agent.displayName)", "credential: \(agent.credential)",
                     "needsLiteralToken: \(snippet.needsLiteralToken)", "", "snippet (\(snippet.kind)):",
                     snippet.text]
        for extra in snippet.extraSnippets {
            lines += ["", "\(extra.title) (\(extra.kind)):", extra.text]
        }
        lines += ["", "steps:"] + snippet.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }
        if !agent.warnings.isEmpty { lines += ["", "warnings:"] + agent.warnings.map { "- \($0)" } }
        if let footnote = agent.footnote { lines += ["", "footnote: \(footnote)"] }
        return lines.joined(separator: "\n")
    }

    static func render(_ provider: TunnelProvider) -> String {
        var lines = ["\(provider.displayName)", "preservesHost: \(provider.preservesHost)",
                     "detectionHeader: \(provider.detectionHeader ?? "none")", "", "commands:"]
        lines += provider.commands(port: remotePort, hostname: tunnelHost)
        if let config = provider.configFile(port: remotePort, hostname: tunnelHost) {
            lines += ["", "config.yml:", config]
        }
        lines += ["", "steps:"] + provider.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }
        lines += ["", "notes:"] + provider.notes.map { "- \($0)" }
        return lines.joined(separator: "\n")
    }

    static func texts(_ agent: CloudAgentKind, _ context: CloudSetupContext) -> [String] {
        let snippet = agent.snippet(context)
        return [snippet.text] + snippet.extraSnippets.map(\.text) + snippet.steps + agent.warnings
            + [agent.footnote ?? "", agent.displayName]
    }

    static func cloudCatalog() {
        precondition(CloudAgentKind.allCases.count == 11 && TunnelProvider.allCases.count == 5)
        let oauth: Set<CloudAgentKind> = [.claudeAI, .chatGPT, .geminiEnterprise]
        for context in [cloud, cloudTricky, cloudOther] {
            for agent in CloudAgentKind.allCases {
                let snippet = agent.snippet(context)
                let key = "\(agent)"
                for text in texts(agent, context) {
                    for prefix in secretPrefixes { precondition(!text.contains(prefix), "\(key) \(prefix)") }
                }
                precondition(!snippet.containsSecret && snippet.installURL == nil, key)
                precondition(snippet.destination == nil && !snippet.skipsListenerCheck, key)
                precondition(!snippet.steps.isEmpty && !agent.displayName.isEmpty, key)
                precondition(snippet.needsLiteralToken == (agent.credential == .bearer), key)
                precondition((agent.credential == .oauth) == oauth.contains(agent), key)
                let pieces = [snippet.text] + snippet.extraSnippets.map(\.text)
                switch agent.credential {
                case .bearer:
                    precondition(pieces.allSatisfy { $0.contains(context.mcpURL) }, key)
                    let placeholders = AgentSetup.remoteTokenPlaceholders
                    precondition(placeholders.contains { snippet.text.contains($0) }, key)
                    precondition(pieces.joined().contains(context.serverKey), key)
                case .oauth:
                    precondition(snippet.text == context.mcpURL && snippet.extraSnippets.isEmpty, key)
                    precondition(snippet.steps.contains { $0.contains("Connect a Cloud App") }, key)
                case .unsupported:
                    precondition(snippet.text.isEmpty && agent.footnote != nil && agent.warnings.isEmpty, key)
                }
                if context.serverKey != AppIdentity.mcpServerKey {
                    for text in pieces {
                        for stale in [AppIdentity.mcpServerKey, cloudURL, "tail1234"] {
                            precondition(!text.contains(stale), "\(key) contains \(stale)")
                        }
                    }
                }
            }
        }
        precondition(CloudAgentKind.copilotAgent.warnings.contains { $0.contains("Read-only") })
        precondition(CloudAgentKind.claudeCodeCloud.warnings.contains { $0.contains("Anyone who uses") })
        precondition(CloudAgentKind.allCases.filter { $0.credential != .unsupported }
            .allSatisfy { $0.warnings.contains(AgentSetup.cloudAskWarning) })
        precondition(CloudAgentKind.codexCloud.credential == .unsupported)
        precondition(AgentSetup.readOnlyToolNames.allSatisfy { $0.hasPrefix("read_") || $0.hasPrefix("list_") })
    }

    static func cloudSyntax() {
        var count = 0
        for context in [cloud, cloudTricky, cloudOther] {
            for agent in CloudAgentKind.allCases {
                let snippet = agent.snippet(context)
                let pieces = [(snippet.kind, snippet.text)] + snippet.extraSnippets.map { ($0.kind, $0.text) }
                for (kind, text) in pieces where kind == .json {
                    _ = parseJSON(text, "\(agent)")
                    count += 1
                }
            }
            let key = context.serverKey
            let copilot = parseJSON(CloudAgentKind.copilotAgent.snippet(context).text, "copilot")
            let copilotEntry = (copilot["mcpServers"] as! [String: Any])[key] as! [String: Any]
            precondition(copilotEntry["type"] as? String == "http")
            precondition(copilotEntry["url"] as? String == context.mcpURL)
            precondition(copilotEntry["tools"] as? [String] == AgentSetup.readOnlyToolNames)
            precondition((copilotEntry["headers"] as? [String: String])?["Authorization"]
                         == "Bearer $COPILOT_MCP_EK_BRIDGE_TOKEN")

            let claudeCode = CloudAgentKind.claudeCodeCloud.snippet(context)
            let entry = (parseJSON(claudeCode.text, "claude code")["mcpServers"] as! [String: Any])[key]
                as! [String: Any]
            precondition((entry["headers"] as? [String: String])?["Authorization"]
                         == "Bearer ${EK_BRIDGE_TOKEN}")
            let bare = (parseJSON(claudeCode.extraSnippets[0].text, "claude code")["mcpServers"]
                        as! [String: Any])[key] as! [String: Any]
            precondition(bare.keys.sorted() == ["type", "url"] && bare["url"] as? String == context.mcpURL)
        }
        precondition(count == 12)
    }

    // Runs each curl snippet through /bin/sh with a stub curl and a fake token in the environment:
    // the body must parse and carry the token exactly, whatever the client name holds.
    static func cloudShellRoundTrip() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("agent-cloud-\(UUID().uuidString)")
        defer { try? files.removeItem(at: root) }
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        try install("#!/bin/sh\nprintf '%s\\0' \"$0\" \"$@\"\n", at: root.appendingPathComponent("curl"))
        let token = "fake-token-with-'quote-and-$dollar"
        let environment = [
            "EK_BRIDGE_REMOTE_TOKEN": token, "ANTHROPIC_API_KEY": "fake-anthropic",
            "OPENAI_API_KEY": "fake-openai", "VAULT_ID": "vlt_test",
        ]
        for context in [cloud, cloudTricky] {
            for agent in [CloudAgentKind.anthropicAPI, .managedAgents, .openAIResponses] {
                let argv = try run(agent.snippet(context).text, root, environment: environment)
                let data = argv.firstIndex(of: "-d").map { argv[$0 + 1] }!
                let body = parseJSON(data, "\(agent) body")
                switch agent {
                case .anthropicAPI:
                    precondition(argv[1] == "https://api.anthropic.com/v1/messages")
                    precondition(argv.contains("x-api-key: fake-anthropic"))
                    let server = (body["mcp_servers"] as! [[String: Any]])[0]
                    precondition(server["authorization_token"] as? String == token)
                    precondition(server["url"] as? String == context.mcpURL)
                case .managedAgents:
                    precondition(argv[1] == "https://api.anthropic.com/v1/vaults/vlt_test/credentials")
                    let auth = body["auth"] as! [String: Any]
                    precondition(auth["token"] as? String == token)
                    precondition(auth["type"] as? String == "static_bearer")
                    precondition(auth["mcp_server_url"] as? String == context.mcpURL)
                    precondition((body["display_name"] as! String).contains(context.clientName))
                default:
                    precondition(argv.contains("authorization: Bearer fake-openai"))
                    let tool = (body["tools"] as! [[String: Any]])[0]
                    precondition(tool["authorization"] as? String == token)
                    precondition(tool["server_url"] as? String == context.mcpURL)
                }
            }
        }
    }

    static func tunnels() {
        for provider in TunnelProvider.allCases {
            let key = "\(provider)"
            let commands = provider.commands(port: remotePort, hostname: tunnelHost)
            let moved = provider.commands(port: 50123, hostname: nil)
            precondition(commands.isEmpty == (provider == .other), key)
            if provider != .other {
                // A named Cloudflare tunnel takes the port from config.yml.
                let config = { (port: Int) in [provider.configFile(port: port, hostname: nil) ?? ""] }
                precondition((commands + config(remotePort)).contains { $0.contains("\(remotePort)") }, key)
                precondition((moved + config(50123)).contains { $0.contains("50123") }, key)
            }
            precondition(!moved.contains { $0.contains("47616") || $0.contains(tunnelHost) }, key)
            precondition(Array(commands.suffix(provider.offCommands(port: remotePort).count))
                         == provider.offCommands(port: remotePort), key)
            precondition(!provider.steps.isEmpty && !provider.notes.isEmpty, key)
            let all = commands + provider.steps + provider.notes
                + [provider.configFile(port: remotePort, hostname: tunnelHost) ?? ""]
            for text in all {
                for prefix in secretPrefixes { precondition(!text.contains(prefix), key) }
                precondition(!text.contains("47615"), "\(key) points at the local port")
            }
        }
        let tailscale = TunnelProvider.tailscaleFunnel.commands(port: remotePort, hostname: nil)
        precondition(tailscale == ["tailscale funnel --bg 47616", "tailscale funnel --bg 47616 off"])
        precondition(TunnelProvider.ngrok.commands(port: remotePort, hostname: nil)[1]
                     == "ngrok http 47616 --url https://<your-dev-domain> --host-header=rewrite")
        let config = TunnelProvider.cloudflareTunnel.configFile(port: 50123, hostname: nil)!
        precondition(config.contains("service: http://127.0.0.1:50123")
                     && config.contains(#"httpHostHeader: "127.0.0.1:50123""#)
                     && config.contains("hostname: mcp.example.com"))
        precondition(TunnelProvider.allCases.filter(\.preservesHost) == [.tailscaleFunnel, .other])
        precondition(TunnelProvider.ngrok.notes.contains { $0.contains("20,000") && !$0.contains("basic") })
        precondition(TunnelProvider.cloudflareQuick.notes[0].contains("testing only"))

        let funnel = [("Host", tunnelHost), ("Tailscale-Funnel-Request", "?1"),
                      ("X-Forwarded-For", "203.0.113.7"), ("X-Forwarded-Host", tunnelHost)]
        let named = [("Host", "127.0.0.1:47616"), ("cf-ray", "8c1f2a3b4c5d6e7f-SJC"),
                     ("CF-Connecting-IP", "203.0.113.7")]
        let quick = [("Host", "random-words-here.trycloudflare.com"), ("CF-Ray", "8c1f2a3b4c5d6e7f-SJC")]
        let ngrok = [("Host", "localhost:47616"), ("X-Forwarded-For", "203.0.113.7"),
                     ("X-Forwarded-Host", "calm-otter-42.ngrok-free.app"), ("X-Forwarded-Proto", "https")]
        let custom = [("Host", "127.0.0.1:47616"), ("X-Forwarded-For", "203.0.113.7")]
        let cases: [([(String, String)], TunnelProvider?)] = [
            (funnel, .tailscaleFunnel), (named, .cloudflareTunnel), (quick, .cloudflareQuick),
            (ngrok, .ngrok), (custom, .other), ([("Host", "127.0.0.1:47616")], nil), ([], nil),
        ]
        for (headers, provider) in cases {
            precondition(TunnelProvider.detect(headers: headers) == provider, "\(headers)")
        }
        for provider in TunnelProvider.allCases {
            guard let header = provider.detectionHeader else { continue }
            let value = provider == .ngrok ? "x.ngrok.app" : "1"
            let detected = TunnelProvider.detect(headers: [(header.uppercased(), value)])
            let expected = provider == .cloudflareQuick ? .cloudflareTunnel : provider
            precondition(detected == expected, "\(provider)")
        }
    }

    static func install(_ script: String, at file: URL) throws {
        try Data(script.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    static func run(_ command: String, _ bin: URL, environment: [String: String] = [:]) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = environment.merging(
            ["PATH": "\(bin.path):/usr/bin:/bin", "HOME": "/nonexistent"]) { $1 }
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
