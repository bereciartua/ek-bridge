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
                              completing: Bool) -> String? {
        if recurring { return "recurrence_unsupported" }
        if completing && completed { return "already_completed" }
        return nil
    }
}
