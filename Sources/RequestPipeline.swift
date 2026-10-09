import Foundation

/// Runs one authorized item command. `EventKitCommands` is the real one; the
/// MCP test harness injects a fake.
@MainActor
protocol BridgeCommandExecutor: AnyObject {
    /// Client authorization is checked before entry and again by
    /// `stillAuthorized` after asynchronous reads and before a mutation.
    /// `isCancelled` is checked before the write is journaled; once it is,
    /// the write finishes even if the caller has gone away.
    func runAuthorized(_ request: BridgeRequest, clientID: String, selected: BridgeScope,
                       stillAuthorized: @escaping () -> Bool, isCancelled: @escaping () -> Bool,
                       completion: @escaping ([String: Any]) -> Void)
}

/// A calendar or reminder list as macOS reports it, for `list_collections`
/// and the inline counts. Kept free of AppKit so the MCP harness can fake it.
struct CollectionRecord: Equatable {
    let id: String
    let name: String
    let account: String
    let writable: Bool
    /// Calendars: the availability values it accepts (busy, free…), possibly none.
    var availabilities: [String]? = nil
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
    /// The client's revision when asked; an allowance ends when it changes.
    var revision = 0
    /// Joins the answer to the request's Activity rows (C03).
    var requestID: String? = nil
}

extension AccessRequest {
    /// The same request as Ask before changes sees it, for the panel's words.
    var approvalRequest: ApprovalRequest {
        ApprovalRequest(clientID: missing.clientID, clientName: missing.clientName, agent: agent, request: request,
                        targetID: missing.sourceID ?? missing.targetID, revision: missing.revision,
                        requestID: requestID)
    }
}

enum ApprovalDecision: Equatable {
    case allowed
    /// An "Allow for 15 minutes" window was open for this client.
    case allowedByWindow
    case denied
    case timedOut
    /// The caller went away, or the request was withdrawn (revoke, pause, bridge off).
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
    private let accessRequests: AccessRequestGate?
    private let limiter: RateLimiter?
    private let bridgeActive: () -> Bool
    private let didRecord: () -> Void
    private var inFlight = [String: Int]()

    init(registry: ClientRegistry, commands: BridgeCommandExecutor, collections: CollectionSource,
         approvals: ApprovalGate? = nil, accessRequests: AccessRequestGate? = nil, limiter: RateLimiter? = nil,
         bridgeActive: @escaping () -> Bool, didRecord: @escaping () -> Void) {
        self.registry = registry
        self.commands = commands
        self.collections = collections
        self.approvals = approvals
        self.accessRequests = accessRequests
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
        // 1b. The client's own switch: paused clients keep their access but
        // are refused like the bridge being off, without taking rate-limit tokens.
        if registry.isPaused(clientID: clientID) {
            reject(request, clientID, origin, ["error": "client_paused"], completion)
            return ticket
        }
        // 2. Rate limits, before any grant work.
        if (inFlight[clientID] ?? 0) >= Self.maxInFlightPerClient {
            reject(request, clientID, origin, ["error": "rate_limited", "retryAfter": 1], completion)
            return ticket
        }
        if case .limited(let wait) = limiter?.allow(clientID, write: request.command.isWrite,
                                                    remote: origin.isRemote) {
            reject(request, clientID, origin, ["error": "rate_limited", "retryAfter": wait], completion)
            return ticket
        }
        // 3. The saved grant for this exact collection and action. A write
        // one action short on a calendar or list it can read may ask the
        // user (3b) instead of being refused.
        switch registry.authorizeOrAsk(clientID: clientID, request: request, origin: origin) {
        case .authorized(let call):
            proceed(call, request, origin, ticket, askedForAccess: false, completion)
        case .refused(let error):
            didRecord()
            completion(["error": error.rawValue])
        case .missingAccess(let missing):
            askForAccess(missing, request, origin, ticket, completion)
        }
        return ticket
    }

    // 3b. Ask for access (P7). The answer counts as the approval for this
    // change, so Ask before changes doesn't hold it again and the request
    // stays inside the agent's time limit.
    private func askForAccess(_ missing: MissingAccess, _ request: BridgeRequest, _ origin: RequestOrigin,
                              _ ticket: PipelineTicket, _ completion: @escaping ([String: Any]) -> Void) {
        let writable = collections.collections(missing.resource)?.first { $0.id == missing.targetID }?.writable
        let requestID = ClientRegistry.requestID(clientID: missing.clientID, request: request)
        let refuse = { [weak self] (approval: String?, reply: [String: Any]) in
            guard let self else { completion(["error": "app_unavailable"]); return }
            let code = reply["error"] as! String
            let recorded = self.registry.recordRefusal(missing, request: request, origin: origin, approval: approval,
                                                       outcome: code == "forbidden" ? "forbidden" : "error:\(code)")
            self.didRecord()
            completion(recorded ? reply : ["error": "activity_unavailable"])
        }
        guard let gate = accessRequests,
              AccessRequestPolicy.eligible(missing, command: request.command, writable: writable) else {
            refuse(nil, ["error": "forbidden"])
            return
        }
        let ask = AccessRequest(missing: missing, request: request, agent: origin.agent, requestID: requestID)
        var answered = false
        let withdraw = gate.requestAccess(ask) { [weak self] decision in
            answered = true
            ticket.withdrawApproval = nil
            guard let self else { completion(["error": "app_unavailable"]); return }
            if ticket.isCancelled { refuse(nil, ["error": "cancelled"]); return }
            switch decision {
            case .allowOnce, .allowAlways:
                if decision == .allowAlways {
                    guard case .success = self.registry.addAccess(clientID: missing.clientID, resource: missing.resource,
                                                                  targetID: missing.targetID, bit: missing.missingBit,
                                                                  expectedRevision: missing.revision)
                    else { refuse(nil, ["error": "scope_changed"]); return }
                }
                let temporary = decision == .allowOnce
                    ? TemporaryGrant(requestID: requestID, resource: missing.resource, targetID: missing.targetID,
                                     bit: missing.missingBit, revision: missing.revision)
                    : nil
                switch self.registry.authorizeOrAsk(clientID: missing.clientID, request: request, origin: origin,
                                                    temporaryGrant: temporary) {
                case .authorized(var call):
                    call.approvalDetail = decision == .allowOnce ? "access_once" : "access_always"
                    self.proceed(call, request, origin, ticket, askedForAccess: true, completion)
                case .refused(let error):
                    self.didRecord()
                    completion(["error": error.rawValue])
                case .missingAccess:
                    // Its access changed while the panel was up.
                    refuse(nil, ["error": "scope_changed"])
                }
            case .notNow: refuse("access_denied", ["error": "forbidden", "detail": "access_denied"])
            case .timedOut: refuse("access_timeout", ["error": "forbidden", "detail": "access_timeout"])
            case .withdrawn: refuse(nil, ["error": "scope_changed"])
            case .unavailable: refuse(nil, ["error": "app_unavailable"])
            }
        }
        guard let withdraw else {
            // The throttle or the queue limits: refused as before, no panel.
            refuse(nil, ["error": "forbidden"])
            return
        }
        if !answered { ticket.withdrawApproval = withdraw }
    }

    // 4–7 for an authorized call. `askedForAccess`: the user just answered
    // an access request for it, which counts as the approval.
    private func proceed(_ call: AuthorizedClientCall, _ request: BridgeRequest, _ origin: RequestOrigin,
                         _ ticket: PipelineTicket, askedForAccess: Bool,
                         _ completion: @escaping ([String: Any]) -> Void) {
        let clientID = call.clientID
        inFlight[clientID, default: 0] += 1
        let finish: (AuthorizedClientCall, [String: Any]) -> Void = { [weak self] call, value in
            guard let self else { completion(["error": "app_unavailable"]); return }
            self.inFlight[clientID, default: 1] -= 1
            if self.inFlight[clientID] == 0 { self.inFlight[clientID] = nil }
            self.finish(call, value, item: ActivityItems.ref(command: request.command,
                                                              parameters: request.parameters, result: value),
                        completion)
        }
        // 4. Strict parameter shapes.
        let selected = BridgeScope(
            calendarID: call.grant?.resource == .calendar ? call.targetID : nil,
            reminderListID: call.grant?.resource == .reminderList ? call.targetID : nil,
            generation: call.revision, moveTargetID: call.moveTargetID)
        if let error = CommandPolicy.validate(request, scope: selected) {
            finish(call, ["error": error])
            return
        }
        // 5. Nothing changed since step 3.
        guard stillAllowed(call) else { finish(call, ["error": "scope_changed"]); return }
        if ticket.isCancelled { finish(call, ["error": "cancelled"]); return }
        // 6. Ask before changes, then recheck: the user may have revoked access,
        // paused the client or turned the bridge off while the panel was up.
        if request.command.isWrite, call.approval == .ask, !askedForAccess, let approvals {
            let approval = ApprovalRequest(clientID: clientID, clientName: call.clientName,
                                           agent: origin.agent, request: request,
                                           targetID: call.targetID, revision: call.revision,
                                           requestID: call.requestID)
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
            return
        }
        dispatch(request, call, selected, ticket, finish)
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
            if request.command.isWrite { limiter?.recordWrite(call.clientID) }
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
                    .merging(found?.availabilities.map { ["availabilities": $0] } ?? [:]) { _, new in new }
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

    // 8. The result row (with the item a write touched), then the reply.
    private func finish(_ call: AuthorizedClientCall, _ value: [String: Any], item: ItemRef?,
                        _ completion: ([String: Any]) -> Void) {
        let outcome = (value["error"] as? String).map { "error:\($0)" } ?? "success"
        let recorded = registry.recordResult(call, outcome: outcome, item: item)
        didRecord()
        completion(recorded ? value : ["error": "activity_unavailable"])
    }
}
