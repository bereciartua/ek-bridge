import CryptoKit
import Darwin
import Foundation

enum ClientResource: String, Codable { case calendar, reminderList }

struct ClientGrant: Codable, Equatable {
    let resource: ClientResource
    let targetID: String
    let mask: Int

    static let read = 1
    static let create = 2
    static let edit = 4
    static let delete = 8
    static let complete = 16

    var isValid: Bool {
        let allowed = resource == .calendar ? 15 : 31
        return !targetID.isEmpty && targetID.utf8.count <= 512 &&
            targetID.rangeOfCharacter(from: .controlCharacters) == nil &&
            mask > 0 && mask & ~allowed == 0
    }

    func allows(_ command: BridgeCommand) -> Bool {
        let required: Int
        switch command {
        case .readEvents where resource == .calendar, .getEvent where resource == .calendar,
             .readReminders where resource == .reminderList,
             .getReminder where resource == .reminderList: required = Self.read
        case .createEvent where resource == .calendar,
             .createReminder where resource == .reminderList: required = Self.create
        case .updateEvent where resource == .calendar,
             .updateReminder where resource == .reminderList: required = Self.edit
        case .deleteEvent where resource == .calendar,
             .deleteReminder where resource == .reminderList: required = Self.delete
        case .completeReminder where resource == .reminderList: required = Self.complete
        default: return false
        }
        return mask & required != 0
    }
}

/// Whether writes from a client wait for the user's Allow (Ask before changes).
enum ApprovalMode: String, Codable, Equatable { case ask, allow }

struct ClientView: Equatable {
    let id: String
    let name: String
    let revoked: Bool
    let grants: [ClientGrant]
    var revokedAt: Date? = nil
    var hasSigningKey = true
    var hasMCPToken = false
    var mcpIssuedAt: Date? = nil
    var approval = ApprovalMode.allow
    /// Remote Access: whether cloud agents may use this client, and whether
    /// it holds a remote token (OAuth connections are kept elsewhere).
    var cloudAccess = false
    var hasRemoteToken = false
    var remoteIssuedAt: Date? = nil
}

/// How a request reached the bridge. The agent name is what the agent reported
/// about itself (MCP `clientInfo`), sanitized, and is for display only.
enum RequestOrigin: Equatable {
    case cli
    case mcp(agent: String?)
    /// Through Remote Access (a tunnel to the remote port).
    case remote(agent: String?)

    var via: String {
        switch self {
        case .cli: "cli"
        case .mcp: "mcp"
        case .remote: "remote"
        }
    }
    var agent: String? {
        switch self {
        case .cli: nil
        case .mcp(let agent), .remote(let agent): agent
        }
    }
    var isRemote: Bool {
        if case .remote = self { return true }
        return false
    }
}

// Activity stores time, client ID, command, outcome and the target calendar or
// list ID. It never stores titles, parameters or item content.
struct ClientActivity: Codable, Equatable {
    let at: Date
    let clientID: String?
    let command: String
    let outcome: String
    // Version 3 field. Version 2 rows decode as nil.
    var targetID: String? = nil
    // Version 4 fields. Older rows decode as nil.
    var via: String? = nil
    var agent: String? = nil
    /// "user", "window", "denied" or "timeout" when Ask before changes applied.
    var approval: String? = nil

    static let approvalDetails: Set<String> = ["user", "window", "denied", "timeout"]
}

struct AuthorizedClientCall {
    let clientID: String
    let clientName: String
    let revision: Int
    let command: BridgeCommand
    let targetID: String?
    let grant: ClientGrant?
    var origin = RequestOrigin.cli
    /// A move's destination, where the client holds Create (plan 03 §13).
    var moveTargetID: String? = nil
    var approval = ApprovalMode.allow
    /// How Ask before changes was answered, for the result row.
    var approvalDetail: String? = nil
}

enum ClientRegistryError: String, Error {
    case unavailable
    case invalidName
    case invalidGrants
    case limitReached
    case clientMissing
    case clientRevoked
    case duplicateName
    case unauthorized
    case forbidden
}

enum ClientNameIssue: Equatable {
    case empty
    case tooLong
    case controlCharacters
    case duplicate(String)
}

// The store protects against other UIDs and unsafe paths. It does not isolate
// its policy file from another process running as this same macOS user.
//
// Not thread-safe: it caches state and persists without locks. Use it from the
// main thread only (the MCP server hops there before authenticating).
final class ClientRegistry {
    private struct Record: Codable, Equatable {
        let id: String
        var name: String
        // Ed25519 public key (hex) of the CLI key, or "" when the client has none.
        var verifier: String
        var revoked: Bool
        var revision: Int
        var grants: [ClientGrant]
        // Version 3 field. Nil for records revoked before version 3.
        var revokedAt: Date?
        // Version 4 fields. SHA-256 (hex) of the MCP token; nil = no MCP access.
        var mcpVerifier: String?
        var mcpIssuedAt: Date?
        // Nil decodes as .allow, the behavior before version 4.
        var approval: ApprovalMode?
        // Remote Access. Off and no token when absent.
        var remoteEnabled: Bool?
        var remoteVerifier: String?
        var remoteIssuedAt: Date?
    }
    private struct State: Codable {
        var version = ClientRegistry.currentVersion
        var clients = [Record]()
        var activity = [ClientActivity]()
    }

    static let currentVersion = 4
    // Only active clients count toward this limit. Revoked records are kept
    // for history, with their own cap; the oldest are pruned first.
    static let maxActiveClients = 32
    static let maxRevokedClients = 200
    static let maxActivity = 500
    static let maxAgentBytes = 64
    static let mcpTokenPrefix = "ekb_mcp_v1_"
    static let remoteTokenPrefix = "ekb_mcpr_v1_"
    // Failed MCP authentications are coalesced so a misconfigured agent can't
    // flush the Activity history.
    static let failedAuthRecordInterval: TimeInterval = 10

    static func backupFileName(version: Int) -> String { "client-registry.v\(version).backup.json" }

    private let directory: URL
    private let file: URL
    private let now: () -> Date
    private var state: State?
    private var failed = false
    // Raw bytes and version of an older file, kept until the one-time backup is written.
    private var pendingBackup: (data: Data, version: Int)?
    private var lastFailedAuthRecord = [String: Date]()

    init(directory override: URL? = nil, now: @escaping () -> Date = Date.init) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask)[0]
        directory = override ?? support.appendingPathComponent("EventKitBridge", isDirectory: true)
        file = directory.appendingPathComponent("client-registry.json")
        self.now = now
    }

    func clients() -> [ClientView]? {
        guard load() else { return nil }
        return state!.clients.map {
            ClientView(id: $0.id, name: $0.name, revoked: $0.revoked,
                       grants: $0.grants, revokedAt: $0.revokedAt,
                       hasSigningKey: !$0.verifier.isEmpty, hasMCPToken: $0.mcpVerifier != nil,
                       mcpIssuedAt: $0.mcpIssuedAt, approval: $0.approval ?? .allow,
                       cloudAccess: $0.remoteEnabled ?? false, hasRemoteToken: $0.remoteVerifier != nil,
                       remoteIssuedAt: $0.remoteIssuedAt)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func activity() -> [ClientActivity]? {
        guard load() else { return nil }
        return Array(state!.activity.reversed())
    }

    func createClient(name: String, credentials: Set<CredentialKind> = [.signingKey],
                      approval: ApprovalMode = .allow)
        -> Result<(id: String, signingKey: String?, mcpToken: String?), ClientRegistryError> {
        guard load() else { return .failure(.unavailable) }
        guard Self.validName(name) else { return .failure(.invalidName) }
        guard !nameTaken(name, excluding: nil) else { return .failure(.duplicateName) }
        guard state!.clients.filter({ !$0.revoked }).count < Self.maxActiveClients else {
            return .failure(.limitReached)
        }
        let signing = credentials.contains(.signingKey) ? Self.newSigningKey() : nil
        let token = credentials.contains(.mcpToken) ? Self.newMCPToken() : nil
        let id = UUID().uuidString.lowercased()
        var next = state!
        next.clients.append(Record(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                   verifier: signing?.verifier ?? "",
                                   revoked: false, revision: 1, grants: [], revokedAt: nil,
                                   mcpVerifier: token.map(Self.tokenDigest),
                                   mcpIssuedAt: token == nil ? nil : now(), approval: approval))
        guard persist(next) else { return .failure(.unavailable) }
        return .success((id, signing?.key, token))
    }

    /// Replaces the CLI key, or adds one to a client that has none.
    func rotateKey(clientID: String) -> Result<String, ClientRegistryError> {
        updateActive(clientID) { record in
            let signing = Self.newSigningKey()
            record.verifier = signing.verifier
            record.revision += 1
            return signing.key
        }
    }

    func addSigningKey(clientID: String) -> Result<String, ClientRegistryError> {
        rotateKey(clientID: clientID)
    }

    func removeSigningKey(clientID: String) -> Result<Void, ClientRegistryError> {
        updateActive(clientID) { record in
            guard !record.verifier.isEmpty else { return }
            record.verifier = ""
            record.revision += 1
        }
    }

    /// Issues a new MCP token (turning MCP access on, or resetting the token).
    /// Only its digest is stored; the caller writes the token file.
    func issueMCPToken(clientID: String) -> Result<String, ClientRegistryError> {
        updateActive(clientID) { record in
            let token = Self.newMCPToken()
            record.mcpVerifier = Self.tokenDigest(token)
            record.mcpIssuedAt = now()
            record.revision += 1
            return token
        }
    }

    func removeMCPToken(clientID: String) -> Result<Void, ClientRegistryError> {
        updateActive(clientID) { record in
            guard record.mcpVerifier != nil else { return }
            record.mcpVerifier = nil
            record.mcpIssuedAt = nil
            record.revision += 1
        }
    }

    /// Remote Access for one client. Turning it off removes the remote token;
    /// the caller revokes the client's OAuth connections.
    func setCloudAccess(clientID: String, _ on: Bool) -> Result<Void, ClientRegistryError> {
        updateActive(clientID) { record in
            guard (record.remoteEnabled ?? false) != on else { return }
            record.remoteEnabled = on
            if !on {
                record.remoteVerifier = nil
                record.remoteIssuedAt = nil
            }
            record.revision += 1
        }
    }

    /// Issues a new remote token (or resets it). Needs cloud access on.
    func issueRemoteToken(clientID: String) -> Result<String, ClientRegistryError> {
        if case .success(let client) = activeRecord(clientID), client.remoteEnabled != true {
            return .failure(.forbidden)
        }
        return updateActive(clientID) { record in
            let token = Self.newToken(prefix: Self.remoteTokenPrefix)
            record.remoteVerifier = Self.tokenDigest(token)
            record.remoteIssuedAt = now()
            record.revision += 1
            return token
        }
    }

    func removeRemoteToken(clientID: String) -> Result<Void, ClientRegistryError> {
        updateActive(clientID) { record in
            guard record.remoteVerifier != nil else { return }
            record.remoteVerifier = nil
            record.remoteIssuedAt = nil
            record.revision += 1
        }
    }

    /// For changes that live outside the registry but must invalidate work in
    /// flight, like a cloud app's OAuth connection being added or revoked.
    func bumpRevision(clientID: String) -> Result<Void, ClientRegistryError> {
        updateActive(clientID) { $0.revision += 1 }
    }

    /// Whether a client may be used from Remote Access right now.
    func cloudAccessAllowed(clientID: String) -> Bool {
        if case .success(let record) = activeRecord(clientID) { return record.remoteEnabled == true }
        return false
    }

    private func activeRecord(_ clientID: String) -> Result<Record, ClientRegistryError> {
        checkThread()
        guard load() else { return .failure(.unavailable) }
        guard let record = state!.clients.first(where: { $0.id == clientID && !$0.revoked }) else {
            return .failure(.clientMissing)
        }
        return .success(record)
    }

    func setApproval(clientID: String, _ mode: ApprovalMode) -> Result<Void, ClientRegistryError> {
        updateActive(clientID) { record in
            guard (record.approval ?? .allow) != mode else { return }
            record.approval = mode
            record.revision += 1
        }
    }

    func revoke(clientID: String) -> Result<Void, ClientRegistryError> {
        guard load() else { return .failure(.unavailable) }
        guard let index = state!.clients.firstIndex(where: { $0.id == clientID }) else {
            return .failure(.clientMissing)
        }
        var next = state!
        if !next.clients[index].revoked { next.clients[index].revokedAt = now() }
        next.clients[index].revoked = true
        next.clients[index].verifier = ""
        next.clients[index].mcpVerifier = nil
        next.clients[index].mcpIssuedAt = nil
        next.clients[index].remoteEnabled = nil
        next.clients[index].remoteVerifier = nil
        next.clients[index].remoteIssuedAt = nil
        next.clients[index].revision += 1
        Self.pruneRevoked(&next)
        guard persist(next) else { return .failure(.unavailable) }
        return .success(())
    }

    // The name is not part of authorization, so renaming keeps the revision and
    // requests already in flight are unaffected.
    func rename(clientID: String, name: String) -> Result<Void, ClientRegistryError> {
        guard load() else { return .failure(.unavailable) }
        guard let index = state!.clients.firstIndex(where: { $0.id == clientID }) else {
            return .failure(.clientMissing)
        }
        guard !state!.clients[index].revoked else { return .failure(.clientRevoked) }
        guard Self.validName(name) else { return .failure(.invalidName) }
        guard !nameTaken(name, excluding: clientID) else { return .failure(.duplicateName) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard state!.clients[index].name != trimmed else { return .success(()) }
        var next = state!
        next.clients[index].name = trimmed
        guard persist(next) else { return .failure(.unavailable) }
        return .success(())
    }

    /// Inline validation for name fields. Nil means the name can be used.
    func nameIssue(_ name: String, excluding clientID: String? = nil) -> ClientNameIssue? {
        if let issue = Self.nameShapeIssue(name) { return issue }
        guard load() else { return nil }
        let key = Self.nameKey(name)
        if let other = state!.clients.first(where: {
            !$0.revoked && $0.id != clientID && Self.nameKey($0.name) == key
        }) { return .duplicate(other.name) }
        return nil
    }

    static func nameShapeIssue(_ name: String) -> ClientNameIssue? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if trimmed.rangeOfCharacter(from: .controlCharacters) != nil { return .controlCharacters }
        if trimmed.utf8.count > 80 { return .tooLong }
        return nil
    }

    private func nameTaken(_ name: String, excluding clientID: String?) -> Bool {
        let key = Self.nameKey(name)
        return state!.clients.contains {
            !$0.revoked && $0.id != clientID && Self.nameKey($0.name) == key
        }
    }

    private static func nameKey(_ name: String) -> String { ClientNames.key(name) }

    private static func pruneRevoked(_ state: inout State) {
        let revoked = state.clients.filter(\.revoked)
        guard revoked.count > maxRevokedClients else { return }
        // Legacy records without a revoke time are the oldest by definition.
        let oldest = revoked.sorted {
            ($0.revokedAt ?? .distantPast) < ($1.revokedAt ?? .distantPast)
        }.prefix(revoked.count - maxRevokedClients)
        let pruned = Set(oldest.map(\.id))
        state.clients.removeAll { pruned.contains($0.id) }
    }

    func replaceGrants(clientID: String, grants: [ClientGrant])
        -> Result<Void, ClientRegistryError> {
        guard load() else { return .failure(.unavailable) }
        guard let index = state!.clients.firstIndex(where: { $0.id == clientID }) else {
            return .failure(.clientMissing)
        }
        guard !state!.clients[index].revoked else { return .failure(.clientRevoked) }
        let identities = grants.map { "\($0.resource.rawValue):\($0.targetID)" }
        guard grants.count <= 100, grants.allSatisfy(\.isValid),
              Set(identities).count == identities.count else {
            return .failure(.invalidGrants)
        }
        var next = state!
        next.clients[index].grants = grants
        next.clients[index].revision += 1
        guard persist(next) else { return .failure(.unavailable) }
        return .success(())
    }

    /// CLI transport: verifies the request signature against the client's key.
    func authenticateSignature(clientID: String, signature: Data, signedPayload: Data,
                               command: BridgeCommand) -> Result<String, ClientRegistryError> {
        checkThread()
        guard load() else { return .failure(.unavailable) }
        let candidate = state!.clients.first { $0.id == clientID && !$0.revoked }
        let verifier = candidate.flatMap { Self.unhex($0.verifier) }
            .flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
        guard candidate != nil, let verifier, signature.count == 64,
              verifier.isValidSignature(signature, for: signedPayload) else {
            _ = record(clientID: nil, command: command.rawValue, outcome: "unauthorized",
                       origin: .cli)
            return .failure(.unauthorized)
        }
        return .success(clientID)
    }

    /// MCP transport: finds the client whose token digest matches.
    ///
    /// Plain SHA-256 is deliberate. The token is 256 random bits, so there is
    /// nothing to brute-force and a slow password hash would add only latency.
    func authenticateMCPToken(_ presented: String) -> Result<String, ClientRegistryError> {
        authenticate(presented, valid: Self.validMCPToken, verifier: { $0.mcpVerifier },
                     origin: .mcp(agent: nil))
    }

    /// Remote Access. Only remote tokens of clients with cloud access on
    /// match; a local MCP token never works through the tunnel, and a remote
    /// token never works locally.
    func authenticateRemoteToken(_ presented: String) -> Result<String, ClientRegistryError> {
        authenticate(presented, valid: Self.validRemoteToken,
                     verifier: { $0.remoteEnabled == true ? $0.remoteVerifier : nil },
                     origin: .remote(agent: nil))
    }

    private func authenticate(_ presented: String, valid: (String) -> Bool,
                              verifier: (Record) -> String?, origin: RequestOrigin)
        -> Result<String, ClientRegistryError> {
        checkThread()
        guard load() else { return .failure(.unavailable) }
        guard valid(presented) else {
            recordFailedAuth(origin)
            return .failure(.unauthorized)
        }
        let digest = Array(SHA256.hash(data: Data(presented.utf8)))
        // Compare against every active verifier without stopping early, so the
        // time taken doesn't depend on which client (if any) matched.
        var match: String?
        for record in state!.clients where !record.revoked {
            guard let stored = verifier(record).flatMap(Self.unhex), stored.count == 32 else { continue }
            var difference: UInt8 = 0
            for index in 0..<32 { difference |= stored[index] ^ digest[index] }
            if difference == 0 { match = record.id }
        }
        guard let match else {
            recordFailedAuth(origin)
            return .failure(.unauthorized)
        }
        return .success(match)
    }

    /// Shared by every transport after authentication: the grant check, plus
    /// an "accepted" Activity row.
    func authorize(clientID: String, request: BridgeRequest, origin: RequestOrigin)
        -> Result<AuthorizedClientCall, ClientRegistryError> {
        checkThread()
        guard load() else { return .failure(.unavailable) }
        guard let candidate = state!.clients.first(where: { $0.id == clientID && !$0.revoked }) else {
            _ = record(clientID: nil, command: request.command.rawValue, outcome: "unauthorized",
                       origin: origin)
            return .failure(.unauthorized)
        }
        let targetID = Self.targetID(request)
        if !request.command.isClientLevel && targetID == nil {
            _ = record(clientID: clientID, command: request.command.rawValue, outcome: "forbidden",
                       origin: origin)
            return .failure(.forbidden)
        }
        let grant = candidate.grants.first {
            $0.targetID == targetID && $0.allows(request.command)
        }
        if targetID != nil && grant == nil {
            _ = record(clientID: clientID, command: request.command.rawValue,
                       outcome: "forbidden", targetID: targetID, origin: origin)
            return .failure(.forbidden)
        }
        // Moving needs Edit here and Create on the destination.
        let moveTargetID = Self.moveTargetID(request)
        if let moveTargetID, let grant,
           !candidate.grants.contains(where: { Self.allowsMove(into: $0, moveTargetID, from: grant) }) {
            _ = record(clientID: clientID, command: request.command.rawValue,
                       outcome: "forbidden", targetID: targetID, origin: origin)
            return .failure(.forbidden)
        }
        var call = AuthorizedClientCall(clientID: clientID, clientName: candidate.name,
                                        revision: candidate.revision,
                                        command: request.command,
                                        targetID: targetID, grant: grant, origin: origin,
                                        approval: candidate.approval ?? .allow)
        call.moveTargetID = moveTargetID
        guard record(clientID: clientID, command: request.command.rawValue,
                     outcome: "accepted", targetID: targetID, origin: origin) else {
            return .failure(.unavailable)
        }
        return .success(call)
    }

    func stillAuthorized(_ call: AuthorizedClientCall) -> Bool {
        checkThread()
        guard load(), let current = state!.clients.first(where: { $0.id == call.clientID }),
              !current.revoked, current.revision == call.revision else { return false }
        guard let targetID = call.targetID else { return true }
        guard let grant = current.grants.first(where: { $0.targetID == targetID && $0.allows(call.command) })
        else { return false }
        guard let moveTargetID = call.moveTargetID else { return true }
        return current.grants.contains { Self.allowsMove(into: $0, moveTargetID, from: grant) }
    }

    /// The destination of a move (`targetCalendarID`, `targetListID`) when it
    /// differs from the source.
    static func moveTargetID(_ request: BridgeRequest) -> String? {
        let key: String
        switch request.command {
        case .updateEvent: key = "targetCalendarID"
        case .updateReminder: key = "targetListID"
        default: return nil
        }
        guard let destination = request.parameters[key] as? String,
              destination != targetID(request) else { return nil }
        return destination
    }

    private static func allowsMove(into grant: ClientGrant, _ destination: String, from source: ClientGrant) -> Bool {
        grant.targetID == destination && grant.resource == source.resource && grant.mask & ClientGrant.create != 0
    }

    @discardableResult
    func recordResult(_ call: AuthorizedClientCall, outcome: String) -> Bool {
        checkThread()
        return record(clientID: call.clientID, command: call.command.rawValue, outcome: outcome,
                      targetID: call.targetID, origin: call.origin, approval: call.approvalDetail)
    }

    /// For requests refused before authorization (bridge off, rate limited),
    /// so the user can still see that a client tried.
    @discardableResult
    func recordRejected(clientID: String, request: BridgeRequest, outcome: String,
                        origin: RequestOrigin) -> Bool {
        checkThread()
        return record(clientID: clientID, command: request.command.rawValue, outcome: outcome,
                      targetID: Self.targetID(request), origin: origin)
    }

    /// Failed authentications are coalesced, per transport, so a misconfigured
    /// agent or an internet scanner can't flush the Activity history.
    private func recordFailedAuth(_ origin: RequestOrigin) {
        let current = now()
        if let last = lastFailedAuthRecord[origin.via],
           current.timeIntervalSince(last) < Self.failedAuthRecordInterval,
           current >= last { return }
        lastFailedAuthRecord[origin.via] = current
        _ = record(clientID: nil, command: "mcp", outcome: "unauthorized", origin: origin)
    }

    /// The failed-auth path for credentials checked elsewhere (OAuth tokens).
    func recordFailedRemoteAuth() {
        checkThread()
        guard load() else { return }
        recordFailedAuth(.remote(agent: nil))
    }

    static func targetID(_ request: BridgeRequest) -> String? {
        switch request.command {
        case .readEvents, .getEvent, .createEvent, .updateEvent, .deleteEvent:
            return request.parameters["calendarID"] as? String
        case .readReminders, .getReminder, .createReminder, .updateReminder,
             .completeReminder, .deleteReminder:
            return request.parameters["listID"] as? String
        default: return nil
        }
    }

    private func record(clientID: String?, command: String, outcome: String,
                        targetID: String? = nil, origin: RequestOrigin,
                        approval: String? = nil) -> Bool {
        guard load() else { return false }
        var next = state!
        next.activity.append(ClientActivity(
            at: now(), clientID: clientID, command: command, outcome: outcome,
            targetID: targetID.flatMap { Self.validTargetID($0) ? $0 : nil },
            via: origin.via, agent: origin.agent.flatMap(Self.sanitizedAgent),
            approval: approval.flatMap { ClientActivity.approvalDetails.contains($0) ? $0 : nil }))
        if next.activity.count > Self.maxActivity {
            next.activity.removeFirst(next.activity.count - Self.maxActivity)
        }
        return persist(next)
    }

    static func validName(_ name: String) -> Bool {
        nameShapeIssue(name) == nil
    }

    /// The agent's self-reported name for display: control characters removed,
    /// whitespace collapsed, at most 64 UTF-8 bytes (cut at a character boundary).
    static func sanitizedAgent(_ raw: String) -> String? {
        let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : $0
        })).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var result = ""
        for character in cleaned {
            if result.utf8.count + String(character).utf8.count > maxAgentBytes { break }
            result.append(character)
        }
        return result.isEmpty ? nil : result
    }

    static func validAgent(_ agent: String) -> Bool {
        !agent.isEmpty && agent.utf8.count <= maxAgentBytes &&
            agent.rangeOfCharacter(from: .controlCharacters) == nil
    }

    static func validMCPToken(_ token: String) -> Bool {
        token.utf8.count == 75 && token.hasPrefix(mcpTokenPrefix) &&
            token.utf8.dropFirst(11).allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func validRemoteToken(_ token: String) -> Bool {
        token.utf8.count == 76 && token.hasPrefix(remoteTokenPrefix) &&
            token.utf8.dropFirst(12).allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func tokenDigest(_ token: String) -> String {
        hex(Data(SHA256.hash(data: Data(token.utf8))))
    }

    private static func newSigningKey() -> (key: String, verifier: String) {
        let key = Curve25519.Signing.PrivateKey()
        return ("ekb_v1_" + hex(key.rawRepresentation), hex(key.publicKey.rawRepresentation))
    }

    private static func newMCPToken() -> String { newToken(prefix: mcpTokenPrefix) }

    private static func newToken(prefix: String) -> String {
        // SystemRandomNumberGenerator reads the kernel CSPRNG.
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return prefix + hex(Data(bytes))
    }

    /// Applies `change` to an active client and persists only if it changed.
    private func updateActive<T>(_ clientID: String, _ change: (inout Record) -> T)
        -> Result<T, ClientRegistryError> {
        checkThread()
        guard load() else { return .failure(.unavailable) }
        guard let index = state!.clients.firstIndex(where: { $0.id == clientID }) else {
            return .failure(.clientMissing)
        }
        guard !state!.clients[index].revoked else { return .failure(.clientRevoked) }
        var next = state!
        let result = change(&next.clients[index])
        guard next.clients[index] != state!.clients[index] else { return .success(result) }
        guard persist(next) else { return .failure(.unavailable) }
        return .success(result)
    }

    private func checkThread() {
        dispatchPrecondition(condition: .onQueue(.main))
    }

    // Same limits as grant target IDs.
    static func validTargetID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 512 && id.rangeOfCharacter(from: .controlCharacters) == nil
    }
    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
    private static func unhex(_ string: String) -> Data? {
        guard string.count.isMultiple(of: 2), string.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0)
        }) else { return nil }
        var data = Data()
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    private func load() -> Bool {
        if failed { return false }
        if state != nil { return true }
        if !FileManager.default.fileExists(atPath: directory.path) {
            state = State()
            return true
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0,
              info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o077 == 0 else { failed = true; return false }
        if !FileManager.default.fileExists(atPath: file.path) {
            state = State()
            return true
        }
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { failed = true; return false }
        defer { close(fd) }
        guard fstat(fd, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_size <= 1_000_000,
              let data = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                .read(upToCount: 1_000_001),
              let decoded = try? JSONDecoder().decode(State.self, from: data),
              (2...Self.currentVersion).contains(decoded.version),
              decoded.clients.filter({ !$0.revoked }).count <= Self.maxActiveClients,
              decoded.clients.count <= Self.maxActiveClients + Self.maxRevokedClients,
              decoded.activity.count <= Self.maxActivity,
              decoded.activity.allSatisfy({
                  ($0.targetID.map(Self.validTargetID) ?? true) &&
                  ($0.via == nil || ["cli", "mcp", "remote"].contains($0.via!)) &&
                  ($0.agent.map(Self.validAgent) ?? true) &&
                  ($0.approval.map(ClientActivity.approvalDetails.contains) ?? true)
              }),
              Set(decoded.clients.map(\.id)).count == decoded.clients.count,
              decoded.clients.allSatisfy(Self.validRecord),
              Self.uniqueTokenVerifiers(decoded.clients)
        else { failed = true; return false }
        // An older file loads as-is and is written as the current version on
        // the next persist, after a one-time backup of the original bytes.
        if decoded.version < Self.currentVersion { pendingBackup = (data, decoded.version) }
        var upgraded = decoded
        upgraded.version = Self.currentVersion
        state = upgraded
        return true
    }

    private static func validRecord(_ record: Record) -> Bool {
        guard UUID(uuidString: record.id) != nil, validName(record.name),
              record.revision > 0, record.grants.count <= 100,
              record.grants.allSatisfy(\.isValid) else { return false }
        if record.revoked {
            return record.verifier.isEmpty && record.mcpVerifier == nil && record.remoteVerifier == nil
        }
        // A remote token exists only while cloud access is on.
        if record.remoteVerifier != nil && record.remoteEnabled != true { return false }
        return (record.verifier.isEmpty || unhex(record.verifier)?.count == 32) &&
            (record.mcpVerifier.map { unhex($0)?.count == 32 } ?? true) &&
            (record.remoteVerifier.map { unhex($0)?.count == 32 } ?? true)
    }

    private static func uniqueTokenVerifiers(_ records: [Record]) -> Bool {
        let active = records.filter { !$0.revoked }
        let local = active.compactMap(\.mcpVerifier)
        let remote = active.compactMap(\.remoteVerifier)
        return Set(local).count == local.count && Set(remote).count == remote.count
    }

    // Older builds fail closed on a newer file, so keep the original bytes of
    // the version that was read, once, to make a rollback possible.
    private func writeBackupIfNeeded() -> Bool {
        guard let (data, version) = pendingBackup else { return true }
        let backup = directory.appendingPathComponent(Self.backupFileName(version: version))
        let fd = open(backup.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd < 0 {
            // An earlier backup already exists; never overwrite it.
            if errno == EEXIST { pendingBackup = nil; return true }
            return false
        }
        let written = data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return false }
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if count <= 0 { return false }
                offset += count
            }
            return fsync(fd) == 0
        }
        close(fd)
        guard written else { unlink(backup.path); return false }
        pendingBackup = nil
        return true
    }

    private func persist(_ next: State) -> Bool {
        guard !failed, let data = try? JSONEncoder().encode(next), data.count <= 1_000_000
        else { failed = true; return false }
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST {
            failed = true; return false
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0,
              info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o077 == 0 else { failed = true; return false }
        guard writeBackupIfNeeded() else { return false }
        let temporary = directory.appendingPathComponent(".tmp-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { failed = true; return false }
        let written = data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return false }
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if count <= 0 { return false }
                offset += count
            }
            return fsync(fd) == 0
        }
        close(fd)
        guard written, Darwin.rename(temporary.path, file.path) == 0 else {
            unlink(temporary.path)
            failed = true; return false
        }
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { failed = true; return false }
        defer { close(directoryFD) }
        guard fsync(directoryFD) == 0 else { failed = true; return false }
        state = next
        return true
    }
}
