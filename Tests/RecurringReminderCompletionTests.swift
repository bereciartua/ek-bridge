import EventKit
import Foundation

@main
struct RecurringReminderCompletionTests {
    static func main() {
        let daily = EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
        let everyOtherDay = EKRecurrenceRule(recurrenceWith: .daily, interval: 2, end: nil)
        let finiteDaily = EKRecurrenceRule(recurrenceWith: .daily, interval: 1,
                                            end: EKRecurrenceEnd(occurrenceCount: 5))
        let weekly = EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)
        let selectedDaily = EKRecurrenceRule(recurrenceWith: .daily, interval: 1,
            daysOfTheWeek: [EKRecurrenceDayOfWeek(.monday)],
            daysOfTheMonth: nil, monthsOfTheYear: nil,
            weeksOfTheYear: nil, daysOfTheYear: nil,
            setPositions: nil, end: nil)
        precondition(RecurringReminderCompletion.exactDailyRule(daily))
        precondition(!RecurringReminderCompletion.exactDailyRule(everyOtherDay))
        precondition(!RecurringReminderCompletion.exactDailyRule(finiteDaily))
        precondition(!RecurringReminderCompletion.exactDailyRule(weekly))
        precondition(!RecurringReminderCompletion.exactDailyRule(selectedDaily))
        precondition(RecurringReminderCompletion.supportedProvider(
            title: "iCloud", type: .calDAV, delegated: false,
            sourceID: "verified", verifiedSourceID: "verified"))
        precondition(!RecurringReminderCompletion.supportedProvider(
            title: "Other CalDAV", type: .calDAV, delegated: false,
            sourceID: "verified", verifiedSourceID: "verified"))
        precondition(!RecurringReminderCompletion.supportedProvider(
            title: "iCloud", type: .local, delegated: false,
            sourceID: "verified", verifiedSourceID: "verified"))
        precondition(!RecurringReminderCompletion.supportedProvider(
            title: "iCloud", type: .calDAV, delegated: true,
            sourceID: "verified", verifiedSourceID: "verified"))
        precondition(!RecurringReminderCompletion.supportedProvider(
            title: "iCloud", type: .calDAV, delegated: false,
            sourceID: "renamed-other-account", verifiedSourceID: "verified"))
        precondition(!RecurringReminderCompletion.supportedProvider(
            title: "iCloud", type: .calDAV, delegated: false,
            sourceID: "verified", verifiedSourceID: nil))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let due = calendar.date(from: DateComponents(year: 2026, month: 10,
                                                     day: 5, hour: 9))!
        let nextDue = calendar.date(byAdding: .day, value: 1, to: due)!
        let before = RecurringReminderCompletion.Candidate(
            listID: "list", sourceID: "iCloud-source", itemID: "series",
            title: "Test daily", notes: "source",
            location: "", url: "", itemTimeZone: "", priority: 0,
            due: due, nextDue: nextDue,
            fingerprint: String(repeating: "a", count: 64))
        func row(_ id: String, _ date: Date, _ completed: Bool,
                 _ rules: Bool, title: String = "Test daily",
                 completionDate: Bool? = nil, alarms: Bool = false,
                 startMatch: Bool = true) -> RecurringReminderCompletion.Record {
            RecurringReminderCompletion.Record(
                listID: "list", sourceID: "iCloud-source", itemID: id,
                title: title, notes: "source",
                location: "", url: "", itemTimeZone: "", priority: 0,
                due: date, completed: completed,
                hasCompletionDate: completionDate ?? completed,
                hasRules: rules, eligibleDailyRule: rules,
                startMatchesDue: startMatch,
                hasAlarms: alarms)
        }
        let completed = row("completed", due, true, false)
        let next = row("series", nextDue, false, true)
        func verified(_ records: [RecurringReminderCompletion.Record],
                      prior: Set<String> = ["series"]) -> Bool {
            RecurringReminderCompletion.verifiedTransition(
                before, preExistingIDs: prior, records: records) != nil
        }
        precondition(verified([completed, next]))
        precondition(verified([row("completed", due.addingTimeInterval(0.25), true, false),
                               row("series", nextDue.addingTimeInterval(0.25), false, true)]))
        precondition(!verified([completed, next], prior: ["series", "completed"]))
        precondition(RecurringReminderCompletion.ambiguousExistingCompletion(
            before, records: [completed, row("series", due, false, true)]))
        precondition(!RecurringReminderCompletion.ambiguousExistingCompletion(
            before, records: [row("series", due, false, true)]))
        precondition(!verified([completed, completed, next]))
        precondition(!verified([completed, row("series", due, false, true)]))
        precondition(!verified([row("series", due, true, false), next]))
        precondition(!verified([completed, row("series", nextDue, false, true,
                                            title: "Changed")]))
        precondition(!verified([row("completed", due, true, false,
                                    completionDate: false), next]))
        precondition(!verified([completed, row("series", nextDue, false, true,
                                            alarms: true)]))
        precondition(!verified([completed, row("series", nextDue, false, true,
                                            startMatch: false)]))
        print("Recurring completion: exact provider/rule and transition guards passed")
    }
}
