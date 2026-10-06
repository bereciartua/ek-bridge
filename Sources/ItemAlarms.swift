import CoreLocation
import EventKit
import Foundation

/// One alarm the bridge can write and read back exactly (plan 03 §10).
enum AlarmSpec: Equatable {
    enum Proximity: String { case arrive, leave }

    /// Seconds relative to the event's start or the reminder's due date;
    /// negative is before.
    case relative(Int)
    /// Unix seconds.
    case absolute(Int64)
    case location(PlaceSpec, Proximity)

    static let maxCount = 5
    /// Read rows list at most this many alarms.
    static let maxRead = 20
    /// Four weeks before, up to a day after.
    static let relativeRange = -40_320 * 60...1_440 * 60

    /// Core shape: {"kind":"relative","offset":s} | {"kind":"absolute","at":s} |
    /// {"kind":"location","location":{…},"proximity":"arrive"|"leave"}.
    static func parse(_ raw: Any?) -> AlarmSpec? {
        guard let object = raw as? [String: Any], let kind = object["kind"] as? String else { return nil }
        switch kind {
        case "relative":
            guard Set(object.keys) == ["kind", "offset"], let offset = integer(object["offset"]),
                  relativeRange.contains(offset) else { return nil }
            return .relative(offset)
        case "absolute":
            guard Set(object.keys) == ["kind", "at"],
                  let at = ReminderDueSpec.timestamp(object["at"]) else { return nil }
            return .absolute(at)
        case "location":
            guard Set(object.keys) == ["kind", "location", "proximity"],
                  let place = PlaceSpec.parse(object["location"]),
                  let proximity = (object["proximity"] as? String).flatMap(Proximity.init(rawValue:))
            else { return nil }
            return .location(place, proximity)
        default:
            return nil
        }
    }

    /// The `alarms` parameter: absent keeps, null clears (updates only), a
    /// list of at most 5 distinct alarms replaces the whole list.
    static func parseList(_ parameters: [String: Any], creating: Bool) -> ItemText.Change<[AlarmSpec]>? {
        guard let raw = parameters["alarms"] else { return .keep }
        if raw is NSNull { return creating ? nil : .clear }
        guard let list = raw as? [Any], list.count <= maxCount else { return nil }
        let specs = list.compactMap(parse)
        guard specs.count == list.count else { return nil }
        for (index, spec) in specs.enumerated() where specs[..<index].contains(spec) { return nil }
        return .set(specs)
    }

    var core: [String: Any] {
        switch self {
        case .relative(let offset): ["kind": "relative", "offset": offset]
        case .absolute(let at): ["kind": "absolute", "at": at]
        case .location(let place, let proximity):
            ["kind": "location", "location": place.core, "proximity": proximity.rawValue]
        }
    }

    var isAbsolute: Bool { if case .absolute = self { return true } else { return false } }
    var isRelative: Bool { if case .relative = self { return true } else { return false } }

    func makeAlarm() -> EKAlarm {
        switch self {
        case .relative(let offset):
            return EKAlarm(relativeOffset: TimeInterval(offset))
        case .absolute(let at):
            return EKAlarm(absoluteDate: Date(timeIntervalSince1970: TimeInterval(at)))
        case .location(let place, let proximity):
            let alarm = EKAlarm()
            alarm.structuredLocation = place.makeLocation()
            alarm.proximity = proximity == .arrive ? .enter : .leave
            return alarm
        }
    }

    /// Nil when the alarm has a part the bridge can't express (a sound, an
    /// email, a script, a proximity without coordinates…).
    static func read(_ alarm: EKAlarm) -> AlarmSpec? {
        guard alarm.soundName == nil, alarm.emailAddress == nil, alarm.type == .display || alarm.type == .audio
        else { return nil }
        if alarm.proximity != .none || alarm.structuredLocation != nil {
            guard alarm.proximity == .enter || alarm.proximity == .leave,
                  let location = alarm.structuredLocation,
                  let place = PlaceSpec.read(location) else { return nil }
            return .location(place, alarm.proximity == .enter ? .arrive : .leave)
        }
        if let date = alarm.absoluteDate {
            let seconds = date.timeIntervalSince1970
            guard seconds.isFinite, seconds.rounded() == seconds,
                  let at = Int64(exactly: seconds) else { return nil }
            return .absolute(at)
        }
        let offset = alarm.relativeOffset
        guard offset.isFinite, offset.rounded() == offset, let whole = Int(exactly: offset) else { return nil }
        return .relative(whole)
    }

    /// Read rows: every alarm (at most 20), unsupported ones described.
    static func readback(_ alarms: [EKAlarm]?) -> (rows: [[String: Any]], truncated: Bool) {
        let all = alarms ?? []
        let rows = all.prefix(maxRead).map { alarm -> [String: Any] in
            read(alarm)?.core ?? ["kind": "unsupported", "summary": summary(alarm)]
        }
        return (rows, all.count > maxRead)
    }

    static func hasUnsupported(_ alarms: [EKAlarm]?) -> Bool {
        (alarms ?? []).contains { read($0) == nil }
    }

    /// Same alarms in any order, places within tolerance (§14).
    static func sameSet(_ requested: [AlarmSpec], _ saved: [AlarmSpec?]) -> Bool {
        guard requested.count == saved.count else { return false }
        var remaining = saved
        for spec in requested {
            guard let index = remaining.firstIndex(where: { candidate in
                guard let candidate else { return false }
                if case .location(let place, let proximity) = spec,
                   case .location(let other, let otherProximity) = candidate {
                    return proximity == otherProximity && place.matches(other)
                }
                return candidate == spec
            }) else { return false }
            remaining.remove(at: index)
        }
        return true
    }

    private static func summary(_ alarm: EKAlarm) -> String {
        if alarm.emailAddress != nil { return "email alarm" }
        if alarm.type == .procedure { return "script alarm" }
        if alarm.soundName != nil { return "alarm with a sound" }
        if alarm.proximity != .none || alarm.structuredLocation != nil {
            return "location alarm without coordinates"
        }
        return "alarm the bridge can't represent"
    }

    private static func integer(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        return value.isFinite && value.rounded() == value ? Int(exactly: value) : nil
    }
}

extension PlaceSpec {
    func makeLocation() -> EKStructuredLocation {
        let location = EKStructuredLocation(title: title)
        location.geoLocation = CLLocation(latitude: latitude, longitude: longitude)
        if let radius { location.radius = radius }
        return location
    }

    /// Nil without coordinates: a place the bridge can't write back exactly.
    static func read(_ location: EKStructuredLocation) -> PlaceSpec? {
        guard let geo = location.geoLocation,
              geo.coordinate.latitude.isFinite, geo.coordinate.longitude.isFinite else { return nil }
        let title = location.title ?? ""
        return PlaceSpec(title: title, latitude: geo.coordinate.latitude,
                         longitude: geo.coordinate.longitude,
                         radius: location.radius > 0 ? location.radius : nil)
    }
}
