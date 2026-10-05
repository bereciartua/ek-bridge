import Foundation

@main
struct BridgeProtocolTests {
    static func main() throws {
        let id = UUID().uuidString
        let token = String(repeating: "a", count: 64)
        let now = Date().timeIntervalSince1970

        func message(
            command: String = "calendar_count",
            suppliedToken: String? = nil,
            issuedAt: Any? = nil,
            extra: Bool = false,
            omitParameters: Bool = false,
            version: Any = 1,
            parameters: [String: Any] = [:]
        ) throws -> Data {
            var object: [String: Any] = [
                "version": version,
                "id": id,
                "command": command,
                "token": suppliedToken ?? token,
                "issuedAt": issuedAt ?? now,
                "parameters": parameters,
            ]
            if omitParameters { object.removeValue(forKey: "parameters") }
            if extra { object["unapproved"] = true }
            return try JSONSerialization.data(withJSONObject: object)
        }

        func expect(_ result: Result<BridgeRequest, BridgeRequestError>,
                    command: BridgeCommand? = nil,
                    error: BridgeRequestError? = nil) {
            switch result {
            case .success(let request):
                precondition(error == nil && request.id == id && request.command == command)
            case .failure(let failure):
                precondition(command == nil && failure.rawValue == error?.rawValue)
            }
        }

        expect(BridgeProtocol.validate(try message(), token: token, now: now, usedIDs: []),
               command: .calendarCount)
        expect(BridgeProtocol.validate(try message(command: "scope_status"), token: token,
                                       now: now, usedIDs: []), command: .scopeStatus)
        expect(BridgeProtocol.validate(try message(suppliedToken: "wrong"), token: token,
                                       now: now, usedIDs: []), error: .unauthorized)
        expect(BridgeProtocol.validate(try message(command: "unlisted_command"), token: token,
                                       now: now, usedIDs: []), error: .invalid)
        expect(BridgeProtocol.validate(try message(issuedAt: now - 31), token: token,
                                       now: now, usedIDs: []), error: .expired)
        expect(BridgeProtocol.validate(try message(issuedAt: now + 6), token: token,
                                       now: now, usedIDs: []), error: .expired)
        expect(BridgeProtocol.validate(try message(), token: token,
                                       now: now, usedIDs: [id]), error: .replay)
        expect(BridgeProtocol.validate(try message(extra: true), token: token,
                                       now: now, usedIDs: []), error: .invalid)
        expect(BridgeProtocol.validate(try message(omitParameters: true), token: token,
                                       now: now, usedIDs: []), error: .invalid)
        expect(BridgeProtocol.validate(try message(version: true), token: token,
                                       now: now, usedIDs: []), error: .invalid)
        expect(BridgeProtocol.validate(try message(issuedAt: true), token: token,
                                       now: now, usedIDs: []), error: .invalid)
        expect(BridgeProtocol.validate(Data(repeating: 65, count: 8_193), token: token,
                                       now: now, usedIDs: []), error: .tooLarge)
        let scope = BridgeScope(calendarID: "approved", reminderListID: "approved-list")
        func request(_ command: BridgeCommand, _ parameters: [String: Any]) -> BridgeRequest {
            BridgeRequest(id: id, command: command, parameters: parameters)
        }
        precondition(CommandPolicy.validate(request(.readEvents, [
            "calendarID": "approved", "start": 1000, "end": 2000, "limit": 10
        ]), scope: scope) == nil)
        precondition(CommandPolicy.validate(request(.readEvents, [
            "calendarID": "other", "start": 1000, "end": 2000, "limit": 10
        ]), scope: scope) != nil)
        precondition(CommandPolicy.validate(request(.readEvents, [
            "calendarID": "approved", "start": 1000, "end": 1000 + 32 * 86_400, "limit": 10
        ]), scope: scope) != nil)
        precondition(CommandPolicy.validate(request(.readEvents, [
            "calendarID": "approved", "start": 1e100, "end": 1e100 + 1000, "limit": 10
        ]), scope: scope) != nil)
        precondition(CommandPolicy.validate(request(.readReminders, [
            "listID": "approved-list", "limit": 101
        ]), scope: scope) != nil)
        precondition(CommandPolicy.validate(request(.readReminders, [
            "listID": "approved-list", "limit": 10, "afterID": "cursor"
        ]), scope: scope) == nil)
        precondition(CommandPolicy.validate(request(.readReminders, [
            "listID": "approved-list", "limit": 10, "afterID": ""
        ]), scope: scope) != nil)
        precondition(CommandPolicy.scopeStillSelected(id: "approved-list", generation: 0,
            scope: scope, reminders: true))
        var cleared = scope
        cleared.reminderListID = nil
        cleared.generation += 1
        precondition(!CommandPolicy.scopeStillSelected(id: "approved-list", generation: 0,
            scope: cleared, reminders: true))
        cleared.reminderListID = "approved-list"
        precondition(!CommandPolicy.scopeStillSelected(id: "approved-list", generation: 0,
            scope: cleared, reminders: true))
        precondition(CommandPolicy.validate(request(.createEvent, [
            "calendarID": "approved", "title": "Test", "start": 1000, "end": 2000,
            "idempotencyKey": WriteIdempotencyKey.make(),
        ]), scope: scope) == nil)
        precondition(CommandPolicy.validate(request(.createEvent, [
            "calendarID": "other", "title": "Test", "start": 1000, "end": 2000,
            "idempotencyKey": WriteIdempotencyKey.make(),
        ]), scope: scope) != nil)
        precondition(CommandPolicy.validate(request(.createEvent, [
            "calendarID": "approved", "title": "Test", "start": 1000, "end": 2000,
            "idempotencyKey": UUID().uuidString,
        ]), scope: scope) != nil)
        precondition(CommandPolicy.validate(request(.createEvent, [
            "calendarID": "approved", "title": "Test", "start": 1000, "end": 2000,
            "idempotencyKey": WriteIdempotencyKey.make(), "recurrence": "daily"
        ]), scope: scope) != nil)
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        let allDayStart = ny.date(from: DateComponents(year: 2026, month: 10, day: 14))!.timeIntervalSince1970
        let allDayEnd = ny.date(from: DateComponents(year: 2026, month: 10, day: 16))!.timeIntervalSince1970
        let allDay: [String: Any] = [
            "calendarID": "approved", "title": "Synthetic all-day test", "start": allDayStart,
            "end": allDayEnd, "allDay": true, "timeZone": "America/New_York",
            "notes": "Source: https://example.test/", "idempotencyKey": WriteIdempotencyKey.make(),
        ]
        precondition(CommandPolicy.validate(request(.createEvent, allDay), scope: scope) == nil)
        var invalidAllDay = allDay
        invalidAllDay["start"] = allDayStart + 3600
        precondition(CommandPolicy.validate(request(.createEvent, invalidAllDay), scope: scope) != nil)
        invalidAllDay = allDay
        invalidAllDay["timeZone"] = "Invalid/Zone"
        precondition(CommandPolicy.validate(request(.createEvent, invalidAllDay), scope: scope) != nil)
        invalidAllDay = allDay
        invalidAllDay["notes"] = String(repeating: "x", count: 2_001)
        precondition(CommandPolicy.validate(request(.createEvent, invalidAllDay), scope: scope) != nil)
        invalidAllDay = allDay
        invalidAllDay["allDay"] = false
        precondition(CommandPolicy.validate(request(.createEvent, invalidAllDay), scope: scope) != nil)
        precondition(MutationPolicy.eventError(recurring: true, allDay: false,
            hasAttendees: false, floatingTime: false, updating: true) == "recurrence_unsupported")
        precondition(MutationPolicy.eventError(recurring: false, allDay: true,
            hasAttendees: false, floatingTime: false, updating: true) ==
            "all_day_or_attendees_unsupported")
        precondition(MutationPolicy.eventError(recurring: false, allDay: false,
            hasAttendees: true, floatingTime: false, updating: false) ==
            "all_day_or_attendees_unsupported")
        precondition(MutationPolicy.eventError(recurring: false, allDay: false,
            hasAttendees: false, floatingTime: true, updating: true) ==
            "floating_time_unsupported")
        precondition(MutationPolicy.reminderError(recurring: false, completed: true,
            completing: true) == "already_completed")
        precondition(MutationPolicy.reminderError(recurring: true, completed: false,
            completing: true) == "recurrence_scope_required")
        precondition(MutationPolicy.reminderError(recurring: true, completed: false,
            completing: false, recurrenceScope: .occurrence) == "recurrence_unsupported")
        precondition(MutationPolicy.reminderError(recurring: true, completed: false,
            completing: false, recurrenceScope: .series) == "recurrence_unsupported")
        precondition(MutationPolicy.reminderError(recurring: false, completed: false,
            completing: false, recurrenceScope: .series) == "recurrence_scope_not_applicable")
        let recurringAction: [String: Any] = [
            "listID": "approved-list", "itemID": "item", "expectedVersion": "version",
            "idempotencyKey": WriteIdempotencyKey.make(), "recurrenceScope": "occurrence",
        ]
        precondition(CommandPolicy.validate(request(.completeReminder, recurringAction),
                                            scope: scope) == nil)
        var invalidScope = recurringAction
        invalidScope["recurrenceScope"] = "all"
        precondition(CommandPolicy.validate(request(.deleteReminder, invalidScope),
                                            scope: scope) != nil)
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("eventkit-journal-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let key = WriteIdempotencyKey.make()
        let write = request(.createReminder, [
            "listID": "approved-list", "title": "Test", "idempotencyKey": key
        ])
        let due: [String: Any] = ["kind": "timed", "at": 1_893_456_000,
                                   "timeZone": "America/New_York"]
        let repeatRule: [String: Any] = ["kind": "rule", "frequency": "daily", "interval": 1]
        let scheduled = request(.createReminder, [
            "listID": "approved-list", "title": "Scheduled", "idempotencyKey":
                WriteIdempotencyKey.make(), "due": due, "recurrence": repeatRule,
        ])
        precondition(CommandPolicy.validate(scheduled, scope: scope) == nil)
        precondition(CommandPolicy.validate(request(.createReminder, [
            "listID": "approved-list", "title": "No anchor", "idempotencyKey":
                WriteIdempotencyKey.make(), "recurrence": repeatRule,
        ]), scope: scope) != nil)
        precondition(CommandPolicy.validate(request(.updateReminder, [
            "listID": "approved-list", "itemID": "synthetic", "expectedVersion": "1",
            "title": "Changed", "idempotencyKey": WriteIdempotencyKey.make(),
            "due": ["kind": "none"], "recurrence": ["kind": "none"],
        ]), scope: scope) == nil)
        precondition(CommandPolicy.validate(request(.updateReminder, [
            "listID": "approved-list", "itemID": "synthetic", "expectedVersion": "1",
            "title": "Changed", "idempotencyKey": WriteIdempotencyKey.make(),
            "recurrence": ["kind": "rule", "frequency": "weekly", "interval": 0],
        ]), scope: scope) != nil)
        let first = WriteJournal(directory: temporary)
        guard case .execute = first.inspect(write) else { preconditionFailure("inspect") }
        let stillEmpty = WriteJournal(directory: temporary)
        guard case .execute = stillEmpty.inspect(write) else { preconditionFailure("inspect did not reserve") }
        guard case .execute = first.begin(write) else { preconditionFailure("first write") }
        let afterRestart = WriteJournal(directory: temporary)
        guard case .reject("idempotency_pending_review") = afterRestart.begin(write)
        else { preconditionFailure("pending after restart") }
        precondition(first.finish(write, result: ["item": ["id": "example"]]))
        let completed = WriteJournal(directory: temporary)
        guard case .repeatResult(let cached) = completed.begin(write),
              let item = cached["item"] as? [String: String], item["id"] == "example"
        else { preconditionFailure("completed after restart") }
        let changed = request(.createReminder, [
            "listID": "approved-list", "title": "Changed", "idempotencyKey": key
        ])
        guard case .reject("idempotency_conflict") = completed.begin(changed)
        else { preconditionFailure("key reuse with changed payload") }
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("eventkit-journal-target-\(UUID().uuidString)")
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("eventkit-journal-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: target)
        }
        guard case .reject("journal_unavailable") = WriteJournal(directory: link).begin(write)
        else { preconditionFailure("symlink journal directory") }
        print("Bridge protocol/policy/journal: 40 positive/negative checks passed")
    }
}
