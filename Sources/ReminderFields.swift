import EventKit
import Foundation

// Reminder writes as values (plan 03 §5, §9, §10, §12, §14). Pure: what a
// request asks for, how it merges with the current reminder, and whether a
// readback matches.

enum ReminderPriority: String, CaseIterable {
    case none, low, medium, high

    /// RFC 5545 values, as the Reminders app writes them.
    var raw: Int {
        switch self {
        case .none: 0
        case .low: 9
        case .medium: 5
        case .high: 1
        }
    }

    static func read(_ raw: Int) -> ReminderPriority? {
        switch raw {
        case 0: ReminderPriority.none
        case 1...4: .high
        case 5: .medium
        case 6...9: .low
        default: nil
        }
    }
}

enum ReminderField: String, CaseIterable {
    case title, due, start, notes, url, location, priority, alarms, recurrence, completed, list
}

struct ReminderChange {
    var title: String?
    var due = ReminderDueChange.keep
    var start = ReminderDueChange.keep
    var recurrence = RecurrenceChange.keep
    var notes = ItemText.Change<String>.keep
    var url = ItemText.Change<String>.keep
    var priority: ReminderPriority?
    var alarms = ItemText.Change<[AlarmSpec]>.keep
    var completed: Bool?
    var targetListID: String?
    var replaceUnsupportedAlarms = false

    // No location: EKReminder ignores it (a location alarm names a place instead).
    static let fieldKeys = ["title", "due", "start", "recurrence", "notes", "url", "priority",
                            "alarms", "completed", "targetListID"]

    static func parse(_ p: [String: Any], creating: Bool) -> Result<ReminderChange, FieldError> {
        var change = ReminderChange()
        let invalid = FieldError("invalid_parameters_or_target")
        if let raw = p["title"] {
            guard let title = raw as? String, EventChange.validTitle(title) else { return .failure(invalid) }
            change.title = title
        }
        guard let due = ReminderDueChange.parse(parameters: p),
              let start = ReminderDueChange.parse(parameters: p, key: "start") else {
            return .failure(FieldError("invalid_schedule"))
        }
        if creating {
            if case .clear = due { return .failure(FieldError("invalid_schedule")) }
            if case .clear = start { return .failure(FieldError("invalid_schedule")) }
        }
        change.due = due
        change.start = start
        guard let recurrence = RecurrenceChange.parse(parameters: p) else {
            return .failure(FieldError("invalid_recurrence"))
        }
        if creating, case .clear = recurrence { return .failure(FieldError("invalid_recurrence")) }
        change.recurrence = recurrence
        switch ItemText.notes(p["notes"], present: p["notes"] != nil, creating: creating) {
        case .success(let value): change.notes = value
        case .failure(let error): return .failure(error)
        }
        switch ItemText.url(p["url"], present: p["url"] != nil, creating: creating) {
        case .success(let value): change.url = value
        case .failure(let error): return .failure(error)
        }
        if let raw = p["priority"] {
            guard let value = (raw as? String).flatMap(ReminderPriority.init(rawValue:)) else {
                return .failure(invalid)
            }
            change.priority = value
        }
        guard let alarms = AlarmSpec.parseList(p, creating: creating) else {
            return .failure(FieldError("invalid_alarms"))
        }
        change.alarms = alarms
        if case .set(let spec) = due, spec.alarmExplicit, !alarms.isKeep {
            return .failure(FieldError("invalid_alarms"))  // The 0.5 alarm or the list, not both.
        }
        if let raw = p["completed"] {
            guard !creating, let flag = raw as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else {
                return .failure(invalid)
            }
            change.completed = flag.boolValue
        }
        if let raw = p["targetListID"] {
            guard !creating, let id = raw as? String, !id.isEmpty, id.utf8.count <= 512 else {
                return .failure(invalid)
            }
            change.targetListID = id
        }
        if let raw = p["replaceUnsupportedAlarms"] {
            guard !creating, let flag = raw as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else {
                return .failure(invalid)
            }
            change.replaceUnsupportedAlarms = flag.boolValue
        }
        if creating {
            guard change.title != nil else { return .failure(invalid) }
            if case .set = recurrence, case .keep = due { return .failure(FieldError("recurrence_requires_due")) }
        } else if !fieldKeys.contains(where: { p[$0] != nil }) {
            return .failure(FieldError("nothing_to_change"))
        }
        return .success(change)
    }
}

/// A reminder's writable fields as plain values.
struct ReminderFields {
    var listID: String
    var title: String
    var due: DateComponents?
    var start: DateComponents?
    var notes: String?
    var url: String?
    var location: String?
    var priority: Int
    /// Nil entries are alarms the bridge can't represent; they stay in place.
    var alarms: [AlarmSpec?]
    var recurrence: RecurrenceRead
    var completed: Bool

    static func blank(listID: String) -> ReminderFields {
        ReminderFields(listID: listID, title: "", due: nil, start: nil, notes: nil, url: nil, location: nil,
                       priority: 0, alarms: [], recurrence: .none, completed: false)
    }

    /// The instant of date components (local midnight for a day), in their
    /// own zone, or the Mac's for floating ones.
    static func instant(_ components: DateComponents?) -> Date? {
        guard var components, components.year != nil else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = components.timeZone ?? .current
        components.calendar = calendar
        return calendar.date(from: components)
    }

    /// A start date as saved: EventKit stores an all-day start as midnight in
    /// its zone, which is the same start.
    static func sameStart(_ requested: DateComponents?, _ saved: DateComponents?) -> Bool {
        if sameDue(requested, saved) { return true }
        guard var day = requested, day.hour == nil, let saved, saved.hour == 0, saved.minute ?? 0 == 0,
              saved.second ?? 0 == 0 else { return false }
        day.hour = 0
        day.minute = 0
        day.second = 0
        return sameDate(day, saved) || (saved.timeZone == nil && day.year == saved.year &&
                                        day.month == saved.month && day.day == saved.day)
    }

    /// A due date as saved: EventKit keeps a due day floating, without the
    /// zone it was written in; the day is what counts.
    static func sameDue(_ requested: DateComponents?, _ saved: DateComponents?) -> Bool {
        if sameDate(requested, saved) { return true }
        guard let requested, requested.hour == nil, let saved, saved.hour == nil, saved.timeZone == nil
        else { return false }
        return requested.year == saved.year && requested.month == saved.month && requested.day == saved.day
    }

    static func sameDate(_ a: DateComponents?, _ b: DateComponents?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let a?, let b?):
            return a.year == b.year && a.month == b.month && a.day == b.day &&
                a.hour == b.hour && a.minute == b.minute && (a.second ?? 0) == (b.second ?? 0) &&
                ((a.timeZone == nil && b.timeZone == nil) ||
                 (a.timeZone != nil && b.timeZone != nil &&
                  ZoneAliases.same(a.timeZone!.identifier, b.timeZone!.identifier)))
        default: return false
        }
    }
}

enum ReminderPlan {
    /// Merges `change` into `current` (nil when creating) and checks every
    /// rule that needs both (§10, §12).
    static func resolve(_ change: ReminderChange, current: ReminderFields?, listID: String,
                        now: Date) -> Result<(target: ReminderFields, touched: Set<ReminderField>), FieldError> {
        let creating = current == nil
        var target = current ?? .blank(listID: listID)
        var touched = Set<ReminderField>()
        if let title = change.title { target.title = title; touched.insert(.title) }
        let dueChanged = !change.due.isKeep
        if let current, current.completed, change.completed != false {
            if dueChanged { return .failure(FieldError("completed_reminder_due_unsupported")) }
            if !change.recurrence.isKeep { return .failure(FieldError("completed_reminder_recurrence_unsupported")) }
        }
        if let current, !current.recurrence.isSupported, dueChanged || !change.recurrence.isKeep {
            return .failure(FieldError("recurrence_unsupported"))
        }

        // Due and start.
        let oldDue = current?.due
        let oldDueInstant = ReminderFields.instant(oldDue)
        switch change.due {
        case .keep: break
        case .clear: target.due = nil; touched.insert(.due)
        case .set(let spec): target.due = spec.components; touched.insert(.due)
        }
        switch change.start {
        case .set(let spec): target.start = spec.components; touched.insert(.start)
        case .clear: target.start = nil; touched.insert(.start)
        case .keep:
            if creating {
                target.start = target.due
                if target.due != nil { touched.insert(.start) }
            } else if dueChanged, let current, let start = current.start,
                      ReminderFields.sameStart(current.due, start) {
                // A start the bridge set to the due date moves with it.
                target.start = target.due
                touched.insert(.start)
            }
        }

        // Recurrence.
        switch change.recurrence {
        case .keep: break
        case .clear: target.recurrence = .none; touched.insert(.recurrence)
        case .set(let spec): target.recurrence = .rule(spec); touched.insert(.recurrence)
        }
        let recurring = target.recurrence != .none
        let newDueInstant = ReminderFields.instant(target.due)
        let timedDue = target.due?.hour != nil

        // Alarms.
        let hasUnsupported = (current?.alarms ?? []).contains { $0 == nil }
        if case .set(let spec) = change.due, spec.alarmExplicit || (creating && change.alarms.isKeep) {
            // The 0.5 single alarm (explicit, or the default at a timed due).
            if hasUnsupported && !change.replaceUnsupportedAlarms { return .failure(FieldError("alarms_unsupported")) }
            if let at = spec.alarmAt {
                if at <= now { return .failure(FieldError("alarm_in_past")) }
                if recurring, let due = newDueInstant {
                    let offset = at.timeIntervalSince(due)
                    guard offset.rounded() == offset, AlarmSpec.relativeRange.contains(Int(offset)) else {
                        return .failure(FieldError("invalid_alarms"))
                    }
                    target.alarms = [.relative(Int(offset))]
                } else {
                    target.alarms = [.absolute(Int64(at.timeIntervalSince1970.rounded(.down)))]
                }
            } else {
                target.alarms = []
            }
            touched.insert(.alarms)
        } else if !change.alarms.isKeep {
            if hasUnsupported && !change.replaceUnsupportedAlarms { return .failure(FieldError("alarms_unsupported")) }
            let list = change.alarms.value ?? []
            for case .absolute(let at) in list where Double(at) <= now.timeIntervalSince1970 {
                return .failure(FieldError("alarm_in_past"))
            }
            target.alarms = list
            touched.insert(.alarms)
        } else if !creating, dueChanged {
            // Alarms stay; one at the old due time follows the due date.
            target.alarms = (current?.alarms ?? []).compactMap { alarm -> AlarmSpec?? in
                switch alarm {
                case .absolute(let at)? where oldDueInstant.map({ Double(at) == $0.timeIntervalSince1970 }) == true:
                    guard let newDue = newDueInstant, timedDue else { return nil }
                    return recurring ? .relative(0) : .absolute(Int64(newDue.timeIntervalSince1970))
                case .relative? where target.due == nil:
                    return nil
                default:
                    return alarm
                }
            }
            touched.insert(.alarms)
        } else if !creating, case .set = change.recurrence, current?.recurrence == RecurrenceRead.none {
            // A one-off becoming repeating: its alarm at the due time becomes relative.
            target.alarms = target.alarms.map { alarm in
                if case .absolute(let at)? = alarm,
                   newDueInstant.map({ Double(at) == $0.timeIntervalSince1970 }) == true {
                    return .relative(0)
                }
                return alarm
            }
            touched.insert(.alarms)
        }
        // Checked when the schedule changes; an item made elsewhere is left as it is.
        let schedule = touched.contains(.alarms) || touched.contains(.recurrence) || touched.contains(.due)
        if schedule && recurring && target.alarms.contains(where: { $0?.isAbsolute == true }) {
            return .failure(FieldError("recurrence_requires_relative_alarm"))
        }
        if schedule && target.due == nil && target.alarms.contains(where: { $0?.isRelative == true }) {
            return .failure(FieldError("alarm_requires_due"))
        }

        // The rule needs a due date it matches.
        if let spec = target.recurrence.spec {
            guard let due = target.due, let instant = newDueInstant else {
                return .failure(FieldError("recurrence_requires_due"))
            }
            if dueChanged || touched.contains(.recurrence) {
                guard spec.matchesAnchor(start: instant, zone: due.timeZone ?? .current) else {
                    return .failure(FieldError("recurrence_anchor_mismatch"))
                }
            }
        }

        switch change.notes {
        case .keep: break
        case .clear: target.notes = nil; touched.insert(.notes)
        case .set(let value): target.notes = value; touched.insert(.notes)
        }
        switch change.url {
        case .keep: break
        case .clear: target.url = nil; touched.insert(.url)
        case .set(let value): target.url = value; touched.insert(.url)
        }
        if let priority = change.priority { target.priority = priority.raw; touched.insert(.priority) }

        if let completed = change.completed {
            if completed {
                // Repeating reminders complete one occurrence at a time, with complete_reminder.
                if recurring || current?.recurrence != RecurrenceRead.none {
                    return .failure(FieldError("recurrence_scope_required"))
                }
            } else if let current, current.completed, current.recurrence != .none {
                return .failure(FieldError("recurrence_uncomplete_unsupported"))
            }
            target.completed = completed
            touched.insert(.completed)
        }
        if let id = change.targetListID, id != target.listID {
            target.listID = id
            touched.insert(.list)
        }
        if creating { touched.insert(.list) }
        return .success((target, touched))
    }
}

enum ReminderWriteVerifier {
    static func mismatches(_ target: ReminderFields, _ saved: ReminderFields,
                           touched: Set<ReminderField>) -> [ReminderField] {
        ReminderField.allCases.filter { touched.contains($0) && !matches($0, target, saved) }
    }

    static func matches(_ field: ReminderField, _ target: ReminderFields, _ saved: ReminderFields) -> Bool {
        switch field {
        case .title: return target.title == saved.title
        case .due: return ReminderFields.sameDue(target.due, saved.due)
        case .start: return ReminderFields.sameStart(target.start, saved.start)
        case .notes: return target.notes == saved.notes
        case .url: return target.url == saved.url
        case .location: return target.location == saved.location
        case .priority: return target.priority == saved.priority
        case .alarms:
            return target.alarms.filter { $0 == nil }.count == saved.alarms.filter { $0 == nil }.count &&
                AlarmSpec.sameSet(target.alarms.compactMap { $0 }, saved.alarms.filter { $0 != nil })
        case .recurrence:
            switch (target.recurrence, saved.recurrence) {
            case (.none, .none): return true
            case (.rule(let a), .rule(let b)):
                guard let due = ReminderFields.instant(saved.due) else { return a == b }
                return a.equivalent(to: b, start: due, zone: saved.due?.timeZone ?? .current)
            default: return false
            }
        case .completed: return target.completed == saved.completed
        case .list: return target.listID == saved.listID
        }
    }

    static func code(_ fields: [ReminderField], _ outcome: String) -> String {
        "\(fields.first?.rawValue ?? "write")_readback_failed_\(outcome)"
    }
}
