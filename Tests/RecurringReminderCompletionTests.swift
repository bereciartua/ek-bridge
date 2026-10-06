import EventKit
import Foundation

// Completing one occurrence of a repeating reminder (plan 03 §12, P4): the
// account-type allowlist that replaced the source pin, the next due date for
// every rule shape, and the transition guards.
@main
struct RecurringReminderCompletionTests {
    static func main() {
        let zone = TimeZone(identifier: "America/New_York")!
        func spec(_ object: [String: Any]) -> RecurrenceSpec {
            RecurrenceSpec.parse(object.merging(["kind": "rule"]) { _, new in new })!
        }
        let daily = spec(["frequency": "daily"])

        // Providers: account types, never a source ID.
        typealias Completion = RecurringReminderCompletion
        precondition(Completion.provider(title: "iCloud", type: .calDAV, delegated: false) == .iCloud)
        precondition(Completion.provider(title: "Fastmail", type: .calDAV, delegated: false) == .calDAV)
        precondition(Completion.provider(title: "On My Mac", type: .local, delegated: false) == .local)
        precondition(Completion.provider(title: "Work", type: .exchange, delegated: false) == .exchange)
        precondition(Completion.provider(title: "iCloud", type: .calDAV, delegated: true) == nil)
        precondition(Completion.provider(title: "Birthdays", type: .birthdays, delegated: false) == nil)

        // Only the verified shape on the verified account type.
        precondition(Completion.verified(.iCloud, daily, timed: true, hasAlarms: false))
        precondition(!Completion.verified(.iCloud, daily, timed: false, hasAlarms: false), "a due day")
        precondition(!Completion.verified(.iCloud, daily, timed: true, hasAlarms: true), "alarms")
        precondition(!Completion.verified(.local, daily, timed: true, hasAlarms: false), "local")
        precondition(!Completion.verified(.calDAV, daily, timed: true, hasAlarms: false), "other CalDAV")
        precondition(!Completion.verified(nil, daily, timed: true, hasAlarms: false), "no provider")
        for unverified in [spec(["frequency": "daily", "interval": 2]),
                           spec(["frequency": "daily", "end": ["kind": "count", "count": 5]]),
                           spec(["frequency": "weekly"]), spec(["frequency": "weekly", "weekdays": ["MO"]])] {
            precondition(!Completion.verified(.iCloud, unverified, timed: true, hasAlarms: false), "\(unverified)")
        }
        // A probe result widens it without code changes elsewhere.
        let weeklyShape = Completion.VerifiedShape(provider: .local, frequencies: [.weekly, .monthly], selectors: true,
                                                   intervals: true, timedDue: true, allDayDue: true, alarms: true,
                                                   ends: false)
        precondition(Completion.verified(.local, spec(["frequency": "weekly", "interval": 2, "weekdays": ["MO", "WE"]]),
                                         timed: false, hasAlarms: true, shapes: [weeklyShape]))
        precondition(!Completion.verified(.local, spec(["frequency": "weekly", "end": ["kind": "count", "count": 2]]),
                                          timed: true, hasAlarms: false, shapes: [weeklyShape]))

        // The next due date keeps the wall time, across DST and for every shape.
        func due(_ y: Int, _ m: Int, _ d: Int, _ h: Int? = 9) -> DateComponents {
            var parts = DateComponents(year: y, month: m, day: d, hour: h, minute: h == nil ? nil : 0,
                                       second: h == nil ? nil : 0)
            parts.timeZone = zone
            return parts
        }
        func next(_ rule: RecurrenceSpec, _ parts: DateComponents) -> String? {
            Completion.nextDue(rule, after: parts, zone: zone).map { MCPFormat.local($0, zone) }
        }
        precondition(next(daily, due(2026, 10, 31)) == "2026-11-01 09:00", "daily")
        precondition(next(daily, due(2026, 11, 1)) == "2026-11-02 09:00", "daily across the DST change")
        precondition(next(spec(["frequency": "weekly", "weekdays": ["MO", "TH"]]), due(2026, 10, 5))
                     == "2026-10-08 09:00", "Monday → Thursday")
        precondition(next(spec(["frequency": "monthly", "weekdays": ["2TU"]]), due(2026, 10, 13))
                     == "2026-11-10 09:00", "second Tuesdays")
        precondition(next(spec(["frequency": "monthly", "monthDays": [-1]]), due(2027, 1, 31, nil))
                     == "2027-02-28 00:00", "last day, all-day due")
        precondition(next(spec(["frequency": "daily", "end": ["kind": "count", "count": 1]]), due(2026, 10, 5)) == nil,
                     "the last occurrence has no next")
        let untilTonight = Int64(DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: zone,
                                                year: 2026, month: 10, day: 5, hour: 23).date!.timeIntervalSince1970)
        precondition(next(spec(["frequency": "daily", "end": ["kind": "until", "at": untilTonight]]),
                          due(2026, 10, 5)) == nil, "until before the next")
        precondition(next(daily, due(2026, 3, 7, 2)) == nil, "2:00 doesn't exist on 2026-03-08 in New York")

        // Transitions.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let dueDate = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 9))!
        let nextDate = calendar.date(byAdding: .day, value: 1, to: dueDate)!
        let before = Completion.Candidate(
            listID: "list", sourceID: "iCloud-source", itemID: "series",
            title: "Test daily", notes: "source", location: "", url: "", itemTimeZone: "", priority: 0,
            spec: daily, alarms: [], due: dueDate, nextDue: nextDate,
            fingerprint: String(repeating: "a", count: 64))
        func row(_ id: String, _ date: Date, _ completed: Bool, _ rules: Bool, title: String = "Test daily",
                 completionDate: Bool? = nil, alarms: [AlarmSpec?] = [], rule: RecurrenceSpec? = nil,
                 startMatch: Bool = true) -> Completion.Record {
            Completion.Record(
                listID: "list", sourceID: "iCloud-source", itemID: id, title: title, notes: "source",
                location: "", url: "", itemTimeZone: "", priority: 0, due: date, completed: completed,
                hasCompletionDate: completionDate ?? completed, hasRules: rules,
                rule: rules ? (rule ?? daily) : nil, startMatchesDue: startMatch, alarms: alarms)
        }
        let completed = row("completed", dueDate, true, false)
        let next = row("series", nextDate, false, true)
        func verified(_ records: [Completion.Record], prior: Set<String> = ["series"]) -> Bool {
            Completion.verifiedTransition(before, preExistingIDs: prior, records: records) != nil
        }
        precondition(verified([completed, next]))
        precondition(verified([row("completed", dueDate.addingTimeInterval(0.25), true, false),
                               row("series", nextDate.addingTimeInterval(0.25), false, true)]))
        precondition(!verified([completed, next], prior: ["series", "completed"]))
        precondition(Completion.ambiguousExistingCompletion(before, records: [completed, row("series", dueDate, false, true)]))
        precondition(!Completion.ambiguousExistingCompletion(before, records: [row("series", dueDate, false, true)]))
        precondition(!verified([completed, completed, next]))
        precondition(!verified([completed, row("series", dueDate, false, true)]))
        precondition(!verified([row("series", dueDate, true, false), next]))
        precondition(!verified([completed, row("series", nextDate, false, true, title: "Changed")]))
        precondition(!verified([row("completed", dueDate, true, false, completionDate: false), next]))
        precondition(!verified([completed, row("series", nextDate, false, true, alarms: [.relative(0)])]))
        precondition(!verified([completed, row("series", nextDate, false, true, startMatch: false)]))
        precondition(!verified([completed, row("series", nextDate, false, true,
                                                rule: spec(["frequency": "daily", "interval": 2]))]),
                     "the series' rule changed")
        print("Recurring completion: account-type allowlist, next due for every shape, transition guards passed")
    }
}

enum MCPFormat {
    static func local(_ date: Date, _ zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!)
    }
}
