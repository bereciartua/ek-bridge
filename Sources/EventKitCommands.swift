import EventKit
import Foundation

// The EventKit side of every item command. Events are in EventCommands.swift
// and reminders in ReminderCommands.swift; this file dispatches and holds what
// they share (lookups, versions, the write journal).
@MainActor
final class EventKitCommands: BridgeCommandExecutor {
    let store: EKEventStore
    let journal: WriteJournal

    init(store: EKEventStore, journal: WriteJournal = WriteJournal()) {
        self.store = store
        self.journal = journal
    }

    func runAuthorized(_ request: BridgeRequest, clientID: String, selected: BridgeScope,
                       stillAuthorized: @escaping () -> Bool, isCancelled: @escaping () -> Bool,
                       completion: @escaping ([String: Any]) -> Void) {
        run(Call(request: request, clientID: clientID, isCancelled: isCancelled, selected: selected,
                 stillAuthorized: stillAuthorized),
            completion: completion)
    }

    struct Call {
        let request: BridgeRequest
        let clientID: String
        let isCancelled: () -> Bool
        let selected: BridgeScope
        let stillAuthorized: () -> Bool

        var p: [String: Any] { request.parameters }
    }

    private func run(_ call: Call, completion: @escaping ([String: Any]) -> Void) {
        let request = call.request
        let selected = call.selected
        guard call.stillAuthorized() else { completion(["error": "scope_changed"]); return }
        if let error = CommandPolicy.validate(request, scope: selected) {
            completion(["error": error])
            return
        }
        let command = request.command
        let entity: EKEntityType = Self.targetsReminders(command) ? .reminder : .event
        if command != .authorizationStatus && command != .scopeStatus && command != .listCollections,
           EKEventStore.authorizationStatus(for: entity) != .fullAccess {
            completion(["error": "full_access_required"])
            return
        }
        if command.isWrite {
            switch journal.inspect(request, clientID: call.clientID) {
            case .execute: break
            case .repeatResult(let result): completion(Self.repeated(result)); return
            case .reject(let error): completion(["error": error]); return
            }
        }
        switch command {
        case .listCollections:
            // Answered by the request pipeline, which knows the client's grants.
            completion(["error": "invalid_request"])
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
        case .readEvents: readEvents(call, completion)
        case .getEvent: getEvent(call, completion)
        case .createEvent: createEvent(call, completion)
        case .updateEvent, .deleteEvent: changeEvent(call, completion)
        case .readReminders: readReminders(call, completion)
        case .getReminder: getReminder(call, completion)
        case .createReminder: createReminder(call, completion)
        case .updateReminder, .completeReminder, .deleteReminder: changeReminder(call, completion)
        }
    }

    static func targetsReminders(_ command: BridgeCommand) -> Bool {
        switch command {
        case .readReminders, .getReminder, .createReminder, .updateReminder, .completeReminder,
             .deleteReminder, .reminderListCount: true
        default: false
        }
    }

    // MARK: Shared helpers

    func calendar(_ value: Any?, _ type: EKEntityType) -> EKCalendar? {
        guard let id = value as? String else { return nil }
        return store.calendars(for: type).first { $0.calendarIdentifier == id }
    }

    func writableCalendar(_ value: Any?, _ type: EKEntityType) -> EKCalendar? {
        guard let calendar = calendar(value, type), calendar.allowsContentModifications else { return nil }
        return calendar
    }

    /// A move target: writable, in the same account as `source` (§13).
    func moveTarget(_ value: Any?, _ type: EKEntityType, from source: EKCalendar) -> Result<EKCalendar, FieldError> {
        guard let target = writableCalendar(value, type) else { return .failure(FieldError("target_not_writable")) }
        guard target.source?.sourceIdentifier == source.source?.sourceIdentifier else {
            return .failure(FieldError("move_across_accounts_unsupported"))
        }
        return .success(target)
    }

    func boundedTitle(_ value: String?) -> (String, Bool) {
        let (text, truncated) = ItemText.prefix(value ?? "", maxBytes: 200)
        return (text, truncated)
    }

    func version(_ date: Date?) -> String? {
        date.map { String(format: "%.6f", $0.timeIntervalSince1970) }
    }

    func matchesVersion(_ date: Date?, _ expected: Any?) -> Bool {
        guard let current = version(date), let expected = expected as? String else { return false }
        return current == expected
    }

    func seconds(_ date: Date?) -> Any {
        date.map { $0.timeIntervalSince1970 as Any } ?? NSNull()
    }

    func finishWrite(_ result: [String: Any], _ request: BridgeRequest,
                     _ completion: ([String: Any]) -> Void) {
        completion(journal.finish(request, result: result)
                   ? result : ["error": "write_committed_journal_pending_review"])
    }

    func reserveWrite(_ call: Call, _ completion: ([String: Any]) -> Void) -> Bool {
        if call.isCancelled() { completion(["error": "cancelled"]); return false }
        switch journal.begin(call.request, clientID: call.clientID) {
        case .execute: return true
        case .repeatResult(let result): completion(Self.repeated(result)); return false
        case .reject(let error): completion(["error": error]); return false
        }
    }

    /// A journal replay: the recorded result, marked so the caller knows the
    /// write wasn't done twice.
    static func repeated(_ result: [String: Any]) -> [String: Any] {
        result.merging(["repeated": true]) { _, new in new }
    }

    /// Stops adding list rows once they pass this many bytes (§16).
    static let rowBudget = 180_000

    static func rowSize(_ row: [String: Any]) -> Int {
        (try? JSONSerialization.data(withJSONObject: row))?.count ?? rowBudget
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

/// macOS access and collections for the request pipeline.
@MainActor
final class EventKitCollectionSource: CollectionSource {
    private let store: EKEventStore

    init(store: EKEventStore) { self.store = store }

    func access(_ resource: ClientResource) -> String {
        switch EKEventStore.authorizationStatus(for: Self.type(resource)) {
        case .fullAccess: "full"
        case .notDetermined: "not_determined"
        case .writeOnly: "write_only"
        case .restricted: "restricted"
        case .denied: "denied"
        @unknown default: "denied"
        }
    }

    func collections(_ resource: ClientResource) -> [CollectionRecord]? {
        let type = Self.type(resource)
        guard EKEventStore.authorizationStatus(for: type) == .fullAccess else { return nil }
        return store.calendars(for: type).map {
            CollectionRecord(id: $0.calendarIdentifier, name: $0.title, account: $0.source.title,
                             writable: $0.allowsContentModifications,
                             availabilities: resource == .calendar
                                ? EventAvailabilityMapping.supported($0).map(\.rawValue).sorted() : nil)
        }
    }

    private static func type(_ resource: ClientResource) -> EKEntityType {
        resource == .calendar ? .event : .reminder
    }
}
