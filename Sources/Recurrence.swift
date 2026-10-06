import EventKit
import Foundation

// One recurrence model for events and reminders (plan 03 §7). The rule has no
// time zone: occurrences keep the first one's wall time in the item's zone
// (the event's timeZone, or the zone of a reminder's due components).

/// A lossless subset of RFC 5545 that EventKit can store and the bridge can
/// read back exactly.
struct RecurrenceSpec: Equatable {
    enum Frequency: String, CaseIterable { case daily, weekly, monthly, yearly }

    struct Weekday: Equatable, Hashable {
        /// 1 = Sunday … 7 = Saturday, as `EKWeekday`.
        let day: Int
        /// 0 = every such weekday; ±n = the nth from the start (or end) of the
        /// month, or of the year in a yearly rule without months.
        var week = 0

        static let codes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]

        /// "MO", "2TU", "-1FR".
        init?(code text: String) {
            let bytes = Array(text.utf8)
            guard bytes.count >= 2, let day = Self.codes.firstIndex(of: String(text.suffix(2))) else {
                return nil
            }
            let prefix = String(text.dropLast(2))
            if prefix.isEmpty {
                self.init(day: day + 1, week: 0)
                return
            }
            let digits = prefix.hasPrefix("-") ? String(prefix.dropFirst()) : prefix
            guard (1...2).contains(digits.count), digits.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Int(digits), number > 0 else { return nil }
            self.init(day: day + 1, week: prefix.hasPrefix("-") ? -number : number)
        }

        init(day: Int, week: Int = 0) {
            self.day = day
            self.week = week
        }

        var code: String { (week == 0 ? "" : String(week)) + Self.codes[day - 1] }
    }

    enum End: Equatable {
        case count(Int)
        /// Unix seconds; occurrences starting after it don't happen.
        case until(Int64)
    }

    var frequency: Frequency
    var interval = 1
    var weekdays: [Weekday] = []
    var monthDays: [Int] = []
    var months: [Int] = []
    var setPositions: [Int] = []
    /// Read only: EventKit can't set it. 1 = Sunday, 2 = Monday; nil when the
    /// rule doesn't say (Monday, per RFC 5545).
    var weekStart: Int?
    var end: End?

    /// Nil when the bridge can write this rule; otherwise what's wrong, in the
    /// MCP argument names.
    var problem: String? {
        guard (1...366).contains(interval) else { return "interval: expected 1 to 366" }
        if !weekdays.isEmpty {
            if frequency == .daily { return "weekdays: not used with daily rules" }
            guard weekdays.count <= 7, Set(weekdays).count == weekdays.count,
                  weekdays.allSatisfy({ (1...7).contains($0.day) }) else {
                return "weekdays: expected 1 to 7 distinct values"
            }
            let limit = frequency == .monthly || (frequency == .yearly && !months.isEmpty) ? 5 : 53
            for weekday in weekdays where weekday.week != 0 {
                if frequency == .weekly {
                    return "weekdays: weekly rules take plain codes like MO, without a number"
                }
                guard (1...limit).contains(abs(weekday.week)) else {
                    return "weekdays: \(weekday.code) needs a number from 1 to \(limit) or -1 to -\(limit)"
                }
            }
        }
        if !monthDays.isEmpty {
            guard frequency == .monthly || frequency == .yearly else {
                return "month_days: only for monthly and yearly rules"
            }
            guard monthDays.count <= 31, Set(monthDays).count == monthDays.count,
                  monthDays.allSatisfy({ (1...31).contains(abs($0)) }) else {
                return "month_days: expected 1 to 31 distinct values from 1 to 31 or -31 to -1"
            }
            if frequency == .yearly && months.isEmpty {
                return "month_days: a yearly rule with month_days also needs months"
            }
        }
        if !months.isEmpty {
            guard frequency == .yearly else { return "months: only for yearly rules" }
            guard months.count <= 12, Set(months).count == months.count,
                  months.allSatisfy({ (1...12).contains($0) }) else {
                return "months: expected 1 to 12 distinct values from 1 to 12"
            }
        }
        if !setPositions.isEmpty {
            guard !weekdays.isEmpty || !monthDays.isEmpty else {
                return "set_positions: needs weekdays or month_days"
            }
            guard setPositions.count <= 366, Set(setPositions).count == setPositions.count,
                  setPositions.allSatisfy({ (1...366).contains(abs($0)) }) else {
                return "set_positions: expected distinct values from 1 to 366 or -366 to -1"
            }
        }
        if let weekStart, !(1...7).contains(weekStart) { return "week_start: expected MO or SU" }
        switch end {
        case .count(let count)? where !(1...10_000).contains(count):
            return "end.count: expected 1 to 10000"
        case .until(let at)? where !(-2_208_988_800...4_102_444_800).contains(at):
            return "end.until: expected a time between 1900 and 2100"
        default:
            return nil
        }
    }

    // MARK: Core JSON

    /// {"kind":"rule","frequency",…}. Weekdays are codes ("MO", "2TU") or
    /// {"day","week"} objects; `dayOfMonth` is the 0.5 alias of
    /// `monthDays: [n]`. Nil for anything malformed or unwritable.
    static func parse(_ raw: Any?) -> RecurrenceSpec? {
        guard let object = raw as? [String: Any], object["kind"] as? String == "rule",
              Set(object.keys).isSubset(of: ["kind", "frequency", "interval", "weekdays", "monthDays",
                                             "months", "setPositions", "dayOfMonth", "end"]),
              let frequency = (object["frequency"] as? String).flatMap(Frequency.init(rawValue:))
        else { return nil }
        var spec = RecurrenceSpec(frequency: frequency)
        if let raw = object["interval"] {
            guard let interval = integer(raw) else { return nil }
            spec.interval = interval
        }
        if let raw = object["weekdays"] {
            guard let list = raw as? [Any], !list.isEmpty else { return nil }
            let parsed = list.compactMap { item -> Weekday? in
                if let code = item as? String { return Weekday(code: code) }
                guard let entry = item as? [String: Any],
                      Set(entry.keys).isSubset(of: ["day", "week"]),
                      let day = (entry["day"] as? String).flatMap({ Weekday.codes.firstIndex(of: $0) })
                else { return nil }
                var week = 0
                if let raw = entry["week"] {
                    guard let number = integer(raw) else { return nil }
                    week = number
                }
                return Weekday(day: day + 1, week: week)
            }
            guard parsed.count == list.count else { return nil }
            spec.weekdays = parsed
        }
        for (key, path) in [("monthDays", \RecurrenceSpec.monthDays), ("months", \.months),
                            ("setPositions", \.setPositions)] {
            guard let raw = object[key] else { continue }
            guard let list = raw as? [Any], !list.isEmpty else { return nil }
            let values = list.compactMap(integer)
            guard values.count == list.count else { return nil }
            spec[keyPath: path] = values
        }
        if let raw = object["dayOfMonth"] {
            guard frequency == .monthly, object["monthDays"] == nil,
                  let day = integer(raw), (1...31).contains(day) else { return nil }
            spec.monthDays = [day]
        }
        if let raw = object["end"] {
            guard let end = raw as? [String: Any], let kind = end["kind"] as? String else { return nil }
            switch kind {
            case "count":
                guard Set(end.keys) == ["kind", "count"], let count = integer(end["count"]) else { return nil }
                spec.end = .count(count)
            case "until":
                guard Set(end.keys) == ["kind", "at"], let at = integer(end["at"]) else { return nil }
                spec.end = .until(Int64(at))
            default:
                return nil
            }
        }
        return spec.problem == nil ? spec : nil
    }

    /// The core readback shape, plus `rrule` and `summary` for display.
    func core(zone: TimeZone?) -> [String: Any] {
        var result: [String: Any] = ["kind": "rule", "supported": true,
                                     "frequency": frequency.rawValue, "interval": interval]
        if !weekdays.isEmpty { result["weekdays"] = weekdays.map(\.code) }
        if !monthDays.isEmpty { result["monthDays"] = monthDays }
        if !months.isEmpty { result["months"] = months }
        if !setPositions.isEmpty { result["setPositions"] = setPositions }
        if let weekStart { result["weekStart"] = Weekday.codes[weekStart - 1] }
        switch end {
        case .count(let count)?: result["end"] = ["kind": "count", "count": count]
        case .until(let at)?: result["end"] = ["kind": "until", "at": at]
        case nil: break
        }
        result["rrule"] = rrule
        result["summary"] = RecurrenceText.summary(self, zone: zone)
        return result
    }

    /// RFC 5545 text, for display only (never parsed back).
    var rrule: String {
        var parts = ["FREQ=\(frequency.rawValue.uppercased())"]
        if interval != 1 { parts.append("INTERVAL=\(interval)") }
        if !weekdays.isEmpty { parts.append("BYDAY=" + weekdays.map(\.code).joined(separator: ",")) }
        if !monthDays.isEmpty { parts.append("BYMONTHDAY=" + monthDays.map(String.init).joined(separator: ",")) }
        if !months.isEmpty { parts.append("BYMONTH=" + months.map(String.init).joined(separator: ",")) }
        if !setPositions.isEmpty { parts.append("BYSETPOS=" + setPositions.map(String.init).joined(separator: ",")) }
        if let weekStart { parts.append("WKST=" + Weekday.codes[weekStart - 1]) }
        switch end {
        case .count(let count)?: parts.append("COUNT=\(count)")
        case .until(let at)?: parts.append("UNTIL=" + Self.utcStamp(at))
        case nil: break
        }
        return parts.joined(separator: ";")
    }

    static func utcStamp(_ seconds: Int64) -> String {
        let days = Int(floor(Double(seconds) / 86_400))
        let rest = Int(seconds) - days * 86_400
        let (year, month, day) = RecurrenceExpansion.civil(days)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ", year, month, day,
                      rest / 3_600, rest % 3_600 / 60, rest % 60)
    }

    // MARK: EventKit

    func makeRule() -> EKRecurrenceRule {
        let frequency: EKRecurrenceFrequency
        switch self.frequency {
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly: frequency = .yearly
        }
        let end: EKRecurrenceEnd?
        switch self.end {
        case .count(let count)?: end = EKRecurrenceEnd(occurrenceCount: count)
        case .until(let at)?: end = EKRecurrenceEnd(end: Date(timeIntervalSince1970: TimeInterval(at)))
        case nil: end = nil
        }
        if weekdays.isEmpty && monthDays.isEmpty && months.isEmpty && setPositions.isEmpty {
            return EKRecurrenceRule(recurrenceWith: frequency, interval: interval, end: end)
        }
        let days = weekdays.isEmpty ? nil : weekdays.map {
            $0.week == 0 ? EKRecurrenceDayOfWeek(EKWeekday(rawValue: $0.day)!)
                : EKRecurrenceDayOfWeek(EKWeekday(rawValue: $0.day)!, weekNumber: $0.week)
        }
        func numbers(_ values: [Int]) -> [NSNumber]? { values.isEmpty ? nil : values.map { NSNumber(value: $0) } }
        return EKRecurrenceRule(recurrenceWith: frequency, interval: interval, daysOfTheWeek: days,
                                daysOfTheMonth: numbers(monthDays), monthsOfTheYear: numbers(months),
                                weeksOfTheYear: nil, daysOfTheYear: nil,
                                setPositions: numbers(setPositions), end: end)
    }

    /// The rule as written, or why the bridge can't represent it.
    struct Unreadable: Error { let reason: String }

    static func read(_ rule: EKRecurrenceRule) -> Result<RecurrenceSpec, Unreadable> {
        let frequency: Frequency
        switch rule.frequency {
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly: frequency = .yearly
        @unknown default: return .failure(Unreadable(reason: "unknown_frequency"))
        }
        if !(rule.weeksOfTheYear ?? []).isEmpty || !(rule.daysOfTheYear ?? []).isEmpty {
            return .failure(Unreadable(reason: "complex_rule"))
        }
        var spec = RecurrenceSpec(frequency: frequency, interval: rule.interval)
        spec.weekdays = (rule.daysOfTheWeek ?? []).map {
            Weekday(day: $0.dayOfTheWeek.rawValue, week: $0.weekNumber)
        }
        spec.monthDays = (rule.daysOfTheMonth ?? []).map(\.intValue)
        spec.months = (rule.monthsOfTheYear ?? []).map(\.intValue)
        spec.setPositions = (rule.setPositions ?? []).map(\.intValue)
        // Only weekly rules use the first day of the week; EventKit sets it to
        // Monday for those with an interval over 1.
        let firstDay = rule.firstDayOfTheWeek
        if frequency == .weekly && firstDay != 0 {
            guard firstDay == 1 || firstDay == 2 else { return .failure(Unreadable(reason: "complex_rule")) }
            spec.weekStart = firstDay
        } else if !(0...7).contains(firstDay) {
            return .failure(Unreadable(reason: "complex_rule"))
        }
        if let end = rule.recurrenceEnd {
            if let date = end.endDate {
                let seconds = date.timeIntervalSince1970
                guard seconds.isFinite, let whole = Int64(exactly: seconds.rounded(.down)) else {
                    return .failure(Unreadable(reason: "unsupported_end"))
                }
                spec.end = .until(whole)
            } else {
                spec.end = .count(end.occurrenceCount)
            }
        }
        if spec.problem != nil { return .failure(Unreadable(reason: "complex_rule")) }
        return .success(spec)
    }

    /// RFC-style text for any rule, including parts the bridge can't write.
    static func rawText(_ rule: EKRecurrenceRule) -> String {
        let names = [EKRecurrenceFrequency.daily: "DAILY", .weekly: "WEEKLY", .monthly: "MONTHLY",
                     .yearly: "YEARLY"]
        var parts = ["FREQ=\(names[rule.frequency] ?? "OTHER")"]
        if rule.interval != 1 { parts.append("INTERVAL=\(rule.interval)") }
        func list(_ key: String, _ values: [NSNumber]?) {
            if let values, !values.isEmpty { parts.append("\(key)=" + values.map(\.stringValue).joined(separator: ",")) }
        }
        if let days = rule.daysOfTheWeek, !days.isEmpty {
            parts.append("BYDAY=" + days.map {
                Weekday(day: $0.dayOfTheWeek.rawValue, week: $0.weekNumber).code
            }.joined(separator: ","))
        }
        list("BYMONTHDAY", rule.daysOfTheMonth)
        list("BYMONTH", rule.monthsOfTheYear)
        list("BYWEEKNO", rule.weeksOfTheYear)
        list("BYYEARDAY", rule.daysOfTheYear)
        list("BYSETPOS", rule.setPositions)
        if let end = rule.recurrenceEnd {
            if let date = end.endDate {
                parts.append("UNTIL=" + utcStamp(Int64(date.timeIntervalSince1970.rounded(.down))))
            } else {
                parts.append("COUNT=\(end.occurrenceCount)")
            }
        }
        return parts.joined(separator: ";")
    }

    private static func integer(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        return value.isFinite && value.rounded() == value ? Int(exactly: value) : nil
    }
}

/// The `recurrence` parameter of a write.
enum RecurrenceChange: Equatable {
    case keep
    case clear
    case set(RecurrenceSpec)

    var isKeep: Bool { self == .keep }

    /// Absent keeps the rule, {"kind":"none"} removes it. Nil when malformed.
    static func parse(parameters: [String: Any]) -> RecurrenceChange? {
        guard let input = parameters["recurrence"] else { return .keep }
        guard let object = input as? [String: Any] else { return nil }
        if object["kind"] as? String == "none" {
            return Set(object.keys) == ["kind"] ? .clear : nil
        }
        return RecurrenceSpec.parse(object).map(Self.set)
    }
}

/// What an item's recurrence rules are, as the bridge sees them.
enum RecurrenceRead: Equatable {
    case none
    case rule(RecurrenceSpec)
    case unsupported(reason: String, summary: String)

    init(_ rules: [EKRecurrenceRule]?) {
        guard let rules, !rules.isEmpty else { self = .none; return }
        guard rules.count == 1 else {
            self = .unsupported(reason: "multiple_rules",
                                summary: rules.map(RecurrenceSpec.rawText).joined(separator: " + "))
            return
        }
        switch RecurrenceSpec.read(rules[0]) {
        case .success(let spec): self = .rule(spec)
        case .failure(let failure):
            self = .unsupported(reason: failure.reason, summary: RecurrenceSpec.rawText(rules[0]))
        }
    }

    var spec: RecurrenceSpec? { if case .rule(let spec) = self { return spec } else { return nil } }
    var isSupported: Bool { if case .unsupported = self { return false } else { return true } }

    func core(zone: TimeZone?) -> [String: Any] {
        switch self {
        case .none: return ["kind": "none", "supported": true]
        case .rule(let spec): return spec.core(zone: zone)
        case .unsupported(let reason, let summary):
            return ["kind": "unsupported", "supported": false, "reason": reason, "summary": summary]
        }
    }
}

extension RecurrenceSpec {
    /// The first occurrence must be one of the rule's own dates (§7.3), and an
    /// `until` can't come before it.
    func matchesAnchor(start: Date, zone: TimeZone) -> Bool {
        if case .until(let at)? = end, TimeInterval(at) < start.timeIntervalSince1970 { return false }
        let anchor = RecurrenceExpansion.localDay(start, zone: zone)
        return RecurrenceExpansion.days(self, anchor: anchor.day, through: anchor.day, ignoreEnd: true)
            .first == anchor.day
    }

    /// The first date at or after `start` that the rule matches, for hints.
    func nextMatch(after start: Date, zone: TimeZone) -> (year: Int, month: Int, day: Int)? {
        let anchor = RecurrenceExpansion.localDay(start, zone: zone)
        guard let day = RecurrenceExpansion.days(self, anchor: anchor.day, through: anchor.day + 4 * 366,
                                                 limit: 1, ignoreEnd: true).first else { return nil }
        return RecurrenceExpansion.civil(day)
    }

    /// Readback comparison (§7.3): the same rule, or one a provider normalized
    /// into the same occurrences over the next 400 days with the same end.
    func equivalent(to saved: RecurrenceSpec, start: Date, zone: TimeZone) -> Bool {
        if self == saved { return true }
        switch (end, saved.end) {
        case (nil, nil): break
        case (.count(let a)?, .count(let b)?) where a == b: break
        case (.until(let a)?, .until(let b)?) where abs(a - b) < 86_400: break
        default: return false
        }
        return RecurrenceExpansion.occurrences(self, start: start, zone: zone)
            == RecurrenceExpansion.occurrences(saved, start: start, zone: zone)
    }
}

/// Pure occurrence dates for a `RecurrenceSpec`, on local calendar days
/// (days since 1970-01-01). Used for anchor checks, readback comparison and
/// hints; EventKit itself expands occurrences for reads.
enum RecurrenceExpansion {
    static let window = 400

    /// Occurrence days from `start` over `window` days, honoring the rule's end.
    static func occurrences(_ spec: RecurrenceSpec, start: Date, zone: TimeZone,
                            window: Int = window) -> [Int] {
        let anchor = localDay(start, zone: zone)
        var last = anchor.day + window
        if case .until(let at)? = spec.end {
            let until = localDay(Date(timeIntervalSince1970: TimeInterval(at)), zone: zone)
            last = min(last, until.seconds >= anchor.seconds ? until.day : until.day - 1)
        }
        return days(spec, anchor: anchor.day, through: last)
    }

    /// Days on or after `anchor` and up to `last`, starting from the anchor's
    /// period, at most `limit`. A count end counts from the anchor.
    static func days(_ spec: RecurrenceSpec, anchor: Int, through last: Int, limit: Int = 2_000,
                     ignoreEnd: Bool = false) -> [Int] {
        var cap = limit
        if !ignoreEnd, case .count(let count)? = spec.end { cap = min(cap, count) }
        var result = [Int]()
        let (anchorYear, anchorMonth, anchorDay) = civil(anchor)
        var period = 0
        while result.count < cap && period < 200_000 {
            let candidates: [Int]
            let periodStart: Int
            switch spec.frequency {
            case .daily:
                periodStart = anchor + period * spec.interval
                candidates = [periodStart]
            case .weekly:
                let weekStart = spec.weekStart ?? 2
                let first = anchor - ((weekday(anchor) - weekStart + 7) % 7)
                periodStart = first + 7 * spec.interval * period
                let wanted = spec.weekdays.isEmpty ? [weekday(anchor)] : spec.weekdays.map(\.day)
                candidates = positions((periodStart..<periodStart + 7).filter { wanted.contains(weekday($0)) },
                                       spec.setPositions)
            case .monthly:
                let index = anchorYear * 12 + (anchorMonth - 1) + period * spec.interval
                let (year, month) = (floorDiv(index, 12), index - floorDiv(index, 12) * 12 + 1)
                periodStart = daysFromCivil(year, month, 1)
                candidates = positions(monthDays(spec, year: year, month: month, anchorDay: anchorDay),
                                       spec.setPositions)
            case .yearly:
                let year = anchorYear + period * spec.interval
                periodStart = daysFromCivil(year, 1, 1)
                candidates = positions(yearDays(spec, year: year, anchorMonth: anchorMonth,
                                                anchorDay: anchorDay), spec.setPositions)
            }
            if periodStart > last { break }
            for day in candidates where day >= anchor && day <= last {
                result.append(day)
                if result.count >= cap { break }
            }
            period += 1
        }
        return result
    }

    private static func monthDays(_ spec: RecurrenceSpec, year: Int, month: Int, anchorDay: Int) -> [Int] {
        let length = monthLength(year, month)
        let first = daysFromCivil(year, month, 1)
        var days: Set<Int>?
        if !spec.monthDays.isEmpty {
            days = Set(spec.monthDays.compactMap { value -> Int? in
                let day = value > 0 ? value : length + value + 1
                return (1...length).contains(day) ? first + day - 1 : nil
            })
        }
        if !spec.weekdays.isEmpty {
            let matching = Set(weekdayDays(spec.weekdays, range: first..<first + length))
            days = days.map { $0.intersection(matching) } ?? matching
        }
        if let days { return days.sorted() }
        return anchorDay <= length ? [first + anchorDay - 1] : []
    }

    private static func yearDays(_ spec: RecurrenceSpec, year: Int, anchorMonth: Int, anchorDay: Int) -> [Int] {
        if !spec.months.isEmpty {
            return spec.months.sorted().flatMap { month -> [Int] in
                if spec.weekdays.isEmpty && spec.monthDays.isEmpty {
                    return anchorDay <= monthLength(year, month) ? [daysFromCivil(year, month, anchorDay)] : []
                }
                return monthDays(spec, year: year, month: month, anchorDay: anchorDay)
            }
        }
        if !spec.weekdays.isEmpty {
            let first = daysFromCivil(year, 1, 1)
            return weekdayDays(spec.weekdays, range: first..<daysFromCivil(year + 1, 1, 1)).sorted()
        }
        return anchorDay <= monthLength(year, anchorMonth) ? [daysFromCivil(year, anchorMonth, anchorDay)] : []
    }

    /// Days in `range` matching any entry; a numbered entry picks the nth
    /// such weekday from the start (or end) of the range.
    private static func weekdayDays(_ entries: [RecurrenceSpec.Weekday], range: Range<Int>) -> [Int] {
        var result = Set<Int>()
        for entry in entries {
            let all = range.filter { weekday($0) == entry.day }
            if entry.week == 0 {
                result.formUnion(all)
            } else {
                let index = entry.week > 0 ? entry.week - 1 : all.count + entry.week
                if all.indices.contains(index) { result.insert(all[index]) }
            }
        }
        return Array(result)
    }

    private static func positions(_ sorted: [Int], _ positions: [Int]) -> [Int] {
        guard !positions.isEmpty else { return sorted }
        let picked = positions.compactMap { position -> Int? in
            let index = position > 0 ? position - 1 : sorted.count + position
            return sorted.indices.contains(index) ? sorted[index] : nil
        }
        return Array(Set(picked)).sorted()
    }

    // MARK: Calendar arithmetic (proleptic Gregorian)

    /// The local day number and seconds since local midnight of an instant.
    static func localDay(_ date: Date, zone: TimeZone) -> (day: Int, seconds: Int) {
        let seconds = Int(date.timeIntervalSince1970.rounded(.down))
        let local = seconds + zone.secondsFromGMT(for: date)
        let day = floorDiv(local, 86_400)
        return (day, local - day * 86_400)
    }

    /// 1 = Sunday … 7 = Saturday. Day 0 (1970-01-01) was a Thursday.
    static func weekday(_ day: Int) -> Int {
        ((day + 4) % 7 + 7) % 7 + 1
    }

    static func monthLength(_ year: Int, _ month: Int) -> Int {
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        return [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
    }

    static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    static func civil(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (month <= 2 ? yearOfEra + era * 400 + 1 : yearOfEra + era * 400, month, day)
    }

    private static func floorDiv(_ a: Int, _ b: Int) -> Int {
        a >= 0 ? a / b : -((-a + b - 1) / b)
    }
}
