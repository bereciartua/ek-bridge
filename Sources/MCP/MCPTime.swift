import Foundation

enum MCPTimeError: Error, Equatable {
    case invalidDateTime(String)
    case invalidDate(String)
    case invalidTimeZone(String)
    case nonexistentLocalTime(local: String, zone: String)
    // Offsets and instants are ordered earlier instant first.
    case ambiguousLocalTime(local: String, zone: String, offsets: [String], instants: [Int])
    case outOfRange(String)
    /// An all-day date whose midnight in the zone falls outside the core's range.
    case dateOutOfRange(String)
    case allDayTooLong
    case allDayEndBeforeStart
}

extension MCPTimeError {
    var code: String {
        switch self {
        case .nonexistentLocalTime: return "nonexistent_local_time"
        case .ambiguousLocalTime: return "ambiguous_local_time"
        default: return "invalid_arguments"
        }
    }

    var message: String {
        switch self {
        case .invalidDateTime(let text):
            return "expected an ISO 8601 date-time with an offset, like 2026-10-06T09:00:00-04:00; "
                + "got \(Self.quoted(text))"
        case .invalidDate(let text):
            return "expected a date like 2026-10-06; got \(Self.quoted(text))"
        case .invalidTimeZone(let text):
            return "expected an IANA time zone like America/New_York; got \(Self.quoted(text))"
        case .nonexistentLocalTime(let local, let zone):
            return "\(local) doesn't exist in \(zone) (clocks skip forward). "
                + "Use a different time or give an offset."
        case .ambiguousLocalTime(let local, let zone, let offsets, _):
            return "\(local) happens twice in \(zone). "
                + "Add the offset you mean: \(offsets.joined(separator: " or "))."
        case .outOfRange(let text):
            return "expected a time between 1900-01-01 and 2100-01-01; got \(Self.quoted(text))"
        case .dateOutOfRange(let text):
            return "expected a date from 1900-01-02 to 2099-12-30; got \(Self.quoted(text))"
        case .allDayTooLong:
            return "an all-day event can span at most 7 days"
        case .allDayEndBeforeStart:
            return "end_date must be on or after start_date"
        }
    }

    // Agent input is echoed back, so keep it short.
    private static func quoted(_ text: String) -> String {
        let limit = 64
        let shown = text.count > limit ? String(text.prefix(limit)) + "…" : text
        return "\"\(shown)\""
    }
}

enum MCPTime {
    static let minimumTimestamp = -2_208_988_800
    static let maximumTimestamp = 4_102_444_800

    // YYYY-MM-DDTHH:MM[:SS[.fraction]][Z|±HH:MM[:SS]|±HHMM], or a space for T.
    // Uppercase T and Z only: lowercase is rejected to keep one spelling.
    static func instant(_ text: String, zone: TimeZone) -> Result<Int, MCPTimeError> {
        guard let parsed = parseDateTime(text) else { return .failure(.invalidDateTime(text)) }
        let wall = daysFromCivil(parsed.year, parsed.month, parsed.day) * 86_400
            + parsed.hour * 3_600 + parsed.minute * 60 + parsed.second
        if let offset = parsed.offset {
            return inRange(wall - offset) ? .success(wall - offset) : .failure(.outOfRange(text))
        }
        // Appendix D: try every offset the zone uses near the wall time; keep the
        // instants whose own offset agrees.
        var offsets: [Int] = []
        var cursor = Date(timeIntervalSince1970: TimeInterval(wall - 26 * 3_600))
        let limit = Date(timeIntervalSince1970: TimeInterval(wall + 26 * 3_600))
        offsets.append(zone.secondsFromGMT(for: cursor))
        while let next = zone.nextDaylightSavingTimeTransition(after: cursor), next <= limit {
            let offset = zone.secondsFromGMT(for: next)
            if !offsets.contains(offset) { offsets.append(offset) }
            cursor = next
        }
        let endOffset = zone.secondsFromGMT(for: limit)
        if !offsets.contains(endOffset) { offsets.append(endOffset) }
        let matches = offsets.filter { offset in
            zone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(wall - offset))) == offset
        }.sorted(by: >)
        switch matches.count {
        case 0:
            return .failure(.nonexistentLocalTime(local: text, zone: zone.identifier))
        case 1:
            let instant = wall - matches[0]
            return inRange(instant) ? .success(instant) : .failure(.outOfRange(text))
        default:
            let instants = matches.map { wall - $0 }
            guard instants.contains(where: inRange) else { return .failure(.outOfRange(text)) }
            return .failure(.ambiguousLocalTime(local: text, zone: zone.identifier,
                                                offsets: matches.map(offsetString),
                                                instants: instants))
        }
    }

    static func date(_ text: String) -> (year: Int, month: Int, day: Int)? {
        let bytes = Array(text.utf8)
        guard bytes.count == 10, bytes[4] == 0x2D, bytes[7] == 0x2D,
              let year = digits(bytes, 0, 4), let month = digits(bytes, 5, 2),
              let day = digits(bytes, 8, 2),
              (1900...2099).contains(year), validDay(year, month, day) else { return nil }
        return (year, month, day)
    }

    // Same accepted set as the core's `timeZone` checks, plus current IANA
    // names that macOS still lists under their old spelling (agents send the
    // new ones). The returned zone's identifier is always one the core accepts.
    static func zone(_ identifier: String) -> TimeZone? {
        let known = TimeZone.knownTimeZoneIdentifiers
        if known.contains(identifier) || identifier == "UTC" { return TimeZone(identifier: identifier) }
        guard let legacy = renamedZones[identifier], known.contains(legacy) else { return nil }
        return TimeZone(identifier: legacy)
    }

    /// The identifier to hand the core for `zone`, or nil if it has none the core accepts.
    static func coreIdentifier(_ zone: TimeZone) -> String? {
        MCPTime.zone(zone.identifier)?.identifier
    }

    private static let renamedZones = [
        "Asia/Kolkata": "Asia/Calcutta", "Asia/Kathmandu": "Asia/Katmandu",
        "Asia/Yangon": "Asia/Rangoon", "Asia/Ho_Chi_Minh": "Asia/Saigon",
        "Europe/Kyiv": "Europe/Kiev", "America/Nuuk": "America/Godthab",
        "Atlantic/Faroe": "Atlantic/Faeroe", "Pacific/Kanton": "Pacific/Enderbury",
        "Pacific/Chuuk": "Pacific/Truk", "Pacific/Pohnpei": "Pacific/Ponape",
        "America/Argentina/Buenos_Aires": "America/Buenos_Aires",
        "America/Indiana/Indianapolis": "America/Indianapolis",
        "America/Kentucky/Louisville": "America/Louisville",
    ]

    static func allDayRange(startDate: String, endDate: String?,
                            zone: TimeZone) -> Result<(start: Int, end: Int), MCPTimeError> {
        guard let first = date(startDate) else { return .failure(.invalidDate(startDate)) }
        let lastText = endDate ?? startDate
        guard let last = date(lastText) else { return .failure(.invalidDate(lastText)) }
        let days = daysFromCivil(last.year, last.month, last.day)
            - daysFromCivil(first.year, first.month, first.day) + 1
        if days < 1 { return .failure(.allDayEndBeforeStart) }
        if days > 7 { return .failure(.allDayTooLong) }
        let start = startOfDay(year: first.year, month: first.month, day: first.day, zone: zone)
        let end = startOfDay(year: last.year, month: last.month, day: last.day, zone: zone, adding: 1)
        guard inRange(start) else { return .failure(.dateOutOfRange(startDate)) }
        guard inRange(end) else { return .failure(.dateOutOfRange(lastText)) }
        return .success((start, end))
    }

    // Matches EventCreationDetails: Gregorian startOfDay in `zone`. Starting from
    // noon avoids asking Calendar for a midnight that DST skips (America/Santiago).
    static func startOfDay(year: Int, month: Int, day: Int, zone: TimeZone, adding: Int = 0) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let noon = (daysFromCivil(year, month, day) + adding) * 86_400 + 12 * 3_600
        let guess = Date(timeIntervalSince1970: TimeInterval(noon - zone.secondsFromGMT(
            for: Date(timeIntervalSince1970: TimeInterval(noon)))))
        return Int(calendar.startOfDay(for: guess).timeIntervalSince1970)
    }

    // Offsets are always explicit, never "Z". Local mean time offsets (e.g. Santiago
    // before 1910) print as ±HH:MM:SS, as ICU's XXXXX does.
    static func format(_ seconds: Double, zone: TimeZone = .current) -> String {
        let (local, offset) = localSeconds(seconds, zone: zone)
        let (date, clock) = split(local)
        return "\(date)T\(clock)\(offsetString(offset))"
    }

    static func formatFloating(year: Int, month: Int, day: Int,
                               hour: Int, minute: Int, second: Int) -> String {
        "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))T"
            + "\(pad(hour, 2)):\(pad(minute, 2)):\(pad(second, 2))"
    }

    static func dateString(_ seconds: Double, zone: TimeZone) -> String {
        split(localSeconds(seconds, zone: zone).local).date
    }

    // `end` is exclusive; `end - 1 s` also maps a 23:59:59 readback to the same day.
    static func allDayDates(start: Double, end: Double,
                            zone: TimeZone) -> (startDate: String, endDate: String) {
        (dateString(start, zone: zone), dateString(max(end - 1, start), zone: zone))
    }

    static func offsetString(_ secondsFromGMT: Int) -> String {
        let sign = secondsFromGMT < 0 ? "-" : "+"
        let value = abs(secondsFromGMT)
        let text = "\(sign)\(pad(value / 3_600, 2)):\(pad(value % 3_600 / 60, 2))"
        return value % 60 == 0 ? text : "\(text):\(pad(value % 60, 2))"
    }

    // MARK: - Helpers

    private struct DateTime {
        var year, month, day, hour, minute, second: Int
        var offset: Int?
    }

    private static func parseDateTime(_ text: String) -> DateTime? {
        let b = Array(text.utf8)
        guard b.count >= 16, b[4] == 0x2D, b[7] == 0x2D, b[10] == 0x54 || b[10] == 0x20,
              b[13] == 0x3A,
              let year = digits(b, 0, 4), let month = digits(b, 5, 2), let day = digits(b, 8, 2),
              let hour = digits(b, 11, 2), let minute = digits(b, 14, 2),
              validDay(year, month, day), hour <= 23, minute <= 59 else { return nil }
        var value = DateTime(year: year, month: month, day: day, hour: hour, minute: minute,
                             second: 0, offset: nil)
        var i = 16
        if i < b.count, b[i] == 0x3A {
            guard let second = digits(b, i + 1, 2), second <= 59 else { return nil }
            value.second = second
            i += 3
            if i < b.count, b[i] == 0x2E {
                var end = i + 1
                while end < b.count, (0x30...0x39).contains(b[end]) { end += 1 }
                guard (1...9).contains(end - i - 1) else { return nil }
                i = end  // Truncated: whole seconds only.
            }
        }
        if i == b.count { return value }
        if b[i] == 0x5A {
            value.offset = 0
            i += 1
        } else if b[i] == 0x2B || b[i] == 0x2D {
            let sign = b[i] == 0x2D ? -1 : 1
            guard let hours = digits(b, i + 1, 2), hours <= 23 else { return nil }
            let colon = i + 3 < b.count && b[i + 3] == 0x3A
            guard let minutes = digits(b, colon ? i + 4 : i + 3, 2), minutes <= 59 else { return nil }
            var offset = hours * 3_600 + minutes * 60
            i += colon ? 6 : 5
            // ±HH:MM:SS only so `format` output for pre-1912 local mean time parses back.
            if colon, i < b.count, b[i] == 0x3A {
                guard let seconds = digits(b, i + 1, 2), seconds <= 59 else { return nil }
                offset += seconds
                i += 3
            }
            value.offset = sign * offset
        } else {
            return nil
        }
        return i == b.count ? value : nil
    }

    private static func digits(_ bytes: [UInt8], _ start: Int, _ count: Int) -> Int? {
        guard start >= 0, start + count <= bytes.count else { return nil }
        var value = 0
        for byte in bytes[start..<start + count] {
            guard (0x30...0x39).contains(byte) else { return nil }
            value = value * 10 + Int(byte - 0x30)
        }
        return value
    }

    private static func validDay(_ year: Int, _ month: Int, _ day: Int) -> Bool {
        guard (1...12).contains(month), day >= 1 else { return false }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return day <= lengths[month - 1]
    }

    private static func inRange(_ seconds: Int) -> Bool {
        (minimumTimestamp...maximumTimestamp).contains(seconds)
    }

    // Wall-clock seconds (local time read as UTC) and the offset used, flooring
    // fractional input so negative instants don't round toward the epoch.
    private static func localSeconds(_ seconds: Double, zone: TimeZone) -> (local: Int, offset: Int) {
        let bound = 1e14
        let whole = seconds.isFinite ? Int(min(max(seconds.rounded(.down), -bound), bound)) : 0
        let offset = zone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(whole)))
        return (whole + offset, offset)
    }

    private static func split(_ local: Int) -> (date: String, clock: String) {
        let days = local >= 0 ? local / 86_400 : -((-local + 86_399) / 86_400)
        let rest = local - days * 86_400
        let (year, month, day) = civilFromDays(days)
        return ("\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))",
                "\(pad(rest / 3_600, 2)):\(pad(rest % 3_600 / 60, 2)):\(pad(rest % 60, 2))")
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let text = String(abs(value))
        let padded = String(repeating: "0", count: max(0, width - text.count)) + text
        return value < 0 ? "-" + padded : padded
    }

    // Proleptic Gregorian day numbers relative to 1970-01-01 (Howard Hinnant's algorithms).
    private static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private static func civilFromDays(_ days: Int) -> (Int, Int, Int) {
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
}
