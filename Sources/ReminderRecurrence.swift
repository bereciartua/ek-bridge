import EventKit
import Foundation

// A deliberately small, lossless subset of EventKit recurrence. The anchor is
// the reminder's dueDateComponents; its calendar/timeZone supplies local wall
// time across DST. An EKRecurrenceRule itself carries no time zone.
enum ReminderRecurrenceChange {
    case keep
    case clear
    case set(EKRecurrenceRule)

    // Missing parameter preserves an existing rule. Clearing must be explicit.
    // Accepted JSON: {kind:"none"}, or {kind:"rule", frequency: daily|
    // weekly|monthly|yearly, interval:1..366, optional weekdays:[SU..SA]
    // (weekly), optional dayOfMonth:1..31 (monthly), optional end:{kind:
    // "count",count:1..10000}|{kind:"until",at:<integer Unix seconds>}}.
    // A malformed or unsupported shape returns nil before EventKit is touched.
    static func parse(parameters: [String: Any]) -> ReminderRecurrenceChange? {
        guard let input = parameters["recurrence"] else { return .keep }
        guard let object = input as? [String: Any],
              let kind = object["kind"] as? String else { return nil }
        if kind == "none" {
            return Set(object.keys) == ["kind"] ? .clear : nil
        }
        guard kind == "rule",
              Set(object.keys).isSubset(of: ["kind", "frequency", "interval", "weekdays", "dayOfMonth", "end"]),
              let frequencyName = object["frequency"] as? String,
              let interval = recurrenceInteger(object["interval"]), (1...366).contains(interval)
        else { return nil }

        let frequency: EKRecurrenceFrequency
        switch frequencyName {
        case "daily": frequency = .daily
        case "weekly": frequency = .weekly
        case "monthly": frequency = .monthly
        case "yearly": frequency = .yearly
        default: return nil
        }

        var weekdays: [EKRecurrenceDayOfWeek]?
        if let raw = object["weekdays"] {
            guard frequency == .weekly, let names = raw as? [String],
                  !names.isEmpty, names.count <= 7,
                  Set(names).count == names.count else { return nil }
            let mapped = names.compactMap { name -> EKRecurrenceDayOfWeek? in
                guard let weekday = ReminderRecurrence.weekdayCodes[name] else { return nil }
                return EKRecurrenceDayOfWeek(weekday)
            }
            guard mapped.count == names.count else { return nil }
            weekdays = mapped
        }

        var monthDays: [NSNumber]?
        if let raw = object["dayOfMonth"] {
            guard frequency == .monthly,
                  let day = recurrenceInteger(raw), (1...31).contains(day)
            else { return nil }
            monthDays = [NSNumber(value: day)]
        }

        var end: EKRecurrenceEnd?
        if let raw = object["end"] {
            guard let value = raw as? [String: Any],
                  let endKind = value["kind"] as? String else { return nil }
            switch endKind {
            case "count":
                guard Set(value.keys) == ["kind", "count"],
                      let count = recurrenceInteger(value["count"]),
                      (1...10_000).contains(count) else { return nil }
                end = EKRecurrenceEnd(occurrenceCount: count)
            case "until":
                guard Set(value.keys) == ["kind", "at"],
                      let seconds = recurrenceInteger(value["at"]),
                      (-2_208_988_800...4_102_444_800).contains(seconds)
                else { return nil }
                end = EKRecurrenceEnd(end: Date(timeIntervalSince1970: TimeInterval(seconds)))
            default: return nil
            }
        }

        let rule: EKRecurrenceRule
        if weekdays != nil || monthDays != nil {
            rule = EKRecurrenceRule(recurrenceWith: frequency, interval: interval,
                                    daysOfTheWeek: weekdays, daysOfTheMonth: monthDays,
                                    monthsOfTheYear: nil, weeksOfTheYear: nil,
                                    daysOfTheYear: nil, setPositions: nil, end: end)
        } else {
            rule = EKRecurrenceRule(recurrenceWith: frequency, interval: interval, end: end)
        }
        return .set(rule)
    }

    // Explicit BYDAY/BYMONTHDAY values must agree with the first due date.
    // Call before a create or recurrence replacement using the due components.
    func matchesAnchor(_ due: DateComponents) -> Bool {
        guard case .set(let rule) = self else { return true }
        guard due.year != nil, due.month != nil, due.day != nil,
              let calendar = due.calendar,
              let date = calendar.date(from: due) else { return false }
        if let weekdayRules = rule.daysOfTheWeek {
            let weekday = calendar.component(.weekday, from: date)
            guard weekdayRules.contains(where: { $0.dayOfTheWeek.rawValue == weekday }) else { return false }
        }
        if let monthDays = rule.daysOfTheMonth {
            guard monthDays.contains(where: { $0.intValue == due.day }) else { return false }
        }
        if let endDate = rule.recurrenceEnd?.endDate, endDate < date { return false }
        return true
    }
}

enum ReminderRecurrence {
    static let weekdayCodes: [String: EKWeekday] = [
        "SU": .sunday, "MO": .monday, "TU": .tuesday, "WE": .wednesday,
        "TH": .thursday, "FR": .friday, "SA": .saturday,
    ]

    static func readback(_ rules: [EKRecurrenceRule]?) -> [String: Any] {
        guard let rules, !rules.isEmpty else { return ["kind": "none", "supported": true] }
        guard rules.count == 1 else {
            return ["kind": "unsupported", "supported": false,
                    "reason": "multiple_rules", "ruleCount": rules.count]
        }
        let rule = rules[0]
        let frequency: String
        switch rule.frequency {
        case .daily: frequency = "daily"
        case .weekly: frequency = "weekly"
        case .monthly: frequency = "monthly"
        case .yearly: frequency = "yearly"
        @unknown default: return unsupported("unknown_frequency", rule)
        }
        guard (1...366).contains(rule.interval),
              rule.setPositions == nil, rule.weeksOfTheYear == nil,
              rule.daysOfTheYear == nil else { return unsupported("complex_rule", rule) }
        var result: [String: Any] = ["kind": "rule", "supported": true,
                                     "frequency": frequency, "interval": rule.interval]
        switch rule.frequency {
        case .daily:
            guard rule.daysOfTheWeek == nil, rule.daysOfTheMonth == nil,
                  rule.monthsOfTheYear == nil else { return unsupported("complex_rule", rule) }
        case .weekly:
            guard rule.daysOfTheMonth == nil, rule.monthsOfTheYear == nil,
                  rule.firstDayOfTheWeek == 0 || rule.firstDayOfTheWeek == 2
            else { return unsupported("complex_rule", rule) }
            if let days = rule.daysOfTheWeek {
                let reverse = Dictionary(uniqueKeysWithValues: weekdayCodes.map { ($0.value.rawValue, $0.key) })
                let mapped = days.compactMap { day -> String? in
                    guard day.weekNumber == 0 else { return nil }
                    return reverse[day.dayOfTheWeek.rawValue]
                }
                guard !mapped.isEmpty, mapped.count == days.count,
                      Set(mapped).count == mapped.count else { return unsupported("complex_rule", rule) }
                result["weekdays"] = mapped.sorted { weekdayOrder($0) < weekdayOrder($1) }
            }
        case .monthly:
            guard rule.daysOfTheWeek == nil, rule.monthsOfTheYear == nil else {
                return unsupported("complex_rule", rule)
            }
            if let days = rule.daysOfTheMonth {
                guard days.count == 1, (1...31).contains(days[0].intValue) else {
                    return unsupported("complex_rule", rule)
                }
                result["dayOfMonth"] = days[0].intValue
            }
        case .yearly:
            guard rule.daysOfTheWeek == nil, rule.daysOfTheMonth == nil,
                  rule.monthsOfTheYear == nil else { return unsupported("complex_rule", rule) }
        @unknown default: return unsupported("unknown_frequency", rule)
        }
        if let end = rule.recurrenceEnd {
            if let date = end.endDate {
                let seconds = date.timeIntervalSince1970
                guard seconds.isFinite, seconds.rounded() == seconds,
                      seconds >= -2_208_988_800, seconds <= 4_102_444_800 else {
                    return unsupported("unsupported_end", rule)
                }
                result["end"] = ["kind": "until", "at": Int(seconds)]
            } else if (1...10_000).contains(end.occurrenceCount) {
                result["end"] = ["kind": "count", "count": end.occurrenceCount]
            } else { return unsupported("unsupported_end", rule) }
        }
        return result
    }

    private static func weekdayOrder(_ name: String) -> Int {
        ["SU", "MO", "TU", "WE", "TH", "FR", "SA"].firstIndex(of: name) ?? 7
    }
    private static func unsupported(_ reason: String, _ rule: EKRecurrenceRule) -> [String: Any] {
        ["kind": "unsupported", "supported": false, "reason": reason,
         "ruleCount": 1, "frequencyRaw": rule.frequency.rawValue, "interval": rule.interval]
    }
}

private func recurrenceInteger(_ raw: Any?) -> Int? {
    guard let number = raw as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let value = number.doubleValue
    return value.isFinite && value.rounded() == value ? Int(exactly: value) : nil
}
