import Foundation

@main
struct MCPTimeTests {
    static let newYork = zone("America/New_York")
    static let london = zone("Europe/London")
    static let lordHowe = zone("Australia/Lord_Howe")
    static let santiago = zone("America/Santiago")
    // macOS lists Asia/Calcutta, not Asia/Kolkata; MCPTime.zone maps the
    // modern name to the one the core accepts. The zone data is the same.
    static let kolkata = zone("Asia/Kolkata")
    static let utc = zone("UTC")

    static func main() {
        appendixVectors()
        otherZones()
        allDay()
        ranges()
        formatting()
        rejects()
        messages()
        roundTrips()
        print("MCP time: Appendix D vectors, DST gaps/folds in 5 zones, all-day ranges, "
            + "readback dates, range limits, formatting, rejects and messages passed")
    }

    static func appendixVectors() {
        for any in [newYork, utc, kolkata] {
            expect("2026-10-06T09:00:00-04:00", any, 1_791_291_600)          // 1
            expect("2026-10-06T13:00:00Z", any, 1_791_291_600)               // 2
            expect("2026-10-06T09:00:00.999-04:00", any, 1_791_291_600)      // 4
        }
        expect("2026-10-06T09:00", newYork, 1_791_291_600)                   // 3
        expectGap("2026-03-08T02:30", newYork)                               // 5
        expectFold("2026-11-01T01:30", newYork, ["-04:00", "-05:00"],
                   [1_793_511_000, 1_793_514_600])                           // 6
        expectGap("2026-03-29T01:30", london)                                // 7
        expectFold("2026-10-25T01:30", london, ["+01:00", "+00:00"],
                   [1_792_888_200, 1_792_891_800])                           // 8
        expectGap("2026-10-04T02:15", lordHowe)                              // 9
        expectFold("2026-04-05T01:45", lordHowe, ["+11:00", "+10:30"],
                   [1_775_313_900, 1_775_315_700])                           // 10
        expect("2026-10-06T09:00", kolkata, 1_791_257_400)                   // 11
        expectDays("2026-11-01", nil, newYork, 1_793_505_600, 1_793_595_600) // 12
        expectDays("2026-12-24", "2026-12-26", newYork, 1_798_088_400, 1_798_347_600) // 13
        let dates = MCPTime.allDayDates(start: 1_798_088_400, end: 1_798_347_599, zone: newYork)
        precondition(dates == ("2026-12-24", "2026-12-26"))
        // 14: Santiago skips midnight; startOfDay is 01:00 -03:00, as the core computes it.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = santiago
        let noon = calendar.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 12))!
        let dayStart = Int(calendar.startOfDay(for: noon).timeIntervalSince1970)
        let nextStart = Int(calendar.startOfDay(for: noon.addingTimeInterval(86_400)).timeIntervalSince1970)
        precondition(dayStart == 1_788_667_200 && nextStart == 1_788_750_000)
        expectDays("2026-09-06", nil, santiago, dayStart, nextStart)
        precondition(MCPTime.format(Double(dayStart), zone: santiago) == "2026-09-06T01:00:00-03:00")
        expectGap("2026-09-06T00:30", santiago)
        expect("2026-11-05T09:00:00-05:00", newYork, 1_793_887_200)          // 15
        for bad in ["tomorrow 9am", "2026-10-06", "1791291600", ""] {        // 16
            expectInvalid(bad)
        }
    }

    static func otherZones() {
        expect("2026-07-01T12:00", london, 1_782_903_600)
        expect("2026-03-29T02:30", london, 1_774_747_800)
        expect("2026-10-25T02:00", london, 1_792_893_600)
        expect("2026-10-04T02:30", lordHowe, 1_791_041_400)
        expect("2026-04-05T02:00", lordHowe, 1_775_316_600)
        expect("2026-03-08T03:00", newYork, 1_772_953_200)
        expect("2026-03-08T01:59:59", newYork, 1_772_953_199)
        // Kolkata has no DST, so no time is skipped or repeated.
        expect("2026-03-08T02:30", kolkata, 1_772_917_200)
        expect("2026-11-01T01:30 ", kolkata, nil)
        expect("2026-11-01 01:30", kolkata, 1_793_476_800)
        expect("2026-10-06T09:00+0530", utc, 1_791_257_400)
        expect("2026-10-06T09:00:00-00:00", kolkata, 1_791_277_200)
    }

    static func allDay() {
        expectDays("2026-03-08", nil, newYork, 1_772_946_000, 1_773_028_800) // 23-hour day
        expectDays("2026-03-29", "2026-03-29", london, 1_774_742_400, 1_774_825_200)
        expectDays("2026-10-04", nil, lordHowe, 1_791_034_200, 1_791_118_800)
        expectDays("2026-10-06", "2026-10-12", kolkata, 1_791_225_000, 1_791_829_800)
        precondition(failure(MCPTime.allDayRange(startDate: "2026-10-06", endDate: "2026-10-13",
                                                 zone: kolkata)) == .allDayTooLong)
        precondition(failure(MCPTime.allDayRange(startDate: "2026-10-06", endDate: "2026-10-05",
                                                 zone: kolkata)) == .allDayEndBeforeStart)
        precondition(failure(MCPTime.allDayRange(startDate: "2026-02-30", endDate: nil,
                                                 zone: kolkata)) == .invalidDate("2026-02-30"))
        precondition(failure(MCPTime.allDayRange(startDate: "2026-10-06", endDate: "2026-10-6",
                                                 zone: kolkata)) == .invalidDate("2026-10-6"))
        // Inclusive end_date from exclusive midnight and from 23:59:59.
        for zone in [newYork, london, lordHowe, santiago, kolkata, utc] {
            for (first, last) in [("2026-11-01", "2026-11-01"), ("2026-09-05", "2026-09-07"),
                                  ("2026-03-28", "2026-04-03"), ("2026-10-03", "2026-10-05")] {
                guard case .success(let range) = MCPTime.allDayRange(startDate: first, endDate: last,
                                                                     zone: zone)
                else { preconditionFailure("\(first) \(zone.identifier)") }
                for end in [range.end, range.end - 1] {
                    let back = MCPTime.allDayDates(start: Double(range.start), end: Double(end),
                                                   zone: zone)
                    precondition(back == (first, last), "\(first) \(zone.identifier) \(back)")
                }
            }
        }
        precondition(MCPTime.allDayDates(start: 0, end: 0, zone: utc) == ("1970-01-01", "1970-01-01"))
        precondition(MCPTime.date("2024-02-29")! == (2024, 2, 29))
        for bad in ["2026-02-29", "1900-02-29", "2026-04-31", "2026-00-10", "2026-10-00",
                    "2026-10-06T00:00", " 2026-10-06", "2026/10/06", "２０２６-10-06"] {
            precondition(MCPTime.date(bad) == nil, bad)
        }
        precondition(MCPTime.zone("UTC")?.secondsFromGMT() == 0)
        precondition(MCPTime.zone("America/New_York")?.identifier == "America/New_York")
        precondition(MCPTime.zone("Not/A_Zone") == nil && MCPTime.zone("") == nil)
        for id in ["Asia/Calcutta", "Etc/UTC", "US/Eastern", "GMT"] {
            precondition((MCPTime.zone(id) != nil) == TimeZone.knownTimeZoneIdentifiers.contains(id), id)
        }
        // Renamed zones resolve to a spelling the core accepts.
        for id in ["Asia/Kolkata", "Europe/Kyiv", "Asia/Kathmandu"] {
            let resolved = MCPTime.zone(id)
            precondition(resolved != nil && TimeZone.knownTimeZoneIdentifiers.contains(resolved!.identifier), id)
        }
        precondition(MCPTime.coreIdentifier(TimeZone(identifier: "Asia/Kolkata")!) != nil)
    }

    static func ranges() {
        expect("1900-01-01T00:00:00Z", kolkata, MCPTime.minimumTimestamp)
        expect("2100-01-01T00:00:00Z", kolkata, MCPTime.maximumTimestamp)
        expect("1900-01-01T00:00", newYork, -2_208_970_800)
        expect("2100-01-01T00:00", kolkata, 4_102_425_000)
        for (text, zone) in [("1899-12-31T23:59:59Z", utc), ("2100-01-01T00:00:01Z", utc),
                             ("1900-01-01T00:00", kolkata), ("2100-01-01T00:00", newYork),
                             ("0001-01-01T00:00:00Z", utc), ("9999-12-31T23:59:59+23:59", utc)] {
            precondition(failure(MCPTime.instant(text, zone: zone)) == .outOfRange(text), text)
        }
        precondition(MCPTime.date("1900-01-01") != nil && MCPTime.date("2099-12-31") != nil)
        precondition(MCPTime.date("1899-12-31") == nil && MCPTime.date("2100-01-01") == nil)
        expectDays("1900-01-01", nil, utc, MCPTime.minimumTimestamp, MCPTime.minimumTimestamp + 86_400)
        expectDays("2099-12-31", nil, kolkata, 4_102_338_600, 4_102_425_000)
        precondition(failure(MCPTime.allDayRange(startDate: "1900-01-01", endDate: nil, zone: kolkata))
                     == .outOfRange("1900-01-01"))
        precondition(failure(MCPTime.allDayRange(startDate: "2099-12-31", endDate: nil, zone: newYork))
                     == .outOfRange("2099-12-31"))
    }

    static func formatting() {
        precondition(MCPTime.format(1_791_291_600, zone: kolkata) == "2026-10-06T18:30:00+05:30")
        precondition(MCPTime.format(1_791_291_600, zone: utc) == "2026-10-06T13:00:00+00:00")
        precondition(MCPTime.format(1_791_291_600, zone: newYork) == "2026-10-06T09:00:00-04:00")
        precondition(MCPTime.format(1_793_514_600, zone: newYork) == "2026-11-01T01:30:00-05:00")
        precondition(MCPTime.format(1_775_315_700, zone: lordHowe) == "2026-04-05T01:45:00+10:30")
        precondition(MCPTime.format(1_791_291_600.999, zone: utc) == "2026-10-06T13:00:00+00:00")
        precondition(MCPTime.format(-1.5, zone: utc) == "1969-12-31T23:59:58+00:00")
        precondition(MCPTime.format(-2_208_988_800, zone: utc) == "1900-01-01T00:00:00+00:00")
        precondition(MCPTime.format(-2_208_988_800, zone: newYork) == "1899-12-31T19:00:00-05:00")
        precondition(MCPTime.format(-86_400 * 365, zone: kolkata) == "1969-01-01T05:30:00+05:30")
        precondition(MCPTime.format(4_102_444_800, zone: utc) == "2100-01-01T00:00:00+00:00")
        precondition(MCPTime.dateString(-1, zone: utc) == "1969-12-31")
        precondition(MCPTime.dateString(1_791_257_400, zone: kolkata) == "2026-10-06")
        precondition(MCPTime.formatFloating(year: 2026, month: 3, day: 8, hour: 2, minute: 30, second: 5)
                     == "2026-03-08T02:30:05")
        precondition(MCPTime.offsetString(19_800) == "+05:30")
        precondition(MCPTime.offsetString(-14_400) == "-04:00")
        precondition(MCPTime.offsetString(0) == "+00:00")
        precondition(MCPTime.offsetString(-17_762) == "-04:56:02")
    }

    static func rejects() {
        for bad in ["tomorrow at 9", "2026-10-06T09", "2026-13-01T00:00", "2026-02-30T00:00",
                    "2026-10-06T24:00", "2026-10-06T23:60", "2026-10-06T09:00:60",
                    "2026-10-06T09:00+24:00", "2026-10-06T09:00+05:60", "2026-10-06T09:00+5:30",
                    "2026-10-06t09:00", "2026-10-06T09:00:00z", "2026-10-06T09:00:00Zjunk",
                    "2026-10-06T09:00:00-04:00 ", "2026-10-06T09:00:00.", "2026-10-06T09:00:00.1234567890",
                    "2026-10-06T09:00.5", "2026-10-06T09:00:0", "2026-10-06T9:00", "26-10-06T09:00",
                    "+2026-10-06T09:00", "2026-W41-2T09:00", "2026-279T09:00", "2026-10-06T09:00:00+04",
                    "2026-10-06T09:00:00+04:0", "2026-10-06T09:00:00GMT", "2026-10-06  09:00",
                    "2026-10-06T09:00:00Z\u{0}", "２０２６-10-06T09:00"] {
            expectInvalid(bad)
        }
        expect("2026-10-06T09:00:00.123456789-04:00", utc, 1_791_291_600)
        expect("2026-10-06T09:00:00.1Z", utc, 1_791_277_200)
        expect("1969-12-31T23:59:59.5Z", utc, -1)
        expect("1900-01-01T19:17:15-04:42:45", utc, -2_208_902_400)
        precondition(MCPTime.format(-2_208_902_400, zone: santiago) == "1900-01-01T19:17:15-04:42:45")
        expectInvalid("2026-10-06T09:00:00-0442:45")
        expectInvalid("2026-10-06T09:00:00-04:42:60")
    }

    static func messages() {
        precondition(MCPTimeError.invalidDateTime("tomorrow at 9").message ==
            "expected an ISO 8601 date-time with an offset, like 2026-10-06T09:00:00-04:00; "
            + "got \"tomorrow at 9\"")
        precondition(MCPTimeError.invalidDate("2026-02-30").message ==
            "expected a date like 2026-10-06; got \"2026-02-30\"")
        precondition(failure(MCPTime.instant("2026-03-08T02:30", zone: newYork)).message ==
            "2026-03-08T02:30 doesn't exist in America/New_York (clocks skip forward). "
            + "Use a different time or give an offset.")
        precondition(failure(MCPTime.instant("2026-11-01T01:30", zone: newYork)).message ==
            "2026-11-01T01:30 happens twice in America/New_York. Add the offset you mean: -04:00 or -05:00.")
        precondition(MCPTimeError.invalidTimeZone("Mars/Base").message.hasSuffix("got \"Mars/Base\""))
        let long = String(repeating: "x", count: 200)
        precondition(MCPTimeError.invalidDateTime(long).message.hasSuffix("got \"\(long.prefix(64))…\""))
        let codes: [(MCPTimeError, String)] = [
            (.invalidDateTime(""), "invalid_arguments"), (.invalidDate(""), "invalid_arguments"),
            (.invalidTimeZone(""), "invalid_arguments"), (.outOfRange(""), "invalid_arguments"),
            (.allDayTooLong, "invalid_arguments"), (.allDayEndBeforeStart, "invalid_arguments"),
            (.nonexistentLocalTime(local: "", zone: ""), "nonexistent_local_time"),
            (.ambiguousLocalTime(local: "", zone: "", offsets: [], instants: []), "ambiguous_local_time"),
        ]
        for (error, code) in codes { precondition(error.code == code, code) }
    }

    // Every formatted instant parses back to itself, and its offset-less wall
    // time resolves to it (or reports it among a fold's candidates).
    static func roundTrips() {
        let zones = [newYork, london, lordHowe, santiago, kolkata, utc, zone("Pacific/Kiritimati")]
        for zone in zones {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            var seconds = MCPTime.minimumTimestamp + 86_400
            while seconds < MCPTime.maximumTimestamp - 86_400 {
                let text = MCPTime.format(Double(seconds), zone: zone)
                expect(text, utc, seconds)
                let wall = String(text.prefix(19))
                switch MCPTime.instant(wall, zone: zone) {
                case .success(let value): precondition(value == seconds, "\(wall) \(zone.identifier)")
                case .failure(.ambiguousLocalTime(_, _, _, let instants)):
                    precondition(instants.count == 2 && instants.contains(seconds), wall)
                case .failure(let error): preconditionFailure("\(wall) \(zone.identifier) \(error)")
                }
                let parts = calendar.dateComponents([.year, .month, .day],
                                                    from: Date(timeIntervalSince1970: TimeInterval(seconds)))
                precondition(MCPTime.dateString(Double(seconds), zone: zone) ==
                             String(format: "%04ld-%02ld-%02ld", parts.year!, parts.month!, parts.day!))
                seconds += 86_400 * 3 + 3_607
            }
        }
    }

    // MARK: - Helpers

    static func zone(_ identifier: String) -> TimeZone {
        guard let zone = MCPTime.zone(identifier) else { preconditionFailure(identifier) }
        return zone
    }

    static func failure<T>(_ result: Result<T, MCPTimeError>) -> MCPTimeError {
        guard case .failure(let error) = result else { preconditionFailure("expected failure") }
        return error
    }

    static func expect(_ text: String, _ zone: TimeZone, _ expected: Int?) {
        switch MCPTime.instant(text, zone: zone) {
        case .success(let value): precondition(value == expected, "\(text) → \(value)")
        case .failure(let error):
            precondition(expected == nil && error == .invalidDateTime(text), "\(text) → \(error)")
        }
    }

    static func expectInvalid(_ text: String) {
        precondition(failure(MCPTime.instant(text, zone: newYork)) == .invalidDateTime(text), text)
    }

    static func expectGap(_ text: String, _ zone: TimeZone) {
        precondition(failure(MCPTime.instant(text, zone: zone))
                     == .nonexistentLocalTime(local: text, zone: zone.identifier), text)
    }

    static func expectFold(_ text: String, _ zone: TimeZone, _ offsets: [String], _ instants: [Int]) {
        precondition(failure(MCPTime.instant(text, zone: zone))
                     == .ambiguousLocalTime(local: text, zone: zone.identifier,
                                            offsets: offsets, instants: instants), text)
    }

    static func expectDays(_ first: String, _ last: String?, _ zone: TimeZone, _ start: Int, _ end: Int) {
        guard case .success(let range) = MCPTime.allDayRange(startDate: first, endDate: last, zone: zone)
        else { preconditionFailure("all-day \(first) \(zone.identifier)") }
        precondition(range.start == start && range.end == end, "\(first) \(zone.identifier) \(range)")
        precondition(MCPTime.allDayDates(start: Double(start), end: Double(end), zone: zone)
                     == (first, last ?? first))
    }
}
