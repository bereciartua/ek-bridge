import Foundation

// Tool-error text for agents (plan Appendix C): "<Label>: <message> (code: <code>)".
// Messages address the model and always end by saying whether to retry, read or
// tell the user. The tool name supplies the action and the calendar/list words.
enum AgentOutcomeText {
    static func text(code: String, tool: String?, detail: String?, retryAfter: Int?,
                     idempotencyKey: String?) -> String {
        let context = Context(tool: tool, detail: detail, retryAfter: retryAfter,
                              idempotencyKey: idempotencyKey)
        let (label, message) = entry(code, context)
            ?? ("Error", "\(AppIdentity.displayName) returned \(code). Tell the user.")
        return "\(label): \(message) (code: \(code))"
    }

    static func isKnown(_ code: String) -> Bool {
        entry(code, Context(tool: nil, detail: nil, retryAfter: nil, idempotencyKey: nil)) != nil
    }

    static let uncertainCodes: Set<String> = [
        "idempotency_pending_review", "write_committed_journal_pending_review",
        "completion_pending_reconciliation", "completion_readback_uncertain", "timeout",
    ]

    private struct Context {
        let tool: String?
        let detail: String?
        let retryAfter: Int?
        let idempotencyKey: String?

        private var events: Bool { tool?.hasSuffix("_event") == true || tool?.hasSuffix("_events") == true }
        private var reminders: Bool {
            tool?.hasSuffix("_reminder") == true || tool?.hasSuffix("_reminders") == true
        }
        var collection: String { events ? "calendar" : reminders ? "list" : "calendar or list" }
        var item: String { events ? "event" : reminders ? "reminder" : "item" }
        var app: String { events ? "Calendar" : reminders ? "Reminders" : "Calendar or Reminders" }
        var access: String { events ? "Calendars" : reminders ? "Reminders" : "Calendars or Reminders" }
        var verb: String? { tool.flatMap { $0.split(separator: "_").first.map(String.init) } }
        var isWrite: Bool { ["create", "update", "delete", "complete"].contains(verb ?? "") }

        // forbidden: what the agent tried, and the grant that would allow it.
        var action: (words: String, grant: String)? {
            switch tool {
            case "read_events", "get_event": ("read events", "Read")
            case "create_event": ("create events", "Create")
            case "update_event": ("edit events", "Edit")
            case "delete_event": ("delete events", "Delete")
            case "read_reminders", "get_reminder": ("read reminders", "Read")
            case "create_reminder": ("add reminders", "Create")
            case "update_reminder": ("edit reminders", "Edit")
            case "complete_reminder": ("complete reminders", "Complete")
            case "delete_reminder": ("delete reminders", "Delete")
            default: nil
            }
        }

        // What "it isn't there" means after an uncertain write.
        var missing: String {
            switch verb {
            case "create": "the \(item) isn't there"
            case "update": "the \(item) doesn't show the change"
            case "delete": "the \(item) is still there"
            case "complete": "the \(item) isn't completed"
            default: "the change isn't there"
            }
        }
    }

    private static func entry(_ code: String, _ c: Context) -> (String, String)? {
        let app = AppIdentity.displayName
        let unsupportedShape = ("Not supported", "the bridge doesn't change items of this shape, "
            + "to avoid damaging them. Tell the user it has to be changed in \(c.app).")
        if code.hasPrefix("completed_reminder_") { return unsupportedShape }
        if let readback = readbackEntry(code, c) { return readback }
        switch code {
        case "forbidden":
            let grant = c.action.map { "grant \($0.grant)" } ?? "grant that access"
            return ("Not allowed", "this agent can't \(c.action?.words ?? "do that") in that "
                + "\(c.collection). If it should be able to, ask the user to \(grant) for this "
                + "client in \(app). Don't retry.")
        case "unauthorized":
            return ("Access removed", "this agent's access was removed in \(app). "
                + "Tell the user; don't retry.")
        case "bridge_off":
            return ("Bridge off", "\(app) is turned off. Ask the user to turn it on from the "
                + "menu bar; don't retry until they do.")
        case "full_access_required":
            return ("Needs Full Access", "macOS isn't giving \(app) Full Access to \(c.access). "
                + "Ask the user to allow it in System Settings ▸ Privacy & Security; "
                + "don't retry until they do.")
        case "target_unavailable":
            return ("Not found", "that \(c.collection) isn't available or its ID changed. "
                + "Call list_collections to get current IDs.")
        case "item_unavailable":
            return ("Not found", "that \(c.item) isn't available or its ID changed. "
                + "Read the \(c.collection) again to get current IDs.")
        case "target_not_writable":
            return ("Read only", "that \(c.collection) is read-only. "
                + "Choose another one from list_collections.")
        case "conflict", "occurrence_conflict":
            return ("Out of date", "the \(c.item) changed since you read it. "
                + "Read it again and retry with the new version.")
        case "too_many_events_narrow_range":
            return ("Too many events", "the range holds more events than the bridge reads at once. "
                + "Call again with a shorter range.")
        case "nothing_to_change":
            return ("Nothing to change", c.detail.map(sentence)
                ?? "the update named no field to change. Send the fields that should change.")
        case "occurrence_required":
            return ("Needs occurrence", "this event repeats. Pass occurrence_start from read_events, "
                + "and span (this, future or all) to say which occurrences change.")
        case "occurrence_not_found":
            return ("Not found", "no occurrence of this event starts at occurrence_start. "
                + "Read the calendar again and use an occurrence_start from it.")
        case "span_not_applicable":
            return ("Doesn't repeat", "this event doesn't repeat, so span must be left out or \"this\". "
                + "Call again without it.")
        case "recurrence_span_invalid":
            return ("Needs a wider span", "changing the repeat rule needs span \"future\" or \"all\", and "
                + "moving a repeating event to another calendar needs span \"all\". Call again with one.")
        case "invitation_read_only":
            return ("Invitation", "this event has attendees, and changing it could notify them, so the bridge "
                + "doesn't change or delete invitations. Tell the user to change it in Calendar.")
        case "floating_time_read_only":
            return ("Floating time", "this event has no time zone, so the bridge can't change its times "
                + "exactly. Other fields can change; tell the user to change the times in Calendar.")
        case "availability_unsupported":
            return ("Not supported", "that calendar doesn't accept this availability. Use one that "
                + "list_collections shows for it, or leave availability out.")
        case "url_scheme_not_allowed":
            return ("Link not allowed", "only http, https, mailto and tel links can be written. "
                + "Fix url and call again.")
        case "invalid_url":
            return ("Invalid link", "url must be a complete link like https://example.com/page, with no "
                + "spaces. Fix it and call again.")
        case "invalid_notes", "notes_too_long", "invalid_location", "location_too_long", "invalid_alarms",
             "invalid_recurrence":
            return ("Rejected", "the bridge rejected a field's value (\(code)). Check the tool's "
                + "description and fix the arguments before calling again.")
        case "alarms_unsupported":
            return ("Alarms can't be replaced", "this \(c.item) has alarms the bridge can't express, and "
                + "alarms would replace them. Leave alarms out, or pass replace_unsupported_alarms true if the "
                + "user agrees to lose them.")
        case "alarm_requires_due":
            return ("Needs a due date", "an alarm in minutes_before counts from the due time, so the reminder "
                + "needs a due date. Send due as well, or use an alarm with at.")
        case "move_across_accounts_unsupported":
            return ("Not supported", "items can move only between calendars or lists of the same account. "
                + "Create a copy in the other one instead if the user wants that.")
        case "already_applied":
            return ("Already done", "this occurrence was already deleted by an earlier request. "
                + "Nothing to do; don't retry.")
        case "invalid_arguments":
            return ("Invalid arguments", c.detail.map(sentence)
                ?? "the arguments don't match the tool's input schema. Fix them and call again.")
        case "nonexistent_local_time":
            return ("Time doesn't exist", c.detail.map(sentence)
                ?? "that local time doesn't exist (clocks skip forward). "
                + "Use a different time or give an offset.")
        case "ambiguous_local_time":
            return ("Ambiguous time", c.detail.map(sentence)
                ?? "that local time happens twice. Add the UTC offset you mean.")
        case "invalid_parameters", "invalid_parameters_or_target", "invalid_schedule",
             "invalid_event_schedule", "invalid_request":
            let hint = c.detail.map { " (\($0))" } ?? ""
            return ("Rejected", "the bridge rejected these values\(hint). Check the tool's "
                + "description; for example, timed events can last at most 31 days, all-day events "
                + "366 days, and reads cover at most 31 days. Fix the arguments before calling again.")
        // Recurrence codes the agent can fix; the rest of the family is a shape problem.
        case "recurrence_requires_due":
            return ("Needs a due date", "a repeating reminder needs a due date. "
                + "Send due with the repeat rule and call again.")
        case "recurrence_anchor_mismatch":
            return ("Repeat doesn't match", "the repeat rule doesn't fit the first occurrence: the "
                + "\(c.item == "event" ? "start" : "due date") must be one of the rule's own dates "
                + "(its weekdays, month_days or months), and an end until must be after it. "
                + "Fix the arguments and call again.")
        case "recurrence_requires_relative_alarm":
            return ("Needs relative alarms", "a repeating reminder can only have alarms relative to its due "
                + "time. Use minutes_before instead of at, and call again.")
        case "recurrence_requires_alarm_reset":
            return ("Needs due and alarm", "adding a repeat rule to this reminder resets its "
                + "alarm. Send due (and alarm, if any) along with recurrence and call again.")
        case "recurrence_scope_required":
            if c.tool == "delete_reminder" {
                return ("Repeats", "this reminder repeats, and deleting it removes every future "
                    + "occurrence. If that's what the user wants, call again with scope \"series\".")
            }
            if c.tool == "update_reminder" {
                return ("Repeats", "a repeating reminder is completed one occurrence at a time. Use "
                    + "complete_reminder with its completion_candidate instead of completed.")
            }
            return ("Needs occurrence", "this reminder repeats. Read it again and pass its "
                + "completion_candidate as occurrence; if it has none, tell the user to "
                + "complete it in Reminders.")
        case "recurrence_scope_not_applicable":
            return ("Doesn't repeat", "this reminder doesn't repeat. "
                + "Call again without occurrence.")
        case _ where code.hasPrefix("recurrence_"),
             "floating_time_unsupported", "complex_alarm_unsupported",
             "complex_start_unsupported", "all_day_or_attendees_unsupported",
             "ambiguous_occurrence":
            return unsupportedShape
        case "alarm_in_past":
            return ("Alarm in the past", "the alarm time is in the past. "
                + "Call again with a future time or alarm \"none\".")
        case "already_completed", "occurrence_already_requested":
            return ("Already done", "this was already done. Nothing to do; don't retry.")
        case "approval_denied":
            return ("Declined", "the user declined this change in \(app). "
                + "Don't retry it unless the user asks you to.")
        case "approval_timed_out":
            return ("Not approved in time", "nobody answered the approval prompt in \(app) "
                + "within 45 seconds. Ask the user whether to try again.")
        case "rate_limited":
            let wait = c.retryAfter.map { "\(max($0, 1)) second\($0 > 1 ? "s" : "")" }
                ?? "a minute"
            return ("Too many requests", "this agent is calling faster than \(app) allows. "
                + "Wait \(wait) before the next call, and don't loop.")
        case "scope_changed":
            return ("Access changed", "access changed while this ran. "
                + "Call list_collections, then try again if still allowed.")
        case "scope_changed_after_write":
            return ("Access changed", "access changed after the change was saved. "
                + "Read to confirm the result; don't repeat the change.")
        case "all_day_readback_failed_cleanup_needed":
            // The journal recorded this result, so a same-key retry only replays it.
            return ("Needs review", "the event was saved but didn't read back as requested, and "
                + "the bridge couldn't remove it. Tell the user to check the \(c.collection) in "
                + "Calendar; don't retry.")
        case _ where uncertainCodes.contains(code):
            if code == "timeout" && !c.isWrite {
                return ("No answer in time", "\(app) didn't answer in time. Try once more; "
                    + "if it fails again, tell the user to check \(app).")
            }
            let check = "the change may have been saved, but the bridge couldn't confirm it. "
                + "Read the \(c.collection) to check."
            guard let key = c.idempotencyKey else {
                return ("Needs review", "\(check) Don't repeat the change until you have.")
            }
            return ("Needs review", "\(check) If \(c.missing), retry this exact call with "
                + "idempotency_key \"\(key)\". Never retry with a new key.")
        case "journal_clock_rollback":
            return ("Clock changed", "the Mac's clock moved backwards, so the bridge is refusing "
                + "changes for safety. Tell the user; don't retry.")
        case "idempotency_conflict":
            return ("Key reused", "that idempotency_key was used for a different change. "
                + "Call again without idempotency_key for a new change.")
        case "idempotency_expired":
            return ("Key expired", "that idempotency_key is too old. Read the \(c.item), "
                + "then make the change without idempotency_key.")
        case "invalid_idempotency_key":
            return ("Invalid key", "that idempotency_key isn't one this server issued. "
                + "Read the \(c.item), then make the change without idempotency_key.")
        case "response_too_large":
            return ("Result too large", "the result is too large. Call again asking for "
                + "fewer items with limit, or a shorter range.")
        case "cancelled":
            return ("Cancelled", "the request was cancelled before it finished, "
                + "so nothing changed. Call again only if you still need it.")
        default:
            guard let what = failures[code] else { return nil }
            return ("Error", "\(app) couldn't complete this (\(what)). Try once more; "
                + "if it fails again, tell the user to check \(app).")
        }
    }

    /// `<field>_readback_failed_<outcome>` (plan 03 §14).
    private static func readbackEntry(_ code: String, _ c: Context) -> (String, String)? {
        guard let range = code.range(of: "_readback_failed_"), code != "all_day_readback_failed_rolled_back",
              code != "all_day_readback_failed_cleanup_needed" else { return nil }
        let field = code[..<range.lowerBound].replacingOccurrences(of: "_", with: " ")
        // "the event's time zone didn't read back as requested", or the whole item.
        let failed = field == "write" ? " couldn't be read back after saving"
            : "'s \(field) didn't read back as requested"
        switch code[range.upperBound...] {
        case "rolled_back":
            return ("Not saved", "the new \(c.item)\(failed), so it was removed and nothing changed. "
                + "The account may not support this value; tell the user rather than retrying the same values.")
        case "restored":
            return ("Not saved", "the \(c.item)\(failed), so its previous values were put back and nothing "
                + "changed. The account may not support this value; tell the user rather than retrying the "
                + "same values.")
        case "cleanup_needed":
            return ("Needs review", "the new \(c.item) was saved but\(field == "write" ? " couldn't be read back" : " its \(field) didn't read back as requested"), "
                + "and the bridge couldn't remove it. Tell the user to check the \(c.collection) in "
                + "\(c.app); don't retry.")
        case "restore_failed":
            return ("Needs review", "the \(c.item)\(failed), and the bridge couldn't put the previous values "
                + "back. Stop, and tell the user to check the \(c.item) in \(c.app); don't retry.")
        default:
            return nil
        }
    }

    private static let failures = [
        "save_failed": "saving failed", "fetch_failed": "reading failed",
        "all_day_readback_failed_rolled_back": "the saved event didn't match, so it was removed",
        "app_unavailable": "the app is quitting or busy",
        "client_unavailable": "its client settings are unavailable",
        "unavailable": "its client settings are unavailable",
        "activity_unavailable": "its activity log is unavailable",
        "journal_unavailable": "its write journal is unavailable",
        "journal_full": "its write journal is full",
    ]

    private static func sentence(_ text: String) -> String {
        text.hasSuffix(".") || text.hasSuffix("?") || text.hasSuffix("!") ? text : text + "."
    }
}
