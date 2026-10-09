import Foundation

/// The checks that need nothing but the HTTP request, in the order §7.4 of
/// the plan fixes. They run on the HTTP queue, so a request that fails here
/// never reaches the main actor or the registry.
enum MCPHTTPGate {
    enum Verdict {
        case proceed(token: String)
        /// A missing or malformed token: counted as a failed authentication.
        case unauthenticated
        case respond(HTTPResponse, close: Bool)
    }

    static let path = "/mcp"
    /// Headers tunnels add. Local agents never send them, so their presence
    /// means a tunnel was pointed at the local port by mistake.
    static let forwardedHeaders = ["tailscale-funnel-request", "cf-connecting-ip", "cf-ray",
                                   "x-forwarded-host"]

    static func check(_ request: HTTPRequest, port: Int, allowedOrigins: Set<String>) -> Verdict {
        guard request.path == path else {
            return .respond(text(404, "Not found. The MCP endpoint is \(path).\n"), close: false)
        }
        // DNS rebinding defense: a page on evil.example resolving to 127.0.0.1
        // still sends Host: evil.example.
        let host = (request.header("host") ?? "").lowercased()
        guard host == "127.0.0.1:\(port)" || host == "localhost:\(port)" else {
            return .respond(HTTPResponse(status: 421), close: true)
        }
        if let origin = request.header("origin"), !allowedOrigins.contains(origin) {
            return .respond(json(403, JSONRPC.error(
                id: nil, code: JSONRPC.invalidRequest,
                message: "Requests from web pages aren't accepted.", omitID: true)), close: false)
        }
        if forwardedHeaders.contains(where: { request.header($0) != nil }) {
            return .respond(json(403, JSONRPC.error(
                id: nil, code: JSONRPC.invalidRequest,
                message: "This port is only for agents on this Mac. Point your tunnel at the "
                    + "Remote Access port in \(AppIdentity.displayName).", omitID: true)), close: false)
        }
        guard request.method == "POST" else {
            return .respond(HTTPResponse(status: 405, headers: [("Allow", "POST")]), close: false)
        }
        let contentType = (request.header("content-type") ?? "").split(separator: ";").first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard contentType == "application/json" else {
            return .respond(HTTPResponse(status: 415), close: false)
        }
        if let accept = request.header("accept") {
            let types = accept.split(separator: ",").map {
                $0.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            }
            guard types.contains(where: { ["application/json", "application/*", "*/*"].contains($0) }) else {
                return .respond(HTTPResponse(status: 406), close: false)
            }
        }
        guard let authorization = request.header("authorization"),
              authorization.count > 7, authorization.prefix(7).lowercased() == "bearer " else {
            return .unauthenticated
        }
        let token = String(authorization.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        guard ClientRegistry.validMCPToken(token) else { return .unauthenticated }
        return .proceed(token: token)
    }

    static func unauthorized() -> HTTPResponse {
        var response = json(401, JSONRPC.error(
            id: nil, code: JSONRPC.authenticationFailed,
            message: "\(AppIdentity.displayName) doesn't recognize this agent's token. "
                + "Copy the setup again from the client's page in \(AppIdentity.displayName)."))
        // No resource_metadata parameter, so clients don't start OAuth.
        response.headers.append(("WWW-Authenticate", "Bearer realm=\"\(AppIdentity.displayName)\""))
        return response
    }

    static func lockedOut(retryAfter: Int) -> HTTPResponse {
        HTTPResponse(status: 429, headers: [("Retry-After", String(retryAfter))])
    }

    static func json(_ status: Int, _ body: Data) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "application/json")], body: body)
    }

    static func text(_ status: Int, _ body: String) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "text/plain; charset=utf-8")],
                     body: Data(body.utf8))
    }
}

/// Counts only, never bodies: Settings ▸ Advanced shows them to help debug
/// agent setups without logging data.
final class MCPTrafficCounters: @unchecked Sendable {
    struct Snapshot: Equatable {
        var requests = 0
        var byStatus = [Int: Int]()
        var authFailures = 0
    }

    private let lock = NSLock()
    private var current = Snapshot()

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func record(status: Int) {
        lock.lock()
        current.requests += 1
        if status >= 400 { current.byStatus[status, default: 0] += 1 }
        lock.unlock()
    }

    func recordAuthFailure() {
        lock.lock()
        current.authFailures += 1
        lock.unlock()
    }
}

/// How one listener authenticates its callers: the local port takes local
/// MCP tokens; the Remote Access port takes remote tokens and OAuth access
/// tokens. Everything after authentication is shared.
@MainActor
struct MCPAuthentication {
    let authenticate: (String) -> Result<String, ClientRegistryError>
    /// The answer to a missing or wrong credential (may be a lockout).
    let rejected: () -> MCPServer.Reply
    let remote: Bool
}

/// The MCP protocol on top of the HTTP gate: authentication, both protocol
/// eras, and method dispatch. Stateless: no sessions are minted, so every
/// request stands alone and a restart loses nothing.
@MainActor
final class MCPServer {
    static let modernVersions = ["2026-07-28"]
    static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]
    static let legacyDefault = "2025-11-25"
    static let toolCallTimeout: TimeInterval = 55
    static let metaVersion = "io.modelcontextprotocol/protocolVersion"
    static let metaCapabilities = "io.modelcontextprotocol/clientCapabilities"
    static let metaClientInfo = "io.modelcontextprotocol/clientInfo"
    static let metaServerInfo = "io.modelcontextprotocol/serverInfo"
    static let metaClientName = "io.github.bereciartua.ekbridge/client"

    struct Reply {
        let response: HTTPResponse
        var close = false
    }

    /// The last authenticated MCP request from a client, for "Connected ·
    /// Claude Code 2.4.1 · 2 min ago". In memory only; Activity holds history.
    struct Connection: Equatable {
        let at: Date
        let agent: String?
        /// Through Remote Access rather than from this Mac.
        var remote = false
    }

    private let registry: ClientRegistry
    private let pipeline: RequestPipeline
    private let limiter: RateLimiter
    private let counters: MCPTrafficCounters
    private let zone: () -> TimeZone
    private let now: () -> Date
    private let didConnect: (String, Connection) -> Void
    private var agents = [String: String]()
    /// Keyed by client and JSON-RPC id. Two sessions of one client can reuse
    /// an id, so each key holds a list.
    private var inFlight = [String: [PipelineTicket]]()

    init(registry: ClientRegistry, pipeline: RequestPipeline, limiter: RateLimiter,
         counters: MCPTrafficCounters, zone: @escaping () -> TimeZone = { TimeZone.current },
         now: @escaping () -> Date = Date.init,
         didConnect: @escaping (String, Connection) -> Void = { _, _ in }) {
        self.registry = registry
        self.pipeline = pipeline
        self.limiter = limiter
        self.counters = counters
        self.zone = zone
        self.now = now
        self.didConnect = didConnect
    }

    /// Called on the main actor for a request that passed `MCPHTTPGate`.
    /// `whenClosed` registers work to run if the connection goes away first;
    /// it returns a closure that unregisters it.
    func handle(_ request: HTTPRequest, token: String, auth: MCPAuthentication? = nil,
                whenClosed: @escaping (@escaping @MainActor () -> Void) -> () -> Void,
                reply: @escaping (Reply) -> Void) {
        let auth = auth ?? localAuthentication
        let clientID: String
        switch auth.authenticate(token) {
        case .success(let id): clientID = id
        case .failure(.unavailable):
            reply(Reply(response: MCPHTTPGate.json(503, JSONRPC.error(
                id: nil, code: JSONRPC.internalError,
                message: "\(AppIdentity.displayName) can't read its client settings. "
                    + "Ask the user to open \(AppIdentity.displayName) and check Overview."))))
            return
        case .failure:
            reply(auth.rejected())
            return
        }
        let remote = auth.remote
        let message: JSONRPCMessage
        switch JSONRPC.parse(request.body) {
        case .success(let parsed): message = parsed
        case .failure(.parse):
            reply(error(400, nil, JSONRPC.parseError, "Parse error: the body isn't valid JSON."))
            return
        case .failure(.invalidRequestWithID(let id)):
            reply(error(400, id, JSONRPC.invalidRequest, "Invalid request."))
            return
        case .failure(.invalidRequest):
            reply(error(400, nil, JSONRPC.invalidRequest,
                        "Invalid request: send one JSON-RPC 2.0 object (batches aren't supported)."))
            return
        }
        let id: JSONRPCID?
        let method: String
        let params: [String: Any]
        switch message {
        case .response:
            reply(Reply(response: HTTPResponse(status: 202)))
            return
        case .notification(let name, let values): (id, method, params) = (nil, name, values)
        case .request(let requestID, let name, let values): (id, method, params) = (requestID, name, values)
        }

        // Era detection, per request (§8.2).
        let header = request.header("mcp-protocol-version")
        let meta = params["_meta"] as? [String: Any]
        let modern: Bool
        if let version = meta?[Self.metaVersion] {
            guard let version = version as? String, header == version else {
                reply(error(400, id, JSONRPC.headerMismatch,
                            "MCP-Protocol-Version must match _meta \(Self.metaVersion)."))
                return
            }
            guard Self.modernVersions.contains(version) else {
                reply(error(400, id, JSONRPC.unsupportedProtocolVersion,
                            "Unsupported protocol version \(version).",
                            data: ["supported": Self.modernVersions + Self.legacyVersions,
                                   "requested": version]))
                return
            }
            guard meta?[Self.metaCapabilities] is [String: Any] else {
                reply(error(400, id, JSONRPC.invalidParams,
                            "Missing _meta \(Self.metaCapabilities)."))
                return
            }
            guard request.header("mcp-method") == method else {
                reply(error(400, id, JSONRPC.headerMismatch, "Mcp-Method must match the method."))
                return
            }
            if method == "tools/call" {
                guard let name = request.header("mcp-name").flatMap(Self.decodeHeaderValue),
                      name == params["name"] as? String else {
                    reply(error(400, id, JSONRPC.headerMismatch, "Mcp-Name must match params.name."))
                    return
                }
            }
            modern = true
        } else if method == "initialize" {
            modern = false
        } else {
            if let header {
                if Self.modernVersions.contains(header) {
                    reply(error(400, id, JSONRPC.invalidParams,
                                "Protocol version \(header) requires _meta \(Self.metaVersion) "
                                    + "and \(Self.metaCapabilities) on every request."))
                    return
                }
                guard Self.legacyVersions.contains(header) else {
                    reply(error(400, id, JSONRPC.unsupportedProtocolVersion,
                                "Unsupported protocol version \(header).",
                                data: ["supported": Self.modernVersions + Self.legacyVersions,
                                       "requested": header]))
                    return
                }
            }
            modern = false
        }

        // Local and remote agents of one client are remembered apart.
        let agentKey = (remote ? "remote|" : "") + clientID
        if let info = (meta?[Self.metaClientInfo] ?? (method == "initialize" ? params["clientInfo"] : nil))
            as? [String: Any], let agent = Self.agentName(info) {
            agents[agentKey] = agent
        }
        let agent = agents[agentKey]
        didConnect(clientID, Connection(at: now(), agent: agent, remote: remote))

        guard let id else {
            // Notifications: accepted and, apart from cancellation, ignored.
            if method == "notifications/cancelled",
               let target = params["requestId"].flatMap(JSONRPCID.init(json:)) {
                inFlight[clientID + "|" + target.key]?.forEach { $0.cancel() }
            }
            reply(Reply(response: HTTPResponse(status: 202)))
            return
        }

        let finish: ([String: Any]) -> Void = { result in
            reply(self.result(id, result, modern: modern))
        }
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            finish([
                "protocolVersion": Self.legacyVersions.contains(requested) ? requested : Self.legacyDefault,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": serverInfo(full: true),
                "instructions": MCPToolCatalog.serverInstructions,
            ])
        case "server/discover":
            var result: [String: Any] = [
                "supportedVersions": Self.modernVersions + Self.legacyVersions,
                "capabilities": ["tools": [String: Any]()],
                "instructions": MCPToolCatalog.serverInstructions,
            ]
            if let name = registry.clients()?.first(where: { $0.id == clientID })?.name {
                // Lets `bridge-mcp check` name the client the token belongs to.
                result["_meta"] = [Self.metaClientName: ["name": name]]
            }
            finish(result)
        case "ping" where !modern:
            finish([:])
        case "tools/list":
            let grants = registry.clients()?.first(where: { $0.id == clientID })?.grants ?? []
            var result: [String: Any] = [
                "tools": MCPToolCatalog.visibleTools(grants: grants).map(\.definition),
            ]
            if modern {
                // The list varies by token, so it must not be shared between clients.
                result["ttlMs"] = 30_000
                result["cacheScope"] = "private"
            }
            finish(result)
        case "tools/call":
            callTool(id: id, params: params, clientID: clientID,
                     origin: remote ? .remote(agent: agent) : .mcp(agent: agent),
                     whenClosed: whenClosed, finish: finish,
                     unknownTool: { reply(self.error(200, id, JSONRPC.invalidParams, $0)) })
        default:
            reply(error(modern ? 404 : 200, id, JSONRPC.methodNotFound, "Method not found: \(method)"))
        }
    }

    private func callTool(id: JSONRPCID, params: [String: Any], clientID: String, origin: RequestOrigin,
                          whenClosed: (@escaping @MainActor () -> Void) -> () -> Void,
                          finish: @escaping ([String: Any]) -> Void,
                          unknownTool: (String) -> Void) {
        // An unknown name is a protocol error; everything after is a tool error
        // the model can act on.
        guard let name = params["name"] as? String, let tool = MCPToolCatalog.tool(named: name) else {
            unknownTool("Unknown tool: \(params["name"] as? String ?? "")")
            return
        }
        guard tool.command.isClientLevel || !tool.isWrite || MCPToolCatalog.writesEnabled else {
            finish(MCPToolMapping.errorResult(tool: name, code: "invalid_arguments",
                                              detail: MCPToolCatalog.writesDisabledMessage,
                                              request: nil, retryAfter: nil))
            return
        }
        let arguments: [String: Any]
        switch params["arguments"] {
        case nil, is NSNull: arguments = [:]
        case let object as [String: Any]: arguments = object
        default:
            finish(MCPToolMapping.errorResult(tool: name, code: "invalid_arguments",
                                              detail: "arguments: expected an object",
                                              request: nil, retryAfter: nil))
            return
        }
        // The model's typos never reach the pipeline, so they aren't Activity rows.
        if let problem = MCPToolCatalog.validate(tool, arguments) {
            finish(MCPToolMapping.errorResult(tool: name, code: "invalid_arguments", detail: problem,
                                              request: nil, retryAfter: nil))
            return
        }
        let zone = self.zone()
        let request: BridgeRequest
        switch MCPToolMapping.request(tool: name, arguments: arguments, zone: zone, now: now()) {
        case .success(let built): request = built
        case .failure(let failure):
            finish(MCPToolMapping.errorResult(tool: name, code: failure.code, detail: failure.message,
                                              request: nil, retryAfter: nil))
            return
        }
        var answered = false
        var ticket: PipelineTicket?
        var unregister: (() -> Void)?
        let key = clientID + "|" + id.key
        let answer: ([String: Any]) -> Void = { [weak self] result in
            guard !answered else { return }
            answered = true
            unregister?()
            if let self, let ticket {
                self.inFlight[key]?.removeAll { $0 === ticket }
                if self.inFlight[key]?.isEmpty == true { self.inFlight[key] = nil }
            }
            finish(result)
        }
        let started = pipeline.handle(request, clientID: clientID, origin: origin) {
            [weak self] core in
            guard let self else { return }
            answer(MCPToolMapping.toolResult(tool: name, request: request, core: core,
                                             zone: zone, now: self.now()))
        }
        guard !answered else { return }
        ticket = started
        inFlight[key, default: []].append(started)
        // A disconnect cancels: before the journal reservation nothing happens;
        // after it, the write finishes and is recorded with nobody to tell.
        unregister = whenClosed { [weak started] in started?.cancel() }
        // Answer before the agent's own 60 s timeout, so it gets our words.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.toolCallTimeout) {
            answer(MCPToolMapping.errorResult(tool: name, code: "timeout", detail: nil,
                                              request: request, retryAfter: nil))
        }
    }

    private var localAuthentication: MCPAuthentication {
        MCPAuthentication(authenticate: { [registry] in registry.authenticateMCPToken($0) },
                          rejected: { [weak self] in self?.rejectToken() ?? Reply(response: MCPHTTPGate.unauthorized()) },
                          remote: false)
    }

    private func rejectToken() -> Reply {
        counters.recordAuthFailure()
        limiter.recordFailedAuth()
        if let wait = limiter.authLockout() {
            return Reply(response: MCPHTTPGate.lockedOut(retryAfter: wait), close: true)
        }
        return Reply(response: MCPHTTPGate.unauthorized())
    }

    private func result(_ id: JSONRPCID, _ result: [String: Any], modern: Bool) -> Reply {
        var result = result
        if modern {
            // Strict legacy validators may reject unknown fields, so these are modern-only.
            result["resultType"] = "complete"
            var meta = result["_meta"] as? [String: Any] ?? [:]
            meta[Self.metaServerInfo] = serverInfo(full: false)
            result["_meta"] = meta
        }
        return Reply(response: MCPHTTPGate.json(200, JSONRPC.result(id: id, result)))
    }

    private func error(_ status: Int, _ id: JSONRPCID?, _ code: Int, _ message: String,
                       data: Any? = nil) -> Reply {
        Reply(response: MCPHTTPGate.json(status, JSONRPC.error(id: id, code: code, message: message,
                                                               data: data)))
    }

    private func serverInfo(full: Bool) -> [String: Any] {
        var info: [String: Any] = ["name": AppIdentity.mcpServerKey, "version": AppIdentity.version]
        if full {
            info["title"] = AppIdentity.displayName
            info["description"] = "Calendar and Reminders on this Mac, limited to what you granted this agent."
        }
        return info
    }

    /// "name version" as the agent reported it, sanitized; display only.
    static func agentName(_ info: [String: Any]) -> String? {
        guard let name = info["name"] as? String else { return nil }
        let version = info["version"] as? String
        return ClientRegistry.sanitizedAgent([name, version].compactMap { $0 }.joined(separator: " "))
    }

    /// `Mcp-Name` may use `=?base64?…?=` for names that aren't header-safe.
    static func decodeHeaderValue(_ value: String) -> String? {
        guard value.hasPrefix("=?base64?"), value.hasSuffix("?=") else { return value }
        let encoded = value.dropFirst(9).dropLast(2)
        return Data(base64Encoded: String(encoded)).flatMap { String(data: $0, encoding: .utf8) }
    }
}
