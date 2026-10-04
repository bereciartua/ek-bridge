import EventKit
import Foundation

// Only for supervised synthetic tests. IDs are kept so a later app launch can
// distinguish collections this app created from an unrelated name collision.
@MainActor
final class TestCollections {
    static let name = "EventKit Bridge Test"
    private let store: EKEventStore
    private let defaults: UserDefaults
    private let calendarKey = "testCalendarIdentifier"
    private let listKey = "testReminderListIdentifier"

    init(store: EKEventStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
    }

    var calendarID: String? { defaults.string(forKey: calendarKey) }
    var reminderListID: String? { defaults.string(forKey: listKey) }

    func sourcePreview() -> String {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess,
              EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            return "Full Calendar and Reminders access is required to inspect test sources."
        }
        guard let eventSource = source(.event), let reminderSource = source(.reminder) else {
            return "A source for one or both test collections is unavailable."
        }
        func description(_ source: EKSource) -> String {
            "\(source.title) (\(source.sourceType == .local ? "local" : "syncing account"))"
        }
        return "Test calendar source: \(description(eventSource))\nTest reminder-list source: \(description(reminderSource))"
    }

    func create() -> String {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess,
              EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            return "Full Calendar and Reminders access is required."
        }
        guard calendarID == nil, reminderListID == nil else {
            return "A test collection ID is already recorded. Clean it up before creating another."
        }
        guard !store.calendars(for: .event).contains(where: { $0.title == Self.name }),
              !store.calendars(for: .reminder).contains(where: { $0.title == Self.name })
        else { return "A collection with the test name already exists; nothing was created." }
        guard let eventSource = source(.event), let reminderSource = source(.reminder) else {
            return "A source for one or both test collections is unavailable."
        }

        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = Self.name
        calendar.source = eventSource
        do {
            try store.saveCalendar(calendar, commit: true)
        } catch {
            return "Could not create test calendar: \(code(error))"
        }
        let newCalendarID = calendar.calendarIdentifier
        guard !newCalendarID.isEmpty else {
            try? store.removeCalendar(calendar, commit: true)
            return "Test calendar identifier was unavailable; creation stopped."
        }
        defaults.set(newCalendarID, forKey: calendarKey)
        guard defaults.synchronize() else {
            do {
                try store.removeCalendar(calendar, commit: true)
                defaults.removeObject(forKey: calendarKey)
                _ = defaults.synchronize()
                return "Could not retain the test calendar ID; creation was rolled back."
            } catch {
                return "Could not retain the test calendar ID or roll back creation. Inspect test collections before retrying."
            }
        }

        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = Self.name
        list.source = reminderSource
        do {
            try store.saveCalendar(list, commit: true)
        } catch {
            return "Test calendar was created, but the reminder list failed (\(code(error))). Its ID is retained for cleanup."
        }
        let newListID = list.calendarIdentifier
        guard !newListID.isEmpty else {
            return "Test reminder list identifier was unavailable; inspect the test collections before cleanup."
        }
        defaults.set(newListID, forKey: listKey)
        guard defaults.synchronize() else {
            return "Test collections were created, but the list ID could not be durably recorded. Inspect them before cleanup."
        }
        return "Created both empty test collections. Calendar ID: \(newCalendarID)\nReminder list ID: \(newListID)"
    }

    func removeEmpty(completion: @escaping (String) -> Void) {
        let eventID = calendarID
        let reminderID = reminderListID
        guard eventID != nil || reminderID != nil else {
            completion("No app-created test collection IDs are recorded.")
            return
        }
        guard (eventID == nil || EKEventStore.authorizationStatus(for: .event) == .fullAccess),
              (reminderID == nil || EKEventStore.authorizationStatus(for: .reminder) == .fullAccess)
        else {
            completion("Full access is needed for each recorded test collection before cleanup.")
            return
        }
        let calendar = eventID.flatMap(store.calendar(withIdentifier:))
        let list = reminderID.flatMap(store.calendar(withIdentifier:))
        if eventID != nil && calendar == nil || reminderID != nil && list == nil {
            completion("A recorded test collection is missing. Inspect it before cleanup.")
            return
        }
        guard (calendar == nil || calendar?.title == Self.name),
              (list == nil || list?.title == Self.name) else {
            completion("A recorded ID no longer has the test name; cleanup refused.")
            return
        }
        if let calendar, containsEvents(calendar) {
            completion("Test calendar still contains events. Delete the synthetic events first.")
            return
        }
        guard let list else {
            completion(removeVerified(calendar: calendar, list: nil))
            return
        }
        let predicate = store.predicateForReminders(in: [list])
        store.fetchReminders(matching: predicate) { [weak self] reminders in
            DispatchQueue.main.async {
                guard let self else { completion("App unavailable."); return }
                guard let reminders else { completion("Could not verify the test list is empty."); return }
                guard reminders.isEmpty else {
                    completion("Test reminder list still contains reminders. Delete the synthetic reminders first.")
                    return
                }
                completion(self.removeVerified(calendar: calendar, list: list))
            }
        }
    }

    private func removeVerified(calendar: EKCalendar?, list: EKCalendar?) -> String {
        // Recheck identity and emptiness immediately before the destructive call.
        if let calendar {
            guard store.calendar(withIdentifier: calendar.calendarIdentifier)?.title == Self.name,
                  !containsEvents(calendar) else {
                return "Test calendar changed during cleanup; nothing was removed."
            }
        }
        if let list {
            guard store.calendar(withIdentifier: list.calendarIdentifier)?.title == Self.name else {
                return "Test reminder list changed during cleanup; nothing was removed."
            }
        }
        do {
            if let list {
                try store.removeCalendar(list, commit: true)
                defaults.removeObject(forKey: listKey)
                _ = defaults.synchronize()
            }
            if let calendar {
                try store.removeCalendar(calendar, commit: true)
                defaults.removeObject(forKey: calendarKey)
                _ = defaults.synchronize()
            }
            return "Removed the empty app-created test collections."
        } catch {
            return "Test cleanup stopped: \(code(error)). Recorded IDs are retained for anything not removed."
        }
    }

    private func containsEvents(_ calendar: EKCalendar) -> Bool {
        let end = Date(timeIntervalSince1970: 4_102_444_800)
        var start = Date(timeIntervalSince1970: -2_208_988_800)
        while start < end {
            let next = min(start.addingTimeInterval(3 * 365 * 86_400), end)
            let predicate = store.predicateForEvents(withStart: start, end: next, calendars: [calendar])
            var found = false
            store.enumerateEvents(matching: predicate) { _, stop in
                found = true
                stop.pointee = true
            }
            if found { return true }
            start = next
        }
        return false
    }

    private func source(_ entity: EKEntityType) -> EKSource? {
        if let local = store.sources.first(where: {
            $0.sourceType == .local && !$0.isDelegate &&
                !$0.calendars(for: entity).isEmpty
        }) { return local }
        return entity == .event
            ? store.defaultCalendarForNewEvents?.source
            : store.defaultCalendarForNewReminders()?.source
    }

    private func code(_ error: Error) -> String {
        let value = error as NSError
        return "\(value.domain) \(value.code)"
    }
}
