import EventKit
import Foundation

// The shared recurrence model (plan 03 §7): parsing and validation, anchors,
// expansion across DST, RRULE text, plain-English summaries, and round trips
// through in-memory EKRecurrenceRule objects (no store access).
@main
struct RecurrenceTests {
    nonisolated(unsafe) static var checks = 0

    static func main() {
        parsing()
        validation()
        anchorsAndExpansion()
        daylightSaving()
        eventKitRoundTrips()
        readbackComparison()
        summaries()
        print("Recurrence: \(checks) checks of parsing, validation, anchors, expansion in three DST zones, "
              + "EventKit round trips, readback comparison, RRULE text and summaries passed")
    }

    static func check(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
        checks += 1
        if !condition {
            print("FAIL line \(line): \(message())")
            exit(1)
        }
    }

    static func parse(_ object: [String: Any]?) -> RecurrenceChange? {
        RecurrenceChange.parse(parameters: object.map { ["recurrence": $0] } ?? [:])
    }

    static func spec(_ object: [String: Any]) -> RecurrenceSpec {
        guard case .set(let spec)? = parse(object) else { fatalError("didn't parse \(object)") }
        return spec
    }

    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 9, _ minute: Int = 0, zone: String) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: minute))!
    }

    static func days(_ list: [Int]) -> [String] {
        list.map { let (y, m, d) = RecurrenceExpansion.civil($0); return String(format: "%04d-%02d-%02d", y, m, d) }
    }

    // MARK: Parsing

    static func parsing() {
        check(parse(nil) == .keep, "absent keeps")
        check(parse(["kind": "none"]) == .clear, "none clears")
        check(parse(["kind": "none", "frequency": "daily"]) == nil, "none takes nothing else")
        check(parse(["kind": "rule"]) == nil, "frequency required")
        check(parse(["kind": "rule", "frequency": "hourly"]) == nil, "hourly")
        check(parse(["kind": "rule", "frequency": "daily", "interval": 0]) == nil, "interval 0")
        check(parse(["kind": "rule", "frequency": "daily", "interval": 367]) == nil, "interval 367")
        check(parse(["kind": "rule", "frequency": "daily", "interval": true]) == nil, "bool interval")
        check(spec(["kind": "rule", "frequency": "daily"]).interval == 1, "interval defaults to 1")
        let monthly = spec(["kind": "rule", "frequency": "monthly", "interval": 1, "weekdays": ["2TU"],
                            "end": ["kind": "count", "count": 10]])
        check(monthly.weekdays == [.init(day: 3, week: 2)] && monthly.end == .count(10), "2TU")
        let objects = spec(["kind": "rule", "frequency": "monthly", "weekdays": [["day": "FR", "week": -1]]])
        check(objects.weekdays == [.init(day: 6, week: -1)], "{day, week} objects")
        check(spec(["kind": "rule", "frequency": "monthly", "dayOfMonth": 15]).monthDays == [15],
              "0.5 dayOfMonth alias")
        check(parse(["kind": "rule", "frequency": "weekly", "dayOfMonth": 15]) == nil, "dayOfMonth only monthly")
        check(parse(["kind": "rule", "frequency": "monthly", "dayOfMonth": 15, "monthDays": [1]]) == nil,
              "alias and new name together")
        check(parse(["kind": "rule", "frequency": "daily", "end": ["kind": "until", "at": 1_800_000_000]]) != nil,
              "until")
        check(parse(["kind": "rule", "frequency": "daily", "end": ["kind": "until", "at": 1_800_000_000,
                                                                   "count": 3]]) == nil, "count and until")
        check(parse(["kind": "rule", "frequency": "daily", "weekStart": "SU"]) == nil, "week start is read only")
        check(parse(["kind": "rule", "frequency": "daily", "extra": 1]) == nil, "unknown key")
        for code in ["MO", "2TU", "-1FR", "53SU", "-53SA"] {
            check(RecurrenceSpec.Weekday(code: code)?.code == code, "code \(code) round trips")
        }
        for bad in ["", "M", "mo", "0MO", "+1MO", "100MO", "1", "XX", "1.5MO", "--1MO"] {
            check(RecurrenceSpec.Weekday(code: bad) == nil, "bad code \(bad)")
        }
    }

    // MARK: Validation

    static func validation() {
        func problem(_ object: [String: Any]) -> String? {
            var full = object
            full["kind"] = "rule"
            guard let frequency = (object["frequency"] as? String).flatMap(RecurrenceSpec.Frequency.init) else {
                return "frequency"
            }
            var spec = RecurrenceSpec(frequency: frequency)
            spec.weekdays = (object["weekdays"] as? [String] ?? []).compactMap(RecurrenceSpec.Weekday.init(code:))
            spec.monthDays = object["monthDays"] as? [Int] ?? []
            spec.months = object["months"] as? [Int] ?? []
            spec.setPositions = object["setPositions"] as? [Int] ?? []
            check((parse(full) != nil) == (spec.problem == nil), "parse agrees with problem for \(object)")
            return spec.problem
        }
        let table: [([String: Any], String?)] = [
            (["frequency": "daily"], nil),
            (["frequency": "daily", "weekdays": ["MO"]], "weekdays: not used with daily rules"),
            (["frequency": "weekly", "weekdays": ["MO", "WE"]], nil),
            (["frequency": "weekly", "weekdays": ["2MO"]],
             "weekdays: weekly rules take plain codes like MO, without a number"),
            (["frequency": "weekly", "weekdays": ["MO", "MO"]], "weekdays: expected 1 to 7 distinct values"),
            (["frequency": "monthly", "weekdays": ["-1FR"]], nil),
            (["frequency": "monthly", "weekdays": ["6MO"]], "weekdays: 6MO needs a number from 1 to 5 or -1 to -5"),
            (["frequency": "yearly", "weekdays": ["20MO"]], nil),
            (["frequency": "yearly", "weekdays": ["20MO"], "months": [3]],
             "weekdays: 20MO needs a number from 1 to 5 or -1 to -5"),
            (["frequency": "monthly", "monthDays": [1, 15, -1]], nil),
            (["frequency": "monthly", "monthDays": [0]],
             "month_days: expected 1 to 31 distinct values from 1 to 31 or -31 to -1"),
            (["frequency": "monthly", "monthDays": [32]],
             "month_days: expected 1 to 31 distinct values from 1 to 31 or -31 to -1"),
            (["frequency": "weekly", "monthDays": [1]], "month_days: only for monthly and yearly rules"),
            (["frequency": "yearly", "monthDays": [1]], "month_days: a yearly rule with month_days also needs months"),
            (["frequency": "yearly", "monthDays": [1], "months": [1, 7]], nil),
            (["frequency": "monthly", "months": [1]], "months: only for yearly rules"),
            (["frequency": "yearly", "months": [13]], "months: expected 1 to 12 distinct values from 1 to 12"),
            (["frequency": "monthly", "setPositions": [1]], "set_positions: needs weekdays or month_days"),
            (["frequency": "monthly", "weekdays": ["MO", "TU", "WE", "TH", "FR"], "setPositions": [-1]], nil),
            (["frequency": "monthly", "weekdays": ["MO"], "setPositions": [367]],
             "set_positions: expected distinct values from 1 to 366 or -366 to -1"),
        ]
        for (object, expected) in table {
            check(problem(object) == expected, "\(object): \(problem(object) ?? "nil")")
        }
        var counted = RecurrenceSpec(frequency: .daily)
        counted.end = .count(10_001)
        check(counted.problem == "end.count: expected 1 to 10000", "count limit")
        counted.end = .count(10_000)
        check(counted.problem == nil, "count 10000")
    }

    // MARK: Anchors and expansion

    static func anchorsAndExpansion() {
        let ny = TimeZone(identifier: "America/New_York")!
        let tuesday = date(2026, 10, 13, zone: "America/New_York")  // second Tuesday
        let secondTuesday = spec(["kind": "rule", "frequency": "monthly", "weekdays": ["2TU"],
                                  "end": ["kind": "count", "count": 10]])
        check(secondTuesday.matchesAnchor(start: tuesday, zone: ny), "second Tuesday anchor")
        check(!secondTuesday.matchesAnchor(start: date(2026, 10, 6, zone: "America/New_York"), zone: ny),
              "first Tuesday doesn't match")
        check(secondTuesday.nextMatch(after: date(2026, 10, 6, zone: "America/New_York"), zone: ny)! == (2026, 10, 13),
              "hint names the next second Tuesday")
        check(days(RecurrenceExpansion.occurrences(secondTuesday, start: tuesday, zone: ny)) == [
            "2026-10-13", "2026-11-10", "2026-12-08", "2027-01-12", "2027-02-09", "2027-03-09", "2027-04-13",
            "2027-05-11", "2027-06-08", "2027-07-13"], "ten second Tuesdays")

        // Every 2 weeks on Monday and Wednesday, starting on a Wednesday.
        let wednesday = date(2026, 10, 7, zone: "America/New_York")
        let biweekly = spec(["kind": "rule", "frequency": "weekly", "interval": 2, "weekdays": ["MO", "WE"]])
        check(biweekly.matchesAnchor(start: wednesday, zone: ny), "biweekly anchor")
        check(days(Array(RecurrenceExpansion.occurrences(biweekly, start: wednesday, zone: ny).prefix(5))) == [
            "2026-10-07", "2026-10-19", "2026-10-21", "2026-11-02", "2026-11-04"],
              "skips the Monday before the anchor and every other week")

        // The last weekday of each month.
        let lastWeekday = spec(["kind": "rule", "frequency": "monthly",
                                "weekdays": ["MO", "TU", "WE", "TH", "FR"], "setPositions": [-1]])
        let october30 = date(2026, 10, 30, zone: "America/New_York")
        check(lastWeekday.matchesAnchor(start: october30, zone: ny), "Oct 30 2026 is the last weekday")
        check(days(Array(RecurrenceExpansion.occurrences(lastWeekday, start: october30, zone: ny).prefix(4))) == [
            "2026-10-30", "2026-11-30", "2026-12-31", "2027-01-29"], "last weekdays")

        // Monthly on the 31st skips shorter months; -1 is always the last day.
        let thirtyFirst = spec(["kind": "rule", "frequency": "monthly"])
        let january31 = date(2027, 1, 31, zone: "America/New_York")
        check(days(Array(RecurrenceExpansion.occurrences(thirtyFirst, start: january31, zone: ny).prefix(3))) == [
            "2027-01-31", "2027-03-31", "2027-05-31"], "31st skips months")
        let lastDay = spec(["kind": "rule", "frequency": "monthly", "monthDays": [-1]])
        check(days(Array(RecurrenceExpansion.occurrences(lastDay, start: january31, zone: ny).prefix(3))) == [
            "2027-01-31", "2027-02-28", "2027-03-31"], "-1 is the last day")

        // Yearly: Feb 29 only in leap years; March and September on the 15th.
        let leap = spec(["kind": "rule", "frequency": "yearly"])
        let feb29 = date(2028, 2, 29, zone: "America/New_York")
        check(days(RecurrenceExpansion.days(leap, anchor: RecurrenceExpansion.localDay(feb29, zone: ny).day,
                                            through: RecurrenceExpansion.localDay(feb29, zone: ny).day + 3_000))
              == ["2028-02-29", "2032-02-29", "2036-02-29"], "leap days")
        let twice = spec(["kind": "rule", "frequency": "yearly", "months": [3, 9], "monthDays": [15],
                          "end": ["kind": "count", "count": 3]])
        let march15 = date(2027, 3, 15, zone: "America/New_York")
        check(twice.matchesAnchor(start: march15, zone: ny), "March 15 anchor")
        check(days(RecurrenceExpansion.occurrences(twice, start: march15, zone: ny)) ==
              ["2027-03-15", "2027-09-15", "2028-03-15"], "count 3")
        // Yearly 20th Monday (ordinal within the year).
        let twentiethMonday = spec(["kind": "rule", "frequency": "yearly", "weekdays": ["20MO"]])
        check(twentiethMonday.nextMatch(after: date(2027, 1, 1, zone: "America/New_York"), zone: ny)! == (2027, 5, 17),
              "20th Monday of 2027")

        // Until: inclusive of an occurrence at the until instant, exclusive after it.
        var daily = spec(["kind": "rule", "frequency": "daily"])
        let start = date(2026, 10, 5, zone: "America/New_York")
        daily.end = .until(Int64(date(2026, 10, 8, zone: "America/New_York").timeIntervalSince1970))
        check(RecurrenceExpansion.occurrences(daily, start: start, zone: ny).count == 4, "until at the 4th start")
        daily.end = .until(Int64(date(2026, 10, 8, 8, 59, zone: "America/New_York").timeIntervalSince1970))
        check(RecurrenceExpansion.occurrences(daily, start: start, zone: ny).count == 3, "until a minute before")
        check(!daily.matchesAnchor(start: date(2026, 10, 9, zone: "America/New_York"), zone: ny),
              "until before the first occurrence")
    }

    // MARK: DST

    static func daylightSaving() {
        // Occurrences keep their wall time: the instants shift by the DST change.
        for (zoneID, before, after) in [("America/New_York", (2026, 11, 1), (2026, 11, 2)),
                                        ("Europe/Madrid", (2026, 10, 25), (2026, 10, 26)),
                                        ("America/Santiago", (2026, 9, 5), (2026, 9, 7))] {
            let zone = TimeZone(identifier: zoneID)!
            let daily = spec(["kind": "rule", "frequency": "daily"])
            let first = date(before.0, before.1, before.2, 9, zone: zoneID)
            let occurrences = RecurrenceExpansion.occurrences(daily, start: first, zone: zone, window: 5)
            let firstDay = RecurrenceExpansion.localDay(first, zone: zone).day
            check(occurrences == Array(firstDay...firstDay + 5), "\(zoneID): one per local day across DST")
            check(RecurrenceExpansion.localDay(date(after.0, after.1, after.2, 9, zone: zoneID), zone: zone).seconds
                  == 9 * 3_600, "\(zoneID): 9:00 stays 9:00")
        }
        // America/Santiago skips midnight on 2026-09-06: an all-day weekly rule still lands on it.
        let santiago = TimeZone(identifier: "America/Santiago")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = santiago
        let sunday = calendar.startOfDay(for: date(2026, 8, 30, 12, zone: "America/Santiago"))
        let weekly = spec(["kind": "rule", "frequency": "weekly", "weekdays": ["SU"]])
        check(weekly.matchesAnchor(start: sunday, zone: santiago), "Santiago Sunday anchor")
        check(days(Array(RecurrenceExpansion.occurrences(weekly, start: sunday, zone: santiago).prefix(2)))
              == ["2026-08-30", "2026-09-06"], "the 23-hour Sunday")
    }

    // MARK: EventKit

    static func eventKitRoundTrips() {
        let shapes: [[String: Any]] = [
            ["kind": "rule", "frequency": "daily", "interval": 3],
            ["kind": "rule", "frequency": "weekly", "weekdays": ["MO", "WE", "FR"],
             "end": ["kind": "until", "at": 1_800_000_000]],
            ["kind": "rule", "frequency": "monthly", "weekdays": ["2TU"], "end": ["kind": "count", "count": 10]],
            ["kind": "rule", "frequency": "monthly", "monthDays": [1, -1]],
            ["kind": "rule", "frequency": "monthly", "weekdays": ["MO", "TU", "WE", "TH", "FR"], "setPositions": [-1]],
            ["kind": "rule", "frequency": "yearly", "months": [3, 9], "monthDays": [15]],
            ["kind": "rule", "frequency": "yearly", "weekdays": ["-1SU"], "months": [10]],
        ]
        for shape in shapes {
            let spec = spec(shape)
            let rule = spec.makeRule()
            guard case .success(let back) = RecurrenceSpec.read(rule) else {
                check(false, "\(shape) didn't read back"); continue
            }
            var expected = spec
            // EventKit sets Monday as the first day for weekly rules with an interval over 1.
            if back.weekStart != nil { expected.weekStart = back.weekStart }
            check(back == expected, "\(shape) round trips: \(back)")
            check(RecurrenceRead([rule]) == .rule(back), "RecurrenceRead")
        }
        // Parts the bridge can't write read as unsupported, with a summary.
        let byWeekNumber = EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, daysOfTheWeek: nil,
                                            daysOfTheMonth: nil, monthsOfTheYear: nil,
                                            weeksOfTheYear: [20], daysOfTheYear: nil, setPositions: nil, end: nil)
        guard case .unsupported(let reason, let summary) = RecurrenceRead([byWeekNumber]) else {
            check(false, "BYWEEKNO is unsupported"); return
        }
        check(reason == "complex_rule" && summary == "FREQ=YEARLY;BYWEEKNO=20", "BYWEEKNO summary: \(summary)")
        let two = RecurrenceRead([EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil),
                                  EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)])
        check(two == .unsupported(reason: "multiple_rules", summary: "FREQ=DAILY + FREQ=WEEKLY"), "two rules")
        check(RecurrenceRead(nil) == .none && RecurrenceRead([]) == .none, "no rules")
        let core = RecurrenceRead([byWeekNumber]).core(zone: nil)
        check(core["supported"] as? Bool == false && core["kind"] as? String == "unsupported", "unsupported core")
    }

    static func readbackComparison() {
        let ny = TimeZone(identifier: "America/New_York")!
        let monday = date(2026, 10, 5, zone: "America/New_York")
        // A provider that adds the start's weekday to a plain weekly rule is equivalent.
        let plain = spec(["kind": "rule", "frequency": "weekly"])
        let normalized = spec(["kind": "rule", "frequency": "weekly", "weekdays": ["MO"]])
        check(plain.equivalent(to: normalized, start: monday, zone: ny), "normalized weekday")
        let other = spec(["kind": "rule", "frequency": "weekly", "weekdays": ["TU"]])
        check(!plain.equivalent(to: other, start: monday, zone: ny), "different weekday")
        var counted = plain
        counted.end = .count(5)
        check(!plain.equivalent(to: counted, start: monday, zone: ny), "an added end")
        var sameUntil = plain, nearUntil = plain
        sameUntil.end = .until(1_800_000_000)
        nearUntil.end = .until(1_800_000_000 + 3_600)
        check(sameUntil.equivalent(to: nearUntil, start: monday, zone: ny), "until within a day")
        let monthlyDay = spec(["kind": "rule", "frequency": "monthly"])
        let monthlyExplicit = spec(["kind": "rule", "frequency": "monthly", "monthDays": [5]])
        check(monthlyDay.equivalent(to: monthlyExplicit, start: monday, zone: ny), "month day made explicit")
    }

    static func summaries() {
        let ny = TimeZone(identifier: "America/New_York")!
        let table: [([String: Any], String, String)] = [
            (["frequency": "daily"], "Daily", "FREQ=DAILY"),
            (["frequency": "daily", "interval": 3], "Every 3 days", "FREQ=DAILY;INTERVAL=3"),
            (["frequency": "weekly", "interval": 2, "weekdays": ["MO", "WE"],
              "end": ["kind": "until", "at": 1_798_779_599]],
             "Every 2 weeks on Monday and Wednesday, until Dec 31, 2026",
             "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE;UNTIL=20270101T045959Z"),
            (["frequency": "weekly", "weekdays": ["FR", "MO", "TU", "WE", "TH"]], "Weekly on weekdays",
             "FREQ=WEEKLY;BYDAY=FR,MO,TU,WE,TH"),
            (["frequency": "monthly", "weekdays": ["2TU"], "end": ["kind": "count", "count": 10]],
             "Monthly on the second Tuesday, 10 times", "FREQ=MONTHLY;BYDAY=2TU;COUNT=10"),
            (["frequency": "monthly", "weekdays": ["1MO", "3MO"]], "Monthly on the first and third Monday",
             "FREQ=MONTHLY;BYDAY=1MO,3MO"),
            (["frequency": "monthly", "monthDays": [1, 15, -1]], "Monthly on days 1 and 15 and the last day",
             "FREQ=MONTHLY;BYMONTHDAY=1,15,-1"),
            (["frequency": "monthly", "weekdays": ["MO", "TU", "WE", "TH", "FR"], "setPositions": [-1]],
             "Monthly on the last of weekdays", "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1"),
            (["frequency": "yearly", "months": [9, 3], "monthDays": [15], "end": ["kind": "count", "count": 1]],
             "Yearly in March and September on day 15, once", "FREQ=YEARLY;BYMONTHDAY=15;BYMONTH=9,3;COUNT=1"),
            (["frequency": "yearly", "weekdays": ["-1SU"], "months": [10]], "Yearly in October on the last Sunday",
             "FREQ=YEARLY;BYDAY=-1SU;BYMONTH=10"),
        ]
        for (object, summary, rrule) in table {
            let spec = spec(object.merging(["kind": "rule"]) { _, new in new })
            check(RecurrenceText.summary(spec, zone: ny) == summary,
                  "summary: \(RecurrenceText.summary(spec, zone: ny))")
            check(spec.rrule == rrule, "rrule: \(spec.rrule)")
            let core = spec.core(zone: ny)
            check(core["summary"] as? String == summary && core["rrule"] as? String == rrule, "core text")
        }
        check(RecurrenceText.ordinal(-2) == "second-to-last" && RecurrenceText.ordinal(22) == "22nd" &&
              RecurrenceText.ordinal(13) == "13th", "ordinals")
    }
}
