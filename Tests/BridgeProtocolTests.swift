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
        expect(BridgeProtocol.validate(Data(repeating: 65, count: 32_769), token: token,
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
        invalidAllDay["notes"] = String(repeating: "x", count: 8_001)
        precondition(CommandPolicy.validate(request(.createEvent, invalidAllDay), scope: scope) == "notes_too_long")
        invalidAllDay["notes"] = String(repeating: "x", count: 8_000)
        precondition(CommandPolicy.validate(request(.createEvent, invalidAllDay), scope: scope) == nil)
        // allDay false is a timed event; two days is within the 31-day limit.
        invalidAllDay = allDay
        invalidAllDay["allDay"] = false
        precondition(CommandPolicy.validate(request(.createEvent, invalidAllDay), scope: scope) == nil)
        func eventError(attendees: Bool = false, recurring: Bool = false, occurrence: Bool = false,
                        span: EventSpan? = nil, rule: Bool = false, moving: Bool = false) -> String? {
            MutationPolicy.eventError(hasAttendees: attendees, recurring: recurring, occurrenceGiven: occurrence,
                                      span: span, changesRecurrence: rule, moving: moving)
        }
        precondition(eventError() == nil && eventError(span: .this) == nil && eventError(rule: true) == nil)
        precondition(eventError(attendees: true) == "invitation_read_only")
        precondition(eventError(attendees: true, recurring: true, occurrence: true) == "invitation_read_only")
        precondition(eventError(recurring: true) == "occurrence_required")
        precondition(eventError(recurring: true, occurrence: true) == nil)
        precondition(eventError(recurring: true, occurrence: true, rule: true) == "recurrence_span_invalid")
        precondition(eventError(recurring: true, occurrence: true, span: .future, rule: true) == nil)
        precondition(eventError(recurring: true, occurrence: true, span: .future, moving: true)
                     == "recurrence_span_invalid")
        precondition(eventError(recurring: true, occurrence: true, span: .all, moving: true) == nil)
        precondition(eventError(span: .future) == "span_not_applicable")
        precondition(eventError(span: .all) == "span_not_applicable")
        precondition(MutationPolicy.reminderError(recurring: false, completed: true,
            completing: true) == "already_completed")
        precondition(MutationPolicy.reminderError(recurring: true, completed: false,
            completing: true) == "recurrence_scope_required")
        precondition(MutationPolicy.reminderError(recurring: true, completed: false,
            completing: false, recurrenceScope: .occurrence) == "recurrence_scope_required")
        precondition(MutationPolicy.reminderError(recurring: true, completed: false,
            completing: false) == "recurrence_scope_required")
        precondition(MutationPolicy.reminderError(recurring: true, completed: false,
            completing: true, recurrenceScope: .occurrence) == nil)
        precondition(MutationPolicy.reminderError(recurring: true, completed: true,
            completing: true, recurrenceScope: .occurrence) == "already_completed")
        precondition(MutationPolicy.reminderError(recurring: true, completed: false,
            completing: true, recurrenceScope: .series) == "recurrence_series_unsupported")
        precondition(MutationPolicy.reminderError(recurring: true, completed: false,
            completing: false, recurrenceScope: .series) == nil)
        precondition(MutationPolicy.reminderError(recurring: false, completed: false,
            completing: false, recurrenceScope: .series) == "recurrence_scope_not_applicable")
        let recurringAction: [String: Any] = [
            "listID": "approved-list", "itemID": "item", "expectedVersion": "version",
            "idempotencyKey": WriteIdempotencyKey.make(), "recurrenceScope": "occurrence",
            "occurrenceDue": 1_893_456_000,
            "occurrenceFingerprint": String(repeating: "a", count: 64),
        ]
        precondition(CommandPolicy.validate(request(.completeReminder, recurringAction),
                                            scope: scope) == nil)
        var invalidScope = recurringAction
        invalidScope["recurrenceScope"] = "all"
        precondition(CommandPolicy.validate(request(.deleteReminder, invalidScope),
                                            scope: scope) != nil)
        var missingDue = recurringAction
        missingDue.removeValue(forKey: "occurrenceDue")
        precondition(CommandPolicy.validate(request(.completeReminder, missingDue),
                                            scope: scope) != nil)
        var invalidDue = recurringAction
        invalidDue["occurrenceDue"] = true
        precondition(CommandPolicy.validate(request(.completeReminder, invalidDue),
                                            scope: scope) != nil)
        var invalidFingerprint = recurringAction
        invalidFingerprint["occurrenceFingerprint"] = String(repeating: "A", count: 64)
        precondition(CommandPolicy.validate(request(.completeReminder, invalidFingerprint),
                                            scope: scope) != nil)
        var seriesWithOccurrence = recurringAction
        seriesWithOccurrence["recurrenceScope"] = "series"
        precondition(CommandPolicy.validate(request(.completeReminder, seriesWithOccurrence),
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

        // list_collections: no parameters, client-level, read-only.
        let listing = BridgeCommand.listCollections
        precondition(listing.rawValue == "list_collections")
        precondition(listing.parameterKeys.isEmpty && listing.parameterKeys == CommandParameterKeys(
            required: [], optional: []))
        precondition(listing.isClientLevel && !listing.isWrite)
        precondition(listing.acceptsKeys(of: [:]) && !listing.acceptsKeys(of: ["calendarID": "approved"]))
        precondition(CommandPolicy.validate(request(.listCollections, [:]), scope: BridgeScope()) == nil)
        precondition(CommandPolicy.validate(request(.listCollections, [:]), scope: scope) == nil)
        for extra in [["calendarID": "approved"], ["listID": "approved-list"], ["limit": 5],
                      ["anything": NSNull()]] as [[String: Any]] {
            precondition(CommandPolicy.validate(request(.listCollections, extra), scope: scope)
                         == "invalid_parameters")
        }
        let listingWire = try message(command: "list_collections")
        precondition(BridgeProtocol.validate(listingWire, token: token, now: now, usedIDs: [])
                     .map(\.command) == .success(.listCollections))
        precondition(BridgeCommand.allCases.filter(\.isClientLevel) == [
            .authorizationStatus, .calendarCount, .reminderListCount, .scopeStatus, .listCollections])

        // A one-day all-day event on the day Santiago's clocks skip midnight
        // (2026-09-06 starts at 01:00 -03:00 and is 23 hours long).
        let santiagoStart = 1_788_667_200.0
        let santiagoEnd = 1_788_750_000.0
        precondition(santiagoEnd - santiagoStart == 23 * 3_600)
        var santiago: [String: Any] = [
            "calendarID": "approved", "title": "Synthetic Santiago day", "start": santiagoStart,
            "end": santiagoEnd, "allDay": true, "timeZone": "America/Santiago",
            "idempotencyKey": WriteIdempotencyKey.make(),
        ]
        let chileZone = TimeZone(identifier: "America/Santiago")!
        precondition(EventFields.allDayLength(start: santiagoStart, end: santiagoEnd, zone: chileZone) == 1)
        precondition(CommandPolicy.validate(request(.createEvent, santiago), scope: scope) == nil)
        var chile = Calendar(identifier: .gregorian)
        chile.timeZone = chileZone
        let lastDay = chile.date(from: DateComponents(year: 2027, month: 9, day: 7))!
        let tooLong = chile.date(from: DateComponents(year: 2027, month: 9, day: 8))!
        precondition(chile.startOfDay(for: lastDay) == lastDay && chile.startOfDay(for: tooLong) == tooLong)
        santiago["end"] = lastDay.timeIntervalSince1970
        precondition(CommandPolicy.validate(request(.createEvent, santiago), scope: scope) == nil,
                     "366 days is the maximum")
        santiago["end"] = tooLong.timeIntervalSince1970
        precondition(CommandPolicy.validate(request(.createEvent, santiago), scope: scope) != nil, "367 days")
        santiago["end"] = santiagoStart
        precondition(CommandPolicy.validate(request(.createEvent, santiago), scope: scope) != nil, "0 days")
        santiago["start"] = santiagoStart - 3_600 // the nominal midnight that doesn't exist
        santiago["end"] = santiagoEnd
        precondition(CommandPolicy.validate(request(.createEvent, santiago), scope: scope) != nil,
                     "not the start of the day")
        let fieldChecks = try plan03(scope: scope, request: request, journal: temporary)
        print("Bridge protocol/policy/journal: 40 positive/negative checks, list_collections, Santiago all-day "
              + "and \(fieldChecks) plan 03 field checks passed")
    }

    /// Plan 03: every new key, absent/null/value, and limits at boundary ± 1 byte.
    static func plan03(scope: BridgeScope, request: (BridgeCommand, [String: Any]) -> BridgeRequest,
                       journal directory: URL) throws -> Int {
        var checks = 0
        func expect(_ command: BridgeCommand, _ parameters: [String: Any], _ code: String?,
                    scope given: BridgeScope? = nil, _ line: Int = #line) {
            let result = CommandPolicy.validate(request(command, parameters), scope: given ?? scope)
            precondition(result == code, "line \(line): expected \(code ?? "nil"), got \(result ?? "nil")")
            checks += 1
        }
        let key = { WriteIdempotencyKey.make() }
        let timed: [String: Any] = ["calendarID": "approved", "title": "Timed", "start": 1_000_000,
                                    "end": 1_003_600, "idempotencyKey": key()]
        expect(.createEvent, timed, nil)
        expect(.createEvent, timed.merging(["timeZone": "Europe/Madrid"]) { _, new in new }, nil)
        expect(.createEvent, timed.merging(["timeZone": "Mars/Base"]) { _, new in new }, "invalid_parameters_or_target")
        expect(.createEvent, timed.merging(["end": 1_000_000 + 31 * 86_400]) { _, new in new }, nil)
        expect(.createEvent, timed.merging(["end": 1_000_001 + 31 * 86_400]) { _, new in new },
               "invalid_parameters_or_target")
        // Text limits at the boundary.
        for (field, limit, code) in [("notes", 8_000, "notes_too_long"), ("location", 500, "location_too_long")] {
            expect(.createEvent, timed.merging([field: String(repeating: "é", count: limit / 2)]) { _, new in new }, nil)
            expect(.createEvent, timed.merging([field: String(repeating: "é", count: limit / 2) + "x"]) { _, new in new },
                   code)
        }
        expect(.createEvent, timed.merging(["notes": "a\u{0000}b"]) { _, new in new }, "invalid_notes")
        expect(.createEvent, timed.merging(["notes": "tab\tand\r\nnewline"]) { _, new in new }, nil)
        expect(.createEvent, timed.merging(["notes": "bell\u{0007}"]) { _, new in new }, "invalid_notes")
        expect(.createEvent, timed.merging(["notes": NSNull()]) { _, new in new }, "invalid_notes")
        expect(.createEvent, timed.merging(["location": "two\nlines"]) { _, new in new }, "invalid_location")
        let longURL = "https://example.com/" + String(repeating: "a", count: 2_048 - 20)
        precondition(longURL.utf8.count == 2_048)
        expect(.createEvent, timed.merging(["url": longURL]) { _, new in new }, nil)
        expect(.createEvent, timed.merging(["url": longURL + "a"]) { _, new in new }, "invalid_url")
        for (url, code) in [("https://example.com/a?b=c#d", nil), ("mailto:ana@example.com", nil),
                            ("tel:+15555550100", nil), ("javascript:alert(1)", "url_scheme_not_allowed"),
                            ("file:///etc/passwd", "url_scheme_not_allowed"), ("https://", "invalid_url"),
                            ("https://exa mple.com", "invalid_url"), ("not a url", "invalid_url"),
                            ("https://example.com/é", "invalid_url")] as [(String, String?)] {
            expect(.createEvent, timed.merging(["url": url]) { _, new in new }, code)
        }
        let place: [String: Any] = ["title": "Office", "latitude": 40.75, "longitude": -73.99, "radius": 150]
        expect(.createEvent, timed.merging(["structuredLocation": place]) { _, new in new }, nil)
        for bad in [["latitude": 90.5], ["longitude": -181], ["radius": 0], ["radius": 100_001], ["title": ""],
                    ["extra": 1]] as [[String: Any]] {
            expect(.createEvent, timed.merging(["structuredLocation": place.merging(bad) { _, new in new }])
                   { _, new in new }, "invalid_location")
        }
        let alarms: [[String: Any]] = [["kind": "relative", "offset": -900], ["kind": "absolute", "at": 4_000_000_000],
                                       ["kind": "location", "location": place, "proximity": "arrive"]]
        expect(.createEvent, timed.merging(["alarms": alarms]) { _, new in new }, nil)
        expect(.createEvent, timed.merging(["alarms": Array(repeating: ["kind": "relative", "offset": -60], count: 1)
            + (1...5).map { ["kind": "relative", "offset": -60 * ($0 + 1)] }]) { _, new in new }, "invalid_alarms")
        expect(.createEvent, timed.merging(["alarms": [alarms[0], alarms[0]]]) { _, new in new }, "invalid_alarms")
        expect(.createEvent, timed.merging(["alarms": [["kind": "relative", "offset": -40_320 * 60 - 60]]])
               { _, new in new }, "invalid_alarms")
        expect(.createEvent, timed.merging(["alarms": [["kind": "relative", "offset": 86_400]]]) { _, new in new }, nil)
        expect(.createEvent, timed.merging(["availability": "free"]) { _, new in new }, nil)
        expect(.createEvent, timed.merging(["availability": "away"]) { _, new in new }, "invalid_parameters_or_target")
        let weekly: [String: Any] = ["kind": "rule", "frequency": "monthly", "weekdays": ["2TU"],
                                     "end": ["kind": "count", "count": 10]]
        expect(.createEvent, timed.merging(["recurrence": weekly]) { _, new in new }, nil)
        expect(.createEvent, timed.merging(["recurrence": ["kind": "none"]]) { _, new in new }, "invalid_recurrence")
        expect(.createEvent, timed.merging(["recurrence": ["kind": "rule", "frequency": "weekly",
                                                            "weekdays": ["2TU"]]]) { _, new in new },
               "invalid_recurrence")
        expect(.createEvent, timed.merging(["span": "all"]) { _, new in new }, "invalid_parameters_or_target")

        // Partial updates: absent keeps, null clears, at least one field.
        let target: [String: Any] = ["calendarID": "approved", "itemID": "E1", "expectedVersion": "1",
                                     "idempotencyKey": key()]
        expect(.updateEvent, target, "nothing_to_change")
        expect(.updateEvent, target.merging(["span": "all", "occurrenceStart": 1_000_000]) { _, new in new },
               "nothing_to_change")
        expect(.updateEvent, target.merging(["title": "Only the title"]) { _, new in new }, nil)
        expect(.updateEvent, target.merging(["start": 1_000_000]) { _, new in new }, nil)
        for field in ["notes", "location", "structuredLocation", "url", "alarms", "availability"] {
            expect(.updateEvent, target.merging([field: NSNull()]) { _, new in new }, nil)
        }
        for field in ["title", "start", "end", "allDay", "timeZone", "recurrence"] {
            expect(.updateEvent, target.merging([field: NSNull()]) { _, new in new }, field == "recurrence"
                   ? "invalid_recurrence" : "invalid_parameters_or_target")
        }
        expect(.updateEvent, target.merging(["notes": "  "]) { _, new in new }, nil)
        expect(.updateEvent, target.merging(["recurrence": ["kind": "none"], "span": "future",
                                             "occurrenceStart": 1_000_000]) { _, new in new }, nil)
        expect(.updateEvent, target.merging(["title": "x", "span": "sometimes"]) { _, new in new },
               "invalid_parameters_or_target")
        expect(.updateEvent, target.merging(["start": 2_000, "end": 1_000]) { _, new in new },
               "invalid_parameters_or_target")
        // A move needs the destination in the scope (Create checked by the registry).
        expect(.updateEvent, target.merging(["targetCalendarID": "elsewhere"]) { _, new in new },
               "invalid_parameters_or_target")
        var moving = scope
        moving.moveTargetID = "elsewhere"
        expect(.updateEvent, target.merging(["targetCalendarID": "elsewhere"]) { _, new in new }, nil, scope: moving)
        expect(.updateEvent, target.merging(["targetCalendarID": "approved", "title": "x"]) { _, new in new }, nil)
        expect(.deleteEvent, target, nil)
        expect(.deleteEvent, target.merging(["occurrenceStart": 1_000_000, "span": "future"]) { _, new in new }, nil)
        expect(.deleteEvent, target.merging(["span": "most"]) { _, new in new }, "invalid_parameters_or_target")
        expect(.deleteEvent, target.merging(["title": "x"]) { _, new in new }, "invalid_parameters_or_target")

        // Reads.
        expect(.getEvent, ["calendarID": "approved", "itemID": "E1"], nil)
        expect(.getEvent, ["calendarID": "approved", "itemID": "E1", "occurrenceStart": 1_000_000], nil)
        expect(.getEvent, ["calendarID": "other", "itemID": "E1"], "invalid_parameters_or_target")
        expect(.getReminder, ["listID": "approved-list", "itemID": "R1"], nil)
        expect(.getReminder, ["listID": "approved-list"], "invalid_parameters_or_target")
        let reads: [String: Any] = ["calendarID": "approved", "start": 1000, "end": 2000, "limit": 10]
        expect(.readEvents, reads.merging(["afterKey": "v1:1000:0:E1"]) { _, new in new }, nil)
        expect(.readEvents, reads.merging(["afterKey": "page 2"]) { _, new in new }, "invalid_parameters_or_target")
        let list: [String: Any] = ["listID": "approved-list", "limit": 10]
        for status in ["incomplete", "completed", "all"] {
            expect(.readReminders, list.merging(["status": status]) { _, new in new }, nil)
        }
        expect(.readReminders, list.merging(["status": "done"]) { _, new in new }, "invalid_parameters_or_target")
        expect(.readReminders, list.merging(["dueAfter": 1000, "dueBefore": 2000]) { _, new in new }, nil)
        expect(.readReminders, list.merging(["dueAfter": 2000, "dueBefore": 2000]) { _, new in new },
               "invalid_parameters_or_target")

        // Reminders.
        let reminder: [String: Any] = ["listID": "approved-list", "title": "R", "idempotencyKey": key()]
        expect(.createReminder, reminder.merging(["notes": "n", "url": "https://example.com",
                                                  "priority": "high", "alarms": [alarms[1]]]) { _, new in new }, nil)
        // EKReminder ignores location text, so the key isn't accepted.
        expect(.createReminder, reminder.merging(["location": "Home"]) { _, new in new }, "invalid_parameters_or_target")
        expect(.createReminder, reminder.merging(["priority": "urgent"]) { _, new in new }, "invalid_parameters_or_target")
        expect(.createReminder, reminder.merging(["completed": true]) { _, new in new }, "invalid_parameters_or_target")
        let due: [String: Any] = ["kind": "timed", "at": 4_000_000_000, "timeZone": "UTC"]
        expect(.createReminder, reminder.merging(["due": due, "start": due]) { _, new in new }, nil)
        expect(.createReminder, reminder.merging(["due": due.merging(["alarmAt": 4_000_000_000]) { _, new in new },
                                                  "alarms": [alarms[1]]]) { _, new in new }, "invalid_alarms")
        expect(.createReminder, reminder.merging(["start": due.merging(["alarmAt": 4_000_000_000]) { _, new in new }])
               { _, new in new }, "invalid_schedule")
        let item: [String: Any] = ["listID": "approved-list", "itemID": "R1", "expectedVersion": "1",
                                   "idempotencyKey": key()]
        expect(.updateReminder, item, "nothing_to_change")
        expect(.updateReminder, item.merging(["completed": false]) { _, new in new }, nil)
        expect(.updateReminder, item.merging(["start": NSNull(), "notes": NSNull(), "url": NSNull(),
                                              "alarms": NSNull()]) { _, new in new }, nil)
        expect(.updateReminder, item.merging(["priority": NSNull()]) { _, new in new }, "invalid_parameters_or_target")
        expect(.updateReminder, item.merging(["targetListID": "other-list"]) { _, new in new },
               "invalid_parameters_or_target")
        var listMove = scope
        listMove.moveTargetID = "other-list"
        expect(.updateReminder, item.merging(["targetListID": "other-list"]) { _, new in new }, nil, scope: listMove)
        expect(.deleteReminder, item.merging(["recurrenceScope": "series"]) { _, new in new }, nil)

        // Every key the commands take is listed once, for bridge-client --help.
        for command in BridgeCommand.allCases {
            let keys = command.parameterKeys.required + command.parameterKeys.optional
            precondition(Set(keys).count == keys.count, "\(command.rawValue) repeats a key")
        }
        precondition(BridgeCommand.getEvent.parameterKeys == CommandParameterKeys(
            required: ["calendarID", "itemID"], optional: ["occurrenceStart"]))
        precondition(!BridgeCommand.getEvent.isWrite && !BridgeCommand.getReminder.isWrite)

        // Two keys can't delete the same occurrence; a different span or occurrence is a new request.
        let journal = WriteJournal(directory: directory.appendingPathComponent("plan03"))
        let delete = target.merging(["occurrenceStart": 1_000_000, "span": "this"]) { _, new in new }
        let first = request(.deleteEvent, delete)
        guard case .execute = journal.begin(first) else { preconditionFailure("first delete") }
        precondition(journal.finish(first, result: ["deleted": true]))
        let again = request(.deleteEvent, delete.merging(["idempotencyKey": key()]) { _, new in new })
        guard case .reject("already_applied") = journal.begin(again) else { preconditionFailure("second delete") }
        let later = request(.deleteEvent, delete.merging(["idempotencyKey": key(), "occurrenceStart": 1_086_400])
                            { _, new in new })
        guard case .execute = journal.begin(later) else { preconditionFailure("another occurrence") }
        precondition(journal.finish(later, result: ["error": "save_failed"]))
        let retry = request(.deleteEvent, delete.merging(["idempotencyKey": key(), "occurrenceStart": 1_086_400])
                            { _, new in new })
        guard case .execute = journal.begin(retry) else { preconditionFailure("a failed delete doesn't block a retry") }
        checks += 4
        return checks
    }
}
