import EventKit
import Foundation

@main
struct ReminderRecurrenceTests {
    static func main() {
        func parse(_ value: [String: Any]?) -> ReminderRecurrenceChange? {
            ReminderRecurrenceChange.parse(parameters: value.map { ["recurrence": $0] } ?? [:])
        }
        func rule(_ value: [String: Any]) -> EKRecurrenceRule {
            guard case .set(let parsed)? = parse(value) else { preconditionFailure("expected rule") }
            return parsed
        }
        func due(_ year: Int, _ month: Int, _ day: Int) -> DateComponents {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "America/New_York")!
            return DateComponents(calendar: calendar, timeZone: calendar.timeZone,
                                  year: year, month: month, day: day, hour: 9, minute: 0)
        }

        guard case .keep? = parse(nil), case .clear? = parse(["kind": "none"]) else {
            preconditionFailure("missing and explicit-clear semantics")
        }
        precondition(parse(["kind": "none", "end": [:]]) == nil)
        precondition(parse(["kind": "rule", "frequency": "daily", "interval": 0]) == nil)
        precondition(parse(["kind": "rule", "frequency": "daily", "interval": true]) == nil)
        precondition(parse(["kind": "rule", "frequency": "daily", "interval": 1,
                            "weekdays": ["MO"]]) == nil)
        precondition(parse(["kind": "rule", "frequency": "weekly", "interval": 1,
                            "weekdays": ["MO", "MO"]]) == nil)
        precondition(parse(["kind": "rule", "frequency": "weekly", "interval": 1,
                            "weekdays": ["XX"]]) == nil)
        precondition(parse(["kind": "rule", "frequency": "monthly", "interval": 1,
                            "dayOfMonth": -1]) == nil)
        precondition(parse(["kind": "rule", "frequency": "yearly", "interval": 1,
                            "dayOfMonth": 4]) == nil)
        precondition(parse(["kind": "rule", "frequency": "daily", "interval": 1,
                            "end": ["kind": "count", "count": 0]]) == nil)
        precondition(parse(["kind": "rule", "frequency": "daily", "interval": 1,
                            "end": ["kind": "until", "at": 1.5]]) == nil)
        precondition(parse(["kind": "rule", "frequency": "daily", "interval": 1,
                            "unexpected": 1]) == nil)

        let daily = rule(["kind": "rule", "frequency": "daily", "interval": 2,
                          "end": ["kind": "count", "count": 9]])
        let dailyBack = ReminderRecurrence.readback([daily])
        precondition(dailyBack["supported"] as? Bool == true)
        precondition(dailyBack["frequency"] as? String == "daily")
        precondition(dailyBack["interval"] as? Int == 2)
        precondition((dailyBack["end"] as? [String: Any])?["count"] as? Int == 9)
        let weekly = rule(["kind": "rule", "frequency": "weekly", "interval": 2,
                           "weekdays": ["WE", "MO"],
                           "end": ["kind": "until", "at": 1_799_000_000]])
        let weeklyBack = ReminderRecurrence.readback([weekly])
        precondition(weeklyBack["supported"] as? Bool == true)
        precondition(weeklyBack["weekdays"] as? [String] == ["MO", "WE"])
        precondition((weeklyBack["end"] as? [String: Any])?["at"] as? Int == 1_799_000_000)
        precondition(ReminderRecurrenceChange.set(weekly).matchesAnchor(due(2026, 10, 5)))
        precondition(!ReminderRecurrenceChange.set(weekly).matchesAnchor(due(2026, 10, 6)))

        let monthly = rule(["kind": "rule", "frequency": "monthly", "interval": 1,
                            "dayOfMonth": 15])
        precondition(ReminderRecurrence.readback([monthly])["dayOfMonth"] as? Int == 15)
        precondition(ReminderRecurrenceChange.set(monthly).matchesAnchor(due(2026, 10, 15)))
        precondition(!ReminderRecurrenceChange.set(monthly).matchesAnchor(due(2026, 10, 16)))
        let yearly = rule(["kind": "rule", "frequency": "yearly", "interval": 1])
        precondition(ReminderRecurrence.readback([yearly])["frequency"] as? String == "yearly")
        precondition(ReminderRecurrence.readback(nil)["kind"] as? String == "none")
        precondition(ReminderRecurrence.readback([daily, yearly])["reason"] as? String == "multiple_rules")
        let nthTuesday = EKRecurrenceRule(recurrenceWith: .monthly, interval: 1,
            daysOfTheWeek: [EKRecurrenceDayOfWeek(.tuesday, weekNumber: 2)],
            daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil,
            daysOfTheYear: nil, setPositions: nil, end: nil)
        precondition(ReminderRecurrence.readback([nthTuesday])["reason"] as? String == "complex_rule")

        // Recurrence uses due's local calendar clock; the absolute interval
        // across New York spring DST is 23 hours, never a fixed 86,400 seconds.
        let before = due(2026, 3, 7)
        let after = due(2026, 3, 8)
        precondition(before.calendar!.date(from: after)!.timeIntervalSince(before.calendar!.date(from: before)!) == 23 * 3_600)
        print("Reminder recurrence: strict parsing, rule readback, unsupported cases, anchor, DST passed")
    }
}
