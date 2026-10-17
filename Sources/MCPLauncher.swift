import BridgeKitCore
import Foundation

// bridge-mcp: the stdio launcher agents run (Contents/MacOS/bridge-mcp). It's
// BridgeKitCore's launcher with EK Bridge's names, paths and wording: a dumb
// pipe to the in-app MCP server, Claude Code's headersHelper, and `check`.
// Foundation only, built with AppIdentity.

private let app = AppIdentity.displayName

/// The data folder: the endpoint file and client-credentials are inside it.
/// Test builds (-D EVENTKIT_MCP_TEST) never touch the real support folder:
/// without the override they point at a path that doesn't exist.
private let supportDirectory: @Sendable () -> String = {
    #if EVENTKIT_MCP_TEST
    return ProcessInfo.processInfo.environment["EVENTKIT_TEST_SUPPORT_DIR"]
        ?? "/var/empty/ek-bridge-test-support"
    #else
    return AppIdentity.toolDataFolder(
        inSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]).path
    #endif
}

#if EVENTKIT_MCP_TEST
// Test builds stand a plain harness binary in for the app bundle; uid and
// socket checks stay real.
private let testMode: LauncherTestMode? = LauncherTestMode(serverPathVariable: "EVENTKIT_MCP_TEST_SERVER_PATH")
#else
private let testMode: LauncherTestMode? = nil
#endif

@main
struct BridgeMCP {
    static func main() {
        BridgeLauncher.run(configuration)
    }
}

private let configuration = LauncherConfiguration(
    launcherName: AppIdentity.launcherName,
    displayName: app,
    keyPrefix: "ekb_mcp_v1_",
    supportDirectory: supportDirectory,
    keyFolderName: "client-credentials",
    agentOption: "client",
    agentMetaKey: "io.github.bereciartua.ekbridge/client",
    // Only a tool call reveals the bridge switch; list_collections is
    // read-only and always visible. It shows in Activity like any call.
    probe: LauncherProbe(tool: "list_collections") { result in
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        guard result["isError"] as? Bool == true else { return .on }
        if text.contains("(code: bridge_off)") {
            return .warning("\(app) is paused: tool calls will be refused until it's turned on")
        }
        if text.contains("(code: client_paused)") {
            return .warning("this client is paused: tool calls will be refused until it's resumed in \(app)")
        }
        return .warning("list_collections failed: \(text)")
    },
    testMode: testMode,
    texts: LauncherTexts(
        help: """
        Usage: bridge-mcp --client ID                     stdio MCP relay
               bridge-mcp --token-file PATH               stdio relay, explicit token file
               bridge-mcp headers --client ID --url URL   for Claude Code's headersHelper
               bridge-mcp check --client ID               diagnose a setup
               bridge-mcp --help | --version

        Connects an agent on this Mac to \(app)'s MCP server. The relay reads one
        JSON-RPC message per stdin line, posts it to the server and writes each reply as one
        stdout line. Problems go to stderr. Copy the setup for your agent from the connection's
        page in \(app).

        Options:
          --client ID         The client's ID (a UUID). Its token file is read from
                              ~/Library/Application Support/\(AppIdentity.dataFolderName)/client-credentials.
          --token-file PATH   Read the token from this file (mode 600) instead.
          --url URL           headers only: the URL in the agent's config. The token is
                              printed only when it's the URL the app serves and the listener
                              there is this user's \(app).
                              CLAUDE_CODE_MCP_SERVER_URL takes precedence when set.

        Exit codes:
          0  ok (relay: stdin closed)
          1  check: token rejected
          2  usage error
          3  check, headers: app or server unavailable, or another program on its port
          4  missing or unsafe token file
        headers prints {} on stdout whenever it refuses, with the reason on stderr.

        """,
        agentIDNotUUID: "--client takes the connection's ID (a UUID), not its name. "
            + "Copy the setup from the connection's page in \(app).",
        squatter: "Another program is using \(app)'s port. Open \(app) and check Settings ▸ Advanced.",
        rejected: "\(app) doesn't recognize this connection's token. "
            + "Open the connection in \(app) and check MCP access.",
        rejectedLog: "the token was rejected. Open the client in \(app) and check MCP access.",
        urlMismatch: { target, served in
            "the agent's URL \(target) isn't the one \(app) serves (\(served)). Copy the setup again from the "
                + "client's page."
        },
        agentNoun: "client",
        noTools: "no tools available: grant this client access in \(app)",
        checkRejected: "token rejected: open the client in \(app) and check MCP access"))
