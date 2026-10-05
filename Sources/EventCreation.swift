import Foundation

enum EventCreationDetails {
    case timed
    case allDay(timeZone: TimeZone, notes: String?)

    static func parse(_ parameters: [String: Any]) -> EventCreationDetails? {
        let extras = Set(parameters.keys).intersection(["allDay", "timeZone", "notes"])
        if extras.isEmpty { return .timed }
        guard extras.contains("allDay"), extras.contains("timeZone"),
              let flag = parameters["allDay"] as? NSNumber,
              CFGetTypeID(flag) == CFBooleanGetTypeID(), flag.boolValue,
              let zoneID = parameters["timeZone"] as? String,
              (TimeZone.knownTimeZoneIdentifiers.contains(zoneID) || zoneID == "UTC"),
              let zone = TimeZone(identifier: zoneID),
              let startNumber = parameters["start"] as? NSNumber,
              let endNumber = parameters["end"] as? NSNumber,
              CFGetTypeID(startNumber) != CFBooleanGetTypeID(),
              CFGetTypeID(endNumber) != CFBooleanGetTypeID()
        else { return nil }
        let start = startNumber.doubleValue
        let end = endNumber.doubleValue
        guard start.isFinite, end.isFinite, end > start,
              start >= -2_208_988_800, end <= 4_102_444_800 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let first = Date(timeIntervalSince1970: start)
        let last = Date(timeIntervalSince1970: end)
        guard calendar.startOfDay(for: first) == first,
              calendar.startOfDay(for: last) == last,
              let days = calendar.dateComponents([.day], from: first, to: last).day,
              (1...7).contains(days) else { return nil }
        let notes: String?
        if let value = parameters["notes"] {
            guard let text = value as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.utf8.count <= 2_000,
                  !text.contains("\u{0000}") else { return nil }
            notes = text
        } else { notes = nil }
        return .allDay(timeZone: zone, notes: notes)
    }
}
