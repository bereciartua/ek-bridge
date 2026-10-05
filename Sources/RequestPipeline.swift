import Foundation

/// A calendar or reminder list as macOS reports it, for `list_collections`
/// and the inline counts. Kept free of AppKit so the MCP harness can fake it.
struct CollectionRecord: Equatable {
    let id: String
    let name: String
    let account: String
    let writable: Bool
}

/// What the pipeline needs to know about macOS access and collections.
@MainActor
protocol CollectionSource: AnyObject {
    /// "full", "not_determined", "denied", "write_only" or "restricted".
    func access(_ resource: ClientResource) -> String
    /// Every collection of this kind, or nil without Full Access.
    func collections(_ resource: ClientResource) -> [CollectionRecord]?
}

struct ApprovalRequest {
    let clientID: String
    /// From the registry, never from the agent.
    let clientName: String
    /// As the agent reported it; display only.
    let agent: String?
    let request: BridgeRequest
    let targetID: String?
}

enum ApprovalDecision: Equatable {
    case allowed
    /// An "Allow for 15 minutes" window was open for this client.
    case allowedByWindow
    case denied
    case timedOut
    /// The caller went away, or the request was withdrawn (revoke, bridge off).
    case withdrawn
    /// Too many changes already waiting for this client.
    case tooMany
    /// The app is quitting.
    case unavailable
}

/// Ask before changes. `ApprovalCenter` is the real one.
@MainActor
protocol ApprovalGate: AnyObject {
    /// Calls `completion` exactly once. The returned closure withdraws the
    /// request if it's still waiting (the completion then gets `.withdrawn`).
    func request(_ approval: ApprovalRequest,
                 completion: @escaping (ApprovalDecision) -> Void) -> () -> Void
}

/// Lets a transport cancel a request it handed to the pipeline (the HTTP
/// connection closed, or the agent sent notifications/cancelled).
@MainActor
final class PipelineTicket {
    fileprivate(set) var isCancelled = false
    fileprivate var withdrawApproval: (() -> Void)?

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        withdrawApproval?()
        withdrawApproval = nil
    }
}

/// The one path every request takes after its transport authenticated the
/// client, so no transport can skip a grant, policy check, revision recheck,
/// approval, journal entry or Activity row. The order of checks is fixed and
/// written straight through in `handle` so it can be read in one go.
@MainActor
final class RequestPipeline {
    static let maxInFlightPerClient = 8

    private let registry: ClientRegistry
    private let commands: BridgeCommandExecutor
    private let collections: CollectionSource
    private let approvals: ApprovalGate?
    private let limiter: RateLimiter?
    private let bridgeActive: () -> Bool
    private let didRecord: () -> Void
    private var inFlight = [String: Int]()

    init(registry: ClientRegistry, commands: BridgeCommandExecutor, collections: CollectionSource,
         approvals: ApprovalGate? = nil, limiter: RateLimiter? = nil,
         bridgeActive: @escaping () -> Bool, didRecord: @escaping () -> Void) {
        self.registry = registry
        self.commands = commands
        self.collections = collections
        self.approvals = approvals
        self.limiter = limiter
        self.bridgeActive = bridgeActive
        self.didRecord = didRecord
    }

    /// The caller has already authenticated `clientID` for this transport.
    @discardableResult
    func handle(_ request: BridgeRequest, clientID: String, origin: RequestOrigin,
                completion: @escaping ([String: Any]) -> Void) -> PipelineTicket {
        let ticket = PipelineTicket()
        // 1. The bridge switch. Recorded so the user sees that a client tried.
        guard bridgeActive() else {
            reject(request, clientID, origin, ["error": "bridge_off"], completion)
            return ticket
        }
        // 2. Rate limits, before any grant work.
        if (inFlight[clientID] ?? 0) >= Self.maxInFlightPerClient {
            reject(request, clientID, origin, ["error": "rate_limited", "retryAfter": 1], completion)
            return ticket
        }
        if case .limited(let wait) = limiter?.allow(clientID, write: request.command.isWrite) {
            reject(request, clientID, origin, ["error": "rate_limited", "retryAfter": wait], completion)
            return ticket
        }
        // 3. The saved grant for this exact collection and action.
        let call: AuthorizedClientCall
        switch registry.authorize(clientID: clientID, request: request, origin: origin) {
        case .success(let authorized): call = authorized
        case .failure(let error):
            didRecord()
            completion(["error": error.rawValue])
            return ticket
        }
        inFlight[clientID, default: 0] += 1
        let finish: (AuthorizedClientCall, [String: Any]) -> Void = { [weak self] call, value in
            guard let self else { completion(["error": "app_unavailable"]); return }
            self.inFlight[clientID, default: 1] -= 1
            if self.inFlight[clientID] == 0 { self.inFlight[clientID] = nil }
            self.finish(call, value, completion)
        }
        // 4. Strict parameter shapes.
        let selected = BridgeScope(
            calendarID: call.grant?.resource == .calendar ? call.targetID : nil,
            reminderListID: call.grant?.resource == .reminderList ? call.targetID : nil,
            generation: call.revision)
        if let error = CommandPolicy.validate(request, scope: selected) {
            finish(call, ["error": error])
            return ticket
        }
        // 5. Nothing changed since step 3.
        guard stillAllowed(call) else { finish(call, ["error": "scope_changed"]); return ticket }
        if ticket.isCancelled { finish(call, ["error": "cancelled"]); return ticket }
        // 6. Ask before changes, then recheck: the user may have revoked access
        // or turned the bridge off while the panel was up.
        if request.command.isWrite, call.approval == .ask, let approvals {
            let approval = ApprovalRequest(clientID: clientID, clientName: call.clientName,
                                           agent: origin.agent, request: request,
                                           targetID: call.targetID)
            ticket.withdrawApproval = approvals.request(approval) { [weak self] decision in
                ticket.withdrawApproval = nil
                guard let self else { completion(["error": "app_unavailable"]); return }
                var answered = call
                answered.approvalDetail = Self.detail(decision)
                if ticket.isCancelled { finish(answered, ["error": "cancelled"]); return }
                switch decision {
                case .allowed, .allowedByWindow:
                    guard self.stillAllowed(call) else {
                        finish(answered, ["error": "scope_changed"]); return
                    }
                    self.dispatch(request, answered, selected, ticket, finish)
                case .denied: finish(answered, ["error": "approval_denied"])
                case .timedOut: finish(answered, ["error": "approval_timed_out"])
                case .withdrawn: finish(answered, ["error": "scope_changed"])
                case .tooMany: finish(answered, ["error": "rate_limited", "retryAfter": 45])
                case .unavailable: finish(answered, ["error": "app_unavailable"])
                }
            }
            return ticket
        }
        dispatch(request, call, selected, ticket, finish)
        return ticket
    }

    private static func detail(_ decision: ApprovalDecision) -> String? {
        switch decision {
        case .allowed: "user"
        case .allowedByWindow: "window"
        case .denied: "denied"
        case .timedOut: "timeout"
        default: nil
        }
    }

    // 7. Client-level commands inline; everything else to EventKit.
    private func dispatch(_ request: BridgeRequest, _ call: AuthorizedClientCall,
                          _ selected: BridgeScope, _ ticket: PipelineTicket,
                          _ finish: @escaping (AuthorizedClientCall, [String: Any]) -> Void) {
        switch request.command {
        case .scopeStatus, .calendarCount, .reminderListCount, .listCollections:
            guard let client = registry.clients()?.first(where: { $0.id == call.clientID }) else {
                finish(call, ["error": "client_unavailable"])
                return
            }
            finish(call, inline(request.command, grants: client.grants))
        default:
            commands.runAuthorized(request, clientID: call.clientID, selected: selected,
                                   stillAuthorized: { [weak self] in self?.stillAllowed(call) ?? false },
                                   isCancelled: { ticket.isCancelled },
                                   completion: { finish(call, $0) })
        }
    }

    private func inline(_ command: BridgeCommand, grants: [ClientGrant]) -> [String: Any] {
        switch command {
        case .scopeStatus:
            return ["grants": grants.map { grant -> [String: Any] in
                ["resource": grant.resource.rawValue, "targetID": grant.targetID, "mask": grant.mask]
            }]
        case .calendarCount, .reminderListCount:
            let resource: ClientResource = command == .calendarCount ? .calendar : .reminderList
            guard let all = collections.collections(resource) else {
                return ["error": "full_access_required"]
            }
            let allowed = Set(grants.filter { $0.resource == resource }.map(\.targetID))
            return ["count": all.filter { allowed.contains($0.id) }.count]
        default:
            // Only collections this client has a grant on, in grant order.
            var known = [ClientResource: [String: CollectionRecord]]()
            for resource in [ClientResource.calendar, .reminderList] {
                known[resource] = collections.collections(resource).map {
                    Dictionary($0.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                }
            }
            let rows = grants.map { grant -> [String: Any] in
                let found = known[grant.resource]?[grant.targetID]
                return ["resource": grant.resource.rawValue, "id": grant.targetID,
                        "name": found?.name as Any? ?? NSNull(),
                        "account": found?.account as Any? ?? NSNull(),
                        "writable": found?.writable ?? false,
                        "available": found != nil, "mask": grant.mask]
            }
            return ["calendarsAccess": collections.access(.calendar),
                    "remindersAccess": collections.access(.reminderList),
                    "collections": rows]
        }
    }

    private func stillAllowed(_ call: AuthorizedClientCall) -> Bool {
        registry.stillAuthorized(call) && bridgeActive()
    }

    private func reject(_ request: BridgeRequest, _ clientID: String, _ origin: RequestOrigin,
                        _ value: [String: Any], _ completion: ([String: Any]) -> Void) {
        let recorded = registry.recordRejected(clientID: clientID, request: request,
                                               outcome: "error:\(value["error"] as! String)",
                                               origin: origin)
        didRecord()
        completion(recorded ? value : ["error": "activity_unavailable"])
    }

    // 8. The result row, then the reply.
    private func finish(_ call: AuthorizedClientCall, _ value: [String: Any],
                        _ completion: ([String: Any]) -> Void) {
        let outcome = (value["error"] as? String).map { "error:\($0)" } ?? "success"
        let recorded = registry.recordResult(call, outcome: outcome)
        didRecord()
        completion(recorded ? value : ["error": "activity_unavailable"])
    }
}
