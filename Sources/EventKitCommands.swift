import EventKit
import Foundation

@MainActor
final class EventKitCommands {
    private let store: EKEventStore
    var scope = BridgeScope()
    private let journal = WriteJournal()

    init(store: EKEventStore) { self.store = store }

    func run(_ request: BridgeRequest, completion: @escaping ([String: Any]) -> Void) {
        if let error = CommandPolicy.validate(request, scope: scope) {
            completion(["error": error])
            return
        }
        let p = request.parameters
        let command = request.command
        let entity: EKEntityType = {
            switch command {
            case .readReminders, .createReminder, .updateReminder, .completeReminder,
                 .deleteReminder, .reminderListCount: .reminder
            default: .event
            }
        }()
        if command != .authorizationStatus,
           EKEventStore.authorizationStatus(for: entity) != .fullAccess {
            completion(["error": "full_access_required"])
            return
        }
        if command.isWrite {
            switch journal.begin(request) {
            case .execute: break
            case .repeatResult(let result): completion(result); return
            case .reject(let error): completion(["error": error]); return
            }
        }
        switch command {
        case .authorizationStatus:
            completion([
                "calendar": status(.event),
                "reminders": status(.reminder),
            ])
        case .calendarCount:
            completion(["count": store.calendars(for: .event).count])
        case .reminderListCount:
            completion(["count": store.calendars(for: .reminder).count])
        case .readEvents:
            guard let calendar = calendar(p["calendarID"], .event) else {
                completion(["error": "target_unavailable"]); return
            }
            let start = Date(timeIntervalSince1970: (p["start"] as! NSNumber).doubleValue)
            let end = Date(timeIntervalSince1970: (p["end"] as! NSNumber).doubleValue)
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [calendar])
            let limit = (p["limit"] as! NSNumber).intValue
            let events = store.events(matching: predicate)
            completion(["items": events.prefix(limit).map(eventRow),
                        "truncated": events.count > limit])
        case .readReminders:
            guard let list = calendar(p["listID"], .reminder) else {
                completion(["error": "target_unavailable"]); return
            }
            let predicate = store.predicateForReminders(in: [list])
            let limit = (p["limit"] as! NSNumber).intValue
            store.fetchReminders(matching: predicate) { [weak self] reminders in
                DispatchQueue.main.async {
                    guard let self else { completion(["error": "app_unavailable"]); return }
                    guard let reminders else { completion(["error": "fetch_failed"]); return }
                    let safe = reminders.filter { $0.calendar.calendarIdentifier == list.calendarIdentifier }
                    completion(["items": safe.prefix(limit).map(self.reminderRow),
                                "truncated": safe.count > limit])
                }
            }
        case .createEvent:
            guard let calendar = writableCalendar(p["calendarID"], .event) else {
                completion(["error": "target_not_writable"]); return
            }
            let event = EKEvent(eventStore: store)
            event.calendar = calendar
            event.title = p["title"] as? String
            event.startDate = Date(timeIntervalSince1970: (p["start"] as! NSNumber).doubleValue)
            event.endDate = Date(timeIntervalSince1970: (p["end"] as! NSNumber).doubleValue)
            do {
                try store.save(event, span: .thisEvent)
                finishWrite(["item": eventReceipt(event)], request, completion)
            } catch { completion(["error": "save_failed"]) }
        case .updateEvent, .deleteEvent:
            guard writableCalendar(p["calendarID"], .event) != nil,
                  let event = store.event(withIdentifier: p["itemID"] as! String),
                  event.calendar.calendarIdentifier == p["calendarID"] as? String else {
                completion(["error": "item_unavailable"]); return
            }
            guard !event.hasRecurrenceRules, !event.isDetached else {
                completion(["error": "recurrence_unsupported"]); return
            }
            guard matchesVersion(event.lastModifiedDate, p["expectedVersion"]) else {
                completion(["error": "conflict"]); return
            }
            do {
                if command == .deleteEvent {
                    try store.remove(event, span: .thisEvent)
                    finishWrite(["deleted": true], request, completion)
                } else {
                    event.title = p["title"] as? String
                    event.startDate = Date(timeIntervalSince1970: (p["start"] as! NSNumber).doubleValue)
                    event.endDate = Date(timeIntervalSince1970: (p["end"] as! NSNumber).doubleValue)
                    try store.save(event, span: .thisEvent)
                    finishWrite(["item": eventReceipt(event)], request, completion)
                }
            } catch { completion(["error": "save_failed"]) }
        case .createReminder:
            guard let list = writableCalendar(p["listID"], .reminder) else {
                completion(["error": "target_not_writable"]); return
            }
            let reminder = EKReminder(eventStore: store)
            reminder.calendar = list
            reminder.title = p["title"] as? String
            do {
                try store.save(reminder, commit: true)
                finishWrite(["item": reminderReceipt(reminder)], request, completion)
            } catch { completion(["error": "save_failed"]) }
        case .updateReminder, .completeReminder, .deleteReminder:
            guard writableCalendar(p["listID"], .reminder) != nil,
                  let reminder = store.calendarItem(withIdentifier: p["itemID"] as! String) as? EKReminder,
                  reminder.calendar.calendarIdentifier == p["listID"] as? String else {
                completion(["error": "item_unavailable"]); return
            }
            guard !reminder.hasRecurrenceRules else {
                completion(["error": "recurrence_unsupported"]); return
            }
            guard matchesVersion(reminder.lastModifiedDate, p["expectedVersion"]) else {
                completion(["error": "conflict"]); return
            }
            do {
                if command == .deleteReminder {
                    try store.remove(reminder, commit: true)
                    finishWrite(["deleted": true], request, completion)
                } else {
                    if command == .completeReminder {
                        reminder.isCompleted = true
                    } else {
                        reminder.title = p["title"] as? String
                    }
                    try store.save(reminder, commit: true)
                    finishWrite(["item": reminderReceipt(reminder)], request, completion)
                }
            } catch { completion(["error": "save_failed"]) }
        }
    }

    private func calendar(_ value: Any?, _ type: EKEntityType) -> EKCalendar? {
        guard let id = value as? String else { return nil }
        return store.calendars(for: type).first { $0.calendarIdentifier == id }
    }
    private func writableCalendar(_ value: Any?, _ type: EKEntityType) -> EKCalendar? {
        guard let calendar = calendar(value, type), calendar.allowsContentModifications else { return nil }
        return calendar
    }
    private func eventRow(_ event: EKEvent) -> [String: Any] {
        var row: [String: Any] = [
            "id": event.eventIdentifier ?? "",
            "title": event.title ?? "",
            "start": event.startDate.timeIntervalSince1970,
            "end": event.endDate.timeIntervalSince1970,
            "recurring": event.hasRecurrenceRules || event.isDetached,
        ]
        if let version = version(event.lastModifiedDate) { row["version"] = version }
        return row
    }
    private func reminderRow(_ reminder: EKReminder) -> [String: Any] {
        var row: [String: Any] = [
            "id": reminder.calendarItemIdentifier,
            "title": reminder.title ?? "",
            "completed": reminder.isCompleted,
            "recurring": reminder.hasRecurrenceRules,
        ]
        if let version = version(reminder.lastModifiedDate) { row["version"] = version }
        return row
    }
    private func eventReceipt(_ event: EKEvent) -> [String: Any] {
        var receipt: [String: Any] = ["id": event.eventIdentifier ?? ""]
        if let version = version(event.lastModifiedDate) { receipt["version"] = version }
        return receipt
    }
    private func reminderReceipt(_ reminder: EKReminder) -> [String: Any] {
        var receipt: [String: Any] = ["id": reminder.calendarItemIdentifier]
        if let version = version(reminder.lastModifiedDate) { receipt["version"] = version }
        return receipt
    }
    private func version(_ date: Date?) -> String? {
        date.map { String(format: "%.6f", $0.timeIntervalSince1970) }
    }
    private func matchesVersion(_ date: Date?, _ expected: Any?) -> Bool {
        guard let current = version(date), let expected = expected as? String else { return false }
        return current == expected
    }
    private func finishWrite(_ result: [String: Any], _ request: BridgeRequest,
                             _ completion: ([String: Any]) -> Void) {
        completion(journal.finish(request, result: result)
                   ? result : ["error": "write_committed_journal_pending_review"])
    }
    private func status(_ type: EKEntityType) -> String {
        switch EKEventStore.authorizationStatus(for: type) {
        case .notDetermined: "Not determined"
        case .restricted: "Restricted"
        case .denied: "Denied"
        case .fullAccess: "Full access"
        case .writeOnly: "Write only"
        @unknown default: "Unknown"
        }
    }
}
