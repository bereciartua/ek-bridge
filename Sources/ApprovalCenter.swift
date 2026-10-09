import Foundation
import Observation

/// What the approval panel shows for one change. Built in the app from the
/// request parameters and a fresh EventKit lookup, never from agent prose.
/// Shown on screen, and kept in memory for the session so Activity can show
/// the change's before → after (C03); never written to disk.
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
    /// A delete's item ID from the request, shown when the item didn't load.
    var itemIDForDisplay: String? = nil

    /// A delete of an item that couldn't be loaded: the panel can't show
    /// what goes, so Deny is the default button.
    var isBlindDelete: Bool { isDelete && lookupFailed }

    /// "x-apple-…4F2A": the first 8 and last 4 characters of a long ID.
    static func shortID(_ id: String) -> String {
        id.count > 14 ? "\(id.prefix(8))…\(id.suffix(4))" : id
    }
}

/// What the access panel says (P7, mockup 06): "Claude Code can't add
/// reminders to Groceries", what it has, and what it asked to do, built from
/// the request and a fresh lookup like the approval panel. Shown, never stored.
struct AccessAsk: Equatable {
    let missing: MissingAccess
    let title: String
    /// "Groceries · iCloud".
    var subtitle: String?
    var collectionColor: CollectionColor?
    /// "Groceries".
    var collection = ""
    /// "Read" or "Read, Edit".
    let has: String
    /// "Add “Buy oat milk”, due Thu, Nov 5, 9:00 AM".
    let asked: String
    /// "Create": what Always Allow saves.
    let action: String
}

struct PendingApproval: Identifiable, Equatable {
    let id: UUID
    let clientID: String
    let clientName: String
    let agent: String?
    let summary: ApprovalSummary
    let expiresAt: Date
    /// The request's Activity request ID, when the pipeline asked.
    var requestID: String? = nil
    /// Set for an access request (C04) instead of a change to approve.
    var access: AccessAsk? = nil

    static func == (lhs: PendingApproval, rhs: PendingApproval) -> Bool { lhs.id == rhs.id }
}

/// Ask before changes: a FIFO of writes waiting for the user, one panel,
/// 45-second answers, and optional 15-minute allowances per client. Access
/// requests (C04) wait in the same queue and panel, with the same arming.
@MainActor @Observable
final class ApprovalCenter: ApprovalGate, AccessRequestGate {
    static let timeout: TimeInterval = 45
    static let allowWindow: TimeInterval = 15 * 60
    static let maxPendingPerClient = 3
    /// Access requests: one waiting per connection, three in all.
    static let maxPendingAccessPerClient = 1
    static let maxPendingAccess = 3

    private(set) var pending = [PendingApproval]()
    /// Index of the request the panel shows ("1 of 3").
    var selection = 0 {
        didSet { if selection != oldValue { selectionChanged() } }
    }

    @ObservationIgnored private let summarize: (ApprovalRequest) -> ApprovalSummary
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    @ObservationIgnored private var completions = [UUID: (ApprovalDecision) -> Void]()
    @ObservationIgnored private var accessCompletions = [UUID: (AccessDecision) -> Void]()
    @ObservationIgnored private var throttle = AccessRequestThrottle()
    @ObservationIgnored private let summarizeAccess: (AccessRequest) -> AccessAsk
    /// Whether Always Allow is held back for a connection: it has unsaved
    /// access edits, which saving would write over the new access.
    @ObservationIgnored var alwaysAllowBlocked: (String) -> Bool = { _ in false }
    @ObservationIgnored private var windows = [String: (until: Date, revision: Int)]()
    @ObservationIgnored private var revisions = [UUID: Int]()
    /// Called whenever the queue changes, so the app can show or hide the panel.
    @ObservationIgnored var queueChanged: () -> Void = {}
    /// Called when the panel shows another change, so it can fit its height.
    @ObservationIgnored var selectionChanged: () -> Void = {}
    /// Called with the panel's summary when a change is answered (allowed,
    /// denied or timed out), so Activity can show it this session (C03).
    @ObservationIgnored var answered: (_ requestID: String, ApprovalSummary, ApprovalDecision) -> Void = { _, _, _ in }
    /// Called when a change or access request expires unanswered (C05).
    @ObservationIgnored var expired: (PendingApproval) -> Void = { _ in }

    init(summarize: @escaping (ApprovalRequest) -> ApprovalSummary,
         summarizeAccess: @escaping (AccessRequest) -> AccessAsk = AccessAsk.plain,
         now: @escaping () -> Date = Date.init,
         schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, action in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(action) }
         }) {
        self.summarize = summarize
        self.summarizeAccess = summarizeAccess
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
        guard pending.filter({ $0.clientID == approval.clientID && $0.access == nil }).count
                < Self.maxPendingPerClient else {
            completion(.tooMany)
            return {}
        }
        let item = PendingApproval(id: UUID(), clientID: approval.clientID,
                                   clientName: approval.clientName, agent: approval.agent,
                                   summary: summarize(approval),
                                   expiresAt: now().addingTimeInterval(Self.timeout),
                                   requestID: approval.requestID)
        pending.append(item)
        completions[item.id] = completion
        revisions[item.id] = approval.revision
        queueChanged()
        schedule(Self.timeout) { [weak self] in self?.resolve(item.id, .timedOut) }
        return { [weak self] in self?.resolve(item.id, .withdrawn) }
    }

    func requestAccess(_ access: AccessRequest,
                       completion: @escaping (AccessDecision) -> Void) -> (() -> Void)? {
        let missing = access.missing
        let waiting = pending.filter { $0.access != nil }
        guard throttle.allows(missing, now: now()),
              waiting.filter({ $0.clientID == missing.clientID }).count < Self.maxPendingAccessPerClient,
              waiting.count < Self.maxPendingAccess else { return nil }
        throttle.record(missing, now: now())
        let ask = summarizeAccess(access)
        let item = PendingApproval(id: UUID(), clientID: missing.clientID, clientName: missing.clientName,
                                   agent: access.agent,
                                   summary: ApprovalSummary(title: ask.title, subtitle: ask.subtitle, rows: [],
                                                            isDelete: false, collectionColor: ask.collectionColor),
                                   expiresAt: now().addingTimeInterval(Self.timeout),
                                   requestID: access.requestID, access: ask)
        pending.append(item)
        accessCompletions[item.id] = completion
        queueChanged()
        schedule(Self.timeout) { [weak self] in self?.resolveAccess(item.id, .timedOut) }
        return { [weak self] in self?.resolveAccess(item.id, .withdrawn) }
    }

    /// Allow Once: this request only.
    func allowOnce(_ id: UUID) { resolveAccess(id, .allowOnce) }

    /// Always Allow: saves the action for the connection. Saving changes its
    /// access, so its other waiting items couldn't go through any more: they
    /// are withdrawn now rather than failing after the user allows them.
    func allowAlways(_ id: UUID) {
        guard let item = pending.first(where: { $0.id == id }), !alwaysAllowBlocked(item.clientID) else { return }
        resolveAccess(id, .allowAlways)
        windows[item.clientID] = nil
        for other in pending where other.clientID == item.clientID {
            resolve(other.id, .withdrawn)
            resolveAccess(other.id, .withdrawn)
        }
    }

    /// "Let it ask for more access" was turned off: its waiting request goes.
    func withdrawAccess(clientID: String) {
        for item in pending where item.clientID == clientID && item.access != nil {
            resolveAccess(item.id, .withdrawn)
        }
    }

    /// Not Now: refused, and not asked again for an hour.
    func notNow(_ id: UUID) {
        if let missing = pending.first(where: { $0.id == id })?.access?.missing {
            throttle.record(missing, now: now())
        }
        resolveAccess(id, .notNow)
    }

    #if EVENTKIT_UI_REVIEW
    /// Snapshots show the same request in light and dark.
    func resetAccessThrottle() { throttle = AccessRequestThrottle() }
    #endif

    var pendingAccess: [PendingApproval] { pending.filter { $0.access != nil } }
    var pendingChanges: [PendingApproval] { pending.filter { $0.access == nil } }

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

    /// Revoke, pause, a grant change, or the client's approval mode changing.
    func withdraw(clientID: String) {
        windows[clientID] = nil
        for item in pending where item.clientID == clientID {
            resolve(item.id, .withdrawn)
            resolveAccess(item.id, .withdrawn)
        }
    }

    /// The bridge turned off: everything waiting is refused as `scope_changed`.
    func withdrawAll() {
        windows.removeAll()
        for item in pending {
            resolve(item.id, .withdrawn)
            resolveAccess(item.id, .withdrawn)
        }
    }

    /// The app is quitting.
    func shutDown() {
        windows.removeAll()
        for item in pending {
            resolve(item.id, .unavailable)
            resolveAccess(item.id, .unavailable)
        }
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
        if let item = pending.first(where: { $0.id == id }), let requestID = item.requestID,
           [.allowed, .denied, .timedOut].contains(decision) {
            answered(requestID, item.summary, decision)
        }
        if decision == .timedOut, let item = pending.first(where: { $0.id == id }) { expired(item) }
        remove(id)
        completion(decision)
    }

    private func resolveAccess(_ id: UUID, _ decision: AccessDecision) {
        guard let completion = accessCompletions.removeValue(forKey: id) else { return }
        if decision == .timedOut, let item = pending.first(where: { $0.id == id }) { expired(item) }
        remove(id)
        completion(decision)
    }

    private func remove(_ id: UUID) {
        if let index = pending.firstIndex(where: { $0.id == id }) {
            pending.remove(at: index)
            // Keep showing the same change when an earlier one goes away.
            if index < selection { selection -= 1 }
            if selection >= pending.count { selection = max(0, pending.count - 1) }
        }
        queueChanged()
    }
}

extension AccessAsk {
    /// Without a lookup (tests): the request's own words only.
    static func plain(_ access: AccessRequest) -> AccessAsk {
        AccessAsk(missing: access.missing,
                  title: String(localized: "\(access.missing.clientName) can't \(access.request.command.rawValue)"),
                  has: AccessWords.words(access.missing.currentMask),
                  asked: access.request.command.rawValue, action: AccessWords.words(access.missing.missingBit))
    }
}
