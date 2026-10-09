import EventKit
import Foundation

// Pure, testable formatting and state logic used by the menu, the main window
// and the setup checklist. No AppKit or SwiftUI here.

struct CollectionColor: Hashable {
    let red: Double
    let green: Double
    let blue: Double
}

/// A calendar or reminder list as EventKit lists it right now. Names are
/// resolved at display time; only granted ones' names are kept, in
/// `CollectionLabelStore`, to name them once they're unavailable.
struct CollectionInfo: Identifiable, Hashable {
    let resource: ClientResource
    let id: String
    let name: String
    let account: String
    let writable: Bool
    let color: CollectionColor?

    var key: GrantKey { GrantKey(resource: resource, targetID: id) }
}

extension Array where Element == CollectionInfo {
    func named(_ key: GrantKey) -> CollectionInfo? {
        first { $0.resource == key.resource && $0.id == key.targetID }
    }

    /// Sorted for display: calendars first, then by account, then by name.
    func sortedForDisplay() -> [CollectionInfo] {
        sorted {
            if $0.resource != $1.resource { return $0.resource == .calendar }
            if $0.account != $1.account {
                return $0.account.localizedStandardCompare($1.account) == .orderedAscending
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

enum AccessWords {
    static let actions: [(bit: Int, word: String, title: String)] = [
        (ClientGrant.read, String(localized: "read"), String(localized: "Read")),
        (ClientGrant.create, String(localized: "create"), String(localized: "Create")),
        (ClientGrant.edit, String(localized: "edit"), String(localized: "Edit")),
        (ClientGrant.delete, String(localized: "delete"), String(localized: "Delete")),
        (ClientGrant.complete, String(localized: "complete"), String(localized: "Complete")),
    ]

    static func actions(for resource: ClientResource) -> [(bit: Int, word: String, title: String)] {
        resource == .calendar ? Array(actions.prefix(4)) : actions
    }

    static func words(_ mask: Int) -> String {
        actions.filter { mask & $0.bit != 0 }.map(\.word).joined(separator: ", ")
    }
}

enum AccessSummary {
    /// "Work: read, create, edit · Home: read". Collections with an identical
    /// mask are grouped. Unlisted grants read "1 unavailable calendar". Only
    /// actions a listed collection allows are named: a read-only calendar
    /// saved with Create reads "read" (see `hasUngrantableBits`).
    static func segments(grants: [ClientGrant], collections: [CollectionInfo],
                         hidden: Set<ClientResource> = [],
                         unavailableName: (GrantKey) -> String? = { _ in nil }) -> [String] {
        let sorted = collections.sortedForDisplay()
        var groups = [(resource: ClientResource, mask: Int, names: [String], unavailable: Int)]()
        func add(_ resource: ClientResource, _ mask: Int, name: String?) {
            if let index = groups.firstIndex(where: { $0.resource == resource && $0.mask == mask }) {
                if let name { groups[index].names.append(name) } else { groups[index].unavailable += 1 }
            } else {
                groups.append((resource, mask, name.map { [$0] } ?? [], name == nil ? 1 : 0))
            }
        }
        var hiddenSegments = [String]()
        for resource in [ClientResource.calendar, .reminderList] {
            let typed = grants.filter { $0.resource == resource }
            // Without Full Access nothing is listed; say why instead of
            // calling every calendar unavailable.
            if hidden.contains(resource) {
                if !typed.isEmpty { hiddenSegments.append(hiddenText(resource, count: typed.count)) }
                continue
            }
            for collection in sorted where collection.resource == resource {
                if let grant = typed.first(where: { $0.targetID == collection.id }) {
                    let mask = grant.mask & ClientGrantEditing.allowedMask(resource: resource,
                                                                           writable: collection.writable)
                    if mask > 0 { add(resource, mask, name: collection.name) }
                }
            }
            for grant in typed where sorted.named(GrantKey(resource: resource,
                                                         targetID: grant.targetID)) == nil {
                // Named from its last-known label when there is one.
                let name = unavailableName(GrantKey(resource: resource, targetID: grant.targetID))
                add(resource, grant.mask, name: name.map { String(localized: "\($0) (unavailable)") })
            }
        }
        return groups.map { group in
            var parts = group.names
            if group.unavailable > 0 {
                parts.append(unavailableText(group.resource, count: group.unavailable))
            }
            return "\(parts.joined(separator: ", ")): \(AccessWords.words(group.mask))"
        } + hiddenSegments
    }

    /// True when a grant holds actions its listed collection can't allow
    /// (Create on a read-only calendar, say). They never apply; the client
    /// page offers to remove them.
    static func hasUngrantableBits(grants: [ClientGrant], collections: [CollectionInfo]) -> Bool {
        grants.contains { grant in
            guard let collection = collections.named(GrantKey(resource: grant.resource,
                                                              targetID: grant.targetID)) else { return false }
            let allowed = ClientGrantEditing.allowedMask(resource: grant.resource, writable: collection.writable)
            return grant.mask & ~allowed != 0
        }
    }

    static func hiddenText(_ resource: ClientResource, count: Int) -> String {
        switch (resource, count) {
        case (.calendar, 1): String(localized: "1 calendar (no Calendar access)")
        case (.calendar, _): String(localized: "\(count) calendars (no Calendar access)")
        case (.reminderList, 1): String(localized: "1 list (no Reminders access)")
        case (.reminderList, _): String(localized: "\(count) lists (no Reminders access)")
        }
    }

    static func unavailableText(_ resource: ClientResource, count: Int) -> String {
        switch (resource, count) {
        case (.calendar, 1): String(localized: "1 unavailable calendar")
        case (.calendar, _): String(localized: "\(count) unavailable calendars")
        case (.reminderList, 1): String(localized: "1 unavailable list")
        case (.reminderList, _): String(localized: "\(count) unavailable lists")
        }
    }

    static func text(grants: [ClientGrant], collections: [CollectionInfo],
                     hidden: Set<ClientResource> = [], maxGroups: Int = 4,
                     unavailableName: (GrantKey) -> String? = { _ in nil }) -> String {
        let all = segments(grants: grants, collections: collections, hidden: hidden,
                           unavailableName: unavailableName)
        guard !all.isEmpty else { return String(localized: "No access yet") }
        guard all.count > maxGroups else { return all.joined(separator: " · ") }
        return all.prefix(maxGroups).joined(separator: " · ") +
            " · " + String(localized: "+\(all.count - maxGroups) more")
    }

    /// "2 calendars, 1 list" or "No access yet".
    static func counts(_ grants: [ClientGrant]) -> String {
        let calendars = grants.filter { $0.resource == .calendar }.count
        let lists = grants.filter { $0.resource == .reminderList }.count
        var parts = [String]()
        if calendars > 0 {
            parts.append(calendars == 1 ? String(localized: "1 calendar")
                                        : String(localized: "\(calendars) calendars"))
        }
        if lists > 0 {
            parts.append(lists == 1 ? String(localized: "1 list")
                                    : String(localized: "\(lists) lists"))
        }
        return parts.isEmpty ? String(localized: "No access yet") : parts.joined(separator: ", ")
    }
}

enum ClientAvatar {
    /// First letters of the first two words.
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
        let letters = words.prefix(2).compactMap { $0.first.map { String($0) } }
        let result = letters.joined().uppercased()
        return result.isEmpty ? "?" : result
    }

    /// A stable index into eight colors (FNV-1a over the client ID).
    static func colorIndex(_ clientID: String, count: Int = 8) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in clientID.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return Int(hash % UInt32(count))
    }
}

enum RelativeTime {
    /// Short age for menus: "now", "2 min", "1 h", "Yesterday", "Oct 3".
    static func short(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return String(localized: "now") }
        if seconds < 3_600 { return String(localized: "\(Int(seconds / 60)) min") }
        if calendar.isDate(date, inSameDayAs: now) || seconds < 6 * 3_600 {
            return String(localized: "\(Int(seconds / 3_600)) h")
        }
        if calendar.isDateInYesterday(date, relativeTo: now) { return String(localized: "Yesterday") }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// Age for sentences: "Just now", "2 min ago", "1 h ago", "Yesterday".
    static func ago(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return String(localized: "Just now") }
        if seconds < 3_600 { return String(localized: "\(Int(seconds / 60)) min ago") }
        if calendar.isDate(date, inSameDayAs: now) || seconds < 6 * 3_600 {
            return String(localized: "\(Int(seconds / 3_600)) h ago")
        }
        if calendar.isDateInYesterday(date, relativeTo: now) { return String(localized: "Yesterday") }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// Activity time column: "10:24 AM" today, "Yesterday", or a short date.
    static func clock(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date, relativeTo: now) { return String(localized: "Yesterday") }
        // "Oct 5" this year, so Activity's Time column stays narrow.
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
            style.calendar = calendar
            style.timeZone = calendar.timeZone
            return date.formatted(style)
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    static func full(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.abbreviated).day().hour().minute().second())
    }
}

private extension Calendar {
    func isDateInYesterday(_ date: Date, relativeTo now: Date) -> Bool {
        guard let yesterday = self.date(byAdding: .day, value: -1, to: now) else { return false }
        return isDate(date, inSameDayAs: yesterday)
    }
}

/// One finished request, ready for display. `accepted` audit rows are dropped:
/// each request also has a result row.
struct ActivityEntry: Identifiable, Equatable {
    let id: String
    let at: Date
    let clientID: String?
    let command: String
    let code: String
    let targetID: String?
    /// "cli" or "mcp"; nil for rows written before version 4.
    var via: String? = nil
    /// The agent's name as it reported it; display only.
    var agent: String? = nil
    /// How Ask before changes was answered: "user", "window", "denied", "timeout".
    var approval: String? = nil

    var outcome: OutcomePresentation { OutcomePresentation.of(code) }
    var isMCP: Bool { via == "mcp" }
    /// A create, update, complete, delete or move, whatever its outcome.
    var isWrite: Bool { BridgeCommand(rawValue: command)?.isWrite == true }
    var isProblem: Bool { outcome.tone.isProblem }

    static func entries(from activity: [ClientActivity]) -> [ActivityEntry] {
        // `activity` is newest first; IDs stay stable while rows are appended.
        var seen = [String: Int]()
        return activity.enumerated().compactMap { index, row in
            let code = OutcomePresentation.normalize(row.outcome)
            guard code != "accepted" else { return nil }
            let base = "\(row.at.timeIntervalSinceReferenceDate)|\(row.clientID ?? "-")|\(row.command)|\(code)"
            let ordinal = seen[base, default: 0]
            seen[base] = ordinal + 1
            return ActivityEntry(id: "\(base)|\(ordinal)", at: row.at, clientID: row.clientID,
                                 command: row.command, code: code, targetID: row.targetID,
                                 via: row.via, agent: row.agent, approval: row.approval)
        }
    }
}

enum ActivityStats {
    static func lastRequest(for clientID: String, in entries: [ActivityEntry]) -> Date? {
        entries.first { $0.clientID == clientID }?.at
    }

    struct Today: Equatable {
        let requests: Int
        let notAllowed: Int
        let last: Date?
    }

    static func today(_ entries: [ActivityEntry], now: Date = Date(),
                      calendar: Calendar = .current) -> Today {
        let today = entries.filter { calendar.isDate($0.at, inSameDayAs: now) }
        return Today(requests: today.count,
                     notAllowed: today.filter { $0.code == "forbidden" || $0.code == "unauthorized" }.count,
                     last: entries.first?.at)
    }

    static func unseenProblems(_ entries: [ActivityEntry], since: Date?) -> Int {
        entries.filter { $0.isProblem && $0.at > (since ?? .distantPast) }.count
    }
}

enum BridgeRunState: Equatable {
    case off
    case on
    case failed(String)

    var isOn: Bool { self == .on }
}

enum AttentionProblem: Equatable, Hashable {
    case calendarAccess(EKAuthorizationStatus)
    case remindersAccess(EKAuthorizationStatus)
    case policyStoreUnavailable
    case bridgeFailed
    case mcpServerFailed(String)
    case remoteAccessFailed(String)

    var title: String {
        switch self {
        case .calendarAccess(let status): AccessText.problemTitle(.calendar, status)
        case .remindersAccess(let status): AccessText.problemTitle(.reminderList, status)
        case .policyStoreUnavailable: String(localized: "Connection settings can't be read")
        case .bridgeFailed: String(localized: "\(AppIdentity.displayName) couldn't start")
        case .mcpServerFailed: String(localized: "The MCP server couldn't start")
        case .remoteAccessFailed: String(localized: "Remote Access couldn't start")
        }
    }

    var opensPrivacySettings: Bool {
        switch self {
        case .calendarAccess, .remindersAccess: true
        default: false
        }
    }
}

enum AttentionLogic {
    /// Problems that put the menu bar icon in the attention state, in display order.
    /// `mcpFailure` is set only for an enabled MCP server that failed: a
    /// server the user turned off is not a problem.
    static func problems(bridge: BridgeRunState, calendar: EKAuthorizationStatus,
                         reminders: EKAuthorizationStatus, clients: [ClientView],
                         policyStoreAvailable: Bool, mcpFailure: String? = nil) -> [AttentionProblem] {
        var result = [AttentionProblem]()
        if case .failed = bridge { result.append(.bridgeFailed) }
        if let mcpFailure { result.append(.mcpServerFailed(mcpFailure)) }
        if !policyStoreAvailable { result.append(.policyStoreUnavailable) }
        let active = clients.filter { !$0.revoked }
        let needsCalendar = active.contains { $0.grants.contains { $0.resource == .calendar } }
        let needsReminders = active.contains { $0.grants.contains { $0.resource == .reminderList } }
        if needsCalendar && calendar != .fullAccess { result.append(.calendarAccess(calendar)) }
        if needsReminders && reminders != .fullAccess { result.append(.remindersAccess(reminders)) }
        return result
    }
}

enum AccessText {
    static func noun(_ resource: ClientResource) -> String {
        resource == .calendar ? String(localized: "Calendar") : String(localized: "Reminders")
    }

    static func problemTitle(_ resource: ClientResource, _ status: EKAuthorizationStatus) -> String {
        switch (resource, status) {
        case (.calendar, .notDetermined): String(localized: "Calendar access isn't allowed yet")
        case (.reminderList, .notDetermined): String(localized: "Reminders access isn't allowed yet")
        case (.calendar, .writeOnly): String(localized: "Calendar access is add-only")
        case (.reminderList, .writeOnly): String(localized: "Reminders access is add-only")
        case (.calendar, .restricted): String(localized: "Calendar access is restricted")
        case (.reminderList, .restricted): String(localized: "Reminders access is restricted")
        case (.calendar, _): String(localized: "Calendar access is turned off")
        case (.reminderList, _): String(localized: "Reminders access is turned off")
        }
    }

    /// Detail text for the shared access status row, or nil for Full Access.
    static func detail(_ resource: ClientResource, _ status: EKAuthorizationStatus) -> String? {
        switch status {
        case .notDetermined:
            resource == .calendar
                ? String(localized: "Not allowed yet. Needed to show your calendars.")
                : String(localized: "Not allowed yet. Needed to show your lists.")
        case .denied: String(localized: "Turned off in System Settings.")
        case .writeOnly: String(localized: "Add-only access. \(AppIdentity.displayName) needs Full Access to read and update items.")
        case .restricted: String(localized: "Blocked by a profile on this Mac. Ask whoever manages it.")
        case .fullAccess: nil
        @unknown default: String(localized: "Unknown access state.")
        }
    }

    static func pill(_ status: EKAuthorizationStatus) -> (label: String, tone: OutcomeTone)? {
        switch status {
        case .notDetermined: nil
        case .denied: (String(localized: "Off"), .bad)
        case .writeOnly: (String(localized: "Add Only"), .warn)
        case .restricted: (String(localized: "Restricted"), .neutral)
        case .fullAccess: (String(localized: "Full Access"), .ok)
        @unknown default: nil
        }
    }
}

/// The first-run checklist (B09, mockup 01): macOS access, add your agent,
/// connect it. Pure so it can be unit tested.
enum SetupChecklist {
    // Raw values are stored (skipped steps), so new steps take new numbers.
    // Steps 1–7 are 0.8's seven-step list: they still decode (a skipped
    // Calendar or Reminders still counts) but aren't shown.
    enum Step: Int, CaseIterable {
        case calendarAccess = 1, remindersAccess, createClient, chooseAccess, turnOn
        case mcpServer = 7
        case testRequest = 6
        case macOSAccess = 10, addConnection = 11, connect = 12
    }

    enum State: Equatable {
        case done
        case skipped
        case current
        case pending
        /// 0.8's optional access step; no longer produced.
        case optional
    }

    struct Input: Equatable {
        var calendar: EKAuthorizationStatus
        var reminders: EKAuthorizationStatus
        var clients: [ClientView]
        var bridgeOn: Bool
        var successfulClientIDs: Set<String>
        var skipped: Set<Step> = []
        var mcpListening = false
    }

    /// The connection the checklist talks about: one with access that hasn't
    /// sent a request yet, else one with no access yet, else the first one.
    static func focusClient(_ input: Input) -> ClientView? {
        let active = input.clients.filter { !$0.revoked }
        return active.first { !$0.grants.isEmpty && !input.successfulClientIDs.contains($0.id) }
            ?? active.first { $0.grants.isEmpty }
            ?? active.first
    }

    /// Calendar or Reminders decided: allowed, turned off, or skipped in setup.
    static func decided(_ resource: ClientResource, _ input: Input) -> Bool {
        let status = resource == .calendar ? input.calendar : input.reminders
        let skip: Step = resource == .calendar ? .calendarAccess : .remindersAccess
        return status == .fullAccess || status == .denied || input.skipped.contains(skip)
    }

    static func isDone(_ step: Step, _ input: Input) -> Bool {
        let active = input.clients.filter { !$0.revoked }
        switch step {
        case .macOSAccess:
            // One type allowed, the other allowed, turned off or skipped.
            return (input.calendar == .fullAccess || input.reminders == .fullAccess)
                && decided(.calendar, input) && decided(.reminderList, input)
        case .addConnection: return active.contains { !$0.grants.isEmpty }
        case .connect, .testRequest: return active.contains { input.successfulClientIDs.contains($0.id) }
        case .calendarAccess: return input.calendar == .fullAccess
        case .remindersAccess: return input.reminders == .fullAccess
        case .createClient: return !active.isEmpty
        case .chooseAccess: return focusClient(input).map { !$0.grants.isEmpty } ?? false
        case .turnOn: return input.bridgeOn
        case .mcpServer: return input.mcpListening
        }
    }

    static func steps(_ input: Input) -> [Step] { [.macOSAccess, .addConnection, .connect] }

    /// Done steps; the first step not done is current, the rest pending.
    static func states(_ input: Input) -> [Step: State] {
        var result = [Step: State]()
        for step in steps(input) { result[step] = isDone(step, input) ? .done : .pending }
        if let first = steps(input).first(where: { result[$0] == .pending }) {
            result[first] = .current
        }
        return result
    }

    static func isComplete(_ input: Input) -> Bool {
        !states(input).values.contains { $0 == .pending || $0 == .current }
    }
}

/// How a client connects, from the credentials it holds.
enum ClientTransport: Equatable {
    case mcp, cli, both, none

    init(_ client: ClientView) {
        switch (client.hasMCPToken, client.hasSigningKey) {
        case (true, true): self = .both
        case (true, false): self = .mcp
        case (false, true): self = .cli
        case (false, false): self = .none
        }
    }

    /// The small badge on client rows; nil for a client with no credential.
    var badge: String? {
        switch self {
        case .mcp: "MCP"
        case .cli: "CLI"
        case .both: "MCP + CLI"
        case .none: nil
        }
    }
}

/// The ready-to-run first request shown on the client page and in setup.
enum ConnectCommand {
    /// Run from the source checkout. An installed command-line tool is `bridge-client`.
    static let sourceProgram = "python3 client.py"

    static func scopeStatus(clientName: String, program: String = sourceProgram) -> String {
        "\(program) scope_status --client \(shellQuoted(clientName))"
    }

    /// Uses the name when it picks exactly one active client, else the ID.
    static func scopeStatus(for client: ClientView, among clients: [ClientView],
                            program: String = sourceProgram) -> String {
        let key = ClientNames.key(client.name)
        let sameName = clients.filter { !$0.revoked && ClientNames.key($0.name) == key }
        return sameName.count == 1
            ? scopeStatus(clientName: client.name, program: program)
            : "\(program) scope_status --client \(client.id)"
    }

    /// Double quotes for ordinary names, single quotes when the text contains
    /// characters a shell would expand inside double quotes.
    static func shellQuoted(_ text: String) -> String {
        if text.rangeOfCharacter(from: CharacterSet(charactersIn: "\"$`\\!")) == nil {
            return "\"\(text)\""
        }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// When the local MCP server runs (D1): only while EK Bridge is on, the
/// user allows it (Settings ▸ Advanced) and some connection has an MCP token.
enum MCPRunPolicy {
    static func shouldRun(bridgeOn: Bool, allowed: Bool, hasMCPConnections: Bool) -> Bool {
        bridgeOn && allowed && hasMCPConnections
    }

    /// The first launch of 0.9 turns 0.8's separate MCP switch into the
    /// Advanced switch: on unless the user turned the server off and no
    /// connection uses MCP. `old` is nil when the switch was never touched.
    static func migratedAllowed(old: Bool?, hasMCPConnections: Bool) -> Bool {
        old == nil || old == true || hasMCPConnections
    }
}

/// Pause EK Bridge ▸ … in the menu bar.
enum PauseChoice: CaseIterable {
    case oneHour, untilTomorrow, untilTurnedOn
}

enum PauseSchedule {
    /// When a pause ends: in an hour, at 8:00 the next local morning, or
    /// never (nil). DST-safe: 8:00 is set on the next calendar day.
    static func resumeDate(_ choice: PauseChoice, now: Date, calendar: Calendar = .current) -> Date? {
        switch choice {
        case .oneHour:
            return now.addingTimeInterval(3_600)
        case .untilTomorrow:
            let today = calendar.startOfDay(for: now)
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
            return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow)
        case .untilTurnedOn:
            return nil
        }
    }

    /// "until 3:40 PM" today, "until tomorrow at 8:00 AM", else "until Oct 10 at 8:00 AM".
    static func untilText(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        var time = Date.FormatStyle(date: .omitted, time: .shortened)
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        let clock = date.formatted(time)
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "until \(clock)") }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return String(localized: "until tomorrow at \(clock)")
        }
        var day = Date.FormatStyle.dateTime.month(.abbreviated).day()
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        return String(localized: "until \(date.formatted(day)) at \(clock)")
    }
}

/// Which menu bar icon shows (`MenuBarGlyph`): attention wins, then on or
/// paused.
enum MenuBarGlyphState: Equatable, CaseIterable {
    case on, paused, attention

    static func `for`(needsAttention: Bool, bridgeOn: Bool) -> MenuBarGlyphState {
        needsAttention ? .attention : bridgeOn ? .on : .paused
    }
}
