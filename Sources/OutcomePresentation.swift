import Foundation

// Plain-language labels for activity rows and CLI hints. Shared by the app and
// bridge-client, so this file depends on Foundation and BridgeProtocol only.

enum OutcomeTone: String {
    case ok, warn, bad, neutral

    var isProblem: Bool { self == .warn || self == .bad }
}

struct OutcomePresentation: Equatable {
    let code: String
    let label: String
    let tone: OutcomeTone
    let why: String?
    let fix: String?

    /// Activity outcomes are `success`, `error:<code>`, or a bare code from
    /// authorization. Strip the prefix so every surface uses the same key.
    static func normalize(_ outcome: String) -> String {
        outcome.hasPrefix("error:") ? String(outcome.dropFirst(6)) : outcome
    }

    static func of(_ outcome: String) -> OutcomePresentation {
        let code = normalize(outcome)
        guard let entry = entries[code] ?? prefixEntry(code) else {
            return OutcomePresentation(
                code: code, label: String(localized: "Error"), tone: .neutral,
                why: String(localized: "\(AppIdentity.displayName) returned \(code)."), fix: nil)
        }
        return OutcomePresentation(code: code, label: entry.label, tone: entry.tone,
                                   why: entry.why, fix: entry.fix)
    }

    /// Every label a row can show, for sizing Activity's Result column.
    static var allLabels: [String] {
        Array(Set(entries.values.map(\.label) + [notSaved.label, reviewNeeded.label, unsupported.label,
                                                  String(localized: "Error")])).sorted()
    }

    static func isKnown(_ code: String) -> Bool {
        entries[normalize(code)] != nil || prefixEntry(normalize(code)) != nil
    }

    private struct Entry {
        let label: String
        let tone: OutcomeTone
        let why: String?
        let fix: String?
    }

    private static func group(_ codes: [String], _ entry: Entry) -> [(String, Entry)] {
        codes.map { ($0, entry) }
    }

    private static let invalid = Entry(
        label: String(localized: "Invalid request"), tone: .warn,
        why: String(localized: "The parameters didn't match what \(AppIdentity.displayName) accepts."),
        fix: String(localized: "See docs/API.md for this command."))
    private static let reviewNeeded = Entry(
        label: String(localized: "Needs review"), tone: .bad,
        why: String(localized: "\(AppIdentity.displayName) can't confirm whether the write happened."),
        fix: String(localized: "Check the item before retrying, and reuse the same idempotency key. See docs/TESTING.md › Troubleshooting."))
    private static let notSaved = Entry(
        label: String(localized: "Not saved"), tone: .warn,
        why: String(localized: "The saved item didn't match the request, so \(AppIdentity.displayName) undid the change."),
        fix: String(localized: "The account may not support that value."))
    private static let unsupported = Entry(
        label: String(localized: "Not supported"), tone: .warn,
        why: String(localized: "\(AppIdentity.displayName) doesn't change items of this shape, to avoid damaging them."),
        fix: String(localized: "See the support matrix in docs/API.md."))
    private static let failure = Entry(
        label: String(localized: "Error"), tone: .bad,
        why: String(localized: "EventKit or \(AppIdentity.displayName) reported an error."),
        fix: String(localized: "Try again. If it repeats, check Overview."))

    private static let entries: [String: Entry] = {
        var table = [String: Entry]()
        let rows: [(String, Entry)] = [
            ("success", Entry(label: String(localized: "Allowed"), tone: .ok, why: nil, fix: nil)),
            ("accepted", Entry(label: String(localized: "Started"), tone: .neutral,
                               why: String(localized: "The request was accepted and is running."),
                               fix: nil)),
            ("forbidden", Entry(
                label: String(localized: "Not allowed"), tone: .bad,
                why: String(localized: "This connection doesn't have that access to the calendar or list."),
                fix: String(localized: "Turn it on in the connection's Access, only if the tool should be able to do this."))),
            ("unauthorized", Entry(
                label: String(localized: "Not recognized"), tone: .bad,
                why: String(localized: "The request wasn't signed by an active connection's key, or used an old key."),
                fix: String(localized: "If this is your tool, check it uses the current key file. Otherwise, something unexpected is calling \(AppIdentity.displayName)."))),
            ("unavailable", Entry(
                label: String(localized: "Error"), tone: .bad,
                why: String(localized: "\(AppIdentity.displayName) couldn't read or update its connection settings."),
                fix: String(localized: "Open \(AppIdentity.displayName) and check Overview."))),
            ("full_access_required", Entry(
                label: String(localized: "Needs Full Access"), tone: .bad,
                why: String(localized: "macOS isn't giving \(AppIdentity.displayName) Full Access."),
                fix: String(localized: "Open Privacy Settings and turn on Full Access for \(AppIdentity.displayName)."))),
            ("target_not_writable", Entry(
                label: String(localized: "Read only"), tone: .warn,
                why: String(localized: "That calendar or list can't be changed."), fix: nil)),
            ("bridge_off", Entry(
                label: String(localized: "\(AppIdentity.displayName) was paused"), tone: .neutral,
                why: String(localized: "\(AppIdentity.displayName) was paused, so the request was refused."),
                fix: String(localized: "Turn \(AppIdentity.displayName) on if you want this to work."))),
            ("client_paused", Entry(
                label: String(localized: "Connection was paused"), tone: .neutral,
                why: String(localized: "This connection was paused, so the request was refused."),
                fix: String(localized: "Resume the connection if you want it to work."))),
            ("rate_limited", Entry(
                label: String(localized: "Too many requests"), tone: .warn,
                why: String(localized: "This connection sent requests faster than \(AppIdentity.displayName) allows."),
                fix: String(localized: "If it keeps happening, check what the tool is doing."))),
            ("approval_denied", Entry(
                label: String(localized: "Declined by you"), tone: .neutral,
                why: String(localized: "You declined this change."), fix: nil)),
            ("approval_timed_out", Entry(
                label: String(localized: "Not approved in time"), tone: .warn,
                why: String(localized: "Nobody answered the approval prompt within 45 seconds."),
                fix: String(localized: "Ask the tool to try again when you're at the Mac, or choose Allow without asking for this connection."))),
            ("cancelled", Entry(
                label: String(localized: "Cancelled"), tone: .neutral,
                why: String(localized: "The tool cancelled the request before it finished."), fix: nil)),
            ("timeout", Entry(
                label: String(localized: "No answer in time"), tone: .bad,
                why: String(localized: "\(AppIdentity.displayName) didn't finish within 55 seconds."),
                fix: String(localized: "Check the item before retrying."))),
            ("too_many_events_narrow_range", Entry(
                label: String(localized: "Too many results"), tone: .warn,
                why: String(localized: "More events matched than the limit."),
                fix: String(localized: "Use a shorter date range."))),
        ]
        rows.forEach { table[$0.0] = $0.1 }
        let groups: [(String, Entry)] =
            group(["expired_request", "replayed_request"], Entry(
                label: String(localized: "Rejected"), tone: .warn,
                why: String(localized: "The request was too old or was sent twice."),
                fix: String(localized: "Check the Mac's clock; send a fresh request.")))
            + group(["invalid_request", "invalid_parameters", "invalid_parameters_or_target",
                     "request_too_large", "invalid_idempotency_key",
                     // MCP-layer argument errors; they never reach Activity.
                     "invalid_arguments", "nonexistent_local_time", "ambiguous_local_time"], invalid)
            + group(["target_unavailable", "item_unavailable"], Entry(
                label: String(localized: "Not found"), tone: .warn,
                why: String(localized: "The calendar, list or item isn't available, or its ID changed after sync."),
                fix: String(localized: "Read again to get current IDs.")))
            + group(["conflict", "occurrence_conflict"], Entry(
                label: String(localized: "Out of date"), tone: .warn,
                why: String(localized: "The item changed since the tool read it."),
                fix: String(localized: "The tool should read it again and retry with the new version.")))
            + group(["scope_changed"], Entry(
                label: String(localized: "Access changed"), tone: .warn,
                why: String(localized: "Access changed or \(AppIdentity.displayName) was paused while the request ran."),
                fix: String(localized: "Send the request again.")))
            + group(["scope_changed_after_write"], Entry(
                label: String(localized: "Access changed"), tone: .warn,
                why: String(localized: "Access changed or \(AppIdentity.displayName) was paused while the request ran, after the write was saved."),
                fix: String(localized: "Check the item before sending the request again.")))
            + group(["idempotency_pending_review", "write_committed_journal_pending_review",
                     "completion_pending_reconciliation", "completion_readback_uncertain",
                     "journal_clock_rollback", "all_day_readback_failed_cleanup_needed"], reviewNeeded)
            + group(["idempotency_conflict"], Entry(
                label: String(localized: "Key reused"), tone: .warn,
                why: String(localized: "This idempotency key was already used for a different request."),
                fix: String(localized: "Use a new idempotency key for a new change.")))
            + group(["idempotency_expired"], Entry(
                label: String(localized: "Key expired"), tone: .warn,
                why: String(localized: "The idempotency key is too old to use."),
                fix: String(localized: "Read the item again and send the change with a new key.")))
            + group(["occurrence_already_requested", "already_completed"], Entry(
                label: String(localized: "Already done"), tone: .neutral,
                why: String(localized: "This was already requested or completed."), fix: nil))
            + group(["floating_time_unsupported", "complex_alarm_unsupported",
                     "complex_start_unsupported", "all_day_or_attendees_unsupported",
                     "alarm_in_past", "invalid_schedule", "invalid_event_schedule",
                     "ambiguous_occurrence"], unsupported)
            + group(["save_failed", "fetch_failed", "all_day_readback_failed_rolled_back",
                     "response_too_large", "app_unavailable", "client_unavailable",
                     "activity_unavailable", "journal_unavailable", "journal_full"], failure)
            + group(["nothing_to_change", "invalid_url", "url_scheme_not_allowed", "invalid_notes",
                     "notes_too_long", "invalid_location", "location_too_long", "invalid_alarms",
                     "invalid_recurrence", "occurrence_required", "span_not_applicable",
                     "alarm_requires_due"], invalid)
            + group(["occurrence_not_found"], Entry(
                label: String(localized: "Not found"), tone: .warn,
                why: String(localized: "No occurrence of the repeating event starts at that time."),
                fix: String(localized: "Read again to get current occurrences.")))
            + group(["invitation_read_only"], Entry(
                label: String(localized: "Invitation"), tone: .warn,
                why: String(localized: "The event has attendees; changing it could notify them, so \(AppIdentity.displayName) leaves it alone."),
                fix: String(localized: "Change it in Calendar.")))
            + group(["floating_time_read_only", "availability_unsupported", "alarms_unsupported",
                     "move_across_accounts_unsupported"], unsupported)
            + group(["already_applied"], Entry(
                label: String(localized: "Already done"), tone: .neutral,
                why: String(localized: "An earlier request already did this."), fix: nil))
        groups.forEach { table[$0.0] = $0.1 }
        return table
    }()

    // Families named by prefix in the outcome map (`recurrence_*`, `completed_reminder_*`).
    private static func prefixEntry(_ code: String) -> Entry? {
        if code.hasPrefix("recurrence_") || code.hasPrefix("completed_reminder_") {
            return unsupported
        }
        // `<field>_readback_failed_<outcome>` (plan 03 §14).
        if code.contains("_readback_failed_") {
            if code.hasSuffix("_rolled_back") || code.hasSuffix("_restored") {
                return notSaved
            }
            if code.hasSuffix("_cleanup_needed") || code.hasSuffix("_restore_failed") {
                return reviewNeeded
            }
        }
        return nil
    }
}

// Request labels shown in Activity, the menu and the setup checklist.
enum CommandPresentation {
    static func label(_ command: String) -> String {
        // Failed MCP authentication has no command to name.
        if command == "mcp" { return String(localized: "Connect over MCP") }
        guard let known = BridgeCommand(rawValue: command) else { return command }
        switch known {
        case .authorizationStatus: return String(localized: "Check macOS access")
        case .scopeStatus: return String(localized: "Check its access")
        case .listCollections: return String(localized: "List calendars and lists")
        case .calendarCount: return String(localized: "Count calendars")
        case .reminderListCount: return String(localized: "Count lists")
        case .readEvents: return String(localized: "Read events")
        case .getEvent: return String(localized: "Read an event")
        case .readReminders: return String(localized: "Read reminders")
        case .getReminder: return String(localized: "Read a reminder")
        case .createEvent: return String(localized: "Create event")
        case .updateEvent: return String(localized: "Update event")
        case .deleteEvent: return String(localized: "Delete event")
        case .createReminder: return String(localized: "Create reminder")
        case .updateReminder: return String(localized: "Update reminder")
        case .completeReminder: return String(localized: "Complete reminder")
        case .deleteReminder: return String(localized: "Delete reminder")
        }
    }

    /// The label in Activity's Request column and the menu, where space is
    /// short: the same as `label`, shortened where it wouldn't fit.
    static func shortLabel(_ command: String) -> String {
        switch BridgeCommand(rawValue: command) {
        case .listCollections: String(localized: "List calendars")
        case .authorizationStatus: String(localized: "macOS access")
        default: label(command)
        }
    }

    /// Every command label Activity can show.
    static var allShortLabels: [String] {
        (BridgeCommand.allCases.map(\.rawValue) + ["mcp"]).map(shortLabel)
    }

    /// What a change did, for Activity's Change column (P6): "Added event",
    /// "Moved event", "Completed". Nil for reads and client-level commands.
    static func pastTense(_ command: String, moved: Bool = false) -> String? {
        switch BridgeCommand(rawValue: command) {
        case .createEvent: String(localized: "Added event")
        case .updateEvent: moved ? String(localized: "Moved event") : String(localized: "Changed event")
        case .deleteEvent: String(localized: "Deleted event")
        case .createReminder: String(localized: "Added reminder")
        case .updateReminder: moved ? String(localized: "Moved reminder") : String(localized: "Changed reminder")
        case .completeReminder: String(localized: "Completed")
        case .deleteReminder: String(localized: "Deleted reminder")
        default: nil
        }
    }

    /// What a change asked to do, for one that didn't happen: "Add event".
    static func presentTense(_ command: String, moved: Bool = false) -> String? {
        switch BridgeCommand(rawValue: command) {
        case .createEvent: String(localized: "Add event")
        case .updateEvent: moved ? String(localized: "Move event") : String(localized: "Change event")
        case .deleteEvent: String(localized: "Delete event")
        case .createReminder: String(localized: "Add reminder")
        case .updateReminder: moved ? String(localized: "Move reminder") : String(localized: "Change reminder")
        case .completeReminder: String(localized: "Complete reminder")
        case .deleteReminder: String(localized: "Delete reminder")
        default: nil
        }
    }

    /// Activity's Change column: past tense when it went through, present
    /// tense when it didn't, the request's label for reads.
    static func changeLabel(_ command: String, moved: Bool, succeeded: Bool) -> String {
        (succeeded ? pastTense(command, moved: moved) : presentTense(command, moved: moved)) ?? shortLabel(command)
    }

    /// The verb alone, for "Moved “Design review”" (C06): past tense when it
    /// went through. Nil for reads.
    static func verb(_ command: String, moved: Bool, succeeded: Bool) -> String? {
        switch BridgeCommand(rawValue: command) {
        case .createEvent, .createReminder: succeeded ? String(localized: "Added") : String(localized: "Add")
        case .updateEvent, .updateReminder:
            moved ? (succeeded ? String(localized: "Moved") : String(localized: "Move"))
                  : (succeeded ? String(localized: "Changed") : String(localized: "Change"))
        case .deleteEvent, .deleteReminder: succeeded ? String(localized: "Deleted") : String(localized: "Delete")
        case .completeReminder: succeeded ? String(localized: "Completed") : String(localized: "Complete")
        default: nil
        }
    }

    /// Every label the Change column can show, for sizing it.
    static var allChangeLabels: [String] {
        let commands = BridgeCommand.allCases.map(\.rawValue) + ["mcp"]
        return Array(Set(commands.flatMap { command in
            [true, false].flatMap { moved in
                [true, false].map { changeLabel(command, moved: moved, succeeded: $0) }
            }
        })).sorted()
    }

    /// The access a command needs, as shown in the access table ("Read", "Create"…).
    static func requiredAction(_ command: String) -> String? {
        switch BridgeCommand(rawValue: command) {
        case .readEvents, .readReminders, .getEvent, .getReminder: String(localized: "Read")
        case .createEvent, .createReminder: String(localized: "Create")
        case .updateEvent, .updateReminder: String(localized: "Edit")
        case .deleteEvent, .deleteReminder: String(localized: "Delete")
        case .completeReminder: String(localized: "Complete")
        default: nil
        }
    }

    /// True for commands that target a list rather than a calendar.
    static func targetsList(_ command: String) -> Bool {
        switch BridgeCommand(rawValue: command) {
        case .readReminders, .getReminder, .createReminder, .updateReminder, .completeReminder,
             .deleteReminder: true
        default: false
        }
    }

    /// Commands that act on one calendar or list.
    static func hasTarget(_ command: String) -> Bool {
        requiredAction(command) != nil
    }

    /// Commands named in docs/API.md, for the "Did you mean" suggestion.
    static let allCommands: [String] = BridgeCommand.allCases.map(\.rawValue)
}
