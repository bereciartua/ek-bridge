import CryptoKit
import EventKit
import Foundation

// Only the timed, alarm-free, unbounded daily iCloud shape observed in the
// supervised two-device test is eligible. This type never mutates EventKit.
enum RecurringReminderCompletion {
    private static let verifiedSourceKey = "EKBridgeVerifiedICloudReminderSourceID"

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
        let eligibleDailyRule: Bool
        let startMatchesDue: Bool
        let hasAlarms: Bool
    }

    struct Transition {
        let completedID: String
        let nextID: String
    }

    static func candidate(_ reminder: EKReminder) -> Candidate? {
        guard let list = reminder.calendar, let source = list.source,
              list.allowsContentModifications,
              supportedProvider(title: source.title, type: source.sourceType,
                                delegated: source.isDelegate,
                                sourceID: source.sourceIdentifier,
                                verifiedSourceID: Bundle.main.object(
                                    forInfoDictionaryKey: verifiedSourceKey) as? String),
              !reminder.isCompleted, reminder.completionDate == nil,
              !reminder.hasAttendees,
              let rules = reminder.recurrenceRules, rules.count == 1,
              exactDailyRule(rules[0]),
              !reminder.hasAlarms, (reminder.alarms ?? []).isEmpty,
              let dueParts = reminder.dueDateComponents,
              let startParts = reminder.startDateComponents,
              ReminderDueSpec.sameDayAndTime(startParts, dueParts),
              let zone = dueParts.timeZone,
              let readback = ReminderDueSpec.readback(dueParts) as? [String: Any],
              readback["kind"] as? String == "timed",
              let at = readback["at"] as? NSNumber,
              at.doubleValue.isFinite,
              at.doubleValue.rounded() == at.doubleValue,
              let modified = reminder.lastModifiedDate else { return nil }
        let due = Date(timeIntervalSince1970: at.doubleValue)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let next = calendar.date(byAdding: .day, value: 1, to: due),
              calendar.component(.hour, from: next) == dueParts.hour,
              calendar.component(.minute, from: next) == dueParts.minute,
              calendar.component(.second, from: next) == (dueParts.second ?? 0) else {
            return nil
        }
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
            "due": Int64(at.doubleValue),
            "timeZone": zone.identifier,
            "version": String(format: "%.6f", modified.timeIntervalSince1970),
            "rule": "daily:1:no-end:no-selectors",
            "alarms": 0,
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
                         priority: reminder.priority, due: due, nextDue: next,
                         fingerprint: fingerprint)
    }

    static func exactDailyRule(_ rule: EKRecurrenceRule) -> Bool {
        rule.frequency == .daily && rule.interval == 1 &&
            rule.recurrenceEnd == nil && rule.daysOfTheWeek == nil &&
            rule.daysOfTheMonth == nil && rule.monthsOfTheYear == nil &&
            rule.weeksOfTheYear == nil && rule.daysOfTheYear == nil &&
            rule.setPositions == nil
    }

    static func supportedProvider(title: String, type: EKSourceType,
                                  delegated: Bool, sourceID: String,
                                  verifiedSourceID: String?) -> Bool {
        guard let verifiedSourceID, !verifiedSourceID.isEmpty else { return false }
        return title == "iCloud" && type == .calDAV && !delegated &&
            sourceID == verifiedSourceID
    }

    static func record(_ reminder: EKReminder) -> Record {
        let rules = reminder.recurrenceRules ?? []
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
                      due: reminder.dueDateComponents?.date,
                      completed: reminder.isCompleted,
                      hasCompletionDate: reminder.completionDate != nil,
                      hasRules: !rules.isEmpty,
                      eligibleDailyRule: rules.count == 1 && exactDailyRule(rules[0]),
                      startMatchesDue: startMatchesDue,
                      hasAlarms: reminder.hasAlarms || !(reminder.alarms ?? []).isEmpty)
    }

    static func ambiguousExistingCompletion(_ before: Candidate,
                                            records: [Record]) -> Bool {
        records.contains { row in
            row.listID == before.listID && row.sourceID == before.sourceID &&
                row.itemID != before.itemID && row.title == before.title &&
                row.notes == before.notes && row.location == before.location &&
                row.url == before.url && row.itemTimeZone == before.itemTimeZone &&
                row.priority == before.priority && row.completed &&
                row.hasCompletionDate && !row.hasRules && !row.hasAlarms &&
                row.due.map { abs($0.timeIntervalSince(before.due)) < 0.5 } == true
        }
    }

    // A provider may split the completed instance from the advancing series.
    // Require one newly appearing completed ID and the original series ID.
    static func verifiedTransition(_ before: Candidate,
                                   preExistingIDs: Set<String>,
                                   records: [Record]) -> Transition? {
        func sameContent(_ row: Record) -> Bool {
            row.listID == before.listID && row.sourceID == before.sourceID &&
                row.title == before.title &&
                row.notes == before.notes && row.location == before.location &&
                row.url == before.url && row.itemTimeZone == before.itemTimeZone &&
                row.priority == before.priority && !row.hasAlarms
        }
        let completed = records.filter { row in
            sameContent(row) && row.itemID != before.itemID &&
                !preExistingIDs.contains(row.itemID) &&
                row.completed && row.hasCompletionDate && !row.hasRules &&
                row.due.map { abs($0.timeIntervalSince(before.due)) < 0.5 } == true
        }
        let next = records.filter { row in
            sameContent(row) && row.itemID == before.itemID &&
                !row.completed && !row.hasCompletionDate && row.eligibleDailyRule &&
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
