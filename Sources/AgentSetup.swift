import Foundation

// Copy-paste setup for each agent the Connect tab knows (§12). Pure, so every
// snippet is golden-tested in Tests/agent-setup/. No snippet ever holds a token.

enum AgentKind: String, CaseIterable, Identifiable {
    case claudeCode, claudeDesktop, codex, cursor, vsCode, geminiCLI, devinDesktop, zed, cline,
         jetBrains, other

    var id: String { rawValue }
}

enum SetupMethod: String, CaseIterable {
    case launcher, directHTTP
}

struct SetupContext {
    let serverKey: String
    let url: String
    let launcherPath: String
    let clientID: String
    let tokenPath: String

    init(serverKey: String = AppIdentity.mcpServerKey, url: String, launcherPath: String,
         clientID: String, tokenPath: String) {
        self.serverKey = serverKey
        self.url = url
        self.launcherPath = launcherPath
        self.clientID = clientID
        self.tokenPath = tokenPath
    }
}

struct SetupSnippet {
    enum Kind { case shellCommand, json, toml, values }

    let kind: Kind
    let text: String
    /// The config file this ends up in, in tilde form for display.
    var destination: String? = nil
    /// Set only when the user edits `destination` by hand, for Show in Finder.
    var destinationFolder: String? = nil
    var steps: [String] = []
    var containsSecret = false
    var installURL: URL? = nil
    /// The UI offers Copy Token… only for these methods.
    var needsLiteralToken = false
    /// The agent sends the token without the launcher's listener check (T9).
    var skipsListenerCheck = false
    var extraSnippets: [(title: String, kind: Kind, text: String)] = []
}

enum AgentSetup {
    static let tokenEnvironmentVariable = "EVENTKIT_BRIDGE_TOKEN"

    static var cloudFootnote: String {
        String(localized: """
            claude.ai, Claude Desktop custom connectors, Claude Cowork, ChatGPT and cloud coding \
            agents connect from the vendor's cloud and can't reach \(AppIdentity.displayName) \
            on this Mac.
            """)
    }

    static var listenerCheckCaveat: String {
        String(localized: """
            With this method the agent sends the token without checking that the program on the \
            port is \(AppIdentity.displayName). The launcher checks first.
            """)
    }
}

extension AgentKind {
    var displayName: String {
        switch self {
        case .claudeCode: return String(localized: "Claude Code")
        case .claudeDesktop: return String(localized: "Claude Desktop")
        case .codex: return String(localized: "Codex")
        case .cursor: return String(localized: "Cursor")
        case .vsCode: return String(localized: "VS Code (Copilot)")
        case .geminiCLI: return String(localized: "Gemini CLI")
        case .devinDesktop: return String(localized: "Devin Desktop")
        case .zed: return String(localized: "Zed")
        case .cline: return String(localized: "Cline")
        case .jetBrains: return String(localized: "JetBrains AI Assistant")
        case .other: return String(localized: "Other agent")
        }
    }

    /// Recommended first.
    var methods: [SetupMethod] {
        switch self {
        case .claudeCode, .other: return [.directHTTP, .launcher]
        case .codex, .cursor, .vsCode, .geminiCLI, .devinDesktop: return [.launcher, .directHTTP]
        case .claudeDesktop, .zed, .cline, .jetBrains: return [.launcher]
        }
    }

    var recommended: SetupMethod { methods[0] }

    var footnote: String? {
        switch self {
        case .claudeDesktop:
            return String(localized: """
                Claude Desktop's custom connectors run from Anthropic's cloud and can't reach this \
                Mac, so use this local setup instead.
                """)
        case .codex:
            return String(localized: """
                Codex started from an app doesn't see your shell's environment variables, so the \
                launcher is more reliable than direct HTTP.
                """)
        case .cursor:
            return String(localized: """
                Use your own ~/.cursor/mcp.json, never a project's .cursor/mcp.json, which often \
                gets committed.
                """)
        case .vsCode:
            return String(localized: """
                Servers that prompt for input aren't sent to VS Code's Agent Host, so the launcher \
                works in more places.
                """)
        case .zed:
            return String(localized: """
                Zed starts a sign-in when a remote server has no Authorization header, so only the \
                launcher is offered.
                """)
        case .cline:
            return String(localized: """
                Cline treats a remote server without a type as legacy SSE, so only the launcher is \
                offered.
                """)
        case .jetBrains:
            return String(localized: """
                AI Assistant has known problems with local HTTP servers, so only the launcher is \
                offered.
                """)
        case .claudeCode, .geminiCLI, .devinDesktop, .other:
            return nil
        }
    }

    func snippet(_ method: SetupMethod, _ c: SetupContext) -> SetupSnippet {
        let method = methods.contains(method) ? method : recommended
        let path = ConnectCommand.shellQuoted(c.launcherPath)
        let key = SetupShell.word(c.serverKey)
        let id = SetupShell.word(c.clientID)
        let stdio: [(String, SetupJSON)] = [
            ("command", .string(c.launcherPath)), ("args", .strings(["--client", c.clientID])),
        ]
        func servers(_ entry: [(String, SetupJSON)], under root: String = "mcpServers") -> String {
            SetupJSON.object([(root, .object([(c.serverKey, .object(entry))]))]).text
        }
        let bearerEnv = "Bearer ${env:\(AgentSetup.tokenEnvironmentVariable)}"
        let open = { (file: String) in String(localized: "Open \(file).") }
        let addEntry = String(localized: "Add the \(c.serverKey) entry under mcpServers.")
        let setEnv = { (agent: String) in
            String(localized: """
                Set \(AgentSetup.tokenEnvironmentVariable) to the token (Copy Token…) in the \
                environment \(agent) starts from.
                """)
        }

        switch (self, method) {
        case (.claudeCode, .directHTTP):
            let helper = "\(path) headers --client \(id) --url \(SetupShell.word(c.url))"
            let json = SetupJSON.object([
                ("type", .string("http")), ("url", .string(c.url)), ("headersHelper", .string(helper)),
            ]).text
            return SetupSnippet(
                kind: .shellCommand,
                text: "claude mcp add-json --scope user \(key) \(SetupShell.singleQuoted(json))",
                destination: "~/.claude.json", steps: [Self.claudeCodeStep])
        case (.claudeCode, _):
            return SetupSnippet(
                kind: .shellCommand,
                text: "claude mcp add --scope user \(key) -- \(path) --client \(id)",
                destination: "~/.claude.json", steps: [Self.claudeCodeStep])

        case (.claudeDesktop, _):
            let file = "~/Library/Application Support/Claude/claude_desktop_config.json"
            return SetupSnippet(
                kind: .json, text: servers(stdio), destination: file,
                destinationFolder: "~/Library/Application Support/Claude",
                steps: [open(file), addEntry, String(localized: "Restart Claude Desktop.")])

        case (.codex, .launcher):
            let toml = SetupTOML.table(c.serverKey, [
                ("command", .string(c.launcherPath)), ("args", .strings(["--client", c.clientID])),
            ])
            return SetupSnippet(
                kind: .shellCommand, text: "codex mcp add \(key) -- \(path) --client \(id)",
                destination: "~/.codex/config.toml", destinationFolder: "~/.codex",
                steps: [
                    String(localized: "Run it in Terminal, or add the lines below to ~/.codex/config.toml."),
                    String(localized: "Codex connects the next time it starts."),
                ],
                extraSnippets: [(String(localized: "Or in ~/.codex/config.toml"), .toml, toml)])
        case (.codex, _):
            let toml = SetupTOML.table(c.serverKey, [
                ("url", .string(c.url)),
                ("bearer_token_env_var", .string(AgentSetup.tokenEnvironmentVariable)),
            ])
            return SetupSnippet(
                kind: .toml, text: toml,
                destination: "~/.codex/config.toml", destinationFolder: "~/.codex",
                steps: [
                    String(localized: "Add this to ~/.codex/config.toml."), setEnv("Codex"),
                    String(localized: "Restart Codex."),
                ],
                needsLiteralToken: true, skipsListenerCheck: true)

        case (.cursor, .launcher):
            return SetupSnippet(
                kind: .json, text: servers([("type", .string("stdio"))] + stdio),
                destination: "~/.cursor/mcp.json", destinationFolder: "~/.cursor",
                steps: [open("~/.cursor/mcp.json"), addEntry, String(localized: "Restart Cursor.")])
        case (.cursor, _):
            let headers = SetupJSON.object([("Authorization", .string(bearerEnv))])
            return SetupSnippet(
                kind: .json, text: servers([("url", .string(c.url)), ("headers", headers)]),
                destination: "~/.cursor/mcp.json", destinationFolder: "~/.cursor",
                steps: [
                    open("~/.cursor/mcp.json"), addEntry, setEnv("Cursor"),
                    String(localized: "Restart Cursor."),
                ],
                needsLiteralToken: true, skipsListenerCheck: true)

        case (.vsCode, .launcher):
            let json = SetupJSON.object([("name", .string(c.serverKey))] + stdio).text
            return SetupSnippet(
                kind: .shellCommand, text: "code --add-mcp \(SetupShell.singleQuoted(json))",
                steps: [
                    String(localized: "Click Install in VS Code, or run the command in Terminal."),
                    String(localized: "Start \(c.serverKey) when VS Code asks."),
                ],
                installURL: URL(string: "vscode:mcp/install?" + SetupURL.percentEncoded(json)))
        case (.vsCode, _):
            let inputID = "\(c.serverKey)-token"
            let json = SetupJSON.object([
                ("inputs", .array([.object([
                    ("type", .string("promptString")), ("id", .string(inputID)),
                    ("description", .string("\(AppIdentity.displayName) MCP token")),
                    ("password", .bool(true)),
                ])])),
                ("servers", .object([(c.serverKey, .object([
                    ("type", .string("http")), ("url", .string(c.url)),
                    ("headers", .object([("Authorization", .string("Bearer ${input:\(inputID)}"))])),
                ]))])),
            ]).text
            return SetupSnippet(
                kind: .json, text: json,
                destination: "~/Library/Application Support/Code/User/mcp.json",
                destinationFolder: "~/Library/Application Support/Code/User",
                steps: [
                    String(localized: "In VS Code, run MCP: Open User Configuration."),
                    String(localized: "Add the inputs and servers entries."),
                    String(localized: "When VS Code asks for the token, paste it from Copy Token…."),
                ],
                needsLiteralToken: true, skipsListenerCheck: true)

        case (.geminiCLI, .launcher):
            return SetupSnippet(
                kind: .json, text: servers(stdio + [("timeout", .number(60000))]),
                destination: "~/.gemini/settings.json", destinationFolder: "~/.gemini",
                steps: [open("~/.gemini/settings.json"), addEntry, String(localized: "Restart Gemini CLI.")])
        case (.geminiCLI, _):
            let headers = SetupJSON.object([
                ("Authorization", .string("Bearer $\(AgentSetup.tokenEnvironmentVariable)")),
            ])
            return SetupSnippet(
                kind: .json,
                text: servers([
                    ("httpUrl", .string(c.url)), ("headers", headers), ("timeout", .number(60000)),
                ]),
                destination: "~/.gemini/settings.json", destinationFolder: "~/.gemini",
                steps: [
                    open("~/.gemini/settings.json"), addEntry, setEnv("Gemini CLI"),
                    String(localized: "Restart Gemini CLI."),
                ],
                needsLiteralToken: true, skipsListenerCheck: true)

        case (.devinDesktop, _):
            // `${file:}` works because the token file holds the bare token (§6.3).
            let entry: [(String, SetupJSON)] = method == .launcher ? stdio : [
                ("serverUrl", .string(c.url)),
                ("headers", .object([("Authorization", .string("Bearer ${file:\(c.tokenPath)}"))])),
            ]
            return SetupSnippet(
                kind: .json, text: servers(entry),
                destination: "~/.config/devin/mcp_config.json", destinationFolder: "~/.config/devin",
                steps: [
                    open("~/.config/devin/mcp_config.json"), addEntry,
                    String(localized: "Restart Devin Desktop."),
                ],
                skipsListenerCheck: method == .directHTTP)

        case (.zed, _):
            return SetupSnippet(
                kind: .json, text: servers(stdio + [("env", .object([]))], under: "context_servers"),
                destination: "~/.config/zed/settings.json", destinationFolder: "~/.config/zed",
                steps: [
                    String(localized: "In Zed, run zed: open settings."),
                    String(localized: "Add the \(c.serverKey) entry under context_servers."),
                ])

        case (.cline, _):
            return SetupSnippet(
                kind: .json,
                text: servers(stdio + [("disabled", .bool(false)), ("autoApprove", .array([]))]),
                steps: [
                    String(localized: "In Cline, open MCP Servers and click Configure MCP Servers."),
                    addEntry,
                ])

        case (.jetBrains, _):
            return SetupSnippet(
                kind: .json, text: servers(stdio),
                steps: [
                    String(localized: "Open Settings ▸ Tools ▸ AI Assistant ▸ Model Context Protocol (MCP)."),
                    String(localized: "Add a server, choose As JSON, and paste this."),
                ])

        case (.other, _):
            let lines = [
                (String(localized: "Server name"), c.serverKey),
                (String(localized: "Transport"), "Streamable HTTP"),
                (String(localized: "URL"), c.url),
                (String(localized: "Header"), "Authorization: Bearer <token>"),
                (String(localized: "Token file"), c.tokenPath),
                (String(localized: "stdio command"), c.launcherPath),
                (String(localized: "stdio args"), "--client \(c.clientID)"),
            ]
            return SetupSnippet(
                kind: .values, text: lines.map { "\($0.0): \($0.1)" }.joined(separator: "\n"),
                steps: [
                    String(localized: """
                        Use the HTTP values if the agent supports Streamable HTTP with a custom \
                        header; otherwise run the launcher over stdio.
                        """),
                    String(localized: """
                        For HTTP, paste the token from Copy Token… or read it from the token file.
                        """),
                ],
                needsLiteralToken: true, skipsListenerCheck: true)
        }
    }

    private static var claudeCodeStep: String {
        String(localized: """
            Run it in Terminal. Claude Code connects the next time it starts (or run /mcp to \
            reconnect).
            """)
    }
}

/// Compact JSON with a fixed key order, so snippets match the goldens byte for byte.
/// Strings go through JSONSerialization; only the punctuation is assembled here.
private indirect enum SetupJSON {
    case string(String), number(Int), bool(Bool), array([SetupJSON]), object([(String, SetupJSON)])

    static func strings(_ values: [String]) -> SetupJSON { .array(values.map { .string($0) }) }

    var text: String {
        switch self {
        case .string(let value):
            let data = try! JSONSerialization.data(
                withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
            return String(decoding: data, as: UTF8.self)
        case .number(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        case .array(let items): return "[" + items.map(\.text).joined(separator: ",") + "]"
        case .object(let pairs):
            return "{" + pairs.map { SetupJSON.string($0.0).text + ":" + $0.1.text }
                .joined(separator: ",") + "}"
        }
    }
}

private enum SetupTOML {
    /// TOML basic strings accept JSON's string escapes, so values reuse SetupJSON's encoding.
    static func table(_ serverKey: String, _ pairs: [(String, SetupJSON)]) -> String {
        let bare = serverKey.unicodeScalars.allSatisfy { SetupShell.bareKey.contains($0) }
        let name = bare ? serverKey : SetupJSON.string(serverKey).text
        let values = pairs.map { key, value -> String in
            guard case .array(let items) = value else { return "\(key) = \(value.text)" }
            return "\(key) = [" + items.map(\.text).joined(separator: ", ") + "]"
        }
        return (["[mcp_servers.\(name)]"] + values).joined(separator: "\n")
    }
}

private enum SetupShell {
    static let bareKey = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
    private static let safe = bareKey.union(CharacterSet(charactersIn: "./:=@%+,"))

    /// Bare when no shell would read anything special into it.
    static func word(_ text: String) -> String {
        !text.isEmpty && text.unicodeScalars.allSatisfy { safe.contains($0) }
            ? text : ConnectCommand.shellQuoted(text)
    }

    static func singleQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private enum SetupURL {
    static func percentEncoded(_ text: String) -> String {
        let unreserved = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return text.addingPercentEncoding(withAllowedCharacters: unreserved)!
    }
}
