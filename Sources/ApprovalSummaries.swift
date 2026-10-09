import EventKit
import Foundation

/// The item a change is compared against, as EventKit has it now.
struct ApprovalLookup {
    var event: EventFields?
    var reminder: ReminderFields?
    /// Whether the event repeats, and the occurrence the request names.
    var recurring = false
    var occurrenceStart: Date?
    /// How many occurrences a `future` or `all` change touches, over the next 400 days.
    var occurrences: Int?
}

/// Builds the panel's text from the request parameters and a fresh EventKit
/// lookup of the current item, never from anything the agent wrote about it
/// (plan 03 §17). The rows come from the same resolvers the write uses, so
/// the panel shows exactly what will be saved.
enum ApprovalSummaries {
    static func build(_ approval: ApprovalRequest, store: EKEventStore?,
                      collections: [CollectionInfo]) -> ApprovalSummary {
        let current = store.map { Self.lookup(approval.request, store: $0) }
        return build(approval, lookup: current ?? ApprovalLookup(), collections: collections)
    }

    static func lookup(_ request: BridgeRequest, store: EKEventStore) -> ApprovalLookup {
        let p = request.parameters
        guard let id = p["itemID"] as? String else { return ApprovalLookup() }
        var result = ApprovalLookup()
        switch request.command {
        case .updateEvent, .deleteEvent:
            guard let base = store.event(withIdentifier: EventSeries.id(id))
                    ?? store.event(withIdentifier: id) else { return result }
            result.recurring = base.hasRecurrenceRules || base.isDetached
            var subject = base
            if result.recurring, let start = ReminderDueSpec.timestamp(p["occurrenceStart"]) {
                let at = Date(timeIntervalSince1970: TimeInterval(start))
                result.occurrenceStart = at
                let predicate = store.predicateForEvents(withStart: at.addingTimeInterval(-86_401),
                                                         end: at.addingTimeInterval(86_401),
                                                         calendars: [base.calendar])
                let series = EventSeries.id(id)
                let matches = store.events(matching: predicate).filter {
                    EventSeries.id($0.eventIdentifier ?? "") == series &&
                        $0.occurrenceDate.map { abs($0.timeIntervalSince(at)) < 0.5 } == true
                }
                if matches.count == 1 { subject = matches[0] }
            }
            let span = p["span"] as? String ?? "this"
            if span == "all" { subject = base }
            result.event = EventFields.read(subject)
            if result.recurring, span != "this" {
                let from = span == "all" ? base.startDate! : (result.occurrenceStart ?? subject.startDate!)
                let predicate = store.predicateForEvents(withStart: from, end: from.addingTimeInterval(400 * 86_400),
                                                         calendars: [base.calendar])
                result.occurrences = store.events(matching: predicate)
                    .filter { EventSeries.id($0.eventIdentifier ?? "") == EventSeries.id(id) }.count
            }
        case .updateReminder, .completeReminder, .deleteReminder:
            guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return result }
            result.reminder = ReminderSchedule.fields(reminder)
            result.recurring = reminder.hasRecurrenceRules
        default:
            break
        }
        return result
    }

    static func build(_ approval: ApprovalRequest, lookup: ApprovalLookup, collections: [CollectionInfo],
                      zone: TimeZone = .current, now: Date = Date()) -> ApprovalSummary {
        let request = approval.request
        let command = request.command
        let reminders = CommandPresentation.targetsList(command.rawValue)
        let collection = approval.targetID.flatMap { id in
            collections.first { $0.id == id && $0.resource == (reminders ? .reminderList : .calendar) }
        }
        let subtitle = collection.map { "\($0.name) · \($0.account)" }
        let title = String(localized: "\(approval.clientName) wants to \(verb(command))")
        var rows = [ApprovalSummary.Row]()
        var lookupFailed = false
        // Every delete is destructive; the rows say how many occurrences go (T27).
        let destructive = command == .deleteEvent || command == .deleteReminder
        switch command {
        case .createEvent, .updateEvent, .deleteEvent:
            lookupFailed = command != .createEvent && lookup.event == nil
            rows = eventRows(request, lookup, collections: collections, zone: zone, now: now)
        case .createReminder, .updateReminder, .completeReminder, .deleteReminder:
            lookupFailed = command != .createReminder && lookup.reminder == nil
            rows = reminderRows(request, lookup, collections: collections, zone: zone, now: now)
        default:
            break
        }
        return ApprovalSummary(title: title, subtitle: subtitle, rows: rows, isDelete: destructive,
                               lookupFailed: lookupFailed, collectionColor: collection?.color,
                               itemIDForDisplay: destructive ? request.parameters["itemID"] as? String : nil)
    }

    static func verb(_ command: BridgeCommand) -> String {
        switch command {
        case .createEvent: String(localized: "add an event")
        case .updateEvent: String(localized: "change an event")
        case .deleteEvent: String(localized: "delete an event")
        case .createReminder: String(localized: "add a reminder")
        case .updateReminder: String(localized: "change a reminder")
        case .completeReminder: String(localized: "complete a reminder")
        case .deleteReminder: String(localized: "delete a reminder")
        default: String(localized: "make a change")
        }
    }

    // MARK: Events

    private static func eventRows(_ request: BridgeRequest, _ lookup: ApprovalLookup,
                                  collections: [CollectionInfo], zone: TimeZone,
                                  now: Date) -> [ApprovalSummary.Row] {
        let p = request.parameters
        let creating = request.command == .createEvent
        var rows = [ApprovalSummary.Row]()
        let current = lookup.event
        if request.command == .deleteEvent {
            rows.append(.init(label: String(localized: "Event"), value: current?.title ?? "–"))
            if let current { rows.append(.init(label: String(localized: "When"), value: when(current, zone: zone))) }
            if let applies = appliesTo(p, lookup, deleting: true, zone: zone) { rows.append(applies) }
            return rows
        }
        let calendarID = p["calendarID"] as? String ?? ""
        // Without the current event, compare against a blank one: the rows
        // still show what the request sets.
        let base = current ?? (creating ? nil : EventFields(
            calendarID: calendarID, title: "–", start: Double((p["start"] as? NSNumber)?.intValue ?? 0),
            end: Double((p["end"] as? NSNumber)?.intValue ?? 1), allDay: p["allDay"] as? Bool ?? false,
            timeZone: p["timeZone"] as? String ?? zone.identifier, notes: nil, location: nil, place: nil,
            url: nil, alarms: [], availability: nil, recurrence: .none))
        let resolved = EventChange.parse(p, creating: creating).flatMap {
            EventFields.resolve($0, current: base, calendarID: calendarID,
                                supportedAvailability: Set(EventAvailability.allCases), macZone: zone, now: now)
        }
        let target: EventFields
        let touched: Set<EventField>
        switch resolved {
        case .success(let plan):
            target = plan.target
            touched = plan.touched
        case .failure(let error):
            rows.append(.init(label: String(localized: "Event"), value: p["title"] as? String ?? current?.title ?? "–"))
            rows.append(.init(label: String(localized: "Problem"),
                              value: String(localized: "\(AppIdentity.displayName) will refuse this change (\(error.code)).")))
            return rows
        }
        func row(_ label: String, _ value: (EventFields) -> String, field: Bool) {
            guard field else { return }
            let after = value(target)
            let before = current.map(value)
            rows.append(.init(label: label, value: after, before: before != after ? before : nil))
        }
        rows.append(.init(label: String(localized: "Event"), value: target.title,
                          before: current.map(\.title).flatMap { $0 != target.title ? $0 : nil }))
        let timesTouched = touched.contains(.start)
        if timesTouched || current != nil {
            row(String(localized: "When"), { when($0, zone: zone) }, field: true)
        }
        if let applies = appliesTo(p, lookup, deleting: false, zone: zone) { rows.append(applies) }
        row(String(localized: "Repeats"), { repeats($0.recurrence, zone: zone) }, field: touched.contains(.recurrence))
        row(String(localized: "Where"), whereText, field: touched.contains(.location))
        if touched.contains(.notes) {
            let (value, full) = notesText(target.notes)
            let before = current.map { notesText($0.notes).value }
            rows.append(.init(label: String(localized: "Notes"), value: value,
                              before: before != value ? before : nil, full: full))
        }
        if touched.contains(.url) {
            let (value, host) = linkText(target.url)
            let before = current.map { linkText($0.url).value }
            rows.append(.init(label: String(localized: "Link"), value: value,
                              before: before != value ? before : nil, emphasis: host))
        }
        row(String(localized: "Alerts"), { alarmsText($0.alarms, zone: zone, reminder: false) },
            field: touched.contains(.alarms))
        row(String(localized: "Show as"), { $0.availability.map(availabilityText) ?? String(localized: "Busy") },
            field: touched.contains(.availability))
        if touched.contains(.calendar), !creating {
            let names = { (id: String) in collections.first { $0.id == id && $0.resource == .calendar }?.name ?? id }
            rows.append(.init(label: String(localized: "Calendar"),
                              value: "\(names(current?.calendarID ?? calendarID)) → \(names(target.calendarID))"))
        }
        return rows
    }

    /// "Only Oct 20", "Oct 20 and later (about 37 occurrences)", "All occurrences".
    private static func appliesTo(_ p: [String: Any], _ lookup: ApprovalLookup, deleting: Bool,
                                  zone: TimeZone) -> ApprovalSummary.Row? {
        guard lookup.recurring || p["span"] != nil else { return nil }
        let day = (lookup.occurrenceStart ?? ReminderDueSpec.timestamp(p["occurrenceStart"])
            .map { Date(timeIntervalSince1970: TimeInterval($0)) })
            .map { $0.formatted(Date.FormatStyle(timeZone: zone).month(.abbreviated).day()) } ?? "–"
        let count = lookup.occurrences
        let value: String
        switch p["span"] as? String ?? "this" {
        case "future":
            let later = count.map { max($0 - 1, 0) }
            if deleting {
                value = later.map { String(localized: "Deletes \(day) and \($0) later occurrences") }
                    ?? String(localized: "Deletes \(day) and every later occurrence")
            } else {
                value = later.map { String(localized: "\(day) and later (about \($0 + 1) occurrences)") }
                    ?? String(localized: "\(day) and later")
            }
        case "all":
            let about = count.map { String(localized: " (about \($0) in the next 400 days)") } ?? ""
            value = deleting ? String(localized: "Deletes every occurrence\(about)")
                : String(localized: "All occurrences\(about)")
        default:
            value = String(localized: "Only \(day)")
        }
        return .init(label: String(localized: "Applies to"), value: value)
    }

    static func when(_ fields: EventFields, zone: TimeZone) -> String {
        let eventZone = fields.timeZone.flatMap(TimeZone.init(identifier:)) ?? zone
        let start = Date(timeIntervalSince1970: fields.start), end = Date(timeIntervalSince1970: fields.end)
        if fields.allDay { return allDaySpan(start, end, zone: eventZone) }
        let text = span(start, end, zone: eventZone)
        return eventZone.identifier == zone.identifier ? text : "\(text) (\(eventZone.identifier))"
    }

    static func span(_ start: Date, _ end: Date, zone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let dayStyle = Date.FormatStyle(timeZone: zone).weekday(.abbreviated).month(.abbreviated).day()
        let timeStyle = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone)
        let day = start.formatted(dayStyle)
        let from = start.formatted(timeStyle)
        let to = calendar.isDate(start, inSameDayAs: end) ? end.formatted(timeStyle)
            : end.formatted(Date.FormatStyle(timeZone: zone).weekday(.abbreviated).month(.abbreviated).day()
                .hour().minute())
        return "\(day), \(from)–\(to)"
    }

    private static func allDaySpan(_ start: Date, _ end: Date, zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let style = Date.FormatStyle(timeZone: zone).weekday(.abbreviated).month(.abbreviated).day()
        let last = end.addingTimeInterval(-1)
        let first = start.formatted(style)
        return calendar.isDate(start, inSameDayAs: last)
            ? String(localized: "\(first), all day")
            : String(localized: "\(first) – \(last.formatted(style)), all day")
    }

    private static func repeats(_ recurrence: RecurrenceRead, zone: TimeZone) -> String {
        switch recurrence {
        case .none: String(localized: "Never")
        case .rule(let spec): RecurrenceText.summary(spec, zone: zone)
        case .unsupported: String(localized: "A rule \(AppIdentity.displayName) can't show")
        }
    }

    private static func whereText(_ fields: EventFields) -> String {
        guard let location = fields.location else { return String(localized: "None") }
        return fields.place == nil ? location : String(localized: "\(location) (map pin)")
    }

    /// The first 3 lines, then "… (2,400 characters)".
    static func notesText(_ notes: String?) -> (value: String, full: String?) {
        guard let notes, !notes.isEmpty else { return (String(localized: "None"), nil) }
        let lines = notes.split(separator: "\n", omittingEmptySubsequences: false)
        var shown = lines.prefix(3).joined(separator: "\n")
        if shown.count > 240 { shown = String(shown.prefix(240)) }
        guard shown.count < notes.count else { return (notes, nil) }
        return ("\(shown)… " + String(localized: "(\(notes.count.formatted()) characters)"), notes)
    }

    /// The URL with its host emphasized; other schemes are named.
    static func linkText(_ url: String?) -> (value: String, host: String?) {
        guard let url else { return (String(localized: "None"), nil) }
        let components = URLComponents(string: url)
        switch components?.scheme?.lowercased() {
        case "http", "https": return (url, components?.host)
        case "tel": return (String(localized: "Phone link: \(url)"), nil)
        case "mailto": return (String(localized: "Email link: \(url)"), nil)
        default: return (String(localized: "Other link: \(url)"), nil)
        }
    }

    /// "15 min before, at Tue, Oct 20, 8:30 AM".
    static func alarmsText(_ alarms: [AlarmSpec?], zone: TimeZone, reminder: Bool) -> String {
        guard !alarms.isEmpty else { return String(localized: "None") }
        let parts = alarms.map { alarm -> String in
            switch alarm {
            case .relative(let offset)?:
                let minutes = -offset / 60
                if minutes == 0 { return reminder ? String(localized: "at the due time") : String(localized: "at the start") }
                let amount = duration(abs(minutes))
                return minutes > 0 ? String(localized: "\(amount) before") : String(localized: "\(amount) after")
            case .absolute(let at)?:
                let date = Date(timeIntervalSince1970: TimeInterval(at))
                return String(localized: "at \(date.formatted(Date.FormatStyle(timeZone: zone).weekday(.abbreviated).month(.abbreviated).day().hour().minute()))")
            case .location(let place, let proximity)?:
                return proximity == .arrive ? String(localized: "arriving at \(place.title)")
                    : String(localized: "leaving \(place.title)")
            case nil:
                return String(localized: "an alert \(AppIdentity.displayName) can't show")
            }
        }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private static func duration(_ minutes: Int) -> String {
        if minutes % 1_440 == 0 {
            let days = minutes / 1_440
            return days == 1 ? String(localized: "1 day") : String(localized: "\(days) days")
        }
        if minutes % 60 == 0 { return String(localized: "\(minutes / 60) h") }
        if minutes > 60 { return String(localized: "\(minutes / 60) h \(minutes % 60) min") }
        return String(localized: "\(minutes) min")
    }

    private static func availabilityText(_ value: EventAvailability) -> String {
        switch value {
        case .busy: String(localized: "Busy")
        case .free: String(localized: "Free")
        case .tentative: String(localized: "Tentative")
        case .unavailable: String(localized: "Unavailable")
        }
    }

    // MARK: Reminders

    private static func reminderRows(_ request: BridgeRequest, _ lookup: ApprovalLookup,
                                     collections: [CollectionInfo], zone: TimeZone,
                                     now: Date) -> [ApprovalSummary.Row] {
        let p = request.parameters
        let command = request.command
        let current = lookup.reminder
        var rows = [ApprovalSummary.Row]()
        if command == .completeReminder || command == .deleteReminder {
            rows.append(.init(label: String(localized: "Reminder"), value: current?.title ?? "–"))
            if let due = current?.due.flatMap(dueText) { rows.append(.init(label: String(localized: "Due"), value: due)) }
            if command == .completeReminder, p["recurrenceScope"] as? String == "occurrence" {
                rows.append(.init(label: String(localized: "Repeats"),
                                  value: String(localized: "Only this occurrence is completed")))
            }
            if command == .deleteReminder, p["recurrenceScope"] as? String == "series" {
                rows.append(.init(label: String(localized: "Repeats"),
                                  value: String(localized: "Deletes this repeating reminder and all its future occurrences")))
            }
            return rows
        }
        let creating = command == .createReminder
        let listID = p["listID"] as? String ?? ""
        let base = current ?? (creating ? nil : ReminderFields.blank(listID: listID))
        let resolved = ReminderChange.parse(p, creating: creating).flatMap {
            ReminderPlan.resolve($0, current: base, listID: listID, now: now)
        }
        let target: ReminderFields
        let touched: Set<ReminderField>
        switch resolved {
        case .success(let plan):
            target = plan.target
            touched = plan.touched
        case .failure(let error):
            rows.append(.init(label: String(localized: "Reminder"), value: p["title"] as? String ?? current?.title ?? "–"))
            rows.append(.init(label: String(localized: "Problem"),
                              value: String(localized: "\(AppIdentity.displayName) will refuse this change (\(error.code)).")))
            return rows
        }
        func row(_ label: String, _ value: (ReminderFields) -> String, field: Bool) {
            guard field else { return }
            let after = value(target)
            let before = current.map(value)
            rows.append(.init(label: label, value: after, before: before != after ? before : nil))
        }
        let none = String(localized: "None")
        rows.append(.init(label: String(localized: "Reminder"), value: target.title,
                          before: current.map(\.title).flatMap { $0 != target.title ? $0 : nil }))
        row(String(localized: "Due"), { $0.due.flatMap(dueText) ?? none },
            field: touched.contains(.due) || (current?.due != nil && !creating))
        if touched.contains(.start), !ReminderFields.sameDate(target.start, target.due) {
            row(String(localized: "Starts"), { $0.start.flatMap(dueText) ?? none }, field: true)
        }
        row(String(localized: "Repeats"), { repeats($0.recurrence, zone: $0.due?.timeZone ?? zone) },
            field: touched.contains(.recurrence))
        if touched.contains(.notes) {
            let (value, full) = notesText(target.notes)
            let before = current.map { notesText($0.notes).value }
            rows.append(.init(label: String(localized: "Notes"), value: value,
                              before: before != value ? before : nil, full: full))
        }
        if touched.contains(.url) {
            let (value, host) = linkText(target.url)
            let before = current.map { linkText($0.url).value }
            rows.append(.init(label: String(localized: "Link"), value: value,
                              before: before != value ? before : nil, emphasis: host))
        }
        row(String(localized: "Where"), { $0.location ?? none }, field: touched.contains(.location))
        if touched.contains(.alarms), !(creating && target.alarms.isEmpty) {
            row(String(localized: "Alerts"), { alarmsText($0.alarms, zone: zone, reminder: true) }, field: true)
        }
        row(String(localized: "Priority"), { priorityText($0.priority) }, field: touched.contains(.priority))
        row(String(localized: "Completed"), {
            $0.completed ? String(localized: "Completed") : String(localized: "Not completed")
        }, field: touched.contains(.completed))
        if touched.contains(.list), !creating {
            let names = { (id: String) in collections.first { $0.id == id && $0.resource == .reminderList }?.name ?? id }
            rows.append(.init(label: String(localized: "List"),
                              value: "\(names(current?.listID ?? listID)) → \(names(target.listID))"))
        }
        return rows
    }

    private static func priorityText(_ raw: Int) -> String {
        switch ReminderPriority.read(raw) {
        case .high?: String(localized: "High")
        case .medium?: String(localized: "Medium")
        case .low?: String(localized: "Low")
        default: String(localized: "None")
        }
    }

    static func dueText(_ components: DateComponents) -> String? {
        guard let date = ReminderFields.instant(components) else { return nil }
        let style = Date.FormatStyle(timeZone: components.timeZone ?? .current)
        return components.hour == nil
            ? date.formatted(style.weekday(.abbreviated).month(.abbreviated).day())
            : date.formatted(style.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }
}
