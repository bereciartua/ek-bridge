import Foundation

enum MutationPolicy {
    static func eventError(recurring: Bool, allDay: Bool, hasAttendees: Bool,
                           floatingTime: Bool, updating: Bool) -> String? {
        if recurring { return "recurrence_unsupported" }
        if allDay || hasAttendees { return "all_day_or_attendees_unsupported" }
        if updating && floatingTime { return "floating_time_unsupported" }
        return nil
    }

    static func reminderError(recurring: Bool, completed: Bool,
                              completing: Bool,
                              recurrenceScope: ReminderRecurrenceScope? = nil) -> String? {
        // Only completion of an explicitly selected occurrence may continue
        // to the narrow provider/schedule guard. Series and recurring removal
        // remain blocked because EventKit exposes no reminder span parameter.
        if recurring {
            if !completing { return "recurrence_delete_unsupported" }
            guard let recurrenceScope else { return "recurrence_scope_required" }
            if completed { return "already_completed" }
            return recurrenceScope == .occurrence ? nil :
                "recurrence_series_unsupported"
        }
        if recurrenceScope != nil { return "recurrence_scope_not_applicable" }
        if completing && completed { return "already_completed" }
        return nil
    }
}
