import Foundation

/// Short English descriptions of a recurrence rule, for read results and the
/// approval panel: "Every 2 weeks on Monday and Wednesday, until Dec 31, 2026".
/// Deterministic (no locale), so goldens stay stable.
enum RecurrenceText {
    static let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    static let monthNames = ["January", "February", "March", "April", "May", "June", "July", "August",
                             "September", "October", "November", "December"]

    static func summary(_ spec: RecurrenceSpec, zone: TimeZone?) -> String {
        var text = base(spec)
        if !spec.months.isEmpty {
            text += " in " + list(spec.months.sorted().map { monthNames[$0 - 1] })
        }
        var selectors = [String]()
        if !spec.weekdays.isEmpty { selectors.append(weekdays(spec)) }
        if !spec.monthDays.isEmpty { selectors.append(monthDays(spec.monthDays)) }
        if !selectors.isEmpty {
            let joined = selectors.joined(separator: " that is also ")
            text += spec.setPositions.isEmpty ? " on " + joined
                : " on the " + positions(spec.setPositions) + " of " + joined
        }
        switch spec.end {
        case .count(let count)?: text += count == 1 ? ", once" : ", \(count) times"
        case .until(let at)?: text += ", until " + date(at, zone: zone ?? TimeZone(identifier: "UTC")!)
        case nil: break
        }
        return text
    }

    private static func base(_ spec: RecurrenceSpec) -> String {
        let units = [RecurrenceSpec.Frequency.daily: ("Daily", "days"), .weekly: ("Weekly", "weeks"),
                     .monthly: ("Monthly", "months"), .yearly: ("Yearly", "years")]
        let (single, plural) = units[spec.frequency]!
        return spec.interval == 1 ? single : "Every \(spec.interval) \(plural)"
    }

    private static func weekdays(_ spec: RecurrenceSpec) -> String {
        // Monday first, as people say them.
        let order = { (day: Int) in (day + 5) % 7 }
        let entries = spec.weekdays.sorted {
            $0.week != $1.week ? ordinalOrder($0.week) < ordinalOrder($1.week) : order($0.day) < order($1.day)
        }
        if entries.allSatisfy({ $0.week == 0 }) {
            let days = Set(entries.map(\.day))
            if days == [2, 3, 4, 5, 6] { return "weekdays" }
            if days == [1, 7] { return "weekends" }
            return list(entries.map { dayNames[$0.day - 1] })
        }
        // Group numbered days by day: "the first and third Monday".
        var groups = [(day: Int, weeks: [Int])]()
        for entry in entries.sorted(by: { order($0.day) != order($1.day) ? order($0.day) < order($1.day)
                                          : ordinalOrder($0.week) < ordinalOrder($1.week) }) {
            if let index = groups.firstIndex(where: { $0.day == entry.day }) {
                groups[index].weeks.append(entry.week)
            } else {
                groups.append((entry.day, [entry.week]))
            }
        }
        return list(groups.map { group in
            let name = dayNames[group.day - 1]
            if group.weeks.contains(0) { return "every \(name)" }
            return "the \(list(group.weeks.map(ordinal))) \(name)"
        })
    }

    private static func monthDays(_ days: [Int]) -> String {
        let positive = days.filter { $0 > 0 }.sorted()
        let negative = days.filter { $0 < 0 }.sorted(by: >)
        var parts = [String]()
        if !positive.isEmpty {
            parts.append((positive.count == 1 ? "day " : "days ") + list(positive.map(String.init)))
        }
        parts += negative.map { $0 == -1 ? "the last day" : "the \(ordinal($0)) day" }
        return list(parts)
    }

    private static func positions(_ values: [Int]) -> String {
        list(values.sorted { ordinalOrder($0) < ordinalOrder($1) }.map(ordinal))
    }

    private static func ordinalOrder(_ value: Int) -> Int { value > 0 ? value : 1_000 - value }

    static func ordinal(_ value: Int) -> String {
        let words = ["first", "second", "third", "fourth", "fifth"]
        if value > 0 { return value <= 5 ? words[value - 1] : "\(value)\(suffix(value))" }
        if value == -1 { return "last" }
        let distance = -value
        return distance <= 5 ? "\(words[distance - 1])-to-last" : "\(distance)\(suffix(distance))-to-last"
    }

    private static func suffix(_ value: Int) -> String {
        if (11...13).contains(value % 100) { return "th" }
        switch value % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }

    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }

    /// "Dec 31, 2026" in `zone`.
    static func date(_ seconds: Int64, zone: TimeZone) -> String {
        let instant = Date(timeIntervalSince1970: TimeInterval(seconds))
        let (year, month, day) = RecurrenceExpansion.civil(RecurrenceExpansion.localDay(instant, zone: zone).day)
        return "\(monthNames[month - 1].prefix(3)) \(day), \(year)"
    }
}
