import Foundation

// EK Bridge on BridgeKitCore: its names, wording and limits, and adapters
// from its registry, tool catalog and pipeline to the core's seams. The MCP
// protocol, HTTP, keys and limits live in BridgeKitCore; everything about
// calendars, reminders, grants and approvals stays here.

enum EKBridgeMCP {
    /// `server/discover` names the client a token belongs to under this key.
    static let clientMetaKey = "io.github.bereciartua.ekbridge/client"
    /// Answer before the agent's own 60 s timeout, so it gets our words.
    static let toolCallTimeout: TimeInterval = 55

    static func configuration(allowedOrigins: Set<String> = []) -> BridgeConfiguration {
        let app = AppIdentity.displayName
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return BridgeConfiguration(
            identity: BridgeIdentity(displayName: app, bundleID: AppIdentity.bundleID,
                                     dataFolder: AppIdentity.dataFolder(inSupport: support),
                                     version: AppIdentity.version),
            mcpPort: MCPDefaults.port, keyPrefix: ClientRegistry.mcpTokenPrefix,
            serverKey: AppIdentity.mcpServerKey, launcherName: AppIdentity.launcherName,
            serverDescription: "Calendar and Reminders on this Mac, limited to what you granted this agent.",
            agentMetaKey: clientMetaKey, toolCallTimeout: toolCallTimeout, allowedOrigins: allowedOrigins,
            texts: BridgeTexts(
                unavailable: "\(app) can't read its client settings. "
                    + "Ask the user to open \(app) and check Overview.",
                unauthorized: "\(app) doesn't recognize this agent's token. "
                    + "Copy the setup again from the connection's page in \(app).",
                tunnelRefused: "This port is only for agents on this Mac. Point your tunnel at the "
                    + "Remote Access port in \(app)."))
    }

    /// A registry answer as the core sees it; the client's name is for `bridge-mcp check`.
    @MainActor
    static func outcome(_ result: Result<String, ClientRegistryError>,
                        registry: ClientRegistry) -> AuthenticationOutcome {
        switch result {
        case .success(let id):
            return .authenticated(AuthenticatedAgent(id: id, name: registry.clients()?.first { $0.id == id }?.name))
        case .failure(.unavailable): return .unavailable
        case .failure: return .rejected
        }
    }
}

/// Local MCP tokens, checked against the registry's digests.
@MainActor
final class RegistryAuthenticator: AgentAuthenticator {
    private let registry: ClientRegistry

    init(registry: ClientRegistry) { self.registry = registry }

    func authenticate(_ key: PresentedKey) async -> AuthenticationOutcome {
        EKBridgeMCP.outcome(registry.authenticateMCPToken(key.value), registry: registry)
    }
}

/// The twelve tools of `MCPToolCatalog`, shown per the client's saved grants.
@MainActor
final class CatalogTools: ToolRegistry {
    private let registry: ClientRegistry

    init(registry: ClientRegistry) { self.registry = registry }

    var serverInstructions: String { MCPToolCatalog.serverInstructions }

    func tool(named name: String) -> ToolDefinition? {
        MCPToolCatalog.tool(named: name).map { ToolDefinition(name: $0.name, definition: $0.definition) }
    }

    func visibleTools(for agent: AuthenticatedAgent) -> [ToolDefinition] {
        let grants = registry.clients()?.first(where: { $0.id == agent.id })?.grants ?? []
        return MCPToolCatalog.visibleTools(grants: grants).map { ToolDefinition(name: $0.name, definition: $0.definition) }
    }

    func failureResult(_ failure: ToolFailure, tool: String, arguments: [String: Any]?) -> ToolResult {
        switch failure {
        case .invalidArguments(let detail):
            return ToolResult(MCPToolMapping.errorResult(tool: tool, code: "invalid_arguments", detail: detail,
                                                         request: nil, retryAfter: nil))
        case .timeout:
            // Only before the pipeline has a request; the handler sets its own.
            return ToolResult(MCPToolMapping.errorResult(tool: tool, code: "timeout", detail: nil,
                                                         request: nil, retryAfter: nil))
        }
    }
}

/// A validated call: mapped to a core request, then through RequestPipeline
/// (bridge switch, grants, policy, limits, approvals, journal, Activity).
@MainActor
final class PipelineHandler: BridgeHandler {
    private let pipeline: RequestPipeline
    private let zone: () -> TimeZone
    private let now: () -> Date

    init(pipeline: RequestPipeline, zone: @escaping () -> TimeZone, now: @escaping () -> Date) {
        self.pipeline = pipeline
        self.zone = zone
        self.now = now
    }

    func handle(_ call: ToolCall) async -> ToolResult {
        let name = call.name
        guard let tool = MCPToolCatalog.tool(named: name),
              tool.command.isClientLevel || !tool.isWrite || MCPToolCatalog.writesEnabled else {
            return ToolResult(MCPToolMapping.errorResult(tool: name, code: "invalid_arguments",
                                                         detail: MCPToolCatalog.writesDisabledMessage,
                                                         request: nil, retryAfter: nil))
        }
        let zone = self.zone()
        let request: BridgeRequest
        switch MCPToolMapping.request(tool: name, arguments: call.arguments, zone: zone, now: now()) {
        case .success(let built): request = built
        case .failure(let failure):
            return ToolResult(MCPToolMapping.errorResult(tool: name, code: failure.code, detail: failure.message,
                                                         request: nil, retryAfter: nil))
        }
        // A timeout names the idempotency key this request carries.
        call.context.timeoutResult = ToolResult(MCPToolMapping.errorResult(
            tool: name, code: "timeout", detail: nil, request: request, retryAfter: nil))
        let origin: RequestOrigin = call.remote ? .remote(agent: call.agentName) : .mcp(agent: call.agentName)
        return await withCheckedContinuation { continuation in
            var resumed = false
            let ticket = pipeline.handle(request, clientID: call.agent.id, origin: origin) { [weak self] core in
                guard !resumed else { return }
                resumed = true
                let now = self?.now() ?? Date()
                continuation.resume(returning: ToolResult(MCPToolMapping.toolResult(
                    tool: name, request: request, core: core, zone: zone, now: now)))
            }
            // A disconnect cancels: before the journal reservation nothing
            // happens; after it, the write finishes and is recorded with nobody to tell.
            call.context.onCancel { [weak ticket] in ticket?.cancel() }
        }
    }
}

extension MCPServer {
    /// EK Bridge's server: its configuration, registry, catalog and pipeline.
    convenience init(registry: ClientRegistry, pipeline: RequestPipeline, limiter: RateLimiter,
                     counters: MCPTrafficCounters, allowedOrigins: Set<String> = [],
                     zone: @escaping () -> TimeZone = { TimeZone.current }, now: @escaping () -> Date = Date.init,
                     didConnect: @escaping (String, Connection) -> Void = { _, _ in }) {
        self.init(configuration: EKBridgeMCP.configuration(allowedOrigins: allowedOrigins),
                  authenticator: RegistryAuthenticator(registry: registry),
                  tools: CatalogTools(registry: registry),
                  handler: PipelineHandler(pipeline: pipeline, zone: zone, now: now),
                  limiter: limiter, counters: counters, now: now, didConnect: didConnect)
    }

    static var toolCallTimeout: TimeInterval { EKBridgeMCP.toolCallTimeout }
}

extension MCPHTTPGate {
    static var forwardedHeaders: [String] { defaultForwardedHeaders }

    static func check(_ request: HTTPRequest, port: Int, allowedOrigins: Set<String>) -> Verdict {
        check(request, port: port, configuration: EKBridgeMCP.configuration(allowedOrigins: allowedOrigins))
    }

    static func unauthorized() -> HTTPResponse { unauthorized(EKBridgeMCP.configuration()) }
}
