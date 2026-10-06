import Foundation

enum MutationPolicy {
    /// Event updates and deletes, before the occurrence lookup (plan 03 §8, §11.3, §13).
    static func eventError(hasAttendees: Bool, recurring: Bool, occurrenceGiven: Bool,
                           span: EventSpan?, changesRecurrence: Bool, moving: Bool) -> String? {
        // Changing a meeting can email every attendee (F5).
        if hasAttendees { return "invitation_read_only" }
        if recurring {
            if !occurrenceGiven { return "occurrence_required" }
            let span = span ?? .this
            if changesRecurrence && span == .this { return "recurrence_span_invalid" }
            if moving && span != .all { return "recurrence_span_invalid" }
        } else if let span, span != .this {
            return "span_not_applicable"
        }
        return nil
    }

    /// Completing or deleting a reminder. EventKit has no span for reminders:
    /// a repeating one is completed one occurrence at a time, and deleted as a
    /// whole series only when the request says so (F9).
    static func reminderError(recurring: Bool, completed: Bool,
                              completing: Bool,
                              recurrenceScope: ReminderRecurrenceScope? = nil) -> String? {
        if recurring {
            guard let recurrenceScope else { return "recurrence_scope_required" }
            if !completing {
                return recurrenceScope == .series ? nil : "recurrence_scope_required"
            }
            if completed { return "already_completed" }
            return recurrenceScope == .occurrence ? nil : "recurrence_series_unsupported"
        }
        if recurrenceScope != nil { return "recurrence_scope_not_applicable" }
        if completing && completed { return "already_completed" }
        return nil
    }
}
