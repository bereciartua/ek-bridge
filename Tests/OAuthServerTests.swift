import CryptoKit
import Darwin
import Foundation

@main
struct OAuthServerTests {
    static func main() {
        MainActor.assumeIsolated { run() }
    }

    @MainActor
    final class FakeFetcher: CIMDFetching {
        var documents = [String: Result<ClientMetadata, CIMDError>]()
        var fetched = [URL]()
        /// When set, completions wait in `held` until the test releases them.
        var hold = false
        var held = [() -> Void]()

        func fetch(_ url: URL, completion: @escaping (Result<ClientMetadata, CIMDError>) -> Void) {
            fetched.append(url)
            let result = documents[url.absoluteString] ?? .failure(.httpStatus(404))
            if hold { held.append { completion(result) } } else { completion(result) }
        }
    }

    @MainActor
    final class Harness {
        let directory: URL
        let fetcher = FakeFetcher()
        var clock = Date(timeIntervalSince1970: 2_000_000_000)
        var allowed: Set<String> = [clientA, clientB]
        var requested = [PairingRequest]()
        var pairingChanges = 0
        var changedClients = [String]()
        var server: OAuthServer!

        init(directory: URL) {
            self.directory = directory
            restart()
        }

        func restart() {
            server = OAuthServer(directory: directory, fetcher: fetcher,
                                 now: { [unowned self] in self.clock },
                                 clientAllowed: { [unowned self] in self.allowed.contains($0) },
                                 clientName: { $0 == clientA ? "claude.ai (Martin)" : "Other client" },
                                 schedule: { _, _ in })
            server.pairingRequested = { [unowned self] in self.requested.append($0) }
            server.pairingChanged = { [unowned self] in self.pairingChanges += 1 }
            server.connectionsChanged = { [unowned self] in self.changedClients.append($0) }
        }

        func advance(_ seconds: TimeInterval) { clock = clock.addingTimeInterval(seconds) }

        /// The reply, which must arrive synchronously (the fake fetcher answers at once unless held).
        func send(_ request: HTTPRequest) -> HTTPResponse {
            var reply: HTTPResponse?
            let handled = server.handle(request, context: context) { reply = $0 }
            precondition(handled, "unhandled \(request.target)")
            return reply!
        }

        func get(_ path: String, _ query: [(String, String)] = []) -> HTTPResponse {
            send(request("GET", path + encodeQuery(query)))
        }

        func post(_ path: String, _ form: [(String, String)],
                  headers: [(String, String)] = []) -> HTTPResponse {
            send(request("POST", path, body: Data(encodeQuery(form).dropFirst().utf8),
                         headers: [("content-type", "application/x-www-form-urlencoded")] + headers))
        }

        func status(_ id: UUID) -> HTTPResponse {
            get(prefix + "/oauth/authorize/status", [("request", id.uuidString)])
        }

        func authorize(clientID: String = cimdURL, redirect: String = redirectURI,
                       challenge: String? = nil, omit: Set<String> = [],
                       extra: [(String, String)] = []) -> HTTPResponse {
            let base: [(String, String)] = [
                ("response_type", "code"), ("client_id", clientID), ("redirect_uri", redirect),
                ("code_challenge", challenge ?? s256(verifier)), ("code_challenge_method", "S256"),
                ("state", "st-1"), ("resource", resource), ("scope", "calendar"),
            ]
            return get(prefix + "/oauth/authorize", base.filter { !omit.contains($0.0) } + extra)
        }

        /// Authorize → Allow → the code from the redirect the browser page receives.
        func pairedCode(clientID: String = cimdURL, redirect: String = redirectURI) -> String {
            let page = authorize(clientID: clientID, redirect: redirect)
            precondition(page.status == 200, "authorize \(page.status) \(text(page))")
            let pending = server.pendingPairings.last!
            server.answerPairing(pending.id, allow: true)
            let status = json(get(prefix + "/oauth/authorize/status", [("request", pending.id.uuidString)]))
            let items = queryItems(status["redirect"] as! String)
            precondition(items["state"] == "st-1" && items["iss"] == issuer)
            return items["code"]!
        }

        func exchange(_ code: String, clientID: String = cimdURL, verifier: String = verifier,
                      redirect: String = redirectURI) -> HTTPResponse {
            post(prefix + "/oauth/token", [
                ("grant_type", "authorization_code"), ("code", code), ("client_id", clientID),
                ("redirect_uri", redirect), ("code_verifier", verifier), ("resource", resource),
            ])
        }

        func refresh(_ token: String, clientID: String = cimdURL) -> HTTPResponse {
            post(prefix + "/oauth/token", [
                ("grant_type", "refresh_token"), ("refresh_token", token), ("client_id", clientID),
            ])
        }

        /// A full connection for client A: (access, refresh).
        func connect(clientID: String = cimdURL, redirect: String = redirectURI) -> (String, String) {
            openWindow()
            let response = exchange(pairedCode(clientID: clientID, redirect: redirect), clientID: clientID,
                                    redirect: redirect)
            precondition(response.status == 200, text(response))
            let body = json(response)
            return (body["access_token"] as! String, body["refresh_token"] as! String)
        }

        func openWindow(_ client: String = clientA) { server.openPairing(clientID: client) }
    }

    static let clientA = "0B0F2C1E-8C55-4C5B-9F59-3A2C1E5D7A11"
    static let clientB = "7E2D1C3B-4A59-4F6E-8D7C-6B5A4F3E2D1C"
    static let secret = "AbCdEfGhIjKlMnOpQrStUv"
    static let prefix = "/r/" + secret
    static let origin = "https://my-mac.tail1234.ts.net"
    static let issuer = origin + prefix
    static let resource = issuer + "/mcp"
    static let context = OAuthContext(publicOrigin: origin, secretPrefix: prefix)
    static let cimdURL = "https://claude.ai/oauth/mcp-oauth-client-metadata"
    static let redirectURI = "https://claude.ai/api/mcp/auth_callback"
    static let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk-abc"

    @MainActor
    static func run() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eventkit-oauth-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        precondition(mkdir(root.path, 0o700) == 0)
        var cases = 0
        func fresh() -> Harness {
            cases += 1
            let harness = Harness(directory: root.appendingPathComponent("case-\(cases)"))
            harness.fetcher.documents[cimdURL] = .success(ClientMetadata(
                clientID: cimdURL, clientName: "Claude", redirectURIs: [redirectURI],
                clientURI: "https://claude.ai"))
            return harness
        }

        discovery(fresh())
        authorizeOutsideWindow(fresh())
        cimd(fresh())
        authorizeErrors(fresh())
        pkce(fresh())
        codes(fresh())
        tokens(fresh())
        refreshRotation(fresh())
        refreshRetry(fresh())
        refreshRetryAfterUse(fresh())
        staleResource(fresh())
        refreshExpiry(fresh())
        revocation(fresh())
        pairingWindow(fresh())
        escaping(fresh())
        dcr(fresh())
        confidential(fresh())
        persistence(fresh())
        unsafeStore(root.appendingPathComponent("unsafe"))
        print("OAuth server: discovery, pairing, CIMD, DCR, PKCE, codes, tokens, refresh rotation, "
            + "revocation, confidential clients, escaping, persistence and fail-closed storage passed")
    }

    // MARK: Cases

    @MainActor
    static func discovery(_ h: Harness) {
        let prm = h.get("/.well-known/oauth-protected-resource" + prefix + "/mcp")
        precondition(prm.status == 200 && header(prm, "content-type") == "application/json")
        precondition(header(prm, "cache-control") == "no-store")
        let prmBody = json(prm)
        precondition(Set(prmBody.keys) == ["resource", "authorization_servers", "scopes_supported",
                                           "bearer_methods_supported"])
        precondition(prmBody["resource"] as? String == resource)
        precondition(prmBody["authorization_servers"] as? [String] == [issuer])
        precondition(prmBody["scopes_supported"] as? [String] == ["calendar"])
        precondition(prmBody["bearer_methods_supported"] as? [String] == ["header"])
        precondition(text(prm).contains("\"https://my-mac.tail1234.ts.net/r/"), "slashes unescaped")
        let paths = ["/.well-known/oauth-authorization-server" + prefix,
                     "/.well-known/openid-configuration" + prefix,
                     prefix + "/.well-known/openid-configuration"]
        for path in paths {
            let body = json(h.get(path))
            precondition(Set(body.keys) == [
                "issuer", "authorization_endpoint", "token_endpoint", "registration_endpoint",
                "revocation_endpoint", "response_types_supported", "grant_types_supported",
                "code_challenge_methods_supported", "token_endpoint_auth_methods_supported",
                "client_id_metadata_document_supported", "authorization_response_iss_parameter_supported",
                "scopes_supported"])
            precondition(body["issuer"] as? String == issuer)
            precondition(body["authorization_endpoint"] as? String == issuer + "/oauth/authorize")
            precondition(body["token_endpoint"] as? String == issuer + "/oauth/token")
            precondition(body["registration_endpoint"] as? String == issuer + "/oauth/register")
            precondition(body["revocation_endpoint"] as? String == issuer + "/oauth/revoke")
            precondition(body["response_types_supported"] as? [String] == ["code"])
            precondition(body["grant_types_supported"] as? [String]
                == ["authorization_code", "refresh_token"])
            precondition(body["code_challenge_methods_supported"] as? [String] == ["S256"])
            precondition(body["token_endpoint_auth_methods_supported"] as? [String] == ["none"])
            precondition(body["client_id_metadata_document_supported"] as? Bool == true)
            precondition(body["authorization_response_iss_parameter_supported"] as? Bool == true)
            precondition(body["scopes_supported"] as? [String] == ["calendar"])
        }
        precondition(OAuthServer.challenge(context) == "Bearer resource_metadata=\"" + origin
            + "/.well-known/oauth-protected-resource" + prefix + "/mcp\", scope=\"calendar\"")
        precondition(context.resourceMetadataURL == origin + "/.well-known/oauth-protected-resource"
            + prefix + "/mcp")
        // Never at root paths, never for traversal, encodings, case variants or another secret.
        for path in ["/.well-known/oauth-protected-resource", "/.well-known/oauth-authorization-server",
                     "/.well-known/openid-configuration", "/oauth/authorize", "/oauth/token",
                     prefix + "/oauth/../oauth/token", prefix + "%2Foauth%2Ftoken", prefix + "/oauth/token/",
                     prefix + "//oauth/token", prefix.uppercased() + "/oauth/token",
                     "/r/AbCdEfGhIjKlMnOpQrStUw/oauth/token", prefix + "/mcp", prefix + "/oauth/authorize/"] {
            var called = false
            precondition(!h.server.handle(request("GET", path), context: context) { _ in called = true })
            precondition(!called, path)
        }
        // A malformed secret prefix (empty, short) never exposes anything.
        for bad in ["", "/r/short", "/r/AbCdEfGhIjKlMnOpQrSt/v", "/x/AbCdEfGhIjKlMnOpQrStUv"] {
            let badContext = OAuthContext(publicOrigin: origin, secretPrefix: bad)
            precondition(!h.server.handle(request("GET", "/.well-known/oauth-authorization-server" + bad),
                                          context: badContext) { _ in })
            precondition(!h.server.handle(request("POST", bad + "/oauth/token"),
                                          context: badContext) { _ in })
        }
        let wrongMethod = h.send(request("POST", "/.well-known/oauth-authorization-server" + prefix))
        precondition(wrongMethod.status == 405 && header(wrongMethod, "allow") == "GET")
        let getToken = h.get(prefix + "/oauth/token")
        precondition(getToken.status == 405 && header(getToken, "allow") == "POST")
        precondition(h.send(request("DELETE", prefix + "/oauth/revoke")).status == 405)
        precondition(h.send(request("POST", prefix + "/oauth/authorize")).status == 405)
        precondition(h.send(request("OPTIONS", prefix + "/oauth/register")).status == 405)
        // Never CORS, whatever the Origin.
        let withOrigin = h.send(request("GET", "/.well-known/oauth-authorization-server" + prefix,
                                        headers: [("origin", "https://evil.example")]))
        precondition(!withOrigin.headers.contains { $0.name.lowercased().hasPrefix("access-control-") })
    }

    @MainActor
    static func authorizeOutsideWindow(_ h: Harness) {
        let page = h.authorize()
        precondition(page.status == 403 && text(page).contains("Pairing isn’t open"))
        precondition(text(page).contains("choose Connect a Cloud App"))
        precondition(h.fetcher.fetched.isEmpty, "nothing is fetched outside a window")
        precondition(h.requested.isEmpty && h.server.pendingPairings.isEmpty)
        precondition(header(page, "location") == nil)
        checkPageHeaders(page)
        // Closing ends it too.
        h.openWindow()
        precondition(h.server.pairingClientID == clientA)
        h.server.closePairing()
        precondition(h.server.pairingClientID == nil && h.authorize().status == 403)
    }

    @MainActor
    static func cimd(_ h: Harness) {
        h.openWindow()
        precondition(h.server.pairingClientID == clientA)
        precondition(h.server.pairingExpiresAt == h.clock.addingTimeInterval(600))
        let page = h.authorize()
        precondition(page.status == 200, text(page))
        checkPageHeaders(page)
        precondition(h.fetcher.fetched.map(\.absoluteString) == [cimdURL])
        precondition(h.requested.count == 1 && h.server.pendingPairings == h.requested)
        let pairing = h.requested[0]
        precondition(pairing.clientID == clientA && pairing.appName == "Claude" && pairing.appURL == cimdURL)
        precondition(pairing.redirectHost == "claude.ai")
        precondition(pairing.expiresAt == h.clock.addingTimeInterval(300))
        let digits = pairing.code.split(separator: " ")
        precondition(digits.count == 2 && digits.allSatisfy { $0.count == 3 && $0.allSatisfy(\.isNumber) })
        let html = text(page)
        precondition(html.contains(pairing.code) && html.contains("claude.ai (Martin)"))
        precondition(html.contains("data-request=\"\(pairing.id.uuidString.lowercased())\""))
        precondition(html.contains("authorize/status?request="))
        let status = json(h.get(prefix + "/oauth/authorize/status", [("request", pairing.id.uuidString)]))
        precondition(status["status"] as? String == "pending" && status["redirect"] == nil)
        precondition(json(h.status(UUID()))["status"] as? String == "expired")

        // The document must name the URL it came from; unknown redirect URIs never redirect.
        let other = "https://evil.example/client.json"
        h.fetcher.documents[other] = .success(ClientMetadata(
            clientID: cimdURL, clientName: "Claude", redirectURIs: ["https://evil.example/cb"],
            clientURI: nil))
        let mismatch = h.authorize(clientID: other, redirect: "https://evil.example/cb")
        precondition(mismatch.status == 400 && header(mismatch, "location") == nil)
        let unknownRedirect = h.authorize(redirect: "https://claude.ai/api/mcp/other")
        precondition(unknownRedirect.status == 400 && header(unknownRedirect, "location") == nil)
        precondition(text(unknownRedirect).contains("return address"))
        let prefixRedirect = h.authorize(redirect: redirectURI + "/x")
        precondition(prefixRedirect.status == 400 && header(prefixRedirect, "location") == nil)
        let failed = h.authorize(clientID: "https://unreachable.example/client.json",
                                 redirect: "https://unreachable.example/cb")
        precondition(failed.status == 502 && header(failed, "location") == nil)
        let unknownClient = h.authorize(clientID: "dcr_unknown")
        precondition(unknownClient.status == 400 && header(unknownClient, "location") == nil)
        let missing = h.authorize(omit: ["redirect_uri"])
        precondition(missing.status == 400 && header(missing, "location") == nil)
        let duplicated = h.authorize(extra: [("client_id", cimdURL)])
        precondition(duplicated.status == 400 && header(duplicated, "location") == nil)
        // A document can't smuggle a script URL in as a redirect URI.
        let scripted = "https://scripted.example/client.json"
        h.fetcher.documents[scripted] = .success(ClientMetadata(
            clientID: scripted, clientName: "X", redirectURIs: ["javascript:alert(1)"], clientURI: nil))
        precondition(h.authorize(clientID: scripted, redirect: "javascript:alert(1)").status == 400)
        precondition(h.requested.count == 1, "no failed request reaches the Mac")

        // The window closing while the document is fetched: no prompt.
        h.fetcher.hold = true
        var reply: HTTPResponse?
        _ = h.server.handle(request("GET", prefix + "/oauth/authorize" + encodeQuery([
            ("response_type", "code"), ("client_id", cimdURL), ("redirect_uri", redirectURI),
            ("code_challenge", s256(verifier)), ("code_challenge_method", "S256"),
        ])), context: context) { reply = $0 }
        precondition(reply == nil)
        h.server.closePairing()
        h.fetcher.held.removeFirst()()
        precondition(reply?.status == 403 && h.requested.count == 1)
        h.fetcher.hold = false

        // A retrying app doesn't stack prompts.
        h.openWindow()
        for _ in 0..<5 { precondition(h.authorize().status == 200) }
        precondition(h.server.pendingPairings.count == OAuthServer.maxPendingPairings)
    }

    @MainActor
    static func authorizeErrors(_ h: Harness) {
        h.openWindow()
        func errorRedirect(_ response: HTTPResponse) -> [String: String] {
            precondition(response.status == 302, "\(response.status) \(text(response))")
            let location = header(response, "location")!
            precondition(location.hasPrefix(redirectURI + "?"))
            let items = queryItems(location)
            precondition(items["state"] == "st-1" && items["iss"] == issuer)
            return items
        }
        let token = [("response_type", "token")]
        precondition(errorRedirect(h.authorize(extra: token))["error"] == "invalid_request")
        precondition(errorRedirect(h.authorize(omit: ["response_type"], extra: token))["error"]
            == "unsupported_response_type")
        precondition(errorRedirect(h.authorize(omit: ["resource"],
                                               extra: [("resource", "https://other.example/mcp")]))["error"]
            == "invalid_target")
        precondition(errorRedirect(h.authorize(omit: ["resource"], extra: [("resource", issuer)]))["error"]
            == "invalid_target")
        precondition(h.requested.isEmpty)
        // Uppercase scheme and host are the same resource; no resource at all binds to ours.
        precondition(h.authorize(omit: ["resource"],
                                 extra: [("resource", "HTTPS://MY-MAC.tail1234.ts.net" + prefix + "/mcp")])
            .status == 200)
        precondition(h.authorize(omit: ["resource", "state"]).status == 200)
        // No state: none echoed.
        let noState = h.authorize(omit: ["state", "response_type"], extra: [("response_type", "id_token")])
        precondition(queryItems(header(noState, "location")!)["state"] == nil)
        // Cloud access turned off meanwhile: a page, no prompt.
        h.allowed = []
        let off = h.authorize()
        precondition(off.status == 403 && header(off, "location") == nil && h.requested.count == 2)
    }

    @MainActor
    static func pkce(_ h: Harness) {
        h.openWindow()
        func error(_ response: HTTPResponse) -> String? {
            header(response, "location").flatMap { queryItems($0)["error"] }
        }
        precondition(error(h.authorize(omit: ["code_challenge"])) == "invalid_request")
        precondition(error(h.authorize(omit: ["code_challenge_method"])) == "invalid_request")
        precondition(error(h.authorize(omit: ["code_challenge_method"],
                                       extra: [("code_challenge_method", "plain")])) == "invalid_request")
        precondition(error(h.authorize(challenge: verifier)) == "invalid_request", "not a S256 value")
        precondition(h.requested.isEmpty)
        // Wrong verifier fails, and the code is spent.
        let code = h.pairedCode()
        let wrong = h.exchange(code, verifier: String(repeating: "a", count: 43))
        precondition(wrong.status == 400 && json(wrong)["error"] as? String == "invalid_grant")
        precondition(json(h.exchange(code))["error"] as? String == "invalid_grant")
        // Missing verifier.
        h.openWindow()
        let second = h.pairedCode()
        let missing = h.post(prefix + "/oauth/token", [
            ("grant_type", "authorization_code"), ("code", second), ("client_id", cimdURL),
            ("redirect_uri", redirectURI)])
        precondition(json(missing)["error"] as? String == "invalid_request")
        // Success with the right verifier.
        h.openWindow()
        let third = h.exchange(h.pairedCode())
        precondition(third.status == 200)
        precondition(OAuthServer.s256("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
            == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "RFC 7636 appendix B")
    }

    @MainActor
    static func codes(_ h: Harness) {
        // Single use: a replay fails and revokes what the first exchange produced.
        h.openWindow()
        precondition(h.server.pairingClientID == clientA)
        let code = h.pairedCode()
        precondition(h.server.pairingClientID == nil, "Allow closes the window")
        let first = h.exchange(code)
        precondition(first.status == 200)
        let access = json(first)["access_token"] as! String
        precondition(h.server.authenticate(accessToken: access, resource: resource) == clientA)
        let replay = h.exchange(code)
        precondition(replay.status == 400 && json(replay)["error"] as? String == "invalid_grant")
        precondition(h.server.authenticate(accessToken: access, resource: resource) == nil)
        precondition(h.server.connections(clientID: clientA).isEmpty)
        // 60 s lifetime.
        h.openWindow()
        let late = h.pairedCode()
        h.advance(61)
        precondition(json(h.exchange(late))["error"] as? String == "invalid_grant")
        // Bound to client_id and redirect_uri.
        h.openWindow()
        precondition(json(h.exchange(h.pairedCode(), clientID: "https://other.example/c.json"))["error"]
            as? String == "invalid_grant")
        h.openWindow()
        precondition(json(h.exchange(h.pairedCode(), redirect: redirectURI + "?x=1"))["error"]
            as? String == "invalid_grant")
        // Bound to the resource.
        h.openWindow()
        let resourceCode = h.pairedCode()
        let wrongResource = h.post(prefix + "/oauth/token", [
            ("grant_type", "authorization_code"), ("code", resourceCode), ("client_id", cimdURL),
            ("redirect_uri", redirectURI), ("code_verifier", verifier),
            ("resource", "https://x.example/mcp")])
        precondition(json(wrongResource)["error"] as? String == "invalid_target")
        // Unknown code.
        precondition(json(h.exchange("nope"))["error"] as? String == "invalid_grant")
        // Deny sends access_denied with state and iss.
        h.openWindow()
        precondition(h.authorize().status == 200)
        let pending = h.server.pendingPairings[0]
        h.server.answerPairing(pending.id, allow: false)
        precondition(h.server.pendingPairings.isEmpty && h.server.pairingClientID == clientA)
        let denied = json(h.get(prefix + "/oauth/authorize/status", [("request", pending.id.uuidString)]))
        let items = queryItems(denied["redirect"] as! String)
        precondition(items["error"] == "access_denied" && items["state"] == "st-1" && items["iss"] == issuer)
        precondition(items["code"] == nil)
        // A client that lost cloud access before Allow gets a denial, not a code.
        precondition(h.authorize().status == 200)
        let revoked = h.server.pendingPairings[0]
        h.allowed = []
        h.server.answerPairing(revoked.id, allow: true)
        let answer = json(h.get(prefix + "/oauth/authorize/status", [("request", revoked.id.uuidString)]))
        precondition(queryItems(answer["redirect"] as! String)["error"] == "access_denied")
    }

    @MainActor
    static func tokens(_ h: Harness) {
        h.openWindow()
        let response = h.exchange(h.pairedCode())
        precondition(response.status == 200)
        precondition(header(response, "cache-control") == "no-store")
        precondition(header(response, "pragma") == "no-cache")
        let body = json(response)
        precondition(Set(body.keys) == ["access_token", "token_type", "expires_in", "refresh_token", "scope"])
        let access = body["access_token"] as! String
        let refresh = body["refresh_token"] as! String
        precondition(OAuthServer.validToken(access, prefix: "ekb_oat_v1_") && access.utf8.count == 75)
        precondition(OAuthServer.validToken(refresh, prefix: "ekb_ort_v1_"))
        precondition(body["token_type"] as? String == "Bearer" && body["expires_in"] as? Int == 3600)
        precondition(h.changedClients == [clientA])
        let views = h.server.connections(clientID: clientA)
        precondition(views.count == 1 && views[0].appName == "Claude" && views[0].createdAt == h.clock)
        precondition(views[0].lastUsedAt == nil && h.server.connections(clientID: clientB).isEmpty)

        // Audience: only this MCP URL (scheme and host case-insensitive).
        precondition(h.server.authenticate(accessToken: access, resource: resource) == clientA)
        let upper = "HTTPS://My-Mac.tail1234.ts.net" + prefix + "/mcp"
        precondition(h.server.authenticate(accessToken: access, resource: upper) == clientA)
        precondition(h.server.authenticate(accessToken: access, resource: issuer) == nil)
        precondition(h.server.authenticate(accessToken: access, resource: "https://other.example/mcp") == nil)
        precondition(h.server.authenticate(accessToken: access,
                                           resource: origin + "/r/AbCdEfGhIjKlMnOpQrStUw/mcp") == nil)
        precondition(h.server.authenticate(accessToken: refresh, resource: resource) == nil)
        precondition(h.server.authenticate(accessToken: access.uppercased(), resource: resource) == nil)
        precondition(h.server.authenticate(accessToken: "", resource: resource) == nil)
        precondition(h.server.connections(clientID: clientA)[0].lastUsedAt == h.clock)
        // Cloud access off: refused at once.
        h.allowed = [clientB]
        precondition(h.server.authenticate(accessToken: access, resource: resource) == nil)
        precondition(json(h.refresh(refresh))["error"] as? String == "invalid_grant")
        h.allowed = [clientA, clientB]
        // One hour.
        h.advance(3599)
        precondition(h.server.authenticate(accessToken: access, resource: resource) == clientA)
        h.advance(1)
        precondition(h.server.authenticate(accessToken: access, resource: resource) == nil)

        // Grant types and client authentication.
        for grant in ["client_credentials", "password", "implicit",
                      "urn:ietf:params:oauth:grant-type:device_code"] {
            let refused = h.post(prefix + "/oauth/token", [("grant_type", grant), ("client_id", cimdURL)])
            precondition(refused.status == 400)
            precondition(json(refused)["error"] as? String == "unsupported_grant_type")
        }
        precondition(json(h.post(prefix + "/oauth/token", [("client_id", cimdURL)]))["error"]
            as? String == "invalid_request")
        precondition(json(h.post(prefix + "/oauth/token", [("grant_type", "refresh_token")]))["error"]
            as? String == "invalid_request", "client_id required")
        let secret = h.post(prefix + "/oauth/token", [("grant_type", "refresh_token"), ("client_id", cimdURL),
                                                      ("client_secret", "s"), ("refresh_token", refresh)])
        precondition(secret.status == 401 && json(secret)["error"] as? String == "invalid_client")
        let refreshForm = [("grant_type", "refresh_token"), ("refresh_token", refresh)]
        let basic = h.post(prefix + "/oauth/token", refreshForm, headers: [
            ("authorization", "Basic " + Data("\(cimdURL):pw".utf8).base64EncodedString())])
        precondition(basic.status == 401 && header(basic, "www-authenticate")?.hasPrefix("Basic") == true)
        let jsonBody = h.send(request("POST", prefix + "/oauth/token",
                                      body: Data("{\"grant_type\":\"refresh_token\"}".utf8),
                                      headers: [("content-type", "application/json")]))
        precondition(jsonBody.status == 400)
        let duplicate = h.post(prefix + "/oauth/token", [("grant_type", "refresh_token"),
                                                         ("grant_type", "authorization_code")])
        precondition(duplicate.status == 400)
        let huge = h.post(prefix + "/oauth/token", [("grant_type", "refresh_token"),
                                                    ("x", String(repeating: "a", count: 17_000))])
        precondition(huge.status == 400)
        // An empty-password Basic header names a public client, which is fine.
        let publicBasic = h.post(prefix + "/oauth/token", refreshForm,
                                 headers: [("authorization", "Basic " + Data("\(encode(cimdURL)):".utf8)
                                    .base64EncodedString())])
        precondition(publicBasic.status == 200, text(publicBasic))
    }

    @MainActor
    static func refreshRotation(_ h: Harness) {
        let (access, refresh) = h.connect()
        h.changedClients = []
        h.advance(100)
        let rotated = h.refresh(refresh)
        precondition(rotated.status == 200, text(rotated))
        let body = json(rotated)
        let access2 = body["access_token"] as! String
        let refresh2 = body["refresh_token"] as! String
        precondition(access2 != access && refresh2 != refresh)
        precondition(h.server.authenticate(accessToken: access2, resource: resource) == clientA)
        precondition(h.server.authenticate(accessToken: access, resource: resource) == nil, "replaced")
        // Wrong client_id and wrong resource don't rotate or revoke.
        precondition(json(h.refresh(refresh2, clientID: "https://other.example/c.json"))["error"]
            as? String == "invalid_grant")
        let wrongResource = h.post(prefix + "/oauth/token", [
            ("grant_type", "refresh_token"), ("refresh_token", refresh2), ("client_id", cimdURL),
            ("resource", "https://other.example/mcp")])
        precondition(json(wrongResource)["error"] as? String == "invalid_target")
        precondition(h.server.authenticate(accessToken: access2, resource: resource) == clientA)
        precondition(h.changedClients.isEmpty)
        let third = json(h.refresh(refresh2))
        let refresh3 = third["refresh_token"] as! String
        let access3 = third["access_token"] as! String
        // Reuse of a rotated token revokes the whole connection.
        let reuse = h.refresh(refresh)
        precondition(reuse.status == 400 && json(reuse)["error"] as? String == "invalid_grant")
        precondition(h.server.authenticate(accessToken: access3, resource: resource) == nil)
        precondition(json(h.refresh(refresh3))["error"] as? String == "invalid_grant")
        precondition(h.server.connections(clientID: clientA).isEmpty && h.changedClients == [clientA])
        precondition(json(h.refresh("ekb_ort_v1_" + String(repeating: "0", count: 64)))["error"]
            as? String == "invalid_grant")
    }

    /// A token response lost in the tunnel: the client retries with the refresh token it just used.
    @MainActor
    static func refreshRetry(_ h: Harness) {
        let (_, refresh) = h.connect()
        h.advance(100)
        let lost = json(h.refresh(refresh))["refresh_token"] as! String
        h.advance(10)
        let retried = h.refresh(refresh)
        precondition(retried.status == 200, "retry within the grace period: \(text(retried))")
        let body = json(retried)
        let refresh3 = body["refresh_token"] as! String
        precondition(h.server.authenticate(accessToken: body["access_token"] as! String, resource: resource) == clientA)
        // The undelivered token is retired; the retried pair works normally.
        let next = h.refresh(refresh3)
        precondition(next.status == 200, text(next))
        precondition(h.server.connections(clientID: clientA).count == 1)
        // A retry past the grace period counts as reuse.
        let refresh4 = json(next)["refresh_token"] as! String
        h.advance(31)
        _ = refresh4
        precondition(h.refresh(refresh3).status == 400)
        precondition(h.server.connections(clientID: clientA).isEmpty, "late retry revokes")
        _ = lost
    }

    @MainActor
    static func refreshRetryAfterUse(_ h: Harness) {
        let (_, refresh) = h.connect()
        let rotated = json(h.refresh(refresh))
        precondition(h.server.authenticate(accessToken: rotated["access_token"] as! String,
                                           resource: resource) == clientA)
        // The new tokens reached the client (it used them), so the old refresh token is a leaked copy.
        precondition(h.refresh(refresh).status == 400)
        precondition(h.server.connections(clientID: clientA).isEmpty)
    }

    /// After Reset Secret Path or a new address, old connections can't refresh and are removed.
    @MainActor
    static func staleResource(_ h: Harness) {
        let (_, refresh) = h.connect()
        let (_, refreshB) = h.connect()
        let newPrefix = "/r/ZyXwVuTsRqPoNmLkJiHgFe"
        let newContext = OAuthContext(publicOrigin: origin, secretPrefix: newPrefix)
        var reply: HTTPResponse?
        _ = h.server.handle(request("POST", newPrefix + "/oauth/token",
                                    body: Data(encodeQuery([("grant_type", "refresh_token"),
                                                            ("refresh_token", refresh),
                                                            ("client_id", cimdURL)]).dropFirst().utf8),
                                    headers: [("content-type", "application/x-www-form-urlencoded")]),
                            context: newContext) { reply = $0 }
        precondition(reply?.status == 400 && h.server.connections(clientID: clientA).count == 1,
                     "a refresh for the old URL fails and ends that connection")
        h.changedClients = []
        precondition(h.server.revokeConnections(notFor: resource) == 0)
        precondition(h.server.revokeConnections(notFor: newContext.resource) == 1)
        precondition(h.server.connections(clientID: clientA).isEmpty && h.changedClients == [clientA])
        precondition(h.refresh(refreshB).status == 400)
    }

    @MainActor
    static func refreshExpiry(_ h: Harness) {
        let (_, refresh) = h.connect()
        // Each use restarts the 30 days.
        h.advance(29 * 86_400)
        let body = json(h.refresh(refresh))
        let refresh2 = body["refresh_token"] as! String
        h.advance(30 * 86_400 - 1)
        precondition(h.server.connections(clientID: clientA).count == 1)
        let refresh3 = json(h.refresh(refresh2))["refresh_token"] as! String
        h.advance(30 * 86_400)
        precondition(h.server.connections(clientID: clientA).isEmpty, "expired connections aren't listed")
        precondition(json(h.refresh(refresh3))["error"] as? String == "invalid_grant")
    }

    @MainActor
    static func revocation(_ h: Harness) {
        let (access, refresh) = h.connect()
        let (access2, refresh2) = h.connect()
        precondition(h.server.connections(clientID: clientA).count == 2)
        // Unknown and malformed tokens: still 200.
        let unknownToken = "ekb_oat_v1_" + String(repeating: "f", count: 64)
        let unknown = h.post(prefix + "/oauth/revoke", [("token", unknownToken)])
        precondition(unknown.status == 200 && unknown.body.isEmpty)
        precondition(h.post(prefix + "/oauth/revoke", [("token", "garbage")]).status == 200)
        precondition(h.post(prefix + "/oauth/revoke", []).status == 400)
        // Another app's client_id can't revoke it.
        let foreign = [("token", access), ("client_id", "https://other.example/c.json")]
        precondition(h.post(prefix + "/oauth/revoke", foreign).status == 200)
        precondition(h.server.authenticate(accessToken: access, resource: resource) == clientA)
        // Revoking the access token ends the connection, refresh token included.
        precondition(h.post(prefix + "/oauth/revoke", [("token", access), ("token_type_hint", "access_token"),
                                                       ("client_id", cimdURL)]).status == 200)
        precondition(h.server.authenticate(accessToken: access, resource: resource) == nil)
        precondition(json(h.refresh(refresh))["error"] as? String == "invalid_grant")
        precondition(h.server.authenticate(accessToken: access2, resource: resource) == clientA)
        // Revoking by refresh token.
        precondition(h.post(prefix + "/oauth/revoke", [("token", refresh2)]).status == 200)
        precondition(h.server.authenticate(accessToken: access2, resource: resource) == nil)
        // App-side revoke and revokeAll.
        let (access3, _) = h.connect()
        let (access4, _) = h.connect()
        let target = h.server.connections(clientID: clientA)[0]
        h.changedClients = []
        h.server.revoke(connectionID: target.id)
        precondition(h.changedClients == [clientA] && h.server.connections(clientID: clientA).count == 1)
        precondition(h.server.authenticate(accessToken: access3, resource: resource) == nil)
        h.server.revokeAll(clientID: clientA)
        precondition(h.server.authenticate(accessToken: access4, resource: resource) == nil)
        precondition(h.server.connections(clientID: clientA).isEmpty)
        // revokeAll also drops a code not yet redeemed.
        h.openWindow()
        let code = h.pairedCode()
        h.server.revokeAll(clientID: clientA)
        precondition(json(h.exchange(code))["error"] as? String == "invalid_grant")
    }

    @MainActor
    static func pairingWindow(_ h: Harness) {
        h.openWindow()
        precondition(h.pairingChanges == 1)
        precondition(h.authorize().status == 200)
        let first = h.server.pendingPairings[0]
        // Requests expire after 5 minutes.
        h.advance(301)
        precondition(h.server.pendingPairings.isEmpty)
        let expired = json(h.get(prefix + "/oauth/authorize/status", [("request", first.id.uuidString)]))
        precondition(expired["status"] as? String == "expired")
        h.server.answerPairing(first.id, allow: true)
        precondition(h.server.pairingClientID == clientA, "answering an expired request does nothing")
        // A request's lifetime never outlives the window.
        h.advance(200)
        precondition(h.authorize().status == 200)
        precondition(h.server.pendingPairings[0].expiresAt == h.server.pairingExpiresAt)
        // The window lasts 10 minutes.
        h.advance(98)
        precondition(h.server.pairingClientID == clientA)
        h.advance(1)
        precondition(h.server.pairingClientID == nil && h.server.pendingPairings.isEmpty)
        let changes = h.pairingChanges
        precondition(h.authorize().status == 403)
        precondition(h.pairingChanges > changes, "expiry is announced")

        // Opening another window replaces the first and drops its requests.
        h.openWindow(clientA)
        precondition(h.authorize().status == 200)
        let stale = h.server.pendingPairings[0]
        h.openWindow(clientB)
        precondition(h.server.pairingClientID == clientB && h.server.pendingPairings.isEmpty)
        h.server.answerPairing(stale.id, allow: true)
        precondition(h.server.pairingClientID == clientB)
        precondition(json(h.status(stale.id))["status"] as? String == "expired")
        precondition(h.authorize().status == 200 && h.server.pendingPairings[0].clientID == clientB)
        h.server.answerPairing(h.server.pendingPairings[0].id, allow: true)
        let tokens = json(h.exchange(codeFromStatus(h, h.requested.last!.id)))
        precondition(h.server.authenticate(accessToken: tokens["access_token"] as! String, resource: resource)
            == clientB)
        // Answered requests stay readable briefly, then go.
        h.advance(61)
        let gone = h.get(prefix + "/oauth/authorize/status", [("request", h.requested.last!.id.uuidString)])
        precondition(json(gone)["status"] as? String == "expired")
    }

    @MainActor
    static func escaping(_ h: Harness) {
        let evil = "https://evil.example/client.json"
        let name = "<script>alert('x')</script>\"&\u{202E}gpj.exe\u{0007}"
        h.fetcher.documents[evil] = .success(ClientMetadata(
            clientID: evil, clientName: name, redirectURIs: ["https://evil.example/cb?a=1"], clientURI: nil))
        h.openWindow()
        let page = h.authorize(clientID: evil, redirect: "https://evil.example/cb?a=1")
        precondition(page.status == 200)
        let html = text(page)
        precondition(!html.contains("<script>alert") && !html.contains("\u{202E}"))
        precondition(html.contains("&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;&quot;&amp;gpj.exe"))
        precondition(h.requested[0].appName == "<script>alert('x')</script>\"&gpj.exe")
        // Exactly one script element: ours, carrying the nonce the CSP names.
        precondition(html.components(separatedBy: "<script").count == 2)
        let csp = header(page, "content-security-policy")!
        let nonce = csp.components(separatedBy: "'nonce-")[1].components(separatedBy: "'")[0]
        precondition(html.contains("<script nonce=\"\(nonce)\">"))
        precondition(html.contains("<style nonce=\"\(nonce)\">"))
        precondition(!csp.contains("unsafe-inline") && csp.contains("connect-src 'self'"))
        precondition(csp.contains("default-src 'none'") && csp.contains("frame-ancestors 'none'"))
        precondition(!html.contains("http://") && !html.contains("src=") && !html.contains("href="))
        // An existing query in the redirect URI is kept.
        h.server.answerPairing(h.requested[0].id, allow: true)
        let redirect = json(h.status(h.requested[0].id))
        precondition((redirect["redirect"] as! String).hasPrefix("https://evil.example/cb?a=1&code="))
        // Long names are cut to 100 bytes.
        precondition(OAuthServer.displayName(String(repeating: "é", count: 80))?.utf8.count == 100)
        precondition(OAuthServer.displayName(" \u{200B}\n ") == nil)
        precondition(OAuthPages.escape("a<b>&\"'") == "a&lt;b&gt;&amp;&quot;&#39;")
    }

    @MainActor
    static func dcr(_ h: Harness) {
        func register(_ object: [String: Any]) -> HTTPResponse {
            h.send(request("POST", prefix + "/oauth/register",
                           body: try! JSONSerialization.data(withJSONObject: object),
                           headers: [("content-type", "application/json")]))
        }
        let callback = "https://chatgpt.com/connector_platform_oauth_redirect"
        // Registration needs an open pairing window, like authorization.
        h.server.closePairing()
        let closed = register(["redirect_uris": [callback], "client_name": "Early"])
        precondition(closed.status == 403 && json(closed)["error"] as? String == "access_denied")
        h.openWindow()
        let created = register(["redirect_uris": [callback], "client_name": "ChatGPT",
                                "token_endpoint_auth_method": "none",
                                "grant_types": ["authorization_code", "refresh_token"]])
        precondition(created.status == 201, text(created))
        precondition(header(created, "cache-control") == "no-store")
        let body = json(created)
        let clientID = body["client_id"] as! String
        precondition(clientID.hasPrefix("dcr_") && clientID.count == 36)
        precondition(body["client_id_issued_at"] as? Int == Int(h.clock.timeIntervalSince1970))
        precondition(body["redirect_uris"] as? [String] == [callback])
        precondition(body["client_name"] as? String == "ChatGPT")
        precondition(body["token_endpoint_auth_method"] as? String == "none")
        precondition(body["client_secret"] == nil)
        // Loopback http is fine (RFC 8252); other http, custom schemes and fragments aren't.
        let loopback = ["http://127.0.0.1:3000/cb", "http://localhost/cb"]
        precondition(register(["redirect_uris": loopback]).status == 201)
        for bad: Any in [["http://example.com/cb"], ["javascript:alert(1)"], ["https://a.example/cb#f"],
                         [String](), Array(repeating: callback, count: 6), "https://a.example/cb",
                         ["https://user:pw@a.example/cb"], ["myapp://cb"],
                         ["https://exämple.com/cb"]] as [Any] {
            let refused = register(["redirect_uris": bad])
            precondition(refused.status == 400 && json(refused)["error"] as? String == "invalid_redirect_uri",
                         "\(bad)")
        }
        let long = register(["redirect_uris": [callback], "client_name": String(repeating: "x", count: 101)])
        precondition(json(long)["error"] as? String == "invalid_client_metadata")
        precondition(json(register(["redirect_uris": [callback], "client_name": "a\nb"]))["error"]
            as? String == "invalid_client_metadata")
        precondition(json(register(["redirect_uris": [callback],
                                    "token_endpoint_auth_method": "client_secret_basic"]))["error"]
            as? String == "invalid_client_metadata")
        precondition(h.send(request("POST", prefix + "/oauth/register", body: Data("[]".utf8),
                                    headers: [("content-type", "application/json")])).status == 400)
        precondition(h.send(request("POST", prefix + "/oauth/register",
                                    body: Data(count: 17_000),
                                    headers: [("content-type", "application/json")]))
            .status == 400)

        // Register, then authorize and connect with it.
        h.openWindow()
        let page = h.authorize(clientID: clientID, redirect: callback)
        precondition(page.status == 200 && h.requested.last?.appName == "ChatGPT")
        precondition(h.requested.last?.appURL == nil && h.fetcher.fetched.isEmpty)
        let wrongRedirect = h.authorize(clientID: clientID, redirect: redirectURI)
        precondition(wrongRedirect.status == 400 && header(wrongRedirect, "location") == nil)
        let (access, _) = h.connect(clientID: clientID, redirect: callback)
        precondition(h.server.authenticate(accessToken: access, resource: resource) == clientA)

        // At most 100: the oldest unused registration goes first; used ones stay.
        h.openWindow()
        for index in 0..<120 {
            h.advance(1)
            let spam = register(["redirect_uris": [callback], "client_name": "spam \(index)"])
            precondition(spam.status == 201)
        }
        h.openWindow()
        precondition(h.authorize(clientID: clientID, redirect: callback).status == 200,
                     "used registration kept")
        let path = h.directory.appendingPathComponent("remote-connections.json").path
        let stored = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
            as! [String: Any]
        let registrations = stored["registrations"] as! [[String: Any]]
        precondition(registrations.count == 100)
        precondition(registrations.contains { $0["clientID"] as? String == clientID })
        precondition(!registrations.contains { $0["clientName"] as? String == "spam 0" })
        precondition(registrations.contains { $0["clientName"] as? String == "spam 119" })
    }

    /// Gemini Enterprise: a client ID and secret set up in the app, bound to one bridge client.
    @MainActor
    static func confidential(_ h: Harness) {
        let gemini = "https://vertexaisearch.cloud.google.com/oauth-redirect"
        precondition(h.server.registerConfidentialClient(for: clientA, name: "Gemini",
                                                         redirectURI: "myapp://cb") == nil)
        h.allowed.remove(clientB)
        precondition(h.server.registerConfidentialClient(for: clientB, name: "Gemini", redirectURI: gemini) == nil)
        h.allowed.insert(clientB)
        let first = h.server.registerConfidentialClient(for: clientA, name: "Gemini", redirectURI: gemini)!
        let issued = h.server.registerConfidentialClient(for: clientA, name: "Gemini", redirectURI: gemini)!
        precondition(issued.clientID.hasPrefix("cfg_") && issued.clientID.count == 36)
        precondition(issued.secret.hasPrefix(OAuthServer.secretPrefix) && issued.clientID != first.clientID)
        let path = h.directory.appendingPathComponent("remote-connections.json")
        let stored = String(decoding: try! Data(contentsOf: path), as: UTF8.self)
        precondition(!stored.contains(issued.secret) && stored.contains(sha256(issued.secret)))
        precondition(!stored.contains(first.clientID), "an unused earlier client is replaced")

        // Only within a window for the same bridge client.
        h.openWindow(clientB)
        let other = h.authorize(clientID: issued.clientID, redirect: gemini)
        precondition(other.status == 403 && h.requested.isEmpty)
        h.openWindow()
        precondition(h.authorize(clientID: first.clientID, redirect: gemini).status == 400)
        precondition(h.authorize(clientID: issued.clientID, redirect: redirectURI).status == 400)
        let code = h.pairedCode(clientID: issued.clientID, redirect: gemini)
        precondition(h.requested.last?.appName == "Gemini" && h.requested.last?.appURL == nil)

        func token(_ form: [(String, String)], headers: [(String, String)] = []) -> HTTPResponse {
            h.post(prefix + "/oauth/token", form, headers: headers)
        }
        let exchange: [(String, String)] = [
            ("grant_type", "authorization_code"), ("code", code), ("redirect_uri", gemini),
            ("code_verifier", verifier),
        ]
        func basic(_ user: String, _ password: String) -> (String, String) {
            ("authorization", "Basic " + Data("\(encode(user)):\(encode(password))".utf8).base64EncodedString())
        }
        // The secret is required, must be right and is sent once. None of these burn the code.
        for (form, headers) in [
            (exchange + [("client_id", issued.clientID)], []),
            (exchange + [("client_id", issued.clientID), ("client_secret", issued.secret + "x")], []),
            (exchange, [basic(issued.clientID, "wrong")]),
            (exchange + [("client_secret", issued.secret)], [basic(issued.clientID, issued.secret)]),
        ] as [([(String, String)], [(String, String)])] {
            let refused = token(form, headers: headers)
            precondition(refused.status == 401 && json(refused)["error"] as? String == "invalid_client",
                         text(refused))
        }
        let granted = token(exchange, headers: [basic(issued.clientID, issued.secret)])
        precondition(granted.status == 200, text(granted))
        let body = json(granted)
        let access = body["access_token"] as! String
        precondition(h.server.authenticate(accessToken: access, resource: resource) == clientA)
        // client_secret_post works for refresh; a public client can't send a secret.
        let refreshed = token([("grant_type", "refresh_token"), ("refresh_token", body["refresh_token"] as! String),
                               ("client_id", issued.clientID), ("client_secret", issued.secret)])
        precondition(refreshed.status == 200, text(refreshed))
        let (_, publicRefresh) = h.connect()
        let publicWithSecret = token([("grant_type", "refresh_token"), ("refresh_token", publicRefresh),
                                      ("client_id", cimdURL), ("client_secret", "anything")])
        precondition(publicWithSecret.status == 401)
        // A used client survives a new setup; revoking everything for the client removes both.
        let replacement = h.server.registerConfidentialClient(for: clientA, name: "Gemini", redirectURI: gemini)!
        precondition(String(decoding: try! Data(contentsOf: path), as: UTF8.self).contains(issued.clientID))
        h.server.revokeAll(clientID: clientA)
        let after = String(decoding: try! Data(contentsOf: path), as: UTF8.self)
        precondition(!after.contains(issued.clientID) && !after.contains(replacement.clientID))
        precondition(h.server.authenticate(accessToken: access, resource: resource) == nil)
        // The file still loads after a restart.
        h.restart()
        precondition(h.server.isAvailable)
    }

    @MainActor
    static func persistence(_ h: Harness) {
        let (access, refresh) = h.connect()
        let file = h.directory.appendingPathComponent("remote-connections.json")
        var info = stat()
        precondition(lstat(file.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
        precondition(lstat(h.directory.path, &info) == 0 && info.st_mode & 0o777 == 0o700)
        let contents = String(decoding: try! Data(contentsOf: file), as: UTF8.self)
        precondition(!contents.contains(access) && !contents.contains(refresh))
        precondition(!contents.contains("ekb_oat_v1_") && !contents.contains("ekb_ort_v1_"))
        precondition(!contents.contains(String(access.dropFirst(11))))
        precondition(!contents.contains(String(refresh.dropFirst(11))))
        precondition(contents.contains(sha256(access)) && contents.contains(sha256(refresh)))
        // lastUsedAt reaches the disk at most once a minute.
        precondition(h.server.authenticate(accessToken: access, resource: resource) == clientA)
        let firstUse = h.clock
        h.advance(30)
        precondition(h.server.authenticate(accessToken: access, resource: resource) == clientA)
        h.restart()
        precondition(h.server.connections(clientID: clientA)[0].lastUsedAt == firstUse)
        // Survives a restart: tokens, refresh and listing.
        precondition(h.server.isAvailable)
        precondition(h.server.authenticate(accessToken: access, resource: resource) == clientA)
        h.advance(30)
        let rotated = json(h.refresh(refresh))
        h.restart()
        let rotatedAccess = rotated["access_token"] as! String
        precondition(h.server.authenticate(accessToken: rotatedAccess, resource: resource) == clientA)
        precondition(json(h.refresh(refresh))["error"] as? String == "invalid_grant", "reuse after restart")
        h.restart()
        precondition(h.server.connections(clientID: clientA).isEmpty, "the revocation persisted")
    }

    @MainActor
    static func unsafeStore(_ directory: URL) {
        let file = directory.appendingPathComponent("remote-connections.json")
        let h = Harness(directory: directory)
        h.fetcher.documents[cimdURL] = .success(ClientMetadata(
            clientID: cimdURL, clientName: "Claude", redirectURIs: [redirectURI], clientURI: nil))
        let (access, refresh) = h.connect()
        let good = try! Data(contentsOf: file)
        func expectClosed(_ why: String) {
            h.restart()
            precondition(!h.server.isAvailable, why)
            precondition(h.server.authenticate(accessToken: access, resource: resource) == nil, why)
            precondition(h.server.connections(clientID: clientA).isEmpty, why)
            precondition(h.refresh(refresh).status == 503, why)
            h.openWindow()
            precondition(h.authorize().status == 503, why)
            precondition(h.post(prefix + "/oauth/revoke", [("token", access)]).status == 200, why)
            // Discovery still answers; nothing is written.
            precondition(h.get("/.well-known/oauth-authorization-server" + prefix).status == 200)
        }
        chmod(file.path, 0o644)
        expectClosed("group-readable file")
        precondition(try! Data(contentsOf: file) == good, "an unsafe file is never overwritten")
        chmod(file.path, 0o600)
        h.restart()
        precondition(h.server.authenticate(accessToken: access, resource: resource) == clientA)

        try! Data("{\"version\":1,\"connections\":[{}],\"registrations\":[]}".utf8).write(to: file)
        chmod(file.path, 0o600)
        expectClosed("invalid contents")
        try! Data("{\"version\":2,\"connections\":[],\"registrations\":[]}".utf8).write(to: file)
        chmod(file.path, 0o600)
        expectClosed("unknown version")
        try! FileManager.default.removeItem(at: file)
        let elsewhere = directory.appendingPathComponent("elsewhere.json")
        try! good.write(to: elsewhere)
        chmod(elsewhere.path, 0o600)
        symlink(elsewhere.path, file.path)
        expectClosed("symlink")
        unlink(file.path)
        try! Data(count: 2_000_001).write(to: file)
        chmod(file.path, 0o600)
        expectClosed("oversize")
        try! good.write(to: file)
        chmod(file.path, 0o600)
        chmod(directory.path, 0o755)
        expectClosed("shared directory")
        chmod(directory.path, 0o700)
        h.restart()
        precondition(h.server.isAvailable)
        precondition(h.server.authenticate(accessToken: access, resource: resource) == clientA)
    }

    // MARK: Helpers

    @MainActor
    static func codeFromStatus(_ h: Harness, _ id: UUID) -> String {
        let status = json(h.get(prefix + "/oauth/authorize/status", [("request", id.uuidString)]))
        return queryItems(status["redirect"] as! String)["code"]!
    }

    @MainActor
    static func checkPageHeaders(_ page: HTTPResponse) {
        precondition(header(page, "content-type") == "text/html; charset=utf-8")
        precondition(header(page, "x-frame-options") == "DENY")
        precondition(header(page, "referrer-policy") == "no-referrer")
        precondition(header(page, "cache-control") == "no-store")
        precondition(header(page, "content-security-policy")?.contains("connect-src 'self'") == true)
        precondition(!page.headers.contains { $0.name.lowercased().hasPrefix("access-control-") })
        // Serializable as-is: every header survives the response writer.
        let wire = String(decoding: page.serialized(close: false), as: UTF8.self)
        precondition(wire.contains("Content-Security-Policy: ") && wire.contains("X-Frame-Options: DENY"))
    }

    static func request(_ method: String, _ target: String, body: Data = Data(),
                        headers: [(String, String)] = []) -> HTTPRequest {
        HTTPRequest(method: method, target: target, path: String(target.prefix { $0 != "?" }),
                    version: "HTTP/1.1", headers: [("host", "my-mac.tail1234.ts.net")] + headers.map {
                        (name: $0.0.lowercased(), value: $0.1) }, body: body)
    }

    static func header(_ response: HTTPResponse, _ name: String) -> String? {
        response.headers.first { $0.name.lowercased() == name }?.value
    }

    static func text(_ response: HTTPResponse) -> String { String(decoding: response.body, as: UTF8.self) }

    static func json(_ response: HTTPResponse) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
    }

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))!
    }

    static func encodeQuery(_ pairs: [(String, String)]) -> String {
        pairs.isEmpty ? "" : "?" + pairs.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
    }

    static func queryItems(_ url: String) -> [String: String] {
        var items = [String: String]()
        for item in URLComponents(string: url)?.queryItems ?? [] { items[item.name] = item.value }
        return items
    }

    static func s256(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
