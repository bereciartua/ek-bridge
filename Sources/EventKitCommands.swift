import EventKit
import Foundation

@MainActor
final class EventKitCommands {
    private let store: EKEventStore
    private let journal = WriteJournal()

    init(store: EKEventStore) { self.store = store }

    // Client authorization is checked before entry and again by the supplied
    // closure after asynchronous EventKit reads and before a mutation.
    func runAuthorized(_ request: BridgeRequest, selected: BridgeScope,
                       stillAuthorized: @escaping () -> Bool,
                       completion: @escaping ([String: Any]) -> Void) {
        run(request, selected: selected,
            stillAuthorized: stillAuthorized, completion: completion)
    }

    private func run(_ request: BridgeRequest, selected: BridgeScope,
                     stillAuthorized: @escaping () -> Bool,
                     completion: @escaping ([String: Any]) -> Void) {
        guard stillAuthorized() else { completion(["error": "scope_changed"]); return }
        if let error = CommandPolicy.validate(request, scope: selected) {
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
        if command != .authorizationStatus && command != .scopeStatus,
           EKEventStore.authorizationStatus(for: entity) != .fullAccess {
            completion(["error": "full_access_required"])
            return
        }
        if command.isWrite {
            switch journal.inspect(request) {
            case .execute: break
            case .repeatResult(let result): completion(result); return
            case .reject(let error): completion(["error": error]); return
            }
        }
        switch command {
        case .scopeStatus:
            completion([
                "calendarID": selected.calendarID as Any? ?? NSNull(),
                "reminderListID": selected.reminderListID as Any? ?? NSNull(),
            ])
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
            let generation = selected.generation
            var rows = [[String: Any]]()
            var truncated = false
            store.enumerateEvents(matching: predicate) { event, stop in
                if rows.count >= limit {
                    truncated = true
                    stop.pointee = true
                } else {
                    rows.append(self.eventRow(event))
                }
            }
            guard CommandPolicy.scopeStillSelected(
                    id: calendar.calendarIdentifier, generation: generation,
                    scope: selected, reminders: false),
                  stillAuthorized(),
                  EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                completion(["error": "scope_changed"]); return
            }
            rows.sort {
                let first = $0["start"] as? Double ?? 0
                let second = $1["start"] as? Double ?? 0
                if first != second { return first < second }
                return ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "")
            }
            completion(truncated ? ["error": "too_many_events_narrow_range"] :
                       ["items": rows, "truncated": false])
        case .readReminders:
            guard let list = calendar(p["listID"], .reminder) else {
                completion(["error": "target_unavailable"]); return
            }
            let predicate = store.predicateForReminders(in: [list])
            let limit = (p["limit"] as! NSNumber).intValue
            let generation = selected.generation
            store.fetchReminders(matching: predicate) { [weak self] reminders in
                DispatchQueue.main.async {
                    guard let self else { completion(["error": "app_unavailable"]); return }
                    guard CommandPolicy.scopeStillSelected(
                            id: list.calendarIdentifier, generation: generation,
                            scope: selected, reminders: true),
                          stillAuthorized(),
                          EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                        completion(["error": "scope_changed"]); return
                    }
                    guard let reminders else { completion(["error": "fetch_failed"]); return }
                    let safe = reminders
                        .filter { $0.calendar.calendarIdentifier == list.calendarIdentifier }
                        .sorted { $0.calendarItemIdentifier < $1.calendarItemIdentifier }
                    let after = p["afterID"] as? String
                    let remaining = after.map { cursor in
                        safe.filter { $0.calendarItemIdentifier > cursor }
                    } ?? safe
                    let page = Array(remaining.prefix(limit))
                    var result: [String: Any] = [
                        "items": page.map(self.reminderRow),
                        "truncated": remaining.count > limit,
                    ]
                    if remaining.count > limit, let last = page.last {
                        result["nextCursor"] = last.calendarItemIdentifier
                    }
                    completion(result)
                }
            }
        case .createEvent:
            guard let calendar = writableCalendar(p["calendarID"], .event) else {
                completion(["error": "target_not_writable"]); return
            }
            guard let details = EventCreationDetails.parse(p) else {
                completion(["error": "invalid_event_schedule"]); return
            }
            let event = EKEvent(eventStore: store)
            event.calendar = calendar
            event.title = p["title"] as? String
            let requestedStart = Date(timeIntervalSince1970: (p["start"] as! NSNumber).doubleValue)
            let requestedEnd = Date(timeIntervalSince1970: (p["end"] as! NSNumber).doubleValue)
            event.startDate = requestedStart
            event.endDate = requestedEnd
            switch details {
            case .timed:
                event.isAllDay = false
                event.timeZone = TimeZone(secondsFromGMT: 0)
            case .allDay(let zone, let notes):
                event.timeZone = zone
                event.isAllDay = true
                event.notes = notes
            }
            guard reserveWrite(request, completion) else { return }
            do {
                try store.save(event, span: .thisEvent)
                var receipt = eventReceipt(event)
                if case .allDay(let zone, let notes) = details {
                    let persisted = event.eventIdentifier.flatMap(store.event(withIdentifier:))
                    var local = Calendar(identifier: .gregorian)
                    local.timeZone = zone
                    let sameDays = persisted.map {
                        local.isDate($0.startDate, inSameDayAs: requestedStart) &&
                        // iCloud EventKit represents an all-day exclusive end
                        // as the preceding day's 23:59:59 on this Mac.
                        ($0.endDate == requestedEnd ||
                         $0.endDate == requestedEnd.addingTimeInterval(-1))
                    } ?? false
                    guard let persisted,
                          persisted.calendar.calendarIdentifier == calendar.calendarIdentifier,
                          persisted.title == event.title,
                          persisted.isAllDay, sameDays, persisted.notes == notes else {
                        do {
                            try store.remove(event, span: .thisEvent)
                            finishWrite(["error": "all_day_readback_failed_rolled_back"], request, completion)
                        } catch {
                            finishWrite(["error": "all_day_readback_failed_cleanup_needed",
                                         "itemID": event.eventIdentifier ?? ""], request, completion)
                        }
                        return
                    }
                    receipt["allDayVerified"] = true
                    receipt["notesVerified"] = true
                    receipt["start"] = persisted.startDate.timeIntervalSince1970
                    receipt["end"] = persisted.endDate.timeIntervalSince1970
                    receipt["endExclusive"] = requestedEnd.timeIntervalSince1970
                }
                finishWrite(["item": receipt], request, completion)
            } catch { completion(["error": "save_failed"]) }
        case .updateEvent, .deleteEvent:
            guard writableCalendar(p["calendarID"], .event) != nil,
                  let event = store.event(withIdentifier: p["itemID"] as! String),
                  event.refresh(),
                  event.calendar.calendarIdentifier == p["calendarID"] as? String else {
                completion(["error": "item_unavailable"]); return
            }
            if let error = MutationPolicy.eventError(
                recurring: isRecurring(event),
                allDay: event.isAllDay, hasAttendees: event.hasAttendees,
                floatingTime: event.timeZone == nil, updating: command == .updateEvent
            ) {
                completion(["error": error]); return
            }
            guard matchesVersion(event.lastModifiedDate, p["expectedVersion"]) else {
                completion(["error": "conflict"]); return
            }
            guard reserveWrite(request, completion) else { return }
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
            guard let dueChange = ReminderDueChange.parse(parameters: p),
                  let recurrenceChange = ReminderRecurrenceChange.parse(parameters: p) else {
                completion(["error": "invalid_schedule"]); return
            }
            if let error = ReminderSchedule.validate(dueChange, recurrenceChange,
                                                     for: reminder, creating: true) {
                completion(["error": error]); return
            }
            guard reserveWrite(request, completion) else { return }
            ReminderSchedule.apply(dueChange, recurrenceChange, to: reminder)
            do {
                try store.save(reminder, commit: true)
                let saved = store.calendarItem(withIdentifier: reminder.calendarItemIdentifier)
                    as? EKReminder ?? reminder
                finishWrite(["item": reminderReceipt(saved)], request, completion)
            } catch { completion(["error": "save_failed"]) }
        case .updateReminder, .completeReminder, .deleteReminder:
            guard writableCalendar(p["listID"], .reminder) != nil,
                  let reminder = store.calendarItem(withIdentifier: p["itemID"] as! String) as? EKReminder,
                  reminder.calendar.calendarIdentifier == p["listID"] as? String else {
                completion(["error": "item_unavailable"]); return
            }
            if command != .updateReminder {
                if let error = MutationPolicy.reminderError(
                    recurring: reminder.hasRecurrenceRules,
                    completed: reminder.isCompleted,
                    completing: command == .completeReminder,
                    recurrenceScope: ReminderRecurrenceScope.parse(p["recurrenceScope"])
                ) {
                    completion(["error": error]); return
                }
            }
            guard matchesVersion(reminder.lastModifiedDate, p["expectedVersion"]) else {
                completion(["error": "conflict"]); return
            }
            let dueChange: ReminderDueChange
            let recurrenceChange: ReminderRecurrenceChange
            if command == .updateReminder {
                guard let due = ReminderDueChange.parse(parameters: p),
                      let recurrence = ReminderRecurrenceChange.parse(parameters: p) else {
                    completion(["error": "invalid_schedule"]); return
                }
                dueChange = due
                recurrenceChange = recurrence
                if let error = ReminderSchedule.validate(due, recurrence,
                                                         for: reminder, creating: false) {
                    completion(["error": error]); return
                }
            } else {
                dueChange = .keep
                recurrenceChange = .keep
            }
            guard reserveWrite(request, completion) else { return }
            do {
                if command == .deleteReminder {
                    try store.remove(reminder, commit: true)
                    finishWrite(["deleted": true], request, completion)
                } else {
                    if command == .completeReminder {
                        reminder.isCompleted = true
                    } else {
                        reminder.title = p["title"] as? String
                        ReminderSchedule.apply(dueChange, recurrenceChange, to: reminder)
                    }
                    try store.save(reminder, commit: true)
                    let saved = store.calendarItem(withIdentifier: reminder.calendarItemIdentifier)
                        as? EKReminder ?? reminder
                    finishWrite(["item": reminderReceipt(saved)], request, completion)
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
    // Some providers populate occurrenceDate for a one-off event. Use recurrence
    // rules and detachment to decide whether mutations need series handling.
    private func isRecurring(_ event: EKEvent) -> Bool {
        event.hasRecurrenceRules || event.isDetached
    }
    private func eventRow(_ event: EKEvent) -> [String: Any] {
        let (title, titleTruncated) = boundedTitle(event.title)
        var row: [String: Any] = [
            "id": event.eventIdentifier ?? "",
            "title": title,
            "titleTruncated": titleTruncated,
            "start": event.startDate.timeIntervalSince1970,
            "end": event.endDate.timeIntervalSince1970,
            "recurring": isRecurring(event),
            "allDay": event.isAllDay,
            "timeZone": event.timeZone?.identifier ?? "",
        ]
        if let version = version(event.lastModifiedDate) { row["version"] = version }
        return row
    }
    private func reminderRow(_ reminder: EKReminder) -> [String: Any] {
        let (title, titleTruncated) = boundedTitle(reminder.title)
        var row: [String: Any] = [
            "id": reminder.calendarItemIdentifier,
            "title": title,
            "titleTruncated": titleTruncated,
            "completed": reminder.isCompleted,
            "recurring": reminder.hasRecurrenceRules,
        ]
        row.merge(ReminderSchedule.describe(reminder)) { _, new in new }
        if let version = version(reminder.lastModifiedDate) { row["version"] = version }
        return row
    }
    private func eventReceipt(_ event: EKEvent) -> [String: Any] {
        var receipt: [String: Any] = ["id": event.eventIdentifier ?? ""]
        if let version = version(event.lastModifiedDate) { receipt["version"] = version }
        return receipt
    }
    private func boundedTitle(_ value: String?) -> (String, Bool) {
        let bytes = Array((value ?? "").utf8)
        guard bytes.count > 200 else { return (value ?? "", false) }
        return (String(decoding: bytes.prefix(200), as: UTF8.self), true)
    }
    private func reminderReceipt(_ reminder: EKReminder) -> [String: Any] {
        var receipt: [String: Any] = [
            "id": reminder.calendarItemIdentifier,
            "title": boundedTitle(reminder.title).0,
        ]
        receipt.merge(ReminderSchedule.describe(reminder)) { _, new in new }
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
    private func reserveWrite(_ request: BridgeRequest,
                              _ completion: ([String: Any]) -> Void) -> Bool {
        switch journal.begin(request) {
        case .execute: return true
        case .repeatResult(let result): completion(result); return false
        case .reject(let error): completion(["error": error]); return false
        }
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
