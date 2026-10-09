import Foundation

/// Remote Access settings the listener needs, read on the HTTP queue.
struct RemoteConfiguration: Equatable {
    /// 22 base64url characters; the MCP endpoint is `/r/<secret>/mcp`.
    var secret: String
    /// `https://my-mac.tail1234.ts.net`, or nil until the user enters it.
    var publicOrigin: String?
    var port: Int

    var secretPrefix: String { "/r/" + secret }

    /// Hosts a tunnel may present: the public hostname (Tailscale Funnel keeps
    /// it), or this port on loopback (tunnels that rewrite Host).
    var allowedHosts: Set<String> {
        var hosts: Set<String> = ["127.0.0.1:\(port)", "localhost:\(port)"]
        if let url = publicOrigin.flatMap(URL.init(string:)), let host = url.host?.lowercased() {
            if let port = url.port {
                hosts.insert(host + ":\(port)")
                if port == 443 { hosts.insert(host) }
            } else {
                hosts.insert(host)
                hosts.insert(host + ":443")
            }
        }
        return hosts
    }

    var oauthContext: OAuthContext? {
        publicOrigin.map { OAuthContext(publicOrigin: $0, secretPrefix: secretPrefix) }
    }

    /// The URL cloud agents use, once the public address is known.
    var mcpURL: String? { publicOrigin.map { $0 + secretPrefix + "/mcp" } }

    static func newSecret() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        return bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func validSecret(_ secret: String) -> Bool {
        secret.utf8.count == 22 && secret.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    /// `https://host` with an optional port, nothing else.
    static func normalizedOrigin(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil
        else { return nil }
        return "https://" + host.lowercased() + (url.port.map { ":\($0)" } ?? "")
    }
}

/// The checks for the Remote Access port, in order: path secret (unknown
/// paths are 404 before anything else, so scanners learn nothing), Host,
/// then per-route rules. Runs on the HTTP queue.
enum RemoteHTTPGate {
    enum Verdict {
        case respond(HTTPResponse, close: Bool)
        case mcp(token: String?, address: String)
        case health(nonce: String, headers: [String], tunnel: String?)
        case oauth(address: String)
    }

    /// Headers tunnels add. Never trusted for authorization: anything on this
    /// Mac can set them. Used for display and the per-address lockout.
    static let tunnelHeaders = ["tailscale-funnel-request", "cf-ray", "cf-connecting-ip", "x-forwarded-for",
                                "x-forwarded-host", "x-forwarded-proto"]

    static func check(_ request: HTTPRequest, configuration: RemoteConfiguration) -> Verdict {
        let path = request.path
        let prefix = configuration.secretPrefix
        let route: String
        if path.hasPrefix("/.well-known/") {
            // Discovery documents insert the issuer path after the well-known name.
            guard let range = path.range(of: "/r/"), secretMatches(path[range.lowerBound...], prefix) else {
                return .respond(notFound(), close: false)
            }
            route = "oauth"
        } else if secretMatches(path[...], prefix) {
            let rest = String(path.dropFirst(prefix.count))
            switch rest {
            case "/mcp": route = "mcp"
            case "/health": route = "health"
            default:
                guard rest.hasPrefix("/oauth/") || rest == "/.well-known/openid-configuration" else {
                    return .respond(notFound(), close: false)
                }
                route = "oauth"
            }
        } else {
            return .respond(notFound(), close: false)
        }
        let host = (request.header("host") ?? "").lowercased()
        guard configuration.allowedHosts.contains(host) else {
            return .respond(HTTPResponse(status: 421), close: true)
        }
        let address = forwardedAddress(request)
        switch route {
        case "health":
            guard request.method == "GET",
                  let nonce = query(request.target)["nonce"], !nonce.isEmpty, nonce.utf8.count <= 64 else {
                return .respond(notFound(), close: false)
            }
            // Detected from the full headers: ngrok and quick tunnels are told apart by host values.
            let tunnel = TunnelProvider.detect(headers: request.headers.map { ($0.name, $0.value) })?.name
            return .health(nonce: nonce, headers: tunnelHeaders.filter { request.header($0) != nil },
                           tunnel: tunnel)
        case "oauth":
            return .oauth(address: address)
        default:
            break
        }
        if request.header("origin") != nil {
            return .respond(MCPHTTPGate.json(403, JSONRPC.error(
                id: nil, code: JSONRPC.invalidRequest,
                message: "Requests from web pages aren't accepted.", omitID: true)), close: false)
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
            return .mcp(token: nil, address: address)
        }
        return .mcp(token: String(authorization.dropFirst(7)).trimmingCharacters(in: .whitespaces),
                    address: address)
    }

    /// The caller's address as the tunnel reported it, for the lockout key and
    /// display only. Tailscale Funnel, Cloudflare and ngrok all append the
    /// address they saw to `X-Forwarded-For`, so its last entry is the one the
    /// caller can't choose; `CF-Connecting-IP` passes through Funnel and ngrok
    /// as sent, so it's used only without `X-Forwarded-For`.
    static func forwardedAddress(_ request: HTTPRequest) -> String {
        if let forwarded = request.header("x-forwarded-for")?.split(separator: ",").last
            .map({ $0.trimmingCharacters(in: .whitespaces) }), validAddress(forwarded) {
            return forwarded
        }
        if let cloudflare = request.header("cf-connecting-ip"), validAddress(cloudflare) { return cloudflare }
        return "unknown"
    }

    private static func validAddress(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 45 &&
            text.allSatisfy { $0.isHexDigit || $0 == "." || $0 == ":" }
    }

    /// Compares the secret segment without stopping at the first difference.
    private static func secretMatches(_ path: Substring, _ prefix: String) -> Bool {
        let candidate = Array(path.utf8.prefix(prefix.utf8.count))
        let expected = Array(prefix.utf8)
        guard candidate.count == expected.count else { return false }
        if path.utf8.count > expected.count, path.utf8[path.utf8.index(path.utf8.startIndex,
                                                                        offsetBy: expected.count)] != 47 {
            return false
        }
        var difference: UInt8 = 0
        for index in 0..<expected.count { difference |= candidate[index] ^ expected[index] }
        return difference == 0
    }

    static func query(_ target: String) -> [String: String] {
        guard let mark = target.firstIndex(of: "?") else { return [:] }
        var result = [String: String]()
        for pair in target[target.index(after: mark)...].split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let name = parts.first?.removingPercentEncoding else { continue }
            result[name] = parts.count > 1 ? parts[1].replacingOccurrences(of: "+", with: " ")
                .removingPercentEncoding : ""
        }
        return result
    }

    static func notFound() -> HTTPResponse { MCPHTTPGate.text(404, "Not found.\n") }
}

/// Nonces issued for the Remote Access page ▸ Test. The health endpoint
/// answers only for a nonce issued in the last 30 seconds, which proves the
/// public URL reaches this app. Thread-safe.
final class RemoteNonces: @unchecked Sendable {
    private let lock = NSLock()
    private var issued = [String: Date]()

    func issue() -> String {
        let nonce = RemoteConfiguration.newSecret()
        lock.lock()
        issued = issued.filter { Date().timeIntervalSince($0.value) < 30 }
        issued[nonce] = Date()
        lock.unlock()
        return nonce
    }

    func consume(_ nonce: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let at = issued.removeValue(forKey: nonce) else { return false }
        return Date().timeIntervalSince(at) < 30
    }
}

/// The last 50 remote requests' tunnel and forwarded address, in memory
/// only, for Activity's inspector. Never written to disk.
struct RemoteRequestNote: Equatable {
    let at: Date
    let clientID: String
    let tunnel: String?
    let address: String
}

/// Runs the Remote Access listener (§22.3): a second loopback port that only
/// a tunnel should reach, with its own credentials and stricter limits.
@MainActor
final class RemoteMCPService {
    enum Status: Equatable {
        case off
        case starting
        case listening(port: Int)
        case failed(LoopbackHTTPServer.Failure)
    }

    private(set) var status = Status.off {
        didSet { if status != oldValue { statusChanged(status) } }
    }
    var statusChanged: (Status) -> Void = { _ in }
    /// Called on the main actor for each authenticated remote request.
    var didServe: (RemoteRequestNote) -> Void = { _ in }

    let nonces = RemoteNonces()
    private let server: MCPServer
    private let registry: ClientRegistry
    private let limiter: RateLimiter
    private let counters: MCPTrafficCounters
    private let oauth: OAuthServer?
    private let configurationBox = Box()
    private var listener: LoopbackHTTPServer?
    private var generation = 0

    init(server: MCPServer, registry: ClientRegistry, limiter: RateLimiter, counters: MCPTrafficCounters,
         oauth: OAuthServer?) {
        self.server = server
        self.registry = registry
        self.limiter = limiter
        self.counters = counters
        self.oauth = oauth
    }

    var configuration: RemoteConfiguration? { configurationBox.value }

    /// Applies new settings without restarting when only the address or
    /// secret changed.
    func update(_ configuration: RemoteConfiguration) {
        let restart = configurationBox.value?.port != configuration.port
        configurationBox.value = configuration
        if restart && listener != nil { start(configuration) }
    }

    func start(_ configuration: RemoteConfiguration) {
        stopListener()
        configurationBox.value = configuration
        generation += 1
        let current = generation
        let listener = LoopbackHTTPServer(port: configuration.port, handler: makeHandler())
        self.listener = listener
        status = .starting
        listener.start { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                switch state {
                case .ready(let port):
                    // The Host check uses the port actually bound (0 picks one in tests).
                    self.configurationBox.value?.port = port
                    self.status = .listening(port: port)
                case .failed(let failure):
                    self.stopListener()
                    self.status = .failed(failure)
                case .stopped, .starting: break
                }
            }
        }
    }

    func stop() {
        stopListener()
        status = .off
    }

    private func stopListener() {
        generation += 1
        listener?.stop()
        listener = nil
    }

    private func makeHandler() -> LoopbackHTTPServer.Handler {
        let box = configurationBox
        let limiter = limiter
        let counters = counters
        let nonces = nonces
        return { [weak self] request, connection, reply in
            let send: (HTTPResponse, Bool) -> Void = { response, close in
                counters.record(status: response.status)
                reply(response, close)
            }
            guard let configuration = box.value else { return send(RemoteHTTPGate.notFound(), true) }
            switch RemoteHTTPGate.check(request, configuration: configuration) {
            case .respond(let response, let close):
                send(response, close)
            case .health(let nonce, let headers, let tunnel):
                guard nonces.consume(nonce) else { return send(RemoteHTTPGate.notFound(), false) }
                let body: [String: Any] = ["ok": true, "nonce": nonce, "headers": headers,
                                           "tunnel": tunnel ?? NSNull()]
                send(MCPHTTPGate.json(200, JSONRPC.encode(body)), false)
            case .oauth:
                // No lockout here: these endpoints take no guessable secret (codes and tokens carry
                // 256 bits), and a lockout keyed on a forwarded address would let anyone block
                // token refreshes for everybody.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, let oauth = self.oauth, let context = configuration.oauthContext,
                              oauth.handle(request, context: context, reply: { send($0, false) }) else {
                            send(RemoteHTTPGate.notFound(), false)
                            return
                        }
                    }
                }
            case .mcp(let token, let address):
                // Under lockout, refuse requests without a plausible credential off the main actor.
                // A well-formed token is always checked, so a locked-out address (which a caller can
                // claim for someone else) never blocks an agent with valid credentials.
                let plausible = token.map {
                    ClientRegistry.validRemoteToken($0)
                        || OAuthServer.validToken($0, prefix: OAuthServer.accessPrefix)
                } ?? false
                if !plausible, let wait = limiter.remoteAuthLockout(address) {
                    counters.recordAuthFailure()
                    return send(MCPHTTPGate.lockedOut(retryAfter: wait), true)
                }
                let tunnel = TunnelProvider.detect(headers: request.headers.map { ($0.name, $0.value) })?
                    .name
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        let auth = self.authentication(configuration: configuration, address: address,
                                                       tunnel: tunnel)
                        self.server.handle(request, token: token ?? "", auth: auth, whenClosed: { action in
                            connection.whenClosed { DispatchQueue.main.async { MainActor.assumeIsolated(action) } }
                        }, reply: { send($0.response, $0.close) })
                    }
                }
            }
        }
    }

    /// Remote tokens and OAuth access tokens. Local MCP tokens are refused
    /// here, so a token leaked from an agent config on this Mac is useless
    /// from the internet.
    private func authentication(configuration: RemoteConfiguration, address: String,
                                tunnel: String?) -> MCPAuthentication {
        MCPAuthentication(authenticate: { [weak self] token in
            guard let self else { return .failure(.unavailable) }
            let result: Result<String, ClientRegistryError>
            if ClientRegistry.validRemoteToken(token) {
                result = self.registry.authenticateRemoteToken(token)
            } else if token.hasPrefix(OAuthServer.accessPrefix), let oauth = self.oauth,
                      let resource = configuration.oauthContext?.resource,
                      let clientID = oauth.authenticate(accessToken: token, resource: resource) {
                result = .success(clientID)
            } else {
                self.registry.recordFailedRemoteAuth()
                result = .failure(.unauthorized)
            }
            if case .success(let clientID) = result {
                self.didServe(RemoteRequestNote(at: Date(), clientID: clientID, tunnel: tunnel, address: address))
            }
            return result
        }, rejected: { [weak self] in
            self?.counters.recordAuthFailure()
            self?.limiter.recordFailedRemoteAuth(address)
            if let wait = self?.limiter.remoteAuthLockout(address) {
                return MCPServer.Reply(response: MCPHTTPGate.lockedOut(retryAfter: wait), close: true)
            }
            return MCPServer.Reply(response: Self.unauthorized(configuration))
        }, remote: true)
    }

    /// 401 for the remote endpoint. With a public address, the challenge
    /// names the protected-resource metadata so OAuth clients can start.
    static func unauthorized(_ configuration: RemoteConfiguration) -> HTTPResponse {
        var response = MCPHTTPGate.json(401, JSONRPC.error(
            id: nil, code: JSONRPC.authenticationFailed,
            message: "\(AppIdentity.displayName) doesn't recognize this credential. Use the client's remote "
                + "token or connect the app again from the client's Cloud section."))
        let challenge = configuration.oauthContext.map(OAuthServer.challenge)
            ?? "Bearer realm=\"\(AppIdentity.displayName)\""
        response.headers.append(("WWW-Authenticate", challenge))
        return response
    }
}

/// The configuration, read from the HTTP queue.
private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: RemoteConfiguration?

    var value: RemoteConfiguration? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
