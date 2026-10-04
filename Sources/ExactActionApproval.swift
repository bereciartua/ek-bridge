import CoreFoundation
import CryptoKit
import Foundation

// Source-only candidate for a future XPC route. The transport must derive
// peerVerified from an OS-enforced code-signing requirement, never from a
// message field. These methods run on the app's main thread.
enum ActionApprovalError: String, Error {
    case unverifiedPeer
    case invalidRequest
    case staleRequest
    case replayedRequest
    case readOnlyCommand
    case invalidTarget
    case pendingAction
    case noPendingAction
    case wrongTicket
    case tamperedRequest
    case expiredApproval
    case scopeChanged
    case cancelled
}

struct ActionProposal {
    let ticketID: String
    let digest: String
    let command: BridgeCommand
    let targetID: String
    let title: String?
    let itemID: String?
    let startsAt: Double?
    let endsAt: Double?
}

struct ApprovedAction {
    let request: BridgeRequest
    let rawRequest: Data

    fileprivate init(request: BridgeRequest, rawRequest: Data) {
        self.request = request
        self.rawRequest = rawRequest
    }
}

final class ExactActionApproval {
    static let maxRequestBytes = BridgeProtocol.maxRequestBytes
    static let requestLifetime: TimeInterval = 30
    static let approvalLifetime: TimeInterval = 5 * 60

    // A new gate must be created on every app launch. The client obtains the
    // epoch through a verified XPC handshake; it is not a durable credential.
    let epoch: String

    private struct Pending {
        let ticketID: String
        let digest: String
        let rawRequest: Data
        let scopeGeneration: Int
        let expiresAt: TimeInterval
        let expiresUptime: TimeInterval
    }
    private var pending: Pending?
    private var seenIDs = [String: TimeInterval]()

    init(epoch: UUID = UUID()) { self.epoch = epoch.uuidString.lowercased() }

    func propose(_ data: Data, peerVerified: Bool, scope: BridgeScope,
                 now: TimeInterval, uptime: TimeInterval)
        -> Result<ActionProposal, ActionApprovalError> {
        precondition(Thread.isMainThread)
        guard peerVerified else { return .failure(.unverifiedPeer) }
        if let pending, now >= pending.expiresAt || uptime >= pending.expiresUptime {
            self.pending = nil
        }
        guard pending == nil else { return .failure(.pendingAction) }
        seenIDs = seenIDs.filter { $0.value > now }

        guard let (request, requestID, issuedAt) = parse(data) else {
            return .failure(.invalidRequest)
        }
        guard now - issuedAt <= Self.requestLifetime, issuedAt - now <= 5 else {
            return .failure(.staleRequest)
        }
        guard request.command.isWrite else { return .failure(.readOnlyCommand) }
        guard seenIDs[requestID] == nil else { return .failure(.replayedRequest) }
        guard CommandPolicy.validateShapeAndTarget(request, scope: scope) == nil else {
            return .failure(.invalidTarget)
        }
        let targetID = (request.parameters["calendarID"] ?? request.parameters["listID"]) as! String
        let raw = Data(data)
        let digest = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        let ticketID = UUID().uuidString.lowercased()
        pending = Pending(ticketID: ticketID, digest: digest, rawRequest: raw,
                          scopeGeneration: scope.generation,
                          expiresAt: now + Self.approvalLifetime,
                          expiresUptime: uptime + Self.approvalLifetime)
        seenIDs[requestID] = max(now, issuedAt) + Self.requestLifetime
        return .success(ActionProposal(
            ticketID: ticketID, digest: digest, command: request.command,
            targetID: targetID, title: request.parameters["title"] as? String,
            itemID: request.parameters["itemID"] as? String,
            startsAt: (request.parameters["start"] as? NSNumber)?.doubleValue,
            endsAt: (request.parameters["end"] as? NSNumber)?.doubleValue))
    }

    // Called only by the app's approval UI. The XPC interface must not expose
    // this method. The request is re-parsed from the exact retained bytes.
    func approve(ticketID: String, displayedDigest: String, scope: BridgeScope,
                 now: TimeInterval, uptime: TimeInterval)
        -> Result<ApprovedAction, ActionApprovalError> {
        precondition(Thread.isMainThread)
        guard let candidate = pending else { return .failure(.noPendingAction) }
        guard candidate.ticketID == ticketID else { return .failure(.wrongTicket) }
        pending = nil
        guard now < candidate.expiresAt, uptime < candidate.expiresUptime else {
            return .failure(.expiredApproval)
        }
        guard displayedDigest == candidate.digest,
              SHA256.hash(data: candidate.rawRequest).map({ String(format: "%02x", $0) }).joined()
                == candidate.digest else { return .failure(.tamperedRequest) }
        guard scope.generation == candidate.scopeGeneration,
              let (request, _, _) = parse(candidate.rawRequest),
              CommandPolicy.validateShapeAndTarget(request, scope: scope) == nil else {
            return .failure(.scopeChanged)
        }
        return .success(ApprovedAction(request: request, rawRequest: candidate.rawRequest))
    }

    @discardableResult
    func cancel(ticketID: String) -> Bool {
        precondition(Thread.isMainThread)
        guard pending?.ticketID == ticketID else { return false }
        pending = nil
        return true
    }

    func cancelAll() {
        precondition(Thread.isMainThread)
        pending = nil
    }

    private func parse(_ data: Data) -> (BridgeRequest, String, Double)? {
        guard data.count <= Self.maxRequestBytes,
              let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(fields.keys) == Set(["version", "epoch", "id", "command", "issuedAt", "parameters"]),
              let version = fields["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.intValue == 2,
              version.doubleValue == 2,
              let epoch = fields["epoch"] as? String, epoch == self.epoch,
              let rawID = fields["id"] as? String, let id = UUID(uuidString: rawID),
              let name = fields["command"] as? String,
              let command = BridgeCommand(rawValue: name),
              let issuedNumber = fields["issuedAt"] as? NSNumber,
              CFGetTypeID(issuedNumber) != CFBooleanGetTypeID(),
              let parameters = fields["parameters"] as? [String: Any]
        else { return nil }
        let issuedAt = issuedNumber.doubleValue
        guard issuedAt.isFinite else { return nil }
        return (BridgeRequest(id: id.uuidString.lowercased(), command: command,
                              parameters: parameters), id.uuidString.lowercased(), issuedAt)
    }
}
