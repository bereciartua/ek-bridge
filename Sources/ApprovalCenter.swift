import Foundation
import Observation

/// What the approval panel shows for one change. Built in the app from the
/// request parameters and a fresh EventKit lookup, never from agent prose.
/// Shown on screen only; never stored.
struct ApprovalSummary: Equatable {
    struct Row: Equatable {
        let label: String
        let value: String
        /// For an update: the current value, shown as "before → after".
        var before: String? = nil
        /// Part of `value` shown in bold, such as a link's host.
        var emphasis: String? = nil
        /// The whole value when `value` is shortened; shown as a tooltip.
        var full: String? = nil
    }

    /// "Claude Code wants to add a reminder".
    let title: String
    /// "Groceries · iCloud".
    var subtitle: String? = nil
    let rows: [Row]
    let isDelete: Bool
    /// The current item couldn't be read (deleted, or no Full Access).
    var lookupFailed = false
    var collectionColor: CollectionColor? = nil
}

struct PendingApproval: Identifiable, Equatable {
    let id: UUID
    let clientID: String
    let clientName: String
    let agent: String?
    let summary: ApprovalSummary
    let expiresAt: Date

    static func == (lhs: PendingApproval, rhs: PendingApproval) -> Bool { lhs.id == rhs.id }
}

/// Ask before changes: a FIFO of writes waiting for the user, one panel,
/// 45-second answers, and optional 15-minute allowances per client.
@MainActor @Observable
final class ApprovalCenter: ApprovalGate {
    static let timeout: TimeInterval = 45
    static let allowWindow: TimeInterval = 15 * 60
    static let maxPendingPerClient = 3

    private(set) var pending = [PendingApproval]()
    /// Index of the request the panel shows ("1 of 3").
    var selection = 0

    @ObservationIgnored private let summarize: (ApprovalRequest) -> ApprovalSummary
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    @ObservationIgnored private var completions = [UUID: (ApprovalDecision) -> Void]()
    @ObservationIgnored private var windows = [String: (until: Date, revision: Int)]()
    @ObservationIgnored private var revisions = [UUID: Int]()
    /// Called whenever the queue changes, so the app can show or hide the panel.
    @ObservationIgnored var queueChanged: () -> Void = {}

    init(summarize: @escaping (ApprovalRequest) -> ApprovalSummary,
         now: @escaping () -> Date = Date.init,
         schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, action in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(action) }
         }) {
        self.summarize = summarize
        self.now = now
        self.schedule = schedule
    }

    func request(_ approval: ApprovalRequest,
                 completion: @escaping (ApprovalDecision) -> Void) -> () -> Void {
        if let window = windows[approval.clientID] {
            if window.until > now() && window.revision == approval.revision {
                completion(.allowedByWindow)
                return {}
            }
            windows[approval.clientID] = nil
        }
        guard pending.filter({ $0.clientID == approval.clientID }).count < Self.maxPendingPerClient else {
            completion(.tooMany)
            return {}
        }
        let item = PendingApproval(id: UUID(), clientID: approval.clientID,
                                   clientName: approval.clientName, agent: approval.agent,
                                   summary: summarize(approval),
                                   expiresAt: now().addingTimeInterval(Self.timeout))
        pending.append(item)
        completions[item.id] = completion
        revisions[item.id] = approval.revision
        queueChanged()
        schedule(Self.timeout) { [weak self] in self?.resolve(item.id, .timedOut) }
        return { [weak self] in self?.resolve(item.id, .withdrawn) }
    }

    /// The user's Allow. With `forWindow`, later changes from the same client
    /// are allowed without asking for 15 minutes, until its access changes.
    func allow(_ id: UUID, forWindow: Bool = false) {
        guard let item = pending.first(where: { $0.id == id }) else { return }
        if forWindow, let revision = revisions[id] {
            windows[item.clientID] = (now().addingTimeInterval(Self.allowWindow), revision)
        }
        resolve(id, .allowed)
    }

    func deny(_ id: UUID) {
        resolve(id, .denied)
    }

    /// Revoke, a grant change, or the client's approval mode changing.
    func withdraw(clientID: String) {
        windows[clientID] = nil
        for item in pending where item.clientID == clientID { resolve(item.id, .withdrawn) }
    }

    /// The bridge turned off: everything waiting is refused as `scope_changed`.
    func withdrawAll() {
        windows.removeAll()
        for item in pending { resolve(item.id, .withdrawn) }
    }

    /// The app is quitting.
    func shutDown() {
        windows.removeAll()
        for item in pending { resolve(item.id, .unavailable) }
    }

    func hasAllowWindow(_ clientID: String) -> Bool {
        windows[clientID].map { $0.until > now() } ?? false
    }

    var current: PendingApproval? {
        pending.indices.contains(selection) ? pending[selection] : pending.first
    }

    private func resolve(_ id: UUID, _ decision: ApprovalDecision) {
        guard let completion = completions.removeValue(forKey: id) else { return }
        revisions[id] = nil
        if let index = pending.firstIndex(where: { $0.id == id }) {
            pending.remove(at: index)
            // Keep showing the same change when an earlier one goes away.
            if index < selection { selection -= 1 }
            if selection >= pending.count { selection = max(0, pending.count - 1) }
        }
        queueChanged()
        completion(decision)
    }
}
