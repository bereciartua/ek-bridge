import Foundation

/// A write refused only because the connection lacks one action on a
/// calendar or list it can already read (P7). The registry reports it
/// instead of refusing outright, so the user can be asked.
struct MissingAccess: Equatable {
    let clientID: String
    /// From the registry, never from the agent.
    let clientName: String
    let revision: Int
    let resource: ClientResource
    /// The calendar or list that lacks the action (a move's destination
    /// when it's the destination that lacks Create).
    let targetID: String
    /// The connection's saved access there.
    let currentMask: Int
    /// One `ClientGrant` bit.
    let missingBit: Int
    /// For a move: the source calendar or list. Set when `targetID` is the destination.
    var sourceID: String? = nil
    /// For a move refused on its source: where it was going.
    var destinationID: String? = nil
    var asksForAccess = true

    var isDestination: Bool { sourceID != nil }
}

/// Allow Once: the missing action, for one request only. Honoured only for
/// that request ID at that revision, and never saved.
struct TemporaryGrant: Equatable {
    let requestID: String
    let resource: ClientResource
    let targetID: String
    let bit: Int
    let revision: Int

    /// `grants` with the bit added to its calendar or list, when this grant
    /// applies to `requestID` at `revision`. Only an existing grant gains it.
    func applied(to grants: [ClientGrant], requestID: String?, revision: Int) -> [ClientGrant] {
        guard requestID == self.requestID, revision == self.revision else { return grants }
        return grants.map {
            $0.resource == resource && $0.targetID == targetID
                ? ClientGrant(resource: $0.resource, targetID: $0.targetID, mask: $0.mask | bit) : $0
        }
    }
}

enum AccessDecision: Equatable {
    /// Lets this one request through (a `TemporaryGrant`).
    case allowOnce
    /// Saves the action for the connection, then lets the request through.
    case allowAlways
    case notNow
    case timedOut
    /// The caller went away, or the request was withdrawn (pause, EK Bridge paused).
    case withdrawn
    /// The app is quitting.
    case unavailable
}

/// What the access panel asks about.
struct AccessRequest {
    let missing: MissingAccess
    let request: BridgeRequest
    /// As the agent reported it; display only.
    let agent: String?
    /// "<clientID>|<request ID>".
    let requestID: String
}

/// Ask for access when refused (`ApprovalCenter` is the real one).
@MainActor
protocol AccessRequestGate: AnyObject {
    /// Shows the request and calls `completion` exactly once, returning a
    /// closure that withdraws it while it waits. Nil when the throttle or the
    /// queue limits refuse it; then nothing is shown and the request is refused.
    func requestAccess(_ access: AccessRequest,
                       completion: @escaping (AccessDecision) -> Void) -> (() -> Void)?
}

/// When a refused write may ask for access (P7, D5). Never for reads (the
/// command line waits only 10 s for them), never for a calendar or list the
/// connection can't read already (an agent mustn't learn about collections
/// it can't see), never for one that's read only or missing, never while the
/// connection is paused, and never when its "ask for more access" is off.
enum AccessRequestPolicy {
    /// `writable`: whether macOS lists the calendar or list and lets it be
    /// changed; nil when it isn't listed (gone, or no Full Access).
    static func eligible(_ missing: MissingAccess, command: BridgeCommand, writable: Bool?) -> Bool {
        guard command.isWrite, missing.asksForAccess,
              missing.currentMask & ClientGrant.read != 0,
              missing.missingBit != ClientGrant.read,
              missing.missingBit > 0, missing.missingBit & (missing.missingBit - 1) == 0,
              writable == true
        else { return false }
        // Complete exists only for lists.
        return missing.missingBit != ClientGrant.complete || missing.resource == .reminderList
    }
}

/// One panel per connection, calendar or list and action per hour; Not Now
/// keeps it quiet for another hour.
struct AccessRequestThrottle {
    static let interval: TimeInterval = 3_600
    private var last = [String: Date]()

    static func key(_ missing: MissingAccess) -> String {
        "\(missing.clientID)|\(missing.resource.rawValue)|\(missing.targetID)|\(missing.missingBit)"
    }

    func allows(_ missing: MissingAccess, now: Date) -> Bool {
        guard let at = last[Self.key(missing)] else { return true }
        return now.timeIntervalSince(at) >= Self.interval || now < at
    }

    mutating func record(_ missing: MissingAccess, now: Date) {
        last[Self.key(missing)] = now
        // Forget what's past the interval.
        last = last.filter { now.timeIntervalSince($0.value) < Self.interval }
    }
}
