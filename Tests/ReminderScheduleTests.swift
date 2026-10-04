import EventKit
import Foundation

@main
struct ReminderScheduleTests {
    static func main() {
        let store = EKEventStore()
        let future = Int64(Date().timeIntervalSince1970) + 30 * 86_400
        let due = ReminderDueChange.parse(parameters: ["due": [
            "kind": "timed", "at": future, "timeZone": "UTC"]])!
        let repeatDaily = ReminderRecurrenceChange.parse(parameters: ["recurrence": [
            "kind": "rule", "frequency": "daily", "interval": 1]])!

        let recurring = EKReminder(eventStore: store)
        precondition(ReminderSchedule.validate(due, repeatDaily, for: recurring,
                                               creating: true) == nil)
        ReminderSchedule.apply(due, repeatDaily, to: recurring)
        precondition(recurring.hasRecurrenceRules)
        precondition(recurring.alarms?.count == 1)
        precondition(recurring.alarms?.first?.absoluteDate == nil)
        precondition(recurring.alarms?.first?.relativeOffset == 0)
        let row = ReminderSchedule.describe(recurring)
        precondition((row["recurrence"] as? [String: Any])?["frequency"] as? String == "daily")
        precondition((row["alarms"] as? [[String: Any]])?.first?["kind"] as? String == "relative")

        let oneShot = EKReminder(eventStore: store)
        ReminderSchedule.apply(due, .keep, to: oneShot)
        precondition(oneShot.alarms?.first?.absoluteDate != nil)
        precondition(ReminderSchedule.validate(.keep, repeatDaily, for: oneShot,
                                               creating: false) == "recurrence_requires_alarm_reset")
        precondition(ReminderSchedule.validate(due, repeatDaily, for: oneShot,
                                               creating: false) == nil)

        let custom = EKReminder(eventStore: store)
        ReminderSchedule.apply(due, .keep, to: custom)
        custom.alarms?.first?.soundName = "test-sound"
        precondition(ReminderSchedule.validate(due, .keep, for: custom,
                                               creating: false) == "complex_alarm_unsupported")

        let noAlarm = ReminderDueChange.parse(parameters: ["due": [
            "kind": "timed", "at": future, "timeZone": "UTC", "alarmAt": NSNull()]])!
        let silent = EKReminder(eventStore: store)
        ReminderSchedule.apply(noAlarm, repeatDaily, to: silent)
        precondition((silent.alarms ?? []).isEmpty)

        precondition(ReminderSchedule.validate(.clear, .keep, for: recurring,
                                               creating: false) == "recurrence_requires_due")
        ReminderSchedule.apply(.clear, .clear, to: recurring)
        precondition(recurring.dueDateComponents == nil && !recurring.hasRecurrenceRules)
        precondition((recurring.alarms ?? []).isEmpty)
        print("Reminder schedule: relative recurring alarms, guard, clear, readback passed")
    }
}
