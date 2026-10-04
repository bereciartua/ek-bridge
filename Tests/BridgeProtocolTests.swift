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
        precondition(BridgeProtocol.sessionIsActive(now: 9, expiresAt: 10,
            uptime: 99, expiresUptime: 100))
        precondition(!BridgeProtocol.sessionIsActive(now: 10, expiresAt: 10,
            uptime: 99, expiresUptime: 100))
        precondition(!BridgeProtocol.sessionIsActive(now: 9, expiresAt: 10,
            uptime: 100, expiresUptime: 100))
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
            "idempotencyKey": UUID().uuidString,
        ]), scope: scope) == "writes_disabled")
        var armed = scope
        armed.writesArmed = true
        precondition(CommandPolicy.validate(request(.createEvent, [
            "calendarID": "approved", "title": "Test", "start": 1000, "end": 2000,
            "idempotencyKey": UUID().uuidString,
        ]), scope: armed) == nil)
        precondition(CommandPolicy.validate(request(.createEvent, [
            "calendarID": "approved", "title": "Test", "start": 1000, "end": 2000,
            "idempotencyKey": UUID().uuidString, "recurrence": "daily"
        ]), scope: armed) != nil)
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
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("eventkit-journal-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let key = UUID().uuidString
        let write = request(.createReminder, [
            "listID": "approved-list", "title": "Test", "idempotencyKey": key
        ])
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
        print("Bridge protocol/policy/journal: 39 positive/negative checks passed")
    }
}
