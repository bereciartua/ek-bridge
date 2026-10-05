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
        // EventKit's reminder removal API has no occurrence/series span choice.
        // Require explicit intent even though both paths remain blocked until
        // provider and cross-device semantics are verified.
        if recurring {
            return recurrenceScope == nil ? "recurrence_scope_required" :
                "recurrence_unsupported"
        }
        if recurrenceScope != nil { return "recurrence_scope_not_applicable" }
        if completing && completed { return "already_completed" }
        return nil
    }
}
