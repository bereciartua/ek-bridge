import CryptoKit
import EventKit
import Foundation

// Completing one occurrence of a repeating reminder. EventKit has no span for
// reminders: the provider splits off a completed copy and advances the series,
// so the bridge only does it for shapes and account types where a supervised
// probe (spike S6, `--synthetic-completion-probe`) saw exactly one completed
// copy and one advanced series. This type never mutates EventKit.
enum RecurringReminderCompletion {
    enum Provider: String { case iCloud = "icloud", local, exchange, calDAV = "caldav" }

    /// A shape the probe verified on one account type.
    struct VerifiedShape: Equatable {
        let provider: Provider
        let frequencies: Set<RecurrenceSpec.Frequency>
        /// Weekdays, month days, months or set positions.
        let selectors: Bool
        /// An interval over 1.
        let intervals: Bool
        let timedDue: Bool
        let allDayDue: Bool
        /// Relative alarms.
        let alarms: Bool
        /// A count or until end.
        let ends: Bool

        func allows(_ provider: Provider, _ spec: RecurrenceSpec, timed: Bool, hasAlarms: Bool) -> Bool {
            provider == self.provider && frequencies.contains(spec.frequency) &&
                (selectors || (spec.weekdays.isEmpty && spec.monthDays.isEmpty && spec.months.isEmpty &&
                               spec.setPositions.isEmpty)) &&
                (intervals || spec.interval == 1) && (timed ? timedDue : allDayDue) &&
                (alarms || !hasAlarms) && (ends || spec.end == nil)
        }
    }

    /// Only what a probe has shown. October 4, 2026, two devices: an iCloud
    /// daily reminder with a due time, no alarm and no end.
    static let verifiedShapes = [
        VerifiedShape(provider: .iCloud, frequencies: [.daily], selectors: false, intervals: false,
                      timedDue: true, allDayDue: false, alarms: false, ends: false),
    ]

    static func provider(title: String, type: EKSourceType, delegated: Bool) -> Provider? {
        guard !delegated else { return nil }
        switch type {
        case .calDAV: return title == "iCloud" ? .iCloud : .calDAV
        case .local: return .local
        case .exchange: return .exchange
        default: return nil
        }
    }

    static func verified(_ provider: Provider?, _ spec: RecurrenceSpec, timed: Bool, hasAlarms: Bool,
                         shapes: [VerifiedShape] = verifiedShapes) -> Bool {
        guard let provider else { return false }
        return shapes.contains { $0.allows(provider, spec, timed: timed, hasAlarms: hasAlarms) }
    }

    struct Candidate {
        let listID: String
        let sourceID: String
        let itemID: String
        let title: String
        let notes: String
        let location: String
        let url: String
        let itemTimeZone: String
        let priority: Int
        let spec: RecurrenceSpec
        let alarms: [AlarmSpec?]
        let due: Date
        let nextDue: Date
        let fingerprint: String
    }

    struct Record {
        let listID: String
        let sourceID: String
        let itemID: String
        let title: String
        let notes: String
        let location: String
        let url: String
        let itemTimeZone: String
        let priority: Int
        let due: Date?
        let completed: Bool
        let hasCompletionDate: Bool
        let hasRules: Bool
        let rule: RecurrenceSpec?
        let startMatchesDue: Bool
        let alarms: [AlarmSpec?]
    }

    struct Transition {
        let completedID: String
        let nextID: String
    }

    static func candidate(_ reminder: EKReminder, shapes: [VerifiedShape] = verifiedShapes) -> Candidate? {
        guard let list = reminder.calendar, let source = list.source,
              list.allowsContentModifications,
              !reminder.isCompleted, reminder.completionDate == nil,
              !reminder.hasAttendees,
              let spec = RecurrenceRead(reminder.recurrenceRules).spec,
              let dueParts = reminder.dueDateComponents,
              let startParts = reminder.startDateComponents,
              ReminderDueSpec.sameDayAndTime(startParts, dueParts),
              let zone = dueParts.timeZone,
              let modified = reminder.lastModifiedDate else { return nil }
        let alarms = (reminder.alarms ?? []).map(AlarmSpec.read)
        guard alarms.allSatisfy({ $0?.isRelative == true }) else { return nil }
        let timed = dueParts.hour != nil
        guard verified(provider(title: source.title, type: source.sourceType, delegated: source.isDelegate),
                       spec, timed: timed, hasAlarms: !alarms.isEmpty, shapes: shapes),
              let due = ReminderFields.instant(dueParts),
              timed ? (ReminderDueSpec.readback(dueParts) as? [String: Any])?["kind"] as? String == "timed" : true,
              let next = nextDue(spec, after: dueParts, zone: zone) else { return nil }
        let identity: [String: Any] = [
            "listID": list.calendarIdentifier,
            "sourceID": source.sourceIdentifier,
            "itemID": reminder.calendarItemIdentifier,
            "title": reminder.title ?? "",
            "notes": reminder.notes ?? "",
            "location": reminder.location ?? "",
            "url": reminder.url?.absoluteString ?? "",
            "itemTimeZone": reminder.timeZone?.identifier ?? "",
            "priority": reminder.priority,
            "due": Int64(due.timeIntervalSince1970),
            "timeZone": zone.identifier,
            "version": String(format: "%.6f", modified.timeIntervalSince1970),
            "rule": spec.rrule,
            "alarms": alarms.map { $0?.core ?? [:] },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: identity,
                                                      options: [.sortedKeys]) else { return nil }
        let fingerprint = SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
        return Candidate(listID: list.calendarIdentifier,
                         sourceID: source.sourceIdentifier,
                         itemID: reminder.calendarItemIdentifier,
                         title: reminder.title ?? "", notes: reminder.notes ?? "",
                         location: reminder.location ?? "",
                         url: reminder.url?.absoluteString ?? "",
                         itemTimeZone: reminder.timeZone?.identifier ?? "",
                         priority: reminder.priority, spec: spec, alarms: alarms,
                         due: due, nextDue: next, fingerprint: fingerprint)
    }

    /// The occurrence after `due`, at the same wall time; nil when the rule
    /// ends there or the wall time doesn't exist that day.
    static func nextDue(_ spec: RecurrenceSpec, after due: DateComponents, zone: TimeZone) -> Date? {
        guard let year = due.year, let month = due.month, let day = due.day else { return nil }
        let anchor = RecurrenceExpansion.daysFromCivil(year, month, day)
        let days = RecurrenceExpansion.days(spec, anchor: anchor, through: anchor + 4 * 366, limit: 2)
        guard days.count == 2, days[0] == anchor else { return nil }
        let (y, m, d) = RecurrenceExpansion.civil(days[1])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var parts = DateComponents(year: y, month: m, day: d, hour: due.hour, minute: due.minute,
                                   second: due.hour == nil ? nil : (due.second ?? 0))
        parts.timeZone = zone
        guard let next = calendar.date(from: parts) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: next)
        guard back.year == y, back.month == m, back.day == d,
              due.hour == nil || (back.hour == due.hour && back.minute == due.minute) else { return nil }
        if case .until(let at)? = spec.end, next.timeIntervalSince1970 > TimeInterval(at) { return nil }
        return next
    }

    static func record(_ reminder: EKReminder) -> Record {
        let sourceID = reminder.calendar?.source?.sourceIdentifier ?? ""
        let startMatchesDue = reminder.startDateComponents.flatMap { start in
            reminder.dueDateComponents.map {
                ReminderDueSpec.sameDayAndTime(start, $0)
            }
        } ?? false
        return Record(listID: reminder.calendar?.calendarIdentifier ?? "",
                      sourceID: sourceID,
                      itemID: reminder.calendarItemIdentifier,
                      title: reminder.title ?? "", notes: reminder.notes ?? "",
                      location: reminder.location ?? "",
                      url: reminder.url?.absoluteString ?? "",
                      itemTimeZone: reminder.timeZone?.identifier ?? "",
                      priority: reminder.priority,
                      due: ReminderFields.instant(reminder.dueDateComponents),
                      completed: reminder.isCompleted,
                      hasCompletionDate: reminder.completionDate != nil,
                      hasRules: !(reminder.recurrenceRules ?? []).isEmpty,
                      rule: RecurrenceRead(reminder.recurrenceRules).spec,
                      startMatchesDue: startMatchesDue,
                      alarms: (reminder.alarms ?? []).map(AlarmSpec.read))
    }

    private static func sameContent(_ row: Record, _ before: Candidate) -> Bool {
        row.listID == before.listID && row.sourceID == before.sourceID &&
            row.title == before.title &&
            row.notes == before.notes && row.location == before.location &&
            row.url == before.url && row.itemTimeZone == before.itemTimeZone &&
            row.priority == before.priority && row.alarms == before.alarms
    }

    static func ambiguousExistingCompletion(_ before: Candidate,
                                            records: [Record]) -> Bool {
        records.contains { row in
            sameContent(row, before) && row.itemID != before.itemID && row.completed &&
                row.hasCompletionDate && !row.hasRules &&
                row.due.map { abs($0.timeIntervalSince(before.due)) < 0.5 } == true
        }
    }

    // A provider may split the completed instance from the advancing series.
    // Require one newly appearing completed ID and the original series ID.
    static func verifiedTransition(_ before: Candidate,
                                   preExistingIDs: Set<String>,
                                   records: [Record]) -> Transition? {
        let completed = records.filter { row in
            sameContent(row, before) && row.itemID != before.itemID &&
                !preExistingIDs.contains(row.itemID) &&
                row.completed && row.hasCompletionDate && !row.hasRules &&
                row.due.map { abs($0.timeIntervalSince(before.due)) < 0.5 } == true
        }
        let next = records.filter { row in
            sameContent(row, before) && row.itemID == before.itemID &&
                !row.completed && !row.hasCompletionDate && row.rule == before.spec &&
                row.startMatchesDue &&
                row.due.map { abs($0.timeIntervalSince(before.nextDue)) < 0.5 } == true
        }
        guard completed.count == 1, next.count == 1,
              records.filter({ $0.itemID == before.itemID }).count == 1 else {
            return nil
        }
        return Transition(completedID: completed[0].itemID,
                          nextID: next[0].itemID)
    }
}
