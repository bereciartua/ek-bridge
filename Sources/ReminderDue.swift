import CoreFoundation
import Foundation

// A missing `due` leaves an existing reminder alone. Explicit `kind: none`
// clears its due date and the one alarm this bridge can safely replace.
enum ReminderDueChange {
    case keep
    case clear
    case set(ReminderDueSpec)

    static func parse(parameters: [String: Any]) -> ReminderDueChange? {
        guard let value = parameters["due"] else { return .keep }
        guard let object = value as? [String: Any],
              let kind = object["kind"] as? String else { return nil }
        if kind == "none" {
            return Set(object.keys) == ["kind"] ? .clear : nil
        }
        guard let zoneID = object["timeZone"] as? String,
              (TimeZone.knownTimeZoneIdentifiers.contains(zoneID) || zoneID == "UTC"),
              let zone = TimeZone(identifier: zoneID) else { return nil }
        let allowed = Set(["kind", "timeZone", "at", "date", "alarmAt"])
        guard Set(object.keys).isSubset(of: allowed) else { return nil }
        let alarm: Date?
        if let explicit = object["alarmAt"] {
            if explicit is NSNull {
                alarm = nil
            } else if let seconds = ReminderDueSpec.timestamp(explicit) {
                alarm = Date(timeIntervalSince1970: TimeInterval(seconds))
            } else { return nil }
        } else if kind == "timed", let seconds = ReminderDueSpec.timestamp(object["at"]) {
            alarm = Date(timeIntervalSince1970: TimeInterval(seconds))
        } else {
            alarm = nil
        }
        switch kind {
        case "timed":
            guard Set(object.keys).isSuperset(of: ["kind", "at", "timeZone"]),
                  object["date"] == nil,
                  let seconds = ReminderDueSpec.timestamp(object["at"])
            else { return nil }
            let spec = ReminderDueSpec(kind: .timed(seconds), timeZone: zone,
                                       alarmAt: alarm)
            // EKReminder persists wall-clock components rather than a distinct
            // UTC offset. Reject the ambiguous DST-fold occurrence that would
            // change instants when the components are reconstructed.
            guard spec.roundTrips else { return nil }
            return .set(spec)
        case "all_day":
            guard Set(object.keys).isSuperset(of: ["kind", "date", "timeZone"]),
                  object["at"] == nil,
                  let date = object["date"] as? String,
                  let day = ReminderDueSpec.day(date, in: zone)
            else { return nil }
            return .set(ReminderDueSpec(kind: .allDay(day), timeZone: zone,
                                        alarmAt: alarm))
        default: return nil
        }
    }
}

struct ReminderDueSpec {
    enum Kind {
        case timed(Int64)
        case allDay(DateComponents)
    }

    let kind: Kind
    let timeZone: TimeZone
    let alarmAt: Date?

    var roundTrips: Bool {
        guard case .timed(let seconds) = kind else { return true }
        let parts = components
        guard let date = parts.calendar?.date(from: parts) else { return false }
        return abs(date.timeIntervalSince1970 - TimeInterval(seconds)) < 0.5
    }

    var components: DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var result: DateComponents
        switch kind {
        case .timed(let seconds):
            result = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                             from: Date(timeIntervalSince1970: TimeInterval(seconds)))
        case .allDay(let day):
            result = DateComponents(year: day.year, month: day.month, day: day.day)
        }
        result.calendar = calendar
        result.timeZone = timeZone
        return result
    }

    static func timestamp(_ value: Any?) -> Int64? {
        guard let value = value as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let number = value.doubleValue
        guard number.isFinite, number.rounded() == number,
              (-2_208_988_800.0...4_102_444_800.0).contains(number)
        else { return nil }
        return Int64(exactly: number)
    }

    static func day(_ value: String, in zone: TimeZone) -> DateComponents? {
        let bytes = Array(value.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ index, byte in
                  index == 4 || index == 7 || (48...57).contains(byte)
              }),
              let year = Int(String(decoding: bytes[0..<4], as: UTF8.self)),
              let month = Int(String(decoding: bytes[5..<7], as: UTF8.self)),
              let day = Int(String(decoding: bytes[8..<10], as: UTF8.self)),
              (1900...2100).contains(year) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var components = DateComponents(year: year, month: month, day: day)
        components.calendar = calendar
        components.timeZone = zone
        guard let date = calendar.date(from: components) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == year, back.month == month, back.day == day else { return nil }
        return components
    }

    static func sameDayAndTime(_ a: DateComponents, _ b: DateComponents) -> Bool {
        a.year == b.year && a.month == b.month && a.day == b.day &&
            a.hour == b.hour && a.minute == b.minute &&
            (a.second ?? 0) == (b.second ?? 0) &&
            a.timeZone?.identifier == b.timeZone?.identifier
    }

    static func readback(_ components: DateComponents?) -> Any {
        guard let components, let year = components.year,
              let month = components.month, let day = components.day,
              (1900...2100).contains(year) else { return NSNull() }
        let zone: Any = components.timeZone?.identifier as Any? ?? NSNull()
        let date = String(format: "%04d-%02d-%02d", year, month, day)
        if components.hour == nil && components.minute == nil && components.second == nil {
            return ["kind": components.timeZone == nil ? "floating_all_day" : "all_day",
                    "date": date, "timeZone": zone] as [String: Any]
        }
        guard let hour = components.hour, let minute = components.minute,
              (0...23).contains(hour), (0...59).contains(minute),
              (0...59).contains(components.second ?? 0) else {
            return ["kind": "unsupported", "timeZone": zone] as [String: Any]
        }
        let second = components.second ?? 0
        let local = String(format: "%04d-%02d-%02dT%02d:%02d:%02d",
                           year, month, day, hour, minute, second)
        guard let timeZone = components.timeZone else {
            return ["kind": "floating_timed", "local": local,
                    "timeZone": NSNull()] as [String: Any]
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var complete = components
        complete.calendar = calendar
        guard let absolute = calendar.date(from: complete) else {
            return ["kind": "unsupported", "timeZone": zone] as [String: Any]
        }
        let reconstructed = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                                    from: absolute)
        guard reconstructed.year == year, reconstructed.month == month,
              reconstructed.day == day, reconstructed.hour == hour,
              reconstructed.minute == minute, (reconstructed.second ?? 0) == second else {
            return ["kind": "invalid_timed", "local": local,
                    "timeZone": timeZone.identifier] as [String: Any]
        }
        var match = DateComponents(year: year, month: month, day: day,
                                   hour: hour, minute: minute, second: second)
        match.timeZone = timeZone
        let dayStart = calendar.startOfDay(for: absolute)
        let searchStart = dayStart.addingTimeInterval(-1)
        if let first = calendar.nextDate(after: searchStart, matching: match,
                                         matchingPolicy: .strict, repeatedTimePolicy: .first,
                                         direction: .forward),
           let last = calendar.nextDate(after: searchStart, matching: match,
                                        matchingPolicy: .strict, repeatedTimePolicy: .last,
                                        direction: .forward),
           abs(first.timeIntervalSince(last)) > 0.5 {
            return ["kind": "ambiguous_timed", "local": local,
                    "timeZone": timeZone.identifier] as [String: Any]
        }
        return ["kind": "timed", "at": absolute.timeIntervalSince1970,
                "local": local, "timeZone": timeZone.identifier] as [String: Any]
    }
}
