import CryptoKit
import Foundation

/// A cloud app's authorization request waiting for the user's answer in the app.
struct PairingRequest: Identifiable, Equatable {
    let id: UUID
    /// The bridge client the pairing window was opened for.
    let clientID: String
    /// Self-reported by the app (CIMD or DCR `client_name`), sanitized. Display only.
    let appName: String
    /// The CIMD URL, which the app's server proved it controls. Nil for DCR clients.
    let appURL: String?
    /// Where the browser returns, so the user can spot a look-alike app.
    let redirectHost: String
    /// "482 913": shown both in the browser and on the Mac.
    let code: String
    let expiresAt: Date
}

struct OAuthConnectionView: Identifiable, Equatable {
    let id: UUID
    let clientID: String
    let appName: String
    let createdAt: Date
    let lastUsedAt: Date?
}

struct OAuthContext {
    let publicOrigin: String
    /// "/r/<secret>"; everything OAuth lives behind it, so scanners of the bare host learn nothing.
    let secretPrefix: String

    var issuer: String { publicOrigin + secretPrefix }
    var resource: String { issuer + "/mcp" }
    var resourceMetadataURL: String {
        publicOrigin + "/.well-known/oauth-protected-resource" + secretPrefix + "/mcp"
    }
}

/// The OAuth 2.1 authorization server of Remote Access (MCP-PLAN §22.6): RFC 9728 and RFC 8414
/// metadata, authorization code with PKCE S256 behind a pairing window the user opens in the app,
/// rotating refresh tokens with reuse detection, CIMD clients with a DCR fallback, and revocation.
/// Every endpoint answers at once; only the browser page waits for the user.
@MainActor
final class OAuthServer {
    static let scope = "calendar"
    nonisolated static let accessPrefix = "ekb_oat_v1_"
    static let refreshPrefix = "ekb_ort_v1_"
    static let pairingDuration: TimeInterval = 10 * 60
    static let requestLifetime: TimeInterval = 5 * 60
    static let codeLifetime: TimeInterval = 60
    static let accessLifetime: TimeInterval = 60 * 60
    static let refreshLifetime: TimeInterval = 30 * 24 * 60 * 60
    static let maxPendingPairings = 3
    static let maxBodyBytes = 16 * 1024
    static let usePersistInterval: TimeInterval = 60
    /// A client whose token response got lost in the tunnel may retry with the refresh token it
    /// just used, within this time and only if nothing used the new tokens yet.
    static let refreshRetryGrace: TimeInterval = 30
    static let secretPrefix = "ekb_ocs_v1_"

    var pairingRequested: (PairingRequest) -> Void = { _ in }
    var pairingChanged: () -> Void = {}
    var connectionsChanged: (String) -> Void = { _ in }

    private let store: OAuthStore
    private let fetcher: CIMDFetching
    private let now: () -> Date
    private let clientAllowed: (String) -> Bool
    private let clientName: (String) -> String?
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void

    private struct Window {
        let id = UUID()
        let clientID: String
        let expiresAt: Date
    }

    /// A validated authorization request: everything a code is bound to.
    private struct Authorization {
        let oauthClientID: String
        let redirectURI: String
        let codeChallenge: String
        let resource: String
        let state: String?
        let issuer: String
    }

    private struct Pairing {
        var request: PairingRequest
        let windowID: UUID
        let authorization: Authorization
        /// Set once answered: the URL the browser page navigates to.
        var redirect: String?
        var retainUntil: Date
    }

    private struct Grant {
        let authorization: Authorization
        let clientID: String
        let appName: String
        let expiresAt: Date
    }

    private var window: Window?
    private var pairings: [Pairing] = []
    /// Keyed by the code's digest. Codes live only in memory: a restart within 60 s loses nothing.
    private var codes: [String: Grant] = [:]
    /// Redeemed codes; a second redemption revokes the connection the first one created.
    private var spentCodes: [String: (connection: UUID?, forgetAt: Date)] = [:]
    private var lastUsePersist: Date?

    init(directory: URL, fetcher: CIMDFetching, now: @escaping () -> Date = Date.init,
         clientAllowed: @escaping (String) -> Bool, clientName: @escaping (String) -> String?,
         schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, action in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(action) }
         }) {
        store = OAuthStore(directory: directory)
        self.fetcher = fetcher
        self.now = now
        self.clientAllowed = clientAllowed
        self.clientName = clientName
        self.schedule = schedule
    }

    var isAvailable: Bool { store.isAvailable }

    // MARK: Pairing window

    var pairingClientID: String? { liveWindow?.clientID }
    var pairingExpiresAt: Date? { liveWindow?.expiresAt }

    var pendingPairings: [PairingRequest] {
        let time = now()
        guard let window = liveWindow else { return [] }
        return pairings
            .filter { $0.redirect == nil && $0.windowID == window.id && $0.request.expiresAt > time }
            .map(\.request)
    }

    private var liveWindow: Window? {
        guard let window, window.expiresAt > now() else { return nil }
        return window
    }

    /// Opens the 10-minute window for one bridge client, replacing any other window.
    func openPairing(clientID: String) {
        sweep()
        pairings.removeAll { $0.redirect == nil }
        let opened = Window(clientID: clientID, expiresAt: now().addingTimeInterval(Self.pairingDuration))
        window = opened
        schedule(Self.pairingDuration) { [weak self] in self?.sweep() }
        pairingChanged()
    }

    func closePairing() {
        sweep()
        guard window != nil || pairings.contains(where: { $0.redirect == nil }) else { return }
        window = nil
        pairings.removeAll { $0.redirect == nil }
        pairingChanged()
    }

    /// Allow mints a code and closes the window (one connection per window); Deny sends
    /// `access_denied` back to the app.
    func answerPairing(_ id: UUID, allow: Bool) {
        sweep()
        guard let index = pairings.firstIndex(where: { $0.request.id == id && $0.redirect == nil }),
              let window = liveWindow, pairings[index].windowID == window.id else { return }
        let pairing = pairings[index]
        let time = now()
        if allow && clientAllowed(pairing.request.clientID) {
            let code = Self.randomToken(prefix: "")
            codes[OAuthStore.digest(code)] = Grant(
                authorization: pairing.authorization, clientID: pairing.request.clientID,
                appName: pairing.request.appName, expiresAt: time.addingTimeInterval(Self.codeLifetime))
            pairings[index].redirect = Self.redirect(pairing.authorization, ["code": code])
            self.window = nil
            pairings.removeAll { $0.redirect == nil }
        } else {
            pairings[index].redirect = Self.redirect(pairing.authorization, [
                "error": "access_denied",
                "error_description": "The connection was declined in \(AppIdentity.displayName).",
            ])
        }
        pairings[index].retainUntil = time.addingTimeInterval(Self.codeLifetime)
        pairingChanged()
    }

    /// Expires windows, requests, answers and codes. Called before every decision and by timers.
    private func sweep() {
        let time = now()
        var changed = false
        if let window, window.expiresAt <= time {
            self.window = nil
            changed = true
        }
        let before = pairings.count
        pairings.removeAll { pairing in
            pairing.redirect == nil
                ? pairing.request.expiresAt <= time || pairing.windowID != window?.id
                : pairing.retainUntil <= time
        }
        changed = changed || pairings.count != before
        codes = codes.filter { $0.value.expiresAt > time }
        spentCodes = spentCodes.filter { $0.value.forgetAt > time }
        if changed { pairingChanged() }
    }

    // MARK: Routing

    private enum Route {
        case resourceMetadata, serverMetadata, authorize, status, token, register, revoke

        var method: String {
            switch self {
            case .resourceMetadata, .serverMetadata, .authorize, .status: return "GET"
            case .token, .register, .revoke: return "POST"
            }
        }
    }

    /// Handles OAuth and metadata routes. Returns false (and never calls reply) for any other path.
    func handle(_ request: HTTPRequest, context: OAuthContext,
                reply: @escaping (HTTPResponse) -> Void) -> Bool {
        let prefix = context.secretPrefix
        guard Self.validPrefix(prefix) else { return false }
        // Exact matches only: dot segments, encoded slashes and case variants fall through to 404.
        let route: Route
        switch request.path {
        case "/.well-known/oauth-protected-resource" + prefix + "/mcp": route = .resourceMetadata
        case "/.well-known/oauth-authorization-server" + prefix,
             "/.well-known/openid-configuration" + prefix,
             prefix + "/.well-known/openid-configuration": route = .serverMetadata
        case prefix + "/oauth/authorize": route = .authorize
        case prefix + "/oauth/authorize/status": route = .status
        case prefix + "/oauth/token": route = .token
        case prefix + "/oauth/register": route = .register
        case prefix + "/oauth/revoke": route = .revoke
        default: return false
        }
        guard request.method == route.method else {
            reply(HTTPResponse(status: 405, headers: [("Allow", route.method)]))
            return true
        }
        sweep()
        switch route {
        case .resourceMetadata: reply(Self.json(200, Self.resourceMetadata(context)))
        case .serverMetadata: reply(Self.json(200, Self.serverMetadata(context)))
        case .authorize: authorize(request, context: context, reply: reply)
        case .status: reply(status(request))
        case .token: reply(token(request, context: context))
        case .register: reply(register(request))
        case .revoke: reply(revoke(request))
        }
        return true
    }

    /// `WWW-Authenticate` value for a 401 on the MCP endpoint.
    static func challenge(_ context: OAuthContext) -> String {
        "Bearer resource_metadata=\"\(context.resourceMetadataURL)\", scope=\"\(scope)\""
    }

    static func resourceMetadata(_ context: OAuthContext) -> [String: Any] {
        [
            "resource": context.resource,
            "authorization_servers": [context.issuer],
            "scopes_supported": [scope],
            "bearer_methods_supported": ["header"],
        ]
    }

    static func serverMetadata(_ context: OAuthContext) -> [String: Any] {
        let base = context.issuer + "/oauth"
        return [
            "issuer": context.issuer,
            "authorization_endpoint": base + "/authorize",
            "token_endpoint": base + "/token",
            "registration_endpoint": base + "/register",
            "revocation_endpoint": base + "/revoke",
            "response_types_supported": ["code"],
            "grant_types_supported": ["authorization_code", "refresh_token"],
            "code_challenge_methods_supported": ["S256"],
            "token_endpoint_auth_methods_supported": ["none"],
            "client_id_metadata_document_supported": true,
            "authorization_response_iss_parameter_supported": true,
            "scopes_supported": [scope],
        ]
    }

    // MARK: Authorization endpoint

    private func authorize(_ request: HTTPRequest, context: OAuthContext,
                           reply: @escaping (HTTPResponse) -> Void) {
        guard store.isAvailable else { return reply(Self.unavailablePage()) }
        // Nothing is fetched or shown outside a window, so the internet can't trigger prompts.
        guard let window = liveWindow else { return reply(OAuthPages.closed()) }
        guard let query = OAuthForm(Self.query(request.target)),
              let clientID = query.single("client_id"), !clientID.isEmpty, clientID.utf8.count <= 2048,
              let redirectURI = query.single("redirect_uri") else {
            return reply(OAuthPages.error(400, title: "This link isn’t complete",
                                          message: "The app sent an authorization request without a "
                                              + "single client_id and redirect_uri. Try connecting again."))
        }
        let badRedirect = OAuthPages.error(
            400, title: "This app’s return address isn’t registered",
            message: "The redirect_uri doesn’t exactly match one the app registered, so "
                + "\(AppIdentity.displayName) won’t send you there.")
        guard Self.validRedirectURI(redirectURI) else { return reply(badRedirect) }
        if clientID.hasPrefix("https://") {
            guard let url = URL(string: clientID) else {
                return reply(OAuthPages.error(400, title: "Unknown app",
                                              message: "The app’s client_id isn’t a valid URL."))
            }
            fetcher.fetch(url) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let document) where document.clientID == clientID:
                    guard document.redirectURIs.contains(redirectURI) else { return reply(badRedirect) }
                    let name = Self.displayName(document.clientName) ?? url.host ?? clientID
                    reply(self.pairingStep(query, context: context, windowID: window.id,
                                           oauthClientID: clientID, redirectURI: redirectURI,
                                           appName: name, appURL: clientID))
                case .success:
                    reply(OAuthPages.error(400, title: "Unknown app",
                                           message: "The app’s metadata document names a different "
                                               + "client_id than the URL it was fetched from."))
                case .failure(let error):
                    reply(OAuthPages.error(502, title: "Couldn’t read the app’s details",
                                           message: "\(AppIdentity.displayName) couldn’t use the app’s "
                                               + "metadata document. \(error.reason) Try connecting again."))
                }
            }
            return
        }
        guard let registration = store.state?.registrations.first(where: { $0.clientID == clientID }) else {
            return reply(OAuthPages.error(400, title: "Unknown app",
                                          message: "This client_id isn’t registered. "
                                              + "Try connecting again."))
        }
        guard registration.redirectURIs.contains(redirectURI) else { return reply(badRedirect) }
        if registration.isConfidential, registration.bridgeClientID != window.clientID {
            return reply(OAuthPages.error(403, title: "This app was set up for another client",
                                          message: "Pairing is open for a different client in "
                                              + "\(AppIdentity.displayName). Open the client this app was "
                                              + "set up for and choose Connect a Cloud App."))
        }
        let name = Self.displayName(registration.clientName) ?? URL(string: redirectURI)?.host ?? "An app"
        reply(pairingStep(query, context: context, windowID: window.id, oauthClientID: clientID,
                          redirectURI: redirectURI, appName: name, appURL: nil))
    }

    /// The checks after the client and redirect URI are trusted: errors now go back to the app.
    private func pairingStep(_ query: OAuthForm, context: OAuthContext, windowID: UUID,
                             oauthClientID: String, redirectURI: String, appName: String,
                             appURL: String?) -> HTTPResponse {
        sweep()
        guard let window = liveWindow, window.id == windowID else { return OAuthPages.closed() }
        let state = query.single("state")
        func fail(_ error: String, _ description: String) -> HTTPResponse {
            let authorization = Authorization(oauthClientID: oauthClientID, redirectURI: redirectURI,
                                              codeChallenge: "", resource: "", state: state,
                                              issuer: context.issuer)
            return Self.redirectResponse(Self.redirect(authorization, [
                "error": error, "error_description": description]))
        }
        guard !query.hasDuplicates else { return fail("invalid_request", "A parameter appears twice.") }
        guard query.single("response_type") == "code" else {
            return fail("unsupported_response_type", "Only response_type=code is supported.")
        }
        guard let challenge = query.single("code_challenge"), query.single("code_challenge_method") == "S256"
        else { return fail("invalid_request", "PKCE with code_challenge_method=S256 is required.") }
        guard Self.validChallenge(challenge) else {
            return fail("invalid_request", "code_challenge isn't a valid S256 challenge.")
        }
        let expected = Self.canonicalResource(context.resource)
        if let resource = query.single("resource"), Self.canonicalResource(resource) != expected {
            return fail("invalid_target", "resource must be \(context.resource).")
        }
        guard clientAllowed(window.clientID), let bridgeName = clientName(window.clientID) else {
            return OAuthPages.error(403, title: "Cloud access is off",
                                    message: "This client no longer allows cloud access. Turn it on in "
                                        + "\(AppIdentity.displayName) and connect again.")
        }
        let time = now()
        let request = PairingRequest(
            id: UUID(), clientID: window.clientID, appName: appName, appURL: appURL,
            redirectHost: URL(string: redirectURI)?.host ?? redirectURI, code: Self.pairingCode(),
            expiresAt: min(time.addingTimeInterval(Self.requestLifetime), window.expiresAt))
        let authorization = Authorization(oauthClientID: oauthClientID, redirectURI: redirectURI,
                                          codeChallenge: challenge, resource: expected, state: state,
                                          issuer: context.issuer)
        // A retrying or spamming app can't stack prompts: the oldest open request gives way.
        let open = pairings.filter { $0.redirect == nil }
        if open.count >= Self.maxPendingPairings, let oldest = open.first {
            pairings.removeAll { $0.request.id == oldest.request.id }
        }
        pairings.append(Pairing(request: request, windowID: window.id, authorization: authorization,
                                redirect: nil, retainUntil: request.expiresAt))
        schedule(request.expiresAt.timeIntervalSince(time)) { [weak self] in self?.sweep() }
        pairingRequested(request)
        pairingChanged()
        return OAuthPages.pairing(request, clientName: bridgeName)
    }

    private func status(_ request: HTTPRequest) -> HTTPResponse {
        guard let query = OAuthForm(Self.query(request.target)),
              let id = query.single("request").flatMap(UUID.init(uuidString:)),
              let pairing = pairings.first(where: { $0.request.id == id }) else {
            return Self.json(200, ["status": "expired"])
        }
        guard let redirect = pairing.redirect else { return Self.json(200, ["status": "pending"]) }
        return Self.json(200, ["status": "answered", "redirect": redirect])
    }

    // MARK: Token endpoint

    private func token(_ request: HTTPRequest, context: OAuthContext) -> HTTPResponse {
        guard store.isAvailable else {
            return Self.oauthError(503, "temporarily_unavailable", "Connections can't be read right now.")
        }
        guard let form = Self.form(request) else {
            return Self.oauthError(400, "invalid_request", "Send a form-urlencoded body.")
        }
        guard !form.hasDuplicates else {
            return Self.oauthError(400, "invalid_request", "Repeated parameter.")
        }
        // CIMD and DCR clients are public and must not send a secret; `cfg_` clients must send theirs,
        // in a Basic header or the body (client_secret_basic or client_secret_post), never both.
        var clientID = form.single("client_id")
        var secret = form.single("client_secret").flatMap { $0.isEmpty ? nil : $0 }
        let headerAuth = request.header("authorization")
        if let headerAuth {
            guard let (user, password) = Self.basicCredentials(headerAuth), secret == nil,
                  clientID == nil || clientID == user else {
                return Self.oauthError(401, "invalid_client", "Send client credentials once.", basic: true)
            }
            clientID = user
            secret = password.isEmpty ? nil : password
        }
        guard let clientID, !clientID.isEmpty else {
            return Self.oauthError(400, "invalid_request", "client_id is required.")
        }
        let expectedSecret = store.state?.registrations.first { $0.clientID == clientID }?.secretHash
        if let expectedSecret {
            guard let secret, Self.match(OAuthStore.digest(secret), in: [[expectedSecret]]) != nil else {
                return Self.oauthError(401, "invalid_client", "The client secret is wrong.",
                                       basic: headerAuth != nil)
            }
        } else if secret != nil {
            return Self.oauthError(401, "invalid_client", "This client is public: send no client_secret.",
                                   basic: headerAuth != nil)
        }
        switch form.single("grant_type") {
        case "authorization_code": return exchangeCode(form, clientID: clientID)
        case "refresh_token": return refresh(form, clientID: clientID, context: context)
        case nil: return Self.oauthError(400, "invalid_request", "grant_type is required.")
        default:
            return Self.oauthError(400, "unsupported_grant_type", "Use authorization_code or refresh_token.")
        }
    }

    private func exchangeCode(_ form: OAuthForm, clientID: String) -> HTTPResponse {
        guard let code = form.single("code") else {
            return Self.oauthError(400, "invalid_request", "code is required.")
        }
        let key = OAuthStore.digest(code)
        let time = now()
        if let spent = spentCodes[key] {
            // A replayed code means someone else holds it too: drop what it produced (OAuth 2.1 §4.1.3).
            if let connection = spent.connection { revoke(connectionID: connection) }
            return Self.oauthError(400, "invalid_grant", "This code was already used.")
        }
        // Single use, whatever the outcome: a failed attempt burns the code.
        guard let grant = codes.removeValue(forKey: key), grant.expiresAt > time else {
            return Self.oauthError(400, "invalid_grant", "The code is invalid or expired.")
        }
        spentCodes[key] = (nil, grant.expiresAt.addingTimeInterval(Self.pairingDuration))
        let authorization = grant.authorization
        guard authorization.oauthClientID == clientID,
              form.single("redirect_uri") == authorization.redirectURI else {
            return Self.oauthError(400, "invalid_grant", "client_id or redirect_uri doesn't match the code.")
        }
        guard let verifier = form.single("code_verifier") else {
            return Self.oauthError(400, "invalid_request", "code_verifier is required.")
        }
        guard Self.validVerifier(verifier), Self.s256(verifier) == authorization.codeChallenge else {
            return Self.oauthError(400, "invalid_grant", "code_verifier doesn't match the code_challenge.")
        }
        if let resource = form.single("resource"),
           Self.canonicalResource(resource) != authorization.resource {
            return Self.oauthError(400, "invalid_target", "resource doesn't match the authorization.")
        }
        guard clientAllowed(grant.clientID) else {
            return Self.oauthError(400, "invalid_grant", "This client no longer allows cloud access.")
        }
        let access = Self.randomToken(prefix: Self.accessPrefix)
        let refresh = Self.randomToken(prefix: Self.refreshPrefix)
        let connection = OAuthConnection(
            id: UUID(), clientID: grant.clientID, appName: grant.appName, oauthClientID: clientID,
            createdAt: time, lastUsedAt: nil, resource: authorization.resource,
            accessHash: OAuthStore.digest(access),
            accessExpiresAt: time.addingTimeInterval(Self.accessLifetime),
            refreshHash: OAuthStore.digest(refresh),
            refreshExpiresAt: time.addingTimeInterval(Self.refreshLifetime), previousRefreshHashes: [])
        var full = false
        let saved = store.update { state in
            state.connections.removeAll { $0.refreshExpiresAt <= time }
            guard state.connections.count < OAuthStore.maxConnections else { full = true; return }
            state.connections.append(connection)
            if let index = state.registrations.firstIndex(where: { $0.clientID == clientID }) {
                state.registrations[index].lastUsedAt = time
            }
        }
        guard saved else { return Self.oauthError(500, "server_error", "Connections couldn't be saved.") }
        guard !full else {
            return Self.oauthError(400, "invalid_grant", "Too many connected apps. Revoke some in "
                                       + "\(AppIdentity.displayName) first.")
        }
        spentCodes[key] = (connection.id, grant.expiresAt.addingTimeInterval(Self.pairingDuration))
        connectionsChanged(grant.clientID)
        return Self.tokenResponse(access: access, refresh: refresh)
    }

    private func refresh(_ form: OAuthForm, clientID: String, context: OAuthContext) -> HTTPResponse {
        guard let presented = form.single("refresh_token") else {
            return Self.oauthError(400, "invalid_request", "refresh_token is required.")
        }
        let invalid = Self.oauthError(400, "invalid_grant", "The refresh token is invalid or expired.")
        guard Self.validToken(presented, prefix: Self.refreshPrefix), let state = store.state else {
            return invalid
        }
        let digest = OAuthStore.digest(presented)
        let time = now()
        let index: Int
        if let current = Self.match(digest, in: state.connections.map { [$0.refreshHash] }) {
            index = current
        } else if let reused = Self.match(digest, in: state.connections.map(\.previousRefreshHashes)) {
            // An already-rotated token: one copy is in the wrong hands, so the connection goes, unless
            // it's an immediate retry of the last rotation whose new tokens nobody has used.
            let connection = state.connections[reused]
            guard connection.previousRefreshHashes.last == digest, connection.usedSinceRotation != true,
                  let rotated = connection.rotatedAt,
                  time.timeIntervalSince(rotated) >= 0,
                  time.timeIntervalSince(rotated) < Self.refreshRetryGrace else {
                revoke(connectionID: connection.id)
                return invalid
            }
            index = reused
        } else {
            return invalid
        }
        var connection = state.connections[index]
        guard connection.oauthClientID == clientID else { return invalid }
        // Expired, or issued for a URL that's no longer this server's (a reset secret path or a new
        // address): the app has to connect again.
        guard connection.refreshExpiresAt > time,
              connection.resource == Self.canonicalResource(context.resource) else {
            revoke(connectionID: connection.id)
            return invalid
        }
        if let resource = form.single("resource"), Self.canonicalResource(resource) != connection.resource {
            return Self.oauthError(400, "invalid_target", "resource doesn't match the connection.")
        }
        guard clientAllowed(connection.clientID) else {
            return Self.oauthError(400, "invalid_grant", "This client no longer allows cloud access.")
        }
        let access = Self.randomToken(prefix: Self.accessPrefix)
        let refresh = Self.randomToken(prefix: Self.refreshPrefix)
        // On a retry the undelivered token is retired too, and the one presented stays the newest
        // previous token, so a second retry within the grace period still works.
        // The grace period runs from the first rotation, so retries can't extend it.
        let isRetry = connection.refreshHash != digest
        let retired = isRetry
            ? connection.previousRefreshHashes.dropLast() + [connection.refreshHash, digest]
            : connection.previousRefreshHashes + [connection.refreshHash]
        connection.previousRefreshHashes = Array(retired.suffix(OAuthStore.maxPreviousRefreshHashes))
        if !isRetry { connection.rotatedAt = time }
        connection.usedSinceRotation = false
        connection.accessHash = OAuthStore.digest(access)
        connection.accessExpiresAt = time.addingTimeInterval(Self.accessLifetime)
        connection.refreshHash = OAuthStore.digest(refresh)
        connection.refreshExpiresAt = time.addingTimeInterval(Self.refreshLifetime)
        connection.lastUsedAt = time
        let id = connection.id
        guard store.update({ state in
            if let index = state.connections.firstIndex(where: { $0.id == id }) {
                state.connections[index] = connection
            }
        }) else { return Self.oauthError(500, "server_error", "Connections couldn't be saved.") }
        return Self.tokenResponse(access: access, refresh: refresh)
    }

    // MARK: Registration and revocation endpoints

    /// RFC 7591, kept as claude.ai's fallback for servers without CIMD. Public clients only.
    private func register(_ request: HTTPRequest) -> HTTPResponse {
        guard store.isAvailable else {
            return Self.oauthError(503, "temporarily_unavailable", "Registrations can't be read right now.")
        }
        // Only while the user has a pairing window open: apps register right
        // before they authorize, and outside a window nobody on the internet
        // can add or churn registrations.
        guard liveWindow != nil else {
            return Self.oauthError(403, "access_denied", "Pairing isn't open. In \(AppIdentity.displayName) "
                                       + "on the Mac, open the client and choose Connect a Cloud App.")
        }
        guard Self.mediaType(request) == "application/json", request.body.count <= Self.maxBodyBytes,
              let object = try? JSONSerialization.jsonObject(with: request.body),
              let metadata = object as? [String: Any] else {
            return Self.oauthError(400, "invalid_client_metadata", "Send client metadata as a JSON object.")
        }
        guard let uris = metadata["redirect_uris"] as? [String], (1...5).contains(uris.count),
              uris.allSatisfy(Self.validRedirectURI) else {
            return Self.oauthError(400, "invalid_redirect_uri", "Send 1–5 redirect_uris: https, or http "
                                       + "only for 127.0.0.1 or localhost.")
        }
        var name: String?
        if let value = metadata["client_name"] {
            guard let text = value as? String, OAuthStore.validName(text) else {
                return Self.oauthError(400, "invalid_client_metadata",
                                       "client_name must be text of at most 100 bytes.")
            }
            name = text
        }
        if let method = metadata["token_endpoint_auth_method"], method as? String != "none" {
            return Self.oauthError(400, "invalid_client_metadata", "token_endpoint_auth_method must be none.")
        }
        let time = now()
        let registration = OAuthRegistration(clientID: "dcr_" + Self.randomToken(prefix: "").prefix(32),
                                             clientName: name, redirectURIs: uris, createdAt: time)
        var full = false
        let saved = store.update { state in
            if state.registrations.count >= OAuthStore.maxRegistrations {
                // Only registrations no connection uses are pruned, oldest first.
                let used = Set(state.connections.map(\.oauthClientID))
                guard let oldest = state.registrations.enumerated()
                    .filter({ !used.contains($0.element.clientID) && !$0.element.isConfidential })
                    .min(by: { $0.element.createdAt < $1.element.createdAt }) else { full = true; return }
                state.registrations.remove(at: oldest.offset)
            }
            state.registrations.append(registration)
        }
        guard saved else {
            return Self.oauthError(500, "server_error", "The registration couldn't be saved.")
        }
        guard !full else { return Self.oauthError(400, "invalid_client_metadata", "Too many registrations.") }
        var body: [String: Any] = [
            "client_id": registration.clientID,
            "client_id_issued_at": Int(time.timeIntervalSince1970),
            "redirect_uris": uris,
            "token_endpoint_auth_method": "none",
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
        ]
        if let name { body["client_name"] = name }
        return Self.json(201, body)
    }

    /// RFC 7009: always 200 for a well-formed request, whether or not the token was known.
    private func revoke(_ request: HTTPRequest) -> HTTPResponse {
        guard let form = Self.form(request), !form.hasDuplicates, let token = form.single("token") else {
            return Self.oauthError(400, "invalid_request", "token is required.")
        }
        let accepted = HTTPResponse(status: 200)
        guard let state = store.state,
              Self.validToken(token, prefix: Self.accessPrefix)
                || Self.validToken(token, prefix: Self.refreshPrefix)
        else { return accepted }
        let digest = OAuthStore.digest(token)
        guard let index = Self.match(digest, in: state.connections.map { [$0.accessHash, $0.refreshHash] })
        else { return accepted }
        let connection = state.connections[index]
        // A public client names itself; another app's client_id can't revoke this connection.
        if let clientID = form.single("client_id"), clientID != connection.oauthClientID { return accepted }
        revoke(connectionID: connection.id)
        return accepted
    }

    // MARK: Bearer validation and connections

    /// The bridge client ID for an unexpired access token issued for `resource` (audience check).
    func authenticate(accessToken: String, resource: String) -> String? {
        guard Self.validToken(accessToken, prefix: Self.accessPrefix), let state = store.state else {
            return nil
        }
        let digest = OAuthStore.digest(accessToken)
        guard let index = Self.match(digest, in: state.connections.map { [$0.accessHash] }) else {
            return nil
        }
        let connection = state.connections[index]
        let time = now()
        guard connection.accessExpiresAt > time,
              connection.resource == Self.canonicalResource(resource),
              clientAllowed(connection.clientID) else { return nil }
        // lastUsedAt is for display: write it at most once a minute, not on every request.
        let persist = lastUsePersist.map { abs(time.timeIntervalSince($0)) >= Self.usePersistInterval }
            ?? true
        let id = connection.id
        let first = connection.usedSinceRotation == false
        guard store.update(persist: persist || first, { state in
            if let index = state.connections.firstIndex(where: { $0.id == id }) {
                state.connections[index].lastUsedAt = time
                state.connections[index].usedSinceRotation = true
            }
        }) else { return nil }
        if persist { lastUsePersist = time }
        return connection.clientID
    }

    func connections(clientID: String) -> [OAuthConnectionView] {
        let time = now()
        return (store.state?.connections ?? [])
            .filter { $0.clientID == clientID && $0.refreshExpiresAt > time }
            .sorted { $0.createdAt < $1.createdAt }
            .map { OAuthConnectionView(id: $0.id, clientID: $0.clientID, appName: $0.appName,
                                       createdAt: $0.createdAt, lastUsedAt: $0.lastUsedAt) }
    }

    func revoke(connectionID: UUID) {
        guard let connection = store.state?.connections.first(where: { $0.id == connectionID }) else {
            return
        }
        store.update { $0.connections.removeAll { $0.id == connectionID } }
        connectionsChanged(connection.clientID)
    }

    /// After the secret path or public address changes: connections issued for the old MCP URL can't
    /// be used or refreshed, so they're removed (with unredeemed codes and open requests) and the
    /// apps have to connect again. Returns how many connections were removed.
    @discardableResult
    func revokeConnections(notFor resource: String) -> Int {
        let current = Self.canonicalResource(resource)
        codes = codes.filter { $0.value.authorization.resource == current }
        if pairings.contains(where: { $0.redirect == nil && $0.authorization.resource != current }) {
            pairings.removeAll { $0.redirect == nil && $0.authorization.resource != current }
            pairingChanged()
        }
        let stale = (store.state?.connections ?? []).filter { $0.resource != current }
        guard !stale.isEmpty else { return 0 }
        store.update { $0.connections.removeAll { $0.resource != current } }
        for clientID in Set(stale.map(\.clientID)) { connectionsChanged(clientID) }
        return stale.count
    }

    /// Also drops codes not yet redeemed for this client, and the confidential clients set up for it.
    func revokeAll(clientID: String) {
        codes = codes.filter { $0.value.clientID != clientID }
        guard let state = store.state,
              state.connections.contains(where: { $0.clientID == clientID })
                || state.registrations.contains(where: { $0.bridgeClientID == clientID }) else { return }
        store.update { state in
            state.connections.removeAll { $0.clientID == clientID }
            state.registrations.removeAll { $0.bridgeClientID == clientID }
        }
        connectionsChanged(clientID)
    }

    /// Sets up a confidential OAuth client for one bridge client, for apps that are configured with
    /// a client ID and secret instead of discovering this server (Gemini Enterprise). It replaces the
    /// bridge client's earlier ones that no connection uses. The secret is returned once and only
    /// its digest is kept. Nil when the store is unavailable or full.
    func registerConfidentialClient(for bridgeClientID: String, name: String,
                                    redirectURI: String) -> (clientID: String, secret: String)? {
        guard clientAllowed(bridgeClientID), Self.validRedirectURI(redirectURI), OAuthStore.validName(name)
        else { return nil }
        let secret = Self.randomToken(prefix: Self.secretPrefix)
        let registration = OAuthRegistration(
            clientID: "cfg_" + Self.randomToken(prefix: "").prefix(32), clientName: name,
            redirectURIs: [redirectURI], createdAt: now(), secretHash: OAuthStore.digest(secret),
            bridgeClientID: bridgeClientID)
        var full = false
        let saved = store.update { state in
            let used = Set(state.connections.map(\.oauthClientID))
            state.registrations.removeAll {
                $0.bridgeClientID == bridgeClientID && !used.contains($0.clientID)
            }
            if state.registrations.count >= OAuthStore.maxRegistrations,
               let oldest = state.registrations.enumerated()
                .filter({ !used.contains($0.element.clientID) && !$0.element.isConfidential })
                .min(by: { $0.element.createdAt < $1.element.createdAt }) {
                state.registrations.remove(at: oldest.offset)
            }
            guard state.registrations.count < OAuthStore.maxRegistrations else { full = true; return }
            state.registrations.append(registration)
        }
        guard saved, !full else { return nil }
        return (registration.clientID, secret)
    }

    // MARK: Helpers

    static func validPrefix(_ prefix: String) -> Bool {
        guard prefix.hasPrefix("/r/") else { return false }
        let secret = prefix.utf8.dropFirst(3)
        return secret.count == 22 && secret.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || $0 == 45 || $0 == 95
        }
    }

    nonisolated static func validToken(_ token: String, prefix: String) -> Bool {
        token.utf8.count == prefix.utf8.count + 64 && token.hasPrefix(prefix)
            && Hex.decode(String(token.dropFirst(prefix.count))) != nil
    }

    /// https anywhere; http only for loopback (RFC 8252 §7.3). No fragments, user info or
    /// non-ASCII, so the URI is safe to put in a `Location` header and navigate to.
    static func validRedirectURI(_ uri: String) -> Bool {
        guard uri.utf8.count <= OAuthStore.maxURIBytes, uri.utf8.allSatisfy({ (0x21...0x7E).contains($0) }),
              let components = URLComponents(string: uri), components.fragment == nil,
              components.user == nil, components.password == nil,
              let host = components.host?.lowercased(), !host.isEmpty else { return false }
        switch components.scheme {
        case "https": return true
        case "http": return ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
        default: return false
        }
    }

    /// Lowercases scheme and host only (RFC 8707 resource identifiers; the MCP spec asks servers to
    /// accept uppercase there). The path, with the secret, stays exact.
    static func canonicalResource(_ resource: String) -> String {
        guard let separator = resource.range(of: "://") else { return resource }
        let rest = resource[separator.upperBound...]
        let end = rest.firstIndex { "/?#".contains($0) } ?? resource.endIndex
        return resource[..<end].lowercased() + resource[end...]
    }

    static func s256(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// RFC 7636 §4.1: 43–128 unreserved characters.
    static func validVerifier(_ verifier: String) -> Bool {
        (43...128).contains(verifier.utf8.count) && verifier.utf8.allSatisfy(isUnreserved)
    }

    /// An S256 challenge is always 43 base64url characters.
    private static func validChallenge(_ challenge: String) -> Bool {
        challenge.utf8.count == 43 && challenge.utf8.allSatisfy { isUnreserved($0) && $0 != 46 && $0 != 126 }
    }

    private static func isUnreserved(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
            || byte == 45 || byte == 46 || byte == 95 || byte == 126
    }

    /// Sanitized display name: no control or format characters (bidi overrides), at most 100 bytes.
    static func displayName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let kept = raw.unicodeScalars.filter {
            $0.properties.generalCategory != .control && $0.properties.generalCategory != .format
        }
        var name = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespacesAndNewlines)
        while name.utf8.count > OAuthStore.maxNameBytes { name.removeLast() }
        return name.isEmpty ? nil : name
    }

    /// Index of the entry holding `digest`, comparing against every hash without stopping early.
    private static func match(_ digest: String, in hashes: [[String]]) -> Int? {
        let wanted = Array(digest.utf8)
        var found: Int?
        for (index, group) in hashes.enumerated() {
            for hash in group {
                let stored = Array(hash.utf8)
                guard stored.count == wanted.count else { continue }
                var difference: UInt8 = 0
                for offset in 0..<wanted.count { difference |= stored[offset] ^ wanted[offset] }
                if difference == 0 { found = index }
            }
        }
        return found
    }

    private static func randomToken(prefix: String) -> String {
        var generator = SystemRandomNumberGenerator()
        return prefix + Hex.encode(Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) }))
    }

    private static func pairingCode() -> String {
        var generator = SystemRandomNumberGenerator()
        let digits = String(format: "%06ld", Int.random(in: 0..<1_000_000, using: &generator))
        return String(digits.prefix(3)) + " " + String(digits.suffix(3))
    }

    private static func redirect(_ authorization: Authorization, _ parameters: [String: String]) -> String {
        var pairs = parameters.sorted { $0.key < $1.key }
        if let state = authorization.state { pairs.append(("state", state)) }
        pairs.append(("iss", authorization.issuer))
        let query = pairs.map { "\($0)=\(Self.encode($1))" }.joined(separator: "&")
        return authorization.redirectURI + (authorization.redirectURI.contains("?") ? "&" : "?") + query
    }

    private static func redirectResponse(_ location: String) -> HTTPResponse {
        HTTPResponse(status: 302, headers: [("Location", location)] + OAuthPages.securityHeaders)
    }

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func query(_ target: String) -> String {
        guard let mark = target.firstIndex(of: "?") else { return "" }
        return String(target[target.index(after: mark)...])
    }

    private static func mediaType(_ request: HTTPRequest) -> String? {
        request.header("content-type")?.split(separator: ";").first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    private static func form(_ request: HTTPRequest) -> OAuthForm? {
        guard mediaType(request) == "application/x-www-form-urlencoded",
              request.body.count <= maxBodyBytes,
              let text = String(data: request.body, encoding: .utf8) else { return nil }
        return OAuthForm(text)
    }

    private static func basicCredentials(_ header: String) -> (String, String)? {
        guard header.count > 6, header.prefix(6).lowercased() == "basic ",
              let data = Data(base64Encoded: header.dropFirst(6).trimmingCharacters(in: .whitespaces)),
              let text = String(data: data, encoding: .utf8), let colon = text.firstIndex(of: ":"),
              let user = OAuthForm.decode(text[..<colon]),
              let secret = OAuthForm.decode(text[text.index(after: colon)...]) else { return nil }
        return (user, secret)
    }

    private static func tokenResponse(access: String, refresh: String) -> HTTPResponse {
        json(200, [
            "access_token": access,
            "token_type": "Bearer",
            "expires_in": Int(accessLifetime),
            "refresh_token": refresh,
            "scope": scope,
        ])
    }

    private static func oauthError(_ status: Int, _ error: String, _ description: String,
                                   basic: Bool = false) -> HTTPResponse {
        var response = json(status, ["error": error, "error_description": description])
        if basic {
            response.headers.append(("WWW-Authenticate", "Basic realm=\"\(AppIdentity.displayName)\""))
        }
        return response
    }

    private static func unavailablePage() -> HTTPResponse {
        OAuthPages.error(503, title: "Connections can’t be read",
                         message: "\(AppIdentity.displayName) can’t read its list of connected apps, so "
                             + "it isn’t accepting new ones. Check the app on your Mac.")
    }

    static func json(_ status: Int, _ object: [String: Any]) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object,
                                                options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return HTTPResponse(status: status, headers: [
            ("Content-Type", "application/json"),
            ("Cache-Control", "no-store"),
            ("Pragma", "no-cache"),
        ], body: body)
    }
}

/// `application/x-www-form-urlencoded` pairs, as in query strings and token request bodies.
struct OAuthForm {
    private(set) var values: [String: [String]] = [:]

    /// Nil when any name or value isn't valid percent-encoded UTF-8.
    init?(_ text: String) {
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = Self.decode(parts[0]),
                  let value = Self.decode(parts.count > 1 ? parts[1] : "") else { return nil }
            values[name, default: []].append(value)
        }
    }

    /// The value when the parameter appears exactly once.
    func single(_ name: String) -> String? {
        guard let all = values[name], all.count == 1 else { return nil }
        return all[0]
    }

    /// OAuth parameters must not repeat (RFC 6749 §3.1).
    var hasDuplicates: Bool { values.values.contains { $0.count > 1 } }

    static func decode(_ text: Substring) -> String? {
        text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }
}
