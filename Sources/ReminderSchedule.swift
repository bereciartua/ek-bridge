import EventKit
import Foundation

// Reminder fields ⇄ EKReminder, kept apart from store access so they can be
// checked against in-memory EKReminder objects before any live writes.
enum ReminderSchedule {
    static func fields(_ reminder: EKReminder) -> ReminderFields {
        ReminderFields(listID: reminder.calendar?.calendarIdentifier ?? "", title: reminder.title ?? "",
                       due: reminder.dueDateComponents, start: reminder.startDateComponents,
                       notes: EventKitText.text(reminder.notes), url: reminder.url?.absoluteString,
                       location: EventKitText.text(reminder.location), priority: reminder.priority,
                       alarms: (reminder.alarms ?? []).map(AlarmSpec.read),
                       recurrence: RecurrenceRead(reminder.recurrenceRules),
                       completed: reminder.isCompleted)
    }

    /// Writes the touched fields. Alarms the bridge can't represent (nil
    /// entries) keep their original EKAlarm, in order.
    static func apply(_ target: ReminderFields, _ touched: Set<ReminderField>, to reminder: EKReminder,
                      list: EKCalendar?) {
        if touched.contains(.list), let list { reminder.calendar = list }
        if touched.contains(.title) { reminder.title = target.title }
        if touched.contains(.start) { reminder.startDateComponents = target.start }
        if touched.contains(.due) { reminder.dueDateComponents = target.due }
        if touched.contains(.notes) { reminder.notes = target.notes }
        if touched.contains(.url) {
            reminder.url = target.url.flatMap { URL(string: $0, encodingInvalidCharacters: false) }
        }
        if touched.contains(.location) { reminder.location = target.location }
        if touched.contains(.priority) { reminder.priority = target.priority }
        if touched.contains(.alarms) {
            var originals = (reminder.alarms ?? []).filter { AlarmSpec.read($0) == nil }.makeIterator()
            // The original objects: a copy loses parts such as the sound.
            reminder.alarms = target.alarms.compactMap { spec in spec?.makeAlarm() ?? originals.next() }
        }
        if touched.contains(.recurrence) {
            reminder.recurrenceRules = target.recurrence.spec.map { [$0.makeRule()] }
        }
        if touched.contains(.completed) { reminder.isCompleted = target.completed }
    }

    /// One reminder as read results show it (§15.3). List rows carry a notes
    /// preview; `full` rows the notes.
    static func describe(_ reminder: EKReminder, full: Bool = false) -> [String: Any] {
        let (title, titleTruncated) = ItemText.prefix(reminder.title ?? "", maxBytes: 200)
        let due = reminder.dueDateComponents
        let (alarms, alarmsTruncated) = AlarmSpec.readback(reminder.alarms)
        var row: [String: Any] = [
            "id": reminder.calendarItemIdentifier,
            "title": title,
            "titleTruncated": titleTruncated,
            "completed": reminder.isCompleted,
            "recurring": reminder.hasRecurrenceRules,
            "due": ReminderDueSpec.readback(due),
            "start": ReminderDueSpec.readback(reminder.startDateComponents),
            "recurrence": RecurrenceRead(reminder.recurrenceRules).core(zone: due?.timeZone ?? .current),
            "alarms": alarms, "alarmCount": reminder.alarms?.count ?? 0,
            "alarmsTruncated": alarmsTruncated,
            "priority": ReminderPriority.read(reminder.priority)?.rawValue as Any? ?? NSNull(),
            "priorityRaw": reminder.priority,
            "completedAt": reminder.completionDate.map { $0.timeIntervalSince1970 as Any } ?? NSNull(),
            "created": reminder.creationDate.map { $0.timeIntervalSince1970 as Any } ?? NSNull(),
            "modified": reminder.lastModifiedDate.map { $0.timeIntervalSince1970 as Any } ?? NSNull(),
            "externalID": reminder.calendarItemExternalIdentifier as Any? ?? NSNull(),
        ]
        let notes = EventKitText.text(reminder.notes) ?? ""
        if full {
            let (text, truncated) = ItemText.prefix(notes, maxBytes: ItemText.maxReadNotesBytes)
            row["notes"] = notes.isEmpty ? NSNull() : text
            row["notesTruncated"] = truncated
        } else {
            let (text, truncated) = ItemText.prefix(notes, maxBytes: ItemText.notesPreviewBytes)
            row["notesPreview"] = notes.isEmpty ? NSNull() : text
            row["hasNotes"] = !notes.isEmpty
            row["notesTruncated"] = truncated
        }
        let location = EventKitText.text(reminder.location) ?? ""
        let (place, locationTruncated) = ItemText.prefix(location, maxBytes: ItemText.maxLocationBytes)
        row["location"] = location.isEmpty ? NSNull() : place
        row["locationTruncated"] = locationTruncated
        if let url = reminder.url?.absoluteString {
            row["url"] = url
            row["urlSchemeAllowed"] = ItemText.schemeAllowed(url)
        } else {
            row["url"] = NSNull()
        }
        return row
    }
}

/// Everything a write may change on a reminder, as EventKit values, so a
/// failed readback can put it back (§14). Held in memory only.
struct ReminderSnapshot {
    let calendar: EKCalendar?
    let title: String?
    let due: DateComponents?
    let start: DateComponents?
    let notes: String?
    let url: URL?
    let location: String?
    let priority: Int
    let alarms: [EKAlarm]
    let rules: [EKRecurrenceRule]?
    let completed: Bool

    init(_ reminder: EKReminder) {
        calendar = reminder.calendar
        title = reminder.title
        due = reminder.dueDateComponents
        start = reminder.startDateComponents
        notes = reminder.notes
        url = reminder.url
        location = reminder.location
        priority = reminder.priority
        // The objects themselves: a copy loses parts such as an alarm's sound.
        alarms = reminder.alarms ?? []
        rules = reminder.recurrenceRules
        completed = reminder.isCompleted
    }

    func restore(to reminder: EKReminder) {
        if let calendar { reminder.calendar = calendar }
        reminder.title = title
        reminder.startDateComponents = start
        reminder.dueDateComponents = due
        reminder.notes = notes
        reminder.url = url
        reminder.location = location
        reminder.priority = priority
        reminder.alarms = alarms
        reminder.recurrenceRules = rules
        reminder.isCompleted = completed
    }
}
