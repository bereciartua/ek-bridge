import EventKit
import Foundation

// Schedule validation and mutation stay separate from store access so they can
// be checked against in-memory EKReminder objects before any live writes.
enum ReminderSchedule {
    static func describe(_ reminder: EKReminder) -> [String: Any] {
        let alarms = reminder.alarms ?? []
        let rows: [[String: Any]] = alarms.prefix(4).map { alarm in
            if let date = alarm.absoluteDate {
                return ["kind": "absolute", "at": date.timeIntervalSince1970]
            }
            return ["kind": "relative", "offset": alarm.relativeOffset]
        }
        return ["due": ReminderDueSpec.readback(reminder.dueDateComponents),
                "recurrence": ReminderRecurrence.readback(reminder.recurrenceRules),
                "alarms": rows, "alarmCount": alarms.count,
                "alarmsTruncated": alarms.count > rows.count]
    }
    static func validate(_ dueChange: ReminderDueChange,
                                          _ recurrenceChange: ReminderRecurrenceChange,
                                          for reminder: EKReminder, creating: Bool) -> String? {
        if !creating && reminder.hasRecurrenceRules &&
           ReminderRecurrence.readback(reminder.recurrenceRules)["supported"] as? Bool != true {
            return "recurrence_unsupported"
        }
        let proposedDue: DateComponents?
        switch dueChange {
        case .keep: proposedDue = reminder.dueDateComponents
        case .clear: proposedDue = nil
        case .set(let spec): proposedDue = spec.components
        }
        let proposedRules: [EKRecurrenceRule]?
        switch recurrenceChange {
        case .keep: proposedRules = reminder.recurrenceRules
        case .clear: proposedRules = nil
        case .set(let rule): proposedRules = [rule]
        }
        if let rules = proposedRules, !rules.isEmpty {
            guard let proposedDue else { return "recurrence_requires_due" }
            if rules.count != 1 ||
               !ReminderRecurrenceChange.set(rules[0]).matchesAnchor(proposedDue) {
                return "recurrence_anchor_mismatch"
            }
        }
        if !creating, let rules = proposedRules, !rules.isEmpty,
           !reminder.hasRecurrenceRules, case .keep = dueChange,
           (reminder.alarms ?? []).contains(where: { $0.absoluteDate != nil }) {
            return "recurrence_requires_alarm_reset"
        }
        if !creating && reminder.isCompleted {
            if case .keep = dueChange {} else { return "completed_reminder_due_unsupported" }
            if case .keep = recurrenceChange {} else {
                return "completed_reminder_recurrence_unsupported"
            }
        }
        if case .set(let spec) = dueChange, let alarm = spec.alarmAt,
           alarm <= Date() { return "alarm_in_past" }
        if !creating {
            if case .keep = dueChange {} else {
                if let start = reminder.startDateComponents {
                    guard let due = reminder.dueDateComponents,
                          ReminderDueSpec.sameDayAndTime(start, due) else {
                        return "complex_start_unsupported"
                    }
                }
                let alarms = reminder.alarms ?? []
                guard alarms.count <= 1,
                      alarms.allSatisfy({ alarm in
                          alarm.type == .display && alarm.structuredLocation == nil &&
                          alarm.proximity == .none && alarm.soundName == nil &&
                          alarm.emailAddress == nil &&
                          (alarm.absoluteDate != nil || reminder.hasRecurrenceRules)
                      }) else {
                    return "complex_alarm_unsupported"
                }
            }
        }
        return nil
    }
    static func apply(_ dueChange: ReminderDueChange,
                                       _ recurrenceChange: ReminderRecurrenceChange,
                                       to reminder: EKReminder) {
        switch dueChange {
        case .keep: break
        case .clear:
            reminder.startDateComponents = nil
            reminder.dueDateComponents = nil
            reminder.alarms = []
        case .set(let spec):
            reminder.startDateComponents = spec.components
            reminder.dueDateComponents = spec.components
            let recurring: Bool
            switch recurrenceChange {
            case .set: recurring = true
            case .clear: recurring = false
            case .keep: recurring = reminder.hasRecurrenceRules
            }
            if let alarm = spec.alarmAt, recurring,
               let start = spec.components.calendar?.date(from: spec.components) {
                reminder.alarms = [EKAlarm(relativeOffset: alarm.timeIntervalSince(start))]
            } else {
                reminder.alarms = spec.alarmAt.map { [EKAlarm(absoluteDate: $0)] } ?? []
            }
        }
        switch recurrenceChange {
        case .keep: break
        case .clear: reminder.recurrenceRules = nil
        case .set(let rule): reminder.recurrenceRules = [rule]
        }
    }
}
