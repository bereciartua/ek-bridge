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

/// What Add to <Agent>… does (B07): merge an entry into a JSON config file,
/// or run the agent's own command. Never contains a token: entries start
/// the launcher, which reads the token file.
enum OneClickSetup: Equatable {
    /// `file` in tilde form; the entry goes under `root` ▸ `key`.
    case jsonMerge(file: String, root: String, key: String, entry: SetupJSON)
    /// `claude` with these arguments (an argument array, never a shell string).
    case claudeCode(key: String, arguments: [String])
}

extension AgentKind {
    /// Agents with one-click setup. Others keep Copy (C07 adds more).
    var oneClick: Bool { [.claudeDesktop, .cursor, .claudeCode].contains(self) }

    /// The one-click setup for the recommended method, matching its snippet.
    func oneClickSetup(_ c: SetupContext) -> OneClickSetup? {
        let stdio: [(String, SetupJSON)] = [
            ("command", .string(c.launcherPath)), ("args", .strings(["--client", c.clientID])),
        ]
        switch self {
        case .claudeDesktop:
            return .jsonMerge(file: "~/Library/Application Support/Claude/claude_desktop_config.json",
                              root: "mcpServers", key: c.serverKey, entry: .object(stdio))
        case .cursor:
            return .jsonMerge(file: "~/.cursor/mcp.json", root: "mcpServers", key: c.serverKey,
                              entry: .object([("type", .string("stdio"))] + stdio))
        case .claudeCode:
            let helper = "\(ConnectCommand.shellQuoted(c.launcherPath)) headers --client "
                + "\(SetupShell.word(c.clientID)) --url \(SetupShell.word(c.url))"
            let json = SetupJSON.object([
                ("type", .string("http")), ("url", .string(c.url)), ("headersHelper", .string(helper)),
            ]).text
            return .claudeCode(key: c.serverKey,
                               arguments: ["mcp", "add-json", "--scope", "user", c.serverKey, json])
        default:
            return nil
        }
    }
}

enum AgentSetup {
    static let tokenEnvironmentVariable = "EK_BRIDGE_TOKEN"

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

// MARK: - Cloud agents (§22.2)

/// How a cloud agent proves it may use a client: the client's remote token, pasted into the
/// vendor's settings, or an OAuth connection approved in the app (Connect a Cloud App…).
enum CloudCredential { case bearer, oauth, unsupported }

struct CloudSetupContext {
    let serverKey: String
    /// The public MCP URL with the secret path: `https://host/r/<secret>/mcp`.
    let mcpURL: String
    let clientName: String

    init(serverKey: String = AppIdentity.mcpServerKey, mcpURL: String, clientName: String) {
        self.serverKey = serverKey
        self.mcpURL = mcpURL
        self.clientName = clientName
    }

    var host: String { URL(string: mcpURL)?.host ?? mcpURL }
}

enum CloudAgentKind: String, CaseIterable, Identifiable {
    case anthropicAPI, managedAgents, claudeCodeCloud, cursorCloud, copilotAgent, devin, openAIResponses,
         claudeAI, chatGPT, geminiEnterprise, codexCloud

    var id: String { rawValue }
}

extension AgentSetup {
    static let remoteTokenEnvironmentVariable = "EK_BRIDGE_REMOTE_TOKEN"
    /// Copilot only passes secrets whose names start with COPILOT_MCP_.
    static let copilotSecretName = "COPILOT_MCP_EK_BRIDGE_TOKEN"
    static var remoteTokenPlaceholder: String { String(localized: "<remote token from Copy Remote Token…>") }
    /// The tools MCPToolCatalog marks readOnlyHint, for agents that take an allowlist.
    static let readOnlyToolNames = ["list_collections", "read_events", "read_reminders"]

    /// Every way a cloud snippet refers to the token without containing it.
    static var remoteTokenPlaceholders: [String] {
        ["$\(remoteTokenEnvironmentVariable)", "${\(tokenEnvironmentVariable)}", "$\(copilotSecretName)",
         remoteTokenPlaceholder]
    }

    static var cloudAskWarning: String {
        String(localized: """
            Cloud agents often run while you're away. With Ask me first, changes wait up to 45 s for \
            you at this Mac and are declined otherwise.
            """)
    }
}

extension CloudAgentKind {
    var displayName: String {
        switch self {
        case .anthropicAPI: return String(localized: "Anthropic API (MCP connector)")
        case .managedAgents: return String(localized: "Claude Managed Agents")
        case .claudeCodeCloud: return String(localized: "Claude Code on the web")
        case .cursorCloud: return String(localized: "Cursor cloud agents")
        case .copilotAgent: return String(localized: "GitHub Copilot coding agent")
        case .devin: return String(localized: "Devin")
        case .openAIResponses: return String(localized: "OpenAI Responses API")
        case .claudeAI: return String(localized: "claude.ai · Claude Desktop · mobile")
        case .chatGPT: return String(localized: "ChatGPT")
        case .geminiEnterprise: return String(localized: "Gemini Enterprise")
        case .codexCloud: return String(localized: "Codex cloud tasks")
        }
    }

    /// Apps configured with a client ID and secret rather than discovering the server: Connect a
    /// Cloud App… sets up a confidential client with this redirect URI.
    var preRegisteredRedirectURI: String? {
        // Where Gemini Enterprise returns after authorization (Google's custom MCP server docs).
        self == .geminiEnterprise ? "https://vertexaisearch.cloud.google.com/oauth-redirect" : nil
    }

    var credential: CloudCredential {
        switch self {
        case .anthropicAPI, .managedAgents, .claudeCodeCloud, .cursorCloud, .copilotAgent, .devin,
             .openAIResponses:
            return .bearer
        case .claudeAI, .chatGPT, .geminiEnterprise: return .oauth
        case .codexCloud: return .unsupported
        }
    }

    var warnings: [String] {
        let apiRunsTools = String(localized: """
            The API calls tools without asking you, so this client's grants are the only limit. Give \
            it only the lists it needs.
            """)
        var list: [String]
        switch self {
        case .anthropicAPI, .managedAgents, .openAIResponses:
            list = [apiRunsTools]
        case .claudeCodeCloud:
            list = [String(localized: """
                Anyone who uses that cloud environment can read its environment variables, including \
                this token. Use an environment only you use, or on Pro and Max plans an API credential.
                """)]
        case .copilotAgent:
            list = [String(localized: """
                Copilot runs MCP tools without asking for approval. Give this client Read-only grants \
                and keep the tools list to the read tools.
                """)]
        case .cursorCloud, .devin, .claudeAI, .chatGPT, .geminiEnterprise:
            list = []
        case .codexCloud:
            return []
        }
        return list + [AgentSetup.cloudAskWarning]
    }

    var footnote: String? {
        switch self {
        case .anthropicAPI:
            return String(localized: """
                Keep the remote token with your app's other secrets; every request carries it.
                """)
        case .managedAgents:
            return String(localized: """
                The vault matches the credential by URL. If you reset the secret path, add the \
                credential again.
                """)
        case .claudeCodeCloud:
            return String(localized: "Cloud sessions load .mcp.json only when the session has one repository.")
        case .cursorCloud:
            return String(localized: """
                Cursor keeps the header on its servers and relays tool calls, so the agent's machine \
                never sees the token.
                """)
        case .copilotAgent:
            return String(localized: "Copilot can't sign in with OAuth, so it uses the remote token.")
        case .devin:
            return nil
        case .openAIResponses:
            return String(localized: "The authorization field takes the bare token, without Bearer.")
        case .claudeAI:
            return String(localized: """
                Once added, the connector also works in Claude Desktop and the Claude mobile app. Claude \
                signs in with OAuth; sending a fixed header is a limited beta.
                """)
        case .chatGPT:
            return String(localized: "ChatGPT can't send an API key, so it connects with OAuth.")
        case .geminiEnterprise:
            return String(localized: """
                Gemini Enterprise needs an OAuth client set up ahead of time: Set Up OAuth Client… \
                creates one for this client. Clicking it again replaces a client that hasn't connected.
                """)
        case .codexCloud:
            return String(localized: """
                Codex cloud tasks can't use your own MCP servers yet. Use Codex on this Mac with the \
                local setup, or the OpenAI Responses API.
                """)
        }
    }

    func snippet(_ c: CloudSetupContext) -> SetupSnippet {
        let placeholder = AgentSetup.remoteTokenPlaceholder
        let copyToken = String(localized: """
            Paste the token from Copy Remote Token… on the “\(c.clientName)” client.
            """)
        let exportToken = String(localized: """
            In Terminal, set \(AgentSetup.remoteTokenEnvironmentVariable) to the remote token (Copy \
            Remote Token…) and ANTHROPIC_API_KEY to your API key, then run the command.
            """)
        let pairing = String(localized: """
            When it asks you to sign in, open the client “\(c.clientName)” in \(AppIdentity.displayName), \
            choose Connect a Cloud App…, and approve the code you see in both places.
            """)

        switch self {
        case .anthropicAPI:
            let body = SetupJSON.object([
                ("model", .string("claude-opus-5-5")), ("max_tokens", .number(1024)),
                ("messages", .array([.object([
                    ("role", .string("user")), ("content", .string("What is on my calendar today?")),
                ])])),
                ("mcp_servers", .array([.object([
                    ("type", .string("url")), ("url", .string(c.mcpURL)), ("name", .string(c.serverKey)),
                    ("authorization_token", .string(SetupCurl.tokenSentinel)),
                ])])),
                ("tools", .array([.object([
                    ("type", .string("mcp_toolset")), ("mcp_server_name", .string(c.serverKey)),
                ])])),
            ])
            return SetupSnippet(
                kind: .shellCommand,
                text: SetupCurl.post("https://api.anthropic.com/v1/messages", headers: [
                    "content-type: application/json", "x-api-key: $ANTHROPIC_API_KEY",
                    "anthropic-version: 2023-06-01", "anthropic-beta: mcp-client-2025-11-20",
                ], body: body),
                steps: [
                    exportToken,
                    String(localized: """
                        In your own code, send the same mcp_servers entry with each request and keep the \
                        anthropic-beta header.
                        """),
                ],
                needsLiteralToken: true)

        case .managedAgents:
            let body = SetupJSON.object([
                ("display_name", .string("\(AppIdentity.displayName) (\(c.clientName))")),
                ("auth", .object([
                    ("type", .string("static_bearer")), ("mcp_server_url", .string(c.mcpURL)),
                    ("token", .string(SetupCurl.tokenSentinel)),
                ])),
            ])
            let agent = SetupJSON.object([
                ("mcp_servers", .array([.object([
                    ("type", .string("url")), ("name", .string(c.serverKey)), ("url", .string(c.mcpURL)),
                ])])),
                ("tools", .array([.object([
                    ("type", .string("mcp_toolset")), ("mcp_server_name", .string(c.serverKey)),
                ])])),
            ]).text
            return SetupSnippet(
                kind: .shellCommand,
                text: SetupCurl.post("https://api.anthropic.com/v1/vaults/$VAULT_ID/credentials", headers: [
                    "content-type: application/json", "x-api-key: $ANTHROPIC_API_KEY",
                    "anthropic-version: 2023-06-01", "anthropic-beta: managed-agents-2026-04-01",
                ], body: body),
                steps: [
                    String(localized: "Create a vault, or pick an existing one, and set VAULT_ID to its ID."),
                    exportToken,
                    String(localized: "Add the mcp_servers and tools entries below to your agent."),
                    String(localized: "Pass the vault in vault_ids when you create a session."),
                ],
                needsLiteralToken: true,
                extraSnippets: [(String(localized: "In your agent"), .json, agent)])

        case .claudeCodeCloud:
            func mcpJSON(_ headers: Bool) -> String {
                var entry: [(String, SetupJSON)] = [("type", .string("http")), ("url", .string(c.mcpURL))]
                if headers {
                    entry.append(("headers", .object([
                        ("Authorization", .string("Bearer ${\(AgentSetup.tokenEnvironmentVariable)}")),
                    ])))
                }
                return SetupJSON.object([("mcpServers", .object([(c.serverKey, .object(entry))]))]).text
            }
            return SetupSnippet(
                kind: .json, text: mcpJSON(true),
                steps: [
                    String(localized: """
                        Add this to .mcp.json at the root of the repository and commit it. It holds no \
                        token.
                        """),
                    String(localized: """
                        At claude.ai/code, edit the cloud environment and add \
                        \(AgentSetup.tokenEnvironmentVariable)=\(placeholder) under Environment variables.
                        """),
                    String(localized: "Set Network access to Custom and add \(c.host) under Allowed domains."),
                    String(localized: """
                        On Pro and Max plans, you can add an API credential for \(c.host) instead (Bearer, \
                        with the remote token as the value) and commit the version without headers.
                        """),
                ],
                needsLiteralToken: true,
                extraSnippets: [(String(localized: "With an API credential"), .json, mcpJSON(false))])

        case .cursorCloud:
            return SetupSnippet(
                kind: .values,
                text: SetupValues.lines([
                    (String(localized: "Name"), c.serverKey), (String(localized: "Type"), "HTTP"),
                    (String(localized: "URL"), c.mcpURL),
                    (String(localized: "Header"), "Authorization: Bearer \(placeholder)"),
                ]),
                steps: [
                    String(localized: "At cursor.com/agents, open the MCP menu and add a server."),
                    String(localized: "Choose HTTP and enter these values."), copyToken,
                ],
                needsLiteralToken: true)

        case .copilotAgent:
            let json = SetupJSON.object([("mcpServers", .object([(c.serverKey, .object([
                ("type", .string("http")), ("url", .string(c.mcpURL)),
                ("headers", .object([("Authorization", .string("Bearer $\(AgentSetup.copilotSecretName)"))])),
                ("tools", .strings(AgentSetup.readOnlyToolNames)),
            ]))]))]).text
            return SetupSnippet(
                kind: .json, text: json,
                steps: [
                    String(localized: """
                        In the repository on GitHub, open Settings ▸ Copilot ▸ MCP servers and paste this \
                        under MCP configuration.
                        """),
                    String(localized: """
                        Add an Agents secret named \(AgentSetup.copilotSecretName) and paste the remote token \
                        (Copy Remote Token…) as its value.
                        """),
                    String(localized: """
                        The tools list holds only the read tools. Add a write tool only if you give this \
                        client a list it may change.
                        """),
                ],
                needsLiteralToken: true)

        case .devin:
            return SetupSnippet(
                kind: .values,
                text: SetupValues.lines([
                    (String(localized: "Server name"), c.serverKey), (String(localized: "Transport"), "HTTP"),
                    (String(localized: "Server URL"), c.mcpURL),
                    (String(localized: "Authentication"), "Auth Header"),
                    (String(localized: "Header key"), "Authorization"),
                    (String(localized: "Header value"), "Bearer \(placeholder)"),
                ]),
                steps: [
                    String(localized: """
                        In Devin, open Customize ▸ MCPs, choose Add MCP, then Add custom MCP.
                        """),
                    String(localized: "Enter these values."), copyToken,
                    String(localized: "Click Test tools."),
                ],
                needsLiteralToken: true)

        case .openAIResponses:
            let body = SetupJSON.object([
                ("model", .string("gpt-6-astra")), ("input", .string("What is on my calendar today?")),
                ("tools", .array([.object([
                    ("type", .string("mcp")), ("server_label", .string(c.serverKey)),
                    ("server_url", .string(c.mcpURL)), ("authorization", .string(SetupCurl.tokenSentinel)),
                    ("allowed_tools", .strings(AgentSetup.readOnlyToolNames)),
                    ("require_approval", .string("never")),
                ])])),
            ])
            return SetupSnippet(
                kind: .shellCommand,
                text: SetupCurl.post("https://api.openai.com/v1/responses", headers: [
                    "content-type: application/json", "authorization: Bearer $OPENAI_API_KEY",
                ], body: body),
                steps: [
                    String(localized: """
                        In Terminal, set \(AgentSetup.remoteTokenEnvironmentVariable) to the remote token \
                        (Copy Remote Token…) and OPENAI_API_KEY to your API key, then run the command.
                        """),
                    String(localized: """
                        This example allows only the read tools, without approval. To use the others, \
                        remove allowed_tools and handle approval requests in your code.
                        """),
                ],
                needsLiteralToken: true)

        case .claudeAI:
            return SetupSnippet(
                kind: .values, text: c.mcpURL,
                steps: [
                    String(localized: """
                        In Claude, open Customize ▸ Connectors and click Add custom connector. On Team and \
                        Enterprise plans, an Owner adds it in Organization settings ▸ Connectors.
                        """),
                    String(localized: "Paste this URL, leave the OAuth settings as they are, and click Add."),
                    pairing,
                ])

        case .chatGPT:
            return SetupSnippet(
                kind: .values, text: c.mcpURL,
                steps: [
                    String(localized: "In ChatGPT, open Plugins, click +, then Create custom MCP server."),
                    String(localized: "Give it a name, paste this URL under Connection, and choose OAuth."),
                    pairing,
                ])

        case .geminiEnterprise:
            return SetupSnippet(
                kind: .values, text: c.mcpURL,
                steps: [
                    String(localized: """
                        In the Google Cloud console, open Gemini Enterprise ▸ Data stores ▸ Create data \
                        store and choose Custom MCP Server.
                        """),
                    String(localized: """
                        Paste this URL as the MCP server URL and choose OAuth 2.0. In \
                        \(AppIdentity.displayName), click Set Up OAuth Client… for “\(c.clientName)” and \
                        enter the Authorization URL, Token URL, Client ID, Client secret and scope it \
                        shows. Turn on Enable PKCE Support.
                        """),
                    pairing,
                ])

        case .codexCloud:
            return SetupSnippet(
                kind: .values, text: "",
                steps: [String(localized: """
                    Codex cloud tasks have no documented way to add an MCP server, so they can't reach \
                    \(AppIdentity.displayName).
                    """)])
        }
    }
}

// MARK: - Tunnels (§22.5)

enum TunnelProvider: String, CaseIterable, Identifiable {
    case tailscaleFunnel, cloudflareTunnel, ngrok, cloudflareQuick, other

    var id: String { rawValue }

    static let defaultRemotePort = 47616
    static let cloudflareTunnelName = "ek-bridge"

    var displayName: String {
        switch self {
        case .tailscaleFunnel: return String(localized: "Tailscale Funnel (recommended)")
        case .cloudflareTunnel: return String(localized: "Cloudflare Tunnel (your own domain)")
        case .ngrok: return String(localized: "ngrok")
        case .cloudflareQuick: return String(localized: "Cloudflare quick tunnel (testing only)")
        case .other: return String(localized: "Other tunnel")
        }
    }

    /// The plain name, for chips, Activity and the Test result.
    var name: String {
        switch self {
        case .tailscaleFunnel: return String(localized: "Tailscale Funnel")
        case .cloudflareTunnel: return String(localized: "Cloudflare Tunnel")
        case .ngrok: return String(localized: "ngrok")
        case .cloudflareQuick: return String(localized: "Cloudflare quick tunnel")
        case .other: return String(localized: "Other")
        }
    }

    /// Start commands, then `offCommands`, to run in order in Terminal.
    func commands(port: Int, hostname: String?) -> [String] {
        let name = Self.cloudflareTunnelName
        let start: [String]
        switch self {
        case .tailscaleFunnel:
            start = ["tailscale funnel --bg \(port)"]
        case .cloudflareTunnel:
            start = [
                "brew install cloudflared", "cloudflared tunnel login", "cloudflared tunnel create \(name)",
                "cloudflared tunnel route dns \(name) \(hostname ?? "mcp.example.com")",
                "cloudflared tunnel run \(name)",
            ]
        case .ngrok:
            start = [
                "ngrok config add-authtoken <your ngrok authtoken>",
                "ngrok http \(port) --url https://\(hostname ?? "<your-dev-domain>") --host-header=rewrite",
            ]
        case .cloudflareQuick:
            // Without the rewrite, the random trycloudflare.com Host fails the remote Host check.
            start = ["cloudflared tunnel --url http://127.0.0.1:\(port) --http-host-header 127.0.0.1:\(port)"]
        case .other:
            start = []
        }
        return start + offCommands(port: port)
    }

    /// Only Funnel keeps running in the background; the others stop with Control-C.
    func offCommands(port: Int) -> [String] {
        self == .tailscaleFunnel ? ["tailscale funnel --bg \(port) off"] : []
    }

    /// `~/.cloudflared/config.yml` for a named Cloudflare tunnel.
    func configFile(port: Int, hostname: String?) -> String? {
        guard self == .cloudflareTunnel else { return nil }
        return """
            tunnel: \(Self.cloudflareTunnelName)
            credentials-file: ~/.cloudflared/<tunnel-UUID>.json
            ingress:
              - hostname: \(hostname ?? "mcp.example.com")
                service: http://127.0.0.1:\(port)
                originRequest:
                  httpHostHeader: "127.0.0.1:\(port)"
              - service: http_status:404
            """
    }

    var steps: [String] {
        let paste = { (address: String) in
            String(localized: "Paste \(address) under Address, then click Test.")
        }
        let controlC = { (tool: String) in
            String(localized: "To turn it off, press Control-C in the Terminal window running \(tool).")
        }
        switch self {
        case .tailscaleFunnel:
            return [
                String(localized: "Install Tailscale on this Mac and sign in."),
                String(localized: """
                    In the Tailscale admin console, turn on MagicDNS and HTTPS certificates, and add the \
                    funnel node attribute to your tailnet policy.
                    """),
                String(localized: """
                    Run the first command in Terminal. Funnel prints your public address, such as \
                    https://my-mac.tail1234.ts.net.
                    """),
                paste(String(localized: "that address"))
                    + " " + String(localized: "Public DNS can take about 10 minutes the first time."),
                String(localized: "To turn it off, run the last command."),
            ]
        case .cloudflareTunnel:
            return [
                String(localized: "You need a domain on Cloudflare. The login command opens your browser."),
                String(localized: """
                    Before you run the tunnel, save the configuration as ~/.cloudflared/config.yml, with \
                    <tunnel-UUID> replaced by the ID that tunnel create printed.
                    """),
                paste(String(localized: "https:// and your hostname")), controlC("cloudflared"),
            ]
        case .ngrok:
            return [
                String(localized: """
                    Sign up at ngrok.com, then put your authtoken and your free dev domain from the \
                    dashboard into the commands.
                    """),
                paste(String(localized: "https:// and your dev domain")), controlC("ngrok"),
            ]
        case .cloudflareQuick:
            return [
                String(localized: """
                    Run the command. cloudflared prints a random https://….trycloudflare.com address.
                    """),
                paste(String(localized: "that address")), controlC("cloudflared"),
            ]
        case .other:
            return [
                String(localized: """
                    Point the tunnel at http://127.0.0.1 and the Remote Access port, never at the port \
                    local agents use.
                    """),
                String(localized: """
                    Have it rewrite Host to 127.0.0.1 and the port, or add its public hostname under \
                    Address.
                    """),
                paste(String(localized: "its HTTPS address")),
            ]
        }
    }

    var notes: [String] {
        let edge = { (provider: String) in
            String(localized: """
                TLS ends at \(provider)'s edge, so \(provider) can read the traffic, calendar data \
                included.
                """)
        }
        switch self {
        case .tailscaleFunnel:
            return [
                String(localized: """
                    TLS ends on this Mac, inside Tailscale, so the relays in between can't read the traffic.
                    """),
                String(localized: """
                    Funnel keeps the public hostname in Host, so it must match Address.
                    """),
                String(localized: "Tailscale Serve isn't enough: cloud agents aren't on your tailnet."),
                String(localized: """
                    Funnel keeps running in the background, even after a restart, until you turn it off.
                    """),
            ]
        case .cloudflareTunnel:
            return [
                edge("Cloudflare"),
                String(localized: "The configuration rewrites Host to this Mac's address."),
                String(localized: """
                    Optionally, put Cloudflare Access service tokens in front for agents that can send \
                    two extra headers, such as Cursor, Copilot and Devin.
                    """),
            ]
        case .ngrok:
            return [
                edge("ngrok"),
                String(localized: "The free plan allows 20,000 requests a month."),
                String(localized: """
                    Don't turn on ngrok's basic auth: it takes over the Authorization header that carries \
                    the token.
                    """),
                String(localized: """
                    Optionally, allow only your agent's addresses with a Traffic Policy IP restriction, \
                    for example Anthropic's 160.79.104.0/21.
                    """),
            ]
        case .cloudflareQuick:
            return [
                String(localized: """
                    For testing only: the address changes every time it starts, which breaks every cloud \
                    agent you set up.
                    """),
                edge("Cloudflare"),
            ]
        case .other:
            return [
                String(localized: "The tunnel must pass the Authorization header through unchanged."),
                String(localized: "If TLS ends at the provider's edge, the provider can read the traffic."),
            ]
        }
    }

    /// Tailscale can't rewrite Host. An unknown tunnel may not either, so ask for the hostname.
    var preservesHost: Bool { self == .tailscaleFunnel || self == .other }

    /// The request header that identifies the provider in Activity. ngrok adds none of its own, only
    /// X-Forwarded-Host, which names an ngrok domain unless you bring your own.
    var detectionHeader: String? {
        switch self {
        case .tailscaleFunnel: return "Tailscale-Funnel-Request"
        case .cloudflareTunnel, .cloudflareQuick: return "CF-Ray"
        case .ngrok: return "X-Forwarded-Host"
        case .other: return nil
        }
    }

    static let ngrokDomains = [".ngrok-free.app", ".ngrok-free.dev", ".ngrok.app", ".ngrok.dev", ".ngrok.io"]

    /// For Activity's "tunnel: …". Display only: anything on the Mac can send these headers.
    static func detect(headers: [(String, String)]) -> TunnelProvider? {
        func value(_ name: String) -> String? {
            headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1.lowercased()
        }
        let forwardedHost = value("X-Forwarded-Host") ?? ""
        if value("Tailscale-Funnel-Request") != nil { return .tailscaleFunnel }
        if value("CF-Ray") != nil {
            // A quick tunnel whose Host was rewritten looks like a named one.
            let hosts = [forwardedHost, value("Host") ?? ""].map { $0.split(separator: ":").first ?? "" }
            return hosts.contains { $0.hasSuffix(".trycloudflare.com") } ? .cloudflareQuick : .cloudflareTunnel
        }
        let bareHost = forwardedHost.split(separator: ":").first ?? ""
        if ngrokDomains.contains(where: { bareHost.hasSuffix($0) }) { return .ngrok }
        if ["X-Forwarded-For", "X-Forwarded-Host", "Forwarded"].contains(where: { value($0) != nil }) {
            return .other
        }
        return nil
    }
}

/// `curl` POSTs whose JSON body splices in the remote token from the environment, so the
/// snippet never holds it.
private enum SetupCurl {
    static let tokenSentinel = "@@EK_BRIDGE_REMOTE_TOKEN@@"

    static func post(_ url: String, headers: [String], body: SetupJSON) -> String {
        let quoted = SetupShell.singleQuoted(body.text).replacingOccurrences(
            of: "\"\(tokenSentinel)\"",
            with: "\"'\"$\(AgentSetup.remoteTokenEnvironmentVariable)\"'\"")
        let lines = ["curl \"\(url)\""] + headers.map { "  -H \"\($0)\"" } + ["  -d \(quoted)"]
        return lines.joined(separator: " \\\n")
    }
}

private enum SetupValues {
    static func lines(_ pairs: [(String, String)]) -> String {
        pairs.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
    }
}

/// Compact JSON with a fixed key order, so snippets match the goldens byte for byte.
/// Strings go through JSONSerialization; only the punctuation is assembled here.
/// Also used by one-click setup (`AgentConfigWriter`).
indirect enum SetupJSON: Equatable {
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

    /// Pretty text: `unit` per level, starting at `level` (the first line isn't indented).
    func pretty(unit: String, level: Int) -> String {
        let inner = String(repeating: unit, count: level + 1)
        let outer = String(repeating: unit, count: level)
        switch self {
        case .array(let items) where !items.isEmpty:
            // Short arrays of plain values stay on one line, as editors write them.
            if items.allSatisfy({ if case .array = $0 { false } else if case .object = $0 { false } else { true } }) {
                return "[" + items.map(\.text).joined(separator: ", ") + "]"
            }
            return "[\n" + items.map { inner + $0.pretty(unit: unit, level: level + 1) }
                .joined(separator: ",\n") + "\n" + outer + "]"
        case .object(let pairs) where !pairs.isEmpty:
            return "{\n" + pairs.map { inner + SetupJSON.string($0.0).text + ": " + $0.1.pretty(unit: unit, level: level + 1) }
                .joined(separator: ",\n") + "\n" + outer + "}"
        default:
            return text
        }
    }

    static func == (lhs: SetupJSON, rhs: SetupJSON) -> Bool { lhs.text == rhs.text }
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
