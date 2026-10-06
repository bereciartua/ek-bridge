import EventKit
import Foundation

// Event writes as values (plan 03 §5, §6, §9–§11, §14): what a request asks
// for, what the event looks like, and whether a readback matches. Pure, so
// every rule here is unit-tested without an event store.

enum EventSpan: String { case this, future, all }

enum EventAvailability: String, CaseIterable {
    case busy, free, tentative, unavailable
}

/// One field a write sets and the readback checks.
enum EventField: CaseIterable {
    case title, start, end, allDay, timeZone, notes, location, structuredLocation, url, alarms, availability
    case recurrence, calendar

    /// The name used in receipts (`verified`) and readback error codes.
    var name: String {
        switch self {
        case .allDay: "all_day"
        case .timeZone: "time_zone"
        case .structuredLocation: "structured_location"
        default: "\(self)"
        }
    }
}

/// A request's parsed fields. Absent means keep; `.clear` means the request
/// sent null.
struct EventChange: Equatable {
    var title: String?
    var start: Int?
    var end: Int?
    var allDay: Bool?
    var timeZone: TimeZone?
    var notes = ItemText.Change<String>.keep
    var location = ItemText.Change<String>.keep
    var structuredLocation = ItemText.Change<PlaceSpec>.keep
    var url = ItemText.Change<String>.keep
    var alarms = ItemText.Change<[AlarmSpec]>.keep
    var availability = ItemText.Change<EventAvailability>.keep
    var recurrence = RecurrenceChange.keep
    var occurrenceStart: Int?
    var span: EventSpan?
    var targetCalendarID: String?
    var replaceUnsupportedAlarms = false

    static let fieldKeys = ["title", "start", "end", "allDay", "timeZone", "notes", "location",
                            "structuredLocation", "url", "alarms", "availability", "recurrence",
                            "targetCalendarID"]

    /// A delete's target: `occurrenceStart` and `span` only.
    static func occurrenceTarget(_ p: [String: Any]) -> EventChange? {
        var change = EventChange()
        if let raw = p["occurrenceStart"] {
            guard let seconds = ReminderDueSpec.timestamp(raw) else { return nil }
            change.occurrenceStart = Int(seconds)
        }
        if let raw = p["span"] {
            guard let span = (raw as? String).flatMap(EventSpan.init(rawValue:)) else { return nil }
            change.span = span
        }
        return change
    }

    var touchesTimes: Bool { start != nil || end != nil || allDay != nil || timeZone != nil }

    /// Core parameters → change. Shape only: rules that need the current
    /// event (span lengths on updates, anchors, availability) run in `resolve`.
    static func parse(_ p: [String: Any], creating: Bool) -> Result<EventChange, FieldError> {
        var change = EventChange()
        let invalid = FieldError("invalid_parameters_or_target")
        if let raw = p["title"] {
            guard let title = raw as? String, validTitle(title) else { return .failure(invalid) }
            change.title = title
        }
        for key in ["start", "end"] where p[key] != nil {
            guard let seconds = ReminderDueSpec.timestamp(p[key]) else { return .failure(invalid) }
            if key == "start" { change.start = Int(seconds) } else { change.end = Int(seconds) }
        }
        if let raw = p["allDay"] {
            guard let flag = raw as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else {
                return .failure(invalid)
            }
            change.allDay = flag.boolValue
        }
        if let raw = p["timeZone"] {
            guard let id = raw as? String, let zone = coreZone(id) else { return .failure(invalid) }
            change.timeZone = zone
        }
        switch ItemText.notes(p["notes"], present: p["notes"] != nil, creating: creating) {
        case .success(let value): change.notes = value
        case .failure(let error): return .failure(error)
        }
        switch ItemText.location(p["location"], present: p["location"] != nil, creating: creating) {
        case .success(let value): change.location = value
        case .failure(let error): return .failure(error)
        }
        if let raw = p["structuredLocation"] {
            if raw is NSNull {
                guard !creating else { return .failure(FieldError("invalid_location")) }
                change.structuredLocation = .clear
            } else {
                guard let place = PlaceSpec.parse(raw) else { return .failure(FieldError("invalid_location")) }
                change.structuredLocation = .set(place)
            }
        }
        // EventKit keeps one value: the location text is the pin's title.
        if let place = change.structuredLocation.value {
            if case .clear = change.location { return .failure(FieldError("invalid_location")) }
            if let text = change.location.value, text != place.title { return .failure(FieldError("invalid_location")) }
        }
        switch ItemText.url(p["url"], present: p["url"] != nil, creating: creating) {
        case .success(let value): change.url = value
        case .failure(let error): return .failure(error)
        }
        guard let alarms = AlarmSpec.parseList(p, creating: creating) else {
            return .failure(FieldError("invalid_alarms"))
        }
        change.alarms = alarms
        if let raw = p["availability"] {
            if raw is NSNull {
                guard !creating else { return .failure(invalid) }
                change.availability = .clear
            } else {
                guard let value = (raw as? String).flatMap(EventAvailability.init(rawValue:)) else {
                    return .failure(invalid)
                }
                change.availability = .set(value)
            }
        }
        guard let recurrence = RecurrenceChange.parse(parameters: p) else {
            return .failure(FieldError("invalid_recurrence"))
        }
        if creating, case .clear = recurrence { return .failure(FieldError("invalid_recurrence")) }
        change.recurrence = recurrence
        if let raw = p["occurrenceStart"] {
            guard !creating, let seconds = ReminderDueSpec.timestamp(raw) else { return .failure(invalid) }
            change.occurrenceStart = Int(seconds)
        }
        if let raw = p["span"] {
            guard !creating, let span = (raw as? String).flatMap(EventSpan.init(rawValue:)) else {
                return .failure(invalid)
            }
            change.span = span
        }
        if let raw = p["targetCalendarID"] {
            guard !creating, let id = raw as? String, !id.isEmpty, id.utf8.count <= 512 else {
                return .failure(invalid)
            }
            change.targetCalendarID = id
        }
        if let raw = p["replaceUnsupportedAlarms"] {
            guard !creating, let flag = raw as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else {
                return .failure(invalid)
            }
            change.replaceUnsupportedAlarms = flag.boolValue
        }
        if creating {
            // A new event needs its title and times; all-day ones name their zone.
            guard change.title != nil, let start = change.start, let end = change.end, end > start
            else { return .failure(invalid) }
            if change.allDay == true && change.timeZone == nil { return .failure(invalid) }
        } else if !fieldKeys.contains(where: { p[$0] != nil }) {
            return .failure(FieldError("nothing_to_change"))
        }
        if let start = change.start, let end = change.end, end <= start { return .failure(invalid) }
        return .success(change)
    }

    static func validTitle(_ title: String) -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            title.utf8.count <= 200 && !title.contains("\u{0000}")
    }

    /// IANA identifiers macOS knows, plus UTC.
    static func coreZone(_ id: String) -> TimeZone? {
        guard TimeZone.knownTimeZoneIdentifiers.contains(id) || id == "UTC" else { return nil }
        return TimeZone(identifier: id)
    }
}

/// An event's writable fields as plain values: the current state, the state a
/// write asks for, and what a readback found.
struct EventFields: Equatable {
    var calendarID: String
    var title: String
    var start: Double
    var end: Double
    var allDay: Bool
    /// Nil for a floating event.
    var timeZone: String?
    var notes: String?
    var location: String?
    /// Nil when there are no coordinates.
    var place: PlaceSpec?
    var url: String?
    /// Nil entries are alarms the bridge can't represent.
    var alarms: [AlarmSpec?]
    /// Nil when the calendar doesn't support availability.
    var availability: EventAvailability?
    var recurrence: RecurrenceRead

    var isFloatingTimed: Bool { timeZone == nil && !allDay }

    static let maxTimedSeconds = 31 * 86_400
    static let maxAllDayDays = 366

    /// Applies `change` to `current` (nil when creating). Checks the rules
    /// that need both: span lengths, all-day midnights, the recurrence anchor,
    /// availability the calendar supports, alarms in the past.
    /// `seriesMoves`: a `future` or `all` change of a recurring event, whose
    /// new start becomes the first occurrence of its rule.
    static func resolve(_ change: EventChange, current: EventFields?, calendarID: String,
                        supportedAvailability: Set<EventAvailability>?, macZone: TimeZone,
                        now: Date, seriesMoves: Bool = false)
        -> Result<(target: EventFields, touched: Set<EventField>), FieldError> {
        var touched = Set<EventField>()
        var target = current ?? EventFields(calendarID: calendarID, title: "", start: 0, end: 0, allDay: false,
                                            timeZone: nil, notes: nil, location: nil, place: nil, url: nil,
                                            alarms: [], availability: nil, recurrence: .none)
        let creating = current == nil
        if let title = change.title { target.title = title; touched.insert(.title) }
        if creating || change.touchesTimes {
            if let current, current.isFloatingTimed { return .failure(FieldError("floating_time_read_only")) }
            let allDay = change.allDay ?? current?.allDay ?? false
            if let current, allDay != current.allDay, change.start == nil || change.end == nil {
                return .failure(FieldError("invalid_event_schedule"))
            }
            let start = Double(change.start ?? 0), end = Double(change.end ?? 0)
            target.start = change.start != nil ? start : current!.start
            target.end = change.end != nil ? end : current!.end
            // An all-day event reads back with its end at 23:59:59 on the last
            // day; the rules here use the exclusive midnight after it.
            if let current, current.allDay, change.end == nil {
                let lastDay = RecurrenceExpansion.localDay(Date(timeIntervalSince1970: current.end - 1), zone: macZone)
                target.end = midnight(day: lastDay.day + 1, in: macZone)
            }
            target.allDay = allDay
            let currentZone = current?.timeZone.flatMap(TimeZone.init(identifier:))
            // An existing all-day event's dates are in the Mac's zone.
            let zone = change.timeZone ?? (current?.allDay == true ? macZone : currentZone ?? macZone)
            target.timeZone = zone.identifier
            guard target.end > target.start else { return .failure(FieldError("invalid_event_schedule")) }
            if allDay {
                guard let days = allDayLength(start: target.start, end: target.end, zone: zone),
                      (1...maxAllDayDays).contains(days) else {
                    return .failure(FieldError("invalid_event_schedule"))
                }
                // EventKit keeps all-day events floating and reads their dates
                // in the Mac's zone: save the same dates as midnights there.
                target.start = floatingMidnight(target.start, from: zone, in: macZone)
                target.end = floatingMidnight(target.end, from: zone, in: macZone)
                target.timeZone = nil
            } else if target.end - target.start > Double(maxTimedSeconds) {
                return .failure(FieldError("invalid_event_schedule"))
            }
            touched.formUnion([.start, .end, .allDay, .timeZone])
        }
        switch change.notes {
        case .keep: break
        case .clear: target.notes = nil; touched.insert(.notes)
        case .set(let value): target.notes = value; touched.insert(.notes)
        }
        switch change.structuredLocation {
        case .keep:
            switch change.location {
            case .keep: break
            // New location text without coordinates drops the old map pin.
            case .clear, .set:
                target.location = change.location.value
                target.place = nil
                touched.formUnion([.location, .structuredLocation])
            }
        case .clear:
            target.place = nil
            if case .set(let text) = change.location { target.location = text }
            if case .clear = change.location { target.location = nil }
            touched.formUnion([.location, .structuredLocation])
        case .set(let place):
            target.place = place
            target.location = place.title
            touched.formUnion([.location, .structuredLocation])
        }
        switch change.url {
        case .keep: break
        case .clear: target.url = nil; touched.insert(.url)
        case .set(let value): target.url = value; touched.insert(.url)
        }
        switch change.alarms {
        case .keep: break
        case .clear: target.alarms = []; touched.insert(.alarms)
        case .set(let alarms):
            for case .absolute(let at) in alarms where Double(at) <= now.timeIntervalSince1970 {
                return .failure(FieldError("alarm_in_past"))
            }
            target.alarms = alarms
            touched.insert(.alarms)
        }
        switch change.availability {
        case .keep: break
        case .clear:
            if let supported = supportedAvailability, supported.contains(.busy) {
                target.availability = .busy
                touched.insert(.availability)
            }
        case .set(let value):
            guard let supported = supportedAvailability, supported.contains(value) else {
                return .failure(FieldError("availability_unsupported"))
            }
            target.availability = value
            touched.insert(.availability)
        }
        switch change.recurrence {
        case .keep: break
        case .clear: target.recurrence = .none; touched.insert(.recurrence)
        case .set(let spec):
            target.recurrence = .rule(spec)
            touched.insert(.recurrence)
        }
        if let spec = target.recurrence.spec,
           touched.contains(.recurrence) || (seriesMoves && touched.contains(.start)) {
            let zone = target.timeZone.flatMap(TimeZone.init(identifier:)) ?? macZone
            guard spec.matchesAnchor(start: Date(timeIntervalSince1970: target.start), zone: zone) else {
                return .failure(FieldError("recurrence_anchor_mismatch"))
            }
        }
        if let id = change.targetCalendarID, id != target.calendarID {
            target.calendarID = id
            touched.insert(.calendar)
        }
        if creating { touched.insert(.calendar) }
        return .success((target, touched))
    }

    /// `span: all` moves the series start by as many calendar days as the
    /// requested occurrence moved, at the requested wall time; seconds would
    /// drift by an hour across a daylight saving change.
    static func shiftedSeriesTime(requested: Int, occurrence: Double, base: Double,
                                  requestZone: TimeZone, eventZone: TimeZone) -> Int {
        let wanted = RecurrenceExpansion.localDay(Date(timeIntervalSince1970: TimeInterval(requested)), zone: requestZone)
        let from = RecurrenceExpansion.localDay(Date(timeIntervalSince1970: occurrence), zone: eventZone).day
        let first = RecurrenceExpansion.localDay(Date(timeIntervalSince1970: base), zone: eventZone).day
        let (year, month, day) = RecurrenceExpansion.civil(first + wanted.day - from)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = requestZone
        let parts = DateComponents(year: year, month: month, day: day, hour: wanted.seconds / 3_600,
                                   minute: wanted.seconds % 3_600 / 60, second: wanted.seconds % 60)
        return Int(calendar.date(from: parts)!.timeIntervalSince1970)
    }

    /// The midnight in `macZone` of the date `seconds` falls on in `zone`.
    static func floatingMidnight(_ seconds: Double, from zone: TimeZone, in macZone: TimeZone) -> Double {
        midnight(day: RecurrenceExpansion.localDay(Date(timeIntervalSince1970: seconds), zone: zone).day, in: macZone)
    }

    /// The start of a local day (days since 1970-01-01) in `zone`, DST-safe.
    static func midnight(day: Int, in zone: TimeZone) -> Double {
        let (year, month, date) = RecurrenceExpansion.civil(day)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let noon = calendar.date(from: DateComponents(year: year, month: month, day: date, hour: 12))!
        return calendar.startOfDay(for: noon).timeIntervalSince1970
    }

    /// Calendar days from one local midnight to another (DST-safe), or nil
    /// when either isn't a midnight in `zone`.
    static func allDayLength(start: Double, end: Double, zone: TimeZone) -> Int? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let first = Date(timeIntervalSince1970: start), last = Date(timeIntervalSince1970: end)
        guard calendar.startOfDay(for: first) == first, calendar.startOfDay(for: last) == last,
              let a = calendar.ordinality(of: .day, in: .era, for: first),
              let b = calendar.ordinality(of: .day, in: .era, for: last) else { return nil }
        return b - a
    }
}

/// Compares a readback with what a write asked for (§14).
enum EventWriteVerifier {
    /// The touched fields the saved event doesn't match, in a fixed order.
    static func mismatches(_ target: EventFields, _ saved: EventFields, touched: Set<EventField>,
                           macZone: TimeZone) -> [EventField] {
        EventField.allCases.filter { touched.contains($0) && !matches($0, target, saved, macZone: macZone) }
    }

    static func matches(_ field: EventField, _ target: EventFields, _ saved: EventFields,
                        macZone: TimeZone) -> Bool {
        switch field {
        case .title: return target.title == saved.title
        case .start:
            if target.allDay { return day(target.start, target, macZone) == day(saved.start, saved, macZone) }
            return abs(target.start - saved.start) < 0.5
        case .end:
            // All-day: the same last day. iCloud returns the exclusive end as
            // the previous 23:59:59, which is still that day.
            if target.allDay { return day(target.end - 1, target, macZone) == day(saved.end - 1, saved, macZone) }
            return abs(target.end - saved.end) < 0.5
        case .allDay: return target.allDay == saved.allDay
        case .timeZone:
            switch (target.timeZone, saved.timeZone) {
            case (nil, nil): return true
            case (let a?, let b?): return ZoneAliases.same(a, b)
            // Providers may keep all-day events floating; their dates are checked above.
            case (_?, nil): return target.allDay
            default: return false
            }
        case .notes: return target.notes == saved.notes
        case .location: return target.location == saved.location
        case .structuredLocation:
            switch (target.place, saved.place) {
            case (nil, nil): return true
            case (let a?, let b?): return a.matches(b)
            default: return false
            }
        case .url: return target.url == saved.url
        case .alarms: return AlarmSpec.sameSet(target.alarms.compactMap { $0 }, saved.alarms)
        case .availability: return target.availability == saved.availability
        case .recurrence:
            switch (target.recurrence, saved.recurrence) {
            case (.none, .none): return true
            case (.rule(let a), .rule(let b)):
                let zone = saved.timeZone.flatMap(TimeZone.init(identifier:)) ?? macZone
                return a.equivalent(to: b, start: Date(timeIntervalSince1970: saved.start), zone: zone)
            default: return false
            }
        case .calendar: return target.calendarID == saved.calendarID
        }
    }

    /// The local calendar day of an instant in the event's own zone (the
    /// Mac's for a floating event), as a day number.
    private static func day(_ seconds: Double, _ fields: EventFields, _ macZone: TimeZone) -> Int {
        let zone = fields.timeZone.flatMap(TimeZone.init(identifier:)) ?? macZone
        return RecurrenceExpansion.localDay(Date(timeIntervalSince1970: seconds), zone: zone).day
    }

    /// "time_zone_readback_failed_rolled_back" and friends; the first field names the code.
    static func code(_ fields: [EventField], _ outcome: String) -> String {
        "\(fields.first?.name ?? "write")_readback_failed_\(outcome)"
    }
}

/// iCloud gives an occurrence changed on its own its own event ID,
/// "<series>/RID=<n>". Rows and lookups use the series'.
enum EventSeries {
    static func id(_ eventIdentifier: String) -> String {
        guard let range = eventIdentifier.range(of: "/RID=") else { return eventIdentifier }
        return String(eventIdentifier[..<range.lowerBound])
    }
}

/// Providers sometimes store a zone under its other IANA name (§6, spike S1).
enum ZoneAliases {
    static let pairs: [Set<String>] = [
        ["Asia/Kolkata", "Asia/Calcutta"], ["Asia/Kathmandu", "Asia/Katmandu"],
        ["Asia/Yangon", "Asia/Rangoon"], ["Asia/Ho_Chi_Minh", "Asia/Saigon"],
        ["Europe/Kyiv", "Europe/Kiev"], ["America/Nuuk", "America/Godthab"],
        ["Atlantic/Faroe", "Atlantic/Faeroe"], ["Pacific/Kanton", "Pacific/Enderbury"],
        ["Pacific/Chuuk", "Pacific/Truk"], ["Pacific/Pohnpei", "Pacific/Ponape"],
        ["America/Argentina/Buenos_Aires", "America/Buenos_Aires"],
        ["America/Indiana/Indianapolis", "America/Indianapolis"],
        ["America/Kentucky/Louisville", "America/Louisville"],
        ["UTC", "GMT", "Etc/UTC", "Etc/GMT"],
    ]

    static func same(_ a: String, _ b: String) -> Bool {
        a == b || pairs.contains { $0.contains(a) && $0.contains(b) }
    }
}

/// Sort and paging key for read rows: start, then ID, then occurrence.
struct EventPageKey: Comparable {
    /// More events than this in one range is refused (narrow the range).
    static let maxScanned = 20_000

    let start: Int64
    let id: String
    let occurrence: Int64

    init(_ key: (Double, String, Double)) {
        start = Int64(key.0.rounded(.down))
        id = key.1
        occurrence = Int64(key.2.rounded(.down))
    }

    /// "v1:<start>:<occurrence>:<id>".
    init?(cursor: String) {
        let parts = cursor.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "v1", let start = Int64(parts[1]), let occurrence = Int64(parts[2]),
              !parts[3].isEmpty else { return nil }
        self.start = start
        self.occurrence = occurrence
        id = String(parts[3])
    }

    var cursor: String { "v1:\(start):\(occurrence):\(id)" }

    static func < (a: EventPageKey, b: EventPageKey) -> Bool {
        (a.start, a.id, a.occurrence) < (b.start, b.id, b.occurrence)
    }
}

enum EventAvailabilityMapping {
    static func supported(_ calendar: EKCalendar) -> Set<EventAvailability> {
        let mask = calendar.supportedEventAvailabilities
        var result = Set<EventAvailability>()
        if mask.contains(.busy) { result.insert(.busy) }
        if mask.contains(.free) { result.insert(.free) }
        if mask.contains(.tentative) { result.insert(.tentative) }
        if mask.contains(.unavailable) { result.insert(.unavailable) }
        return result
    }

    static func read(_ value: EKEventAvailability) -> EventAvailability? {
        switch value {
        case .busy: .busy
        case .free: .free
        case .tentative: .tentative
        case .unavailable: .unavailable
        default: nil
        }
    }

    static func write(_ value: EventAvailability) -> EKEventAvailability {
        switch value {
        case .busy: .busy
        case .free: .free
        case .tentative: .tentative
        case .unavailable: .unavailable
        }
    }
}

extension EventFields {
    /// An event's fields as EventKit has them now.
    static func read(_ event: EKEvent) -> EventFields {
        EventFields(calendarID: event.calendar.calendarIdentifier, title: event.title ?? "",
                    start: event.startDate.timeIntervalSince1970, end: event.endDate.timeIntervalSince1970,
                    allDay: event.isAllDay, timeZone: event.timeZone?.identifier,
                    notes: EventKitText.text(event.notes), location: EventKitText.text(event.location),
                    place: event.structuredLocation.flatMap(PlaceSpec.read),
                    url: event.url?.absoluteString,
                    alarms: (event.alarms ?? []).map(AlarmSpec.read),
                    availability: EventAvailabilityMapping.supported(event.calendar).isEmpty
                        ? nil : EventAvailabilityMapping.read(event.availability),
                    recurrence: RecurrenceRead(event.recurrenceRules))
    }
}
