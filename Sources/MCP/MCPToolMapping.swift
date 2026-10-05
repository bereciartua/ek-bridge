import Foundation

/// A tool call the mapping refused. `message` is the agent-facing detail, e.g.
/// `start: expected an ISO 8601 date-time …`; AgentOutcomeText adds label and code.
struct MCPToolFailure: Error, Equatable {
    let code: String
    let message: String
}

// Pure MCP ⇄ core translation (plan §9.3–9.6). One tool call builds exactly one
// BridgeRequest; one core result becomes one CallToolResult. Arguments have
// already passed MCPToolCatalog's schema check, but nothing here trusts that.
enum MCPToolMapping {
    static let maxResultBytes = 200_000
    static let defaultLimit = 50

    static func request(tool: String, arguments: [String: Any], zone: TimeZone,
                        now: Date) -> Result<BridgeRequest, MCPToolFailure> {
        do throws(MCPToolFailure) {
            let (command, parameters) = try build(tool, Arguments(values: arguments, path: ""),
                                                  zone: zone, now: now)
            return .success(BridgeRequest(id: UUID().uuidString.lowercased(), command: command,
                                          parameters: parameters))
        } catch {
            return .failure(error)
        }
    }

    static func toolResult(tool: String, request: BridgeRequest?, core: [String: Any],
                           zone: TimeZone, now: Date) -> [String: Any] {
        if let code = core["error"] as? String {
            return errorResult(tool: tool, code: code, detail: nil, request: request,
                               retryAfter: integer(core["retryAfter"]))
        }
        guard let structured = structured(tool, request?.parameters ?? [:], core,
                                          zone: zone, now: now),
              let data = try? JSONSerialization.data(
                  withJSONObject: structured, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else {
            return errorResult(tool: tool, code: "unexpected_result", detail: nil,
                               request: request, retryAfter: nil)
        }
        guard data.count <= maxResultBytes else {
            return errorResult(tool: tool, code: "response_too_large", detail: nil,
                               request: request, retryAfter: nil)
        }
        return ["content": [["type": "text", "text": text]], "structuredContent": structured,
                "isError": false]
    }

    static func errorResult(tool: String, code: String, detail: String?, request: BridgeRequest?,
                            retryAfter: Int?) -> [String: Any] {
        let key = request.flatMap { $0.command.isWrite ? $0.parameters["idempotencyKey"] as? String : nil }
        let text = AgentOutcomeText.text(code: code, tool: tool, detail: detail,
                                         retryAfter: retryAfter, idempotencyKey: key)
        return ["content": [["type": "text", "text": text]], "isError": true]
    }

    // MARK: - Arguments → core parameters

    private static func build(_ tool: String, _ a: Arguments, zone: TimeZone,
                              now: Date) throws(MCPToolFailure) -> (BridgeCommand, [String: Any]) {
        switch tool {
        case "list_collections":
            try a.only([])
            return (.listCollections, [:])
        case "read_events":
            try a.only(["calendar_id", "start", "end", "limit"])
            let calendarID = try a.required("calendar_id")
            let (start, end) = try timedRange(a, zone: zone, maxDays: 31)
            return (.readEvents, ["calendarID": calendarID, "start": start, "end": end,
                                  "limit": try limit(a)])
        case "create_event":
            try a.only(["calendar_id", "title", "start", "end", "all_day", "start_date", "end_date",
                        "time_zone", "notes", "idempotency_key"])
            var p: [String: Any] = ["calendarID": try a.required("calendar_id"),
                                    "title": try title(a)]
            let eventZone = try timeZone(a, "time_zone", default: zone)
            if try a.bool("all_day") == true {
                for key in ["start", "end"] where a.has(key) {
                    throw invalid("\(key): not used for an all-day event; "
                        + "pass start_date and end_date (inclusive) instead")
                }
                let (start, end) = try allDayRange(a, zone: eventZone)
                // Any of allDay/timeZone/notes makes the core treat it as all-day.
                p["start"] = start
                p["end"] = end
                p["allDay"] = true
                p["timeZone"] = try coreZone(eventZone, field: "time_zone")
                if let notes = try a.string("notes") {
                    guard !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw invalid("notes: must not be blank; leave it out instead")
                    }
                    p["notes"] = notes
                }
            } else {
                for key in ["start_date", "end_date"] where a.has(key) {
                    throw invalid("\(key): only for all-day events; pass all_day true, "
                        + "or use start and end for a timed event")
                }
                if a.has("notes") { throw invalid("notes: only supported on all-day events (all_day true)") }
                let (start, end) = try timedRange(a, zone: eventZone, maxDays: 7, missing:
                    " for a timed event (or pass all_day true with start_date)")
                p["start"] = start
                p["end"] = end
            }
            p["idempotencyKey"] = try idempotencyKey(a, now: now)
            return (.createEvent, p)
        case "update_event":
            try a.only(["calendar_id", "event_id", "version", "title", "start", "end",
                        "idempotency_key"])
            var p = try itemTarget(a, collection: "calendar_id", item: "event_id")
            p["title"] = try title(a)
            let (start, end) = try timedRange(a, zone: zone, maxDays: 7)
            p["start"] = start
            p["end"] = end
            p["idempotencyKey"] = try idempotencyKey(a, now: now)
            return (.updateEvent, p)
        case "delete_event":
            try a.only(["calendar_id", "event_id", "version", "idempotency_key"])
            var p = try itemTarget(a, collection: "calendar_id", item: "event_id")
            p["idempotencyKey"] = try idempotencyKey(a, now: now)
            return (.deleteEvent, p)
        case "read_reminders":
            try a.only(["list_id", "limit", "cursor"])
            var p: [String: Any] = ["listID": try a.required("list_id"), "limit": try limit(a)]
            if let cursor = try a.string("cursor") { p["afterID"] = try identifier(cursor, "cursor", 512) }
            return (.readReminders, p)
        case "create_reminder":
            try a.only(["list_id", "title", "due", "alarm", "recurrence", "idempotency_key"])
            var p: [String: Any] = ["listID": try a.required("list_id"), "title": try title(a)]
            p.merge(try schedule(a, creating: true, zone: zone)) { _, new in new }
            p["idempotencyKey"] = try idempotencyKey(a, now: now)
            return (.createReminder, p)
        case "update_reminder":
            try a.only(["list_id", "reminder_id", "version", "title", "due", "alarm", "recurrence",
                        "idempotency_key"])
            var p = try itemTarget(a, collection: "list_id", item: "reminder_id")
            p["title"] = try title(a)
            p.merge(try schedule(a, creating: false, zone: zone)) { _, new in new }
            p["idempotencyKey"] = try idempotencyKey(a, now: now)
            return (.updateReminder, p)
        case "complete_reminder":
            try a.only(["list_id", "reminder_id", "version", "occurrence", "idempotency_key"])
            var p = try itemTarget(a, collection: "list_id", item: "reminder_id")
            if let occurrence = try a.object("occurrence") {
                try occurrence.only(["occurrence_due", "occurrence_fingerprint"])
                p["recurrenceScope"] = "occurrence"
                p["occurrenceDue"] = try instant(occurrence, "occurrence_due", zone: zone)
                let fingerprint = try occurrence.required("occurrence_fingerprint")
                guard fingerprint.utf8.count == 64,
                      fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
                else {
                    throw invalid("occurrence.occurrence_fingerprint: expected the 64-character "
                        + "value from completion_candidate, unchanged")
                }
                p["occurrenceFingerprint"] = fingerprint
            }
            p["idempotencyKey"] = try idempotencyKey(a, now: now)
            return (.completeReminder, p)
        case "delete_reminder":
            try a.only(["list_id", "reminder_id", "version", "idempotency_key"])
            var p = try itemTarget(a, collection: "list_id", item: "reminder_id")
            p["idempotencyKey"] = try idempotencyKey(a, now: now)
            return (.deleteReminder, p)
        default:
            throw invalid("unknown tool \(quoted(tool))")
        }
    }

    private static func itemTarget(_ a: Arguments, collection: String,
                                   item: String) throws(MCPToolFailure) -> [String: Any] {
        [collection == "list_id" ? "listID" : "calendarID": try a.required(collection),
         "itemID": try identifier(try a.required(item), item, 512),
         "expectedVersion": try identifier(try a.required("version"), "version", 64)]
    }

    // The core's limits for item IDs, versions and cursors.
    private static func identifier(_ value: String, _ field: String,
                                   _ maxBytes: Int) throws(MCPToolFailure) -> String {
        guard !value.isEmpty, value.utf8.count <= maxBytes else {
            throw invalid("\(field): expected the value from the latest read, unchanged")
        }
        return value
    }

    private static func title(_ a: Arguments) throws(MCPToolFailure) -> String {
        let title = try a.required("title")
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw invalid("title: must not be blank")
        }
        return title
    }

    private static func limit(_ a: Arguments) throws(MCPToolFailure) -> Int {
        guard let limit = try a.integer("limit") else { return defaultLimit }
        guard (1...100).contains(limit) else { throw invalid("limit: expected 1 to 100; got \(limit)") }
        return limit
    }

    // Absent → a fresh key. Present → used as is or refused: a mangled key on a
    // retry must never silently become a second write (§9.4).
    private static func idempotencyKey(_ a: Arguments, now: Date) throws(MCPToolFailure) -> String {
        guard a.has("idempotency_key") else {
            return WriteIdempotencyKey.make(now: now.timeIntervalSince1970)
        }
        let value = a.values["idempotency_key"]
        guard let key = value as? String, WriteIdempotencyKey.timestamp(key) != nil else {
            throw MCPToolFailure(code: "invalid_idempotency_key", message: "idempotency_key: expected "
                + "the exact key an earlier result returned, like ekb3_1791216000_…; got "
                + ((value as? String).map(quoted) ?? "a non-string"))
        }
        return key
    }

    private static func timedRange(_ a: Arguments, zone: TimeZone, maxDays: Int,
                                   missing: String = "") throws(MCPToolFailure) -> (Int, Int) {
        for key in ["start", "end"] where !a.has(key) { throw invalid("\(key): required\(missing)") }
        let start = try instant(a, "start", zone: zone)
        let end = try instant(a, "end", zone: zone)
        guard end > start else { throw invalid("end: must be after start") }
        guard end - start <= maxDays * 86_400 else {
            throw invalid("end: must be at most \(maxDays) days after start")
        }
        return (start, end)
    }

    private static func allDayRange(_ a: Arguments,
                                    zone: TimeZone) throws(MCPToolFailure) -> (Int, Int) {
        guard let startDate = try a.string("start_date") else {
            throw invalid("start_date: required for an all-day event, like 2026-10-06")
        }
        let endDate = try a.string("end_date")
        switch MCPTime.allDayRange(startDate: startDate, endDate: endDate, zone: zone) {
        case .success(let range):
            return range
        case .failure(.allDayEndBeforeStart):
            throw invalid("end_date: must be on or after start_date")
        case .failure(let error):
            let field: String
            switch error {
            case .invalidDate(let text), .outOfRange(let text), .dateOutOfRange(let text):
                field = text == startDate ? "start_date" : "end_date"
            default: field = "end_date"
            }
            throw MCPToolFailure(code: error.code, message: "\(field): \(error.message)")
        }
    }

    // The due date, its alarm and the repeat rule (§9.3 cross-field rules, §9.4 rows).
    private static func schedule(_ a: Arguments, creating: Bool,
                                 zone: TimeZone) throws(MCPToolFailure) -> [String: Any] {
        var p = [String: Any]()
        let alarm = try a.string("alarm")
        var dueZone = zone
        var dueForm: String?
        if let due = try a.object("due") {
            try due.only(["date", "date_time", "time_zone", "none"])
            let forms = ["date", "date_time", "none"].filter(due.has)
            guard forms.count == 1, let form = forms.first else {
                throw invalid("due: expected exactly one of date, date_time or none")
            }
            dueForm = form
            if form == "none" {
                guard try due.bool("none") == true else { throw invalid("due.none: expected true") }
                guard !creating else {
                    throw invalid("due: {\"none\": true} only works in update_reminder; "
                        + "leave out due for a reminder without a due date")
                }
                if due.has("time_zone") { throw invalid("due.time_zone: not used with none") }
                if alarm != nil {
                    throw invalid("alarm: not used when removing the due date; leave it out")
                }
                p["due"] = ["kind": "none"]
            } else {
                dueZone = try timeZone(due, "time_zone", default: zone)
                var spec: [String: Any] = ["timeZone": try coreZone(dueZone, field: "due.time_zone")]
                if form == "date" {
                    let date = try due.required("date")
                    guard MCPTime.date(date) != nil else {
                        throw invalid("due.date: \(MCPTimeError.invalidDate(date).message)")
                    }
                    spec["kind"] = "all_day"
                    spec["date"] = date
                } else {
                    let at = try instant(due, "date_time", zone: dueZone)
                    try checkWallClock(at, zone: dueZone)
                    spec["kind"] = "timed"
                    spec["at"] = at
                }
                switch alarm {
                case nil:
                    break  // Core default: at the due time for a timed due, none for a day.
                case "at_due":
                    guard form == "date_time" else {
                        throw invalid("alarm: at_due needs a due time (due.date_time); for a due "
                            + "day use none or an ISO 8601 date-time")
                    }
                case "none":
                    spec["alarmAt"] = NSNull()
                case let text?:
                    switch MCPTime.instant(text, zone: dueZone) {
                    case .success(let at):
                        spec["alarmAt"] = at
                    case .failure(.invalidDateTime):
                        throw invalid("alarm: expected at_due, none, or an ISO 8601 date-time "
                            + "with an offset, like 2026-10-06T09:00:00-04:00; got \(quoted(text))")
                    case .failure(let error):
                        throw MCPToolFailure(code: error.code, message: "alarm: \(error.message)")
                    }
                }
                p["due"] = spec
            }
        } else if alarm != nil {
            throw invalid("alarm: only together with due; send due as well"
                + (creating ? "" : " (the current one, if it isn't changing)"))
        }
        if let recurrence = try a.object("recurrence") {
            if recurrence.has("none") {
                guard try recurrence.bool("none") == true, recurrence.values.count == 1 else {
                    throw invalid("recurrence: {\"none\": true} can't be combined with other fields")
                }
                guard !creating else {
                    throw invalid("recurrence: {\"none\": true} only works in update_reminder; "
                        + "leave out recurrence for a reminder that doesn't repeat")
                }
                p["recurrence"] = ["kind": "none"]
            } else {
                guard dueForm != "none" else {
                    throw invalid("recurrence: a repeating reminder needs a due date; "
                        + "don't combine it with due {\"none\": true}")
                }
                guard !creating || dueForm != nil else {
                    throw invalid("recurrence: a repeating reminder needs due (date or date_time)")
                }
                p["recurrence"] = try rule(recurrence, zone: dueZone)
            }
        }
        return p
    }

    private static func rule(_ r: Arguments, zone: TimeZone) throws(MCPToolFailure) -> [String: Any] {
        try r.only(["frequency", "interval", "weekdays", "day_of_month", "end_count", "end_until"])
        let frequencies = ["daily", "weekly", "monthly", "yearly"]
        guard let frequency = try r.string("frequency"), frequencies.contains(frequency) else {
            throw invalid("recurrence.frequency: expected daily, weekly, monthly or yearly")
        }
        let interval = try r.integer("interval") ?? 1
        guard (1...366).contains(interval) else {
            throw invalid("recurrence.interval: expected 1 to 366; got \(interval)")
        }
        var rule: [String: Any] = ["kind": "rule", "frequency": frequency, "interval": interval]
        if let weekdays = try r.strings("weekdays") {
            guard frequency == "weekly" else { throw invalid("recurrence.weekdays: only for weekly rules") }
            let codes = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]
            guard !weekdays.isEmpty, Set(weekdays).count == weekdays.count,
                  weekdays.allSatisfy(codes.contains) else {
                throw invalid("recurrence.weekdays: expected distinct codes from MO, TU, WE, TH, FR, SA, SU")
            }
            rule["weekdays"] = weekdays
        }
        if let day = try r.integer("day_of_month") {
            guard frequency == "monthly" else {
                throw invalid("recurrence.day_of_month: only for monthly rules")
            }
            guard (1...31).contains(day) else {
                throw invalid("recurrence.day_of_month: expected 1 to 31; got \(day)")
            }
            rule["dayOfMonth"] = day
        }
        let count = try r.integer("end_count")
        guard count == nil || !r.has("end_until") else {
            throw invalid("recurrence: pass end_count or end_until, not both")
        }
        if let count {
            guard (1...10_000).contains(count) else {
                throw invalid("recurrence.end_count: expected 1 to 10000; got \(count)")
            }
            rule["end"] = ["kind": "count", "count": count]
        } else if r.has("end_until") {
            rule["end"] = ["kind": "until", "at": try instant(r, "end_until", zone: zone)]
        }
        return rule
    }

    // Reminders store a timed due as wall-clock time in its zone, so the second
    // pass through a DST fold can't be saved exactly (the core would refuse it).
    private static func checkWallClock(_ at: Int, zone: TimeZone) throws(MCPToolFailure) {
        let local = String(MCPTime.format(Double(at), zone: zone).prefix(19))
        if case .failure(.ambiguousLocalTime(_, _, let offsets, let instants)) =
            MCPTime.instant(local, zone: zone), instants.first != at {
            throw invalid("due.date_time: \(local) happens twice in \(zone.identifier), and a "
                + "reminder keeps only the wall-clock time, so only the first one "
                + "(\(offsets.first ?? "")) can be saved. Use a different time")
        }
    }

    private static func instant(_ a: Arguments, _ key: String,
                                zone: TimeZone) throws(MCPToolFailure) -> Int {
        let text = try a.required(key)
        switch MCPTime.instant(text, zone: zone) {
        case .success(let seconds): return seconds
        case .failure(let error):
            throw MCPToolFailure(code: error.code, message: "\(a.path)\(key): \(error.message)")
        }
    }

    private static func timeZone(_ a: Arguments, _ key: String,
                                 default fallback: TimeZone) throws(MCPToolFailure) -> TimeZone {
        guard let id = try a.string(key) else { return fallback }
        guard let zone = MCPTime.zone(id) else {
            throw invalid("\(a.path)\(key): \(MCPTimeError.invalidTimeZone(id).message)")
        }
        return zone
    }

    private static func coreZone(_ zone: TimeZone, field: String) throws(MCPToolFailure) -> String {
        guard let id = MCPTime.coreIdentifier(zone) else {
            throw invalid("\(field): the Mac's time zone (\(zone.identifier)) isn't one "
                + "\(AppIdentity.displayName) accepts; pass \(field.split(separator: ".").last!) "
                + "as an IANA name like America/New_York")
        }
        return id
    }

    private static func invalid(_ message: String) -> MCPToolFailure {
        MCPToolFailure(code: "invalid_arguments", message: message)
    }

    // Agent input is echoed back, so keep it short.
    private static func quoted(_ text: String) -> String {
        "\"\(text.count > 64 ? String(text.prefix(64)) + "…" : text)\""
    }

    /// One level of tool arguments. Wrong JSON types become invalid_arguments.
    private struct Arguments {
        let values: [String: Any]
        let path: String

        func has(_ key: String) -> Bool { values[key] != nil }

        func only(_ allowed: Set<String>) throws(MCPToolFailure) {
            if let extra = values.keys.sorted().first(where: { !allowed.contains($0) }) {
                throw invalid("\(path)\(extra): unknown argument")
            }
        }

        func string(_ key: String) throws(MCPToolFailure) -> String? {
            guard let value = values[key] else { return nil }
            guard let text = value as? String else { throw wrongType(key, "a string") }
            return text
        }

        func required(_ key: String) throws(MCPToolFailure) -> String {
            guard let text = try string(key) else { throw invalid("\(path)\(key): required") }
            return text
        }

        func integer(_ key: String) throws(MCPToolFailure) -> Int? {
            guard let value = values[key] else { return nil }
            guard let number = MCPToolMapping.integer(value) else { throw wrongType(key, "an integer") }
            return number
        }

        func bool(_ key: String) throws(MCPToolFailure) -> Bool? {
            guard let value = values[key] else { return nil }
            guard let flag = MCPToolMapping.bool(value) else { throw wrongType(key, "true or false") }
            return flag
        }

        func object(_ key: String) throws(MCPToolFailure) -> Arguments? {
            guard let value = values[key] else { return nil }
            guard let object = value as? [String: Any] else { throw wrongType(key, "an object") }
            return Arguments(values: object, path: "\(path)\(key).")
        }

        func strings(_ key: String) throws(MCPToolFailure) -> [String]? {
            guard let value = values[key] else { return nil }
            guard let list = value as? [Any], let texts = list as? [String] else {
                throw wrongType(key, "an array of strings")
            }
            return texts
        }

        private func wrongType(_ key: String, _ expected: String) -> MCPToolFailure {
            invalid("\(path)\(key): expected \(expected)")
        }
    }

    // MARK: - Core results → structuredContent (§9.5)

    private static func structured(_ tool: String, _ p: [String: Any], _ core: [String: Any],
                                   zone: TimeZone, now: Date) -> [String: Any]? {
        let key = p["idempotencyKey"] as? String
        var result: [String: Any]
        switch tool {
        case "list_collections":
            return collections(core, zone: zone, now: now)
        case "read_events":
            guard let calendarID = p["calendarID"] as? String,
                  let items = core["items"] as? [[String: Any]] else { return nil }
            let events = items.compactMap { eventRow($0, zone: zone) }
            guard events.count == items.count else { return nil }
            return ["calendar_id": calendarID, "events": events]
        case "read_reminders":
            guard let listID = p["listID"] as? String,
                  let items = core["items"] as? [[String: Any]] else { return nil }
            let reminders = items.compactMap { reminderRow($0, zone: zone) }
            guard reminders.count == items.count else { return nil }
            return ["list_id": listID, "reminders": reminders,
                    "next_cursor": core["nextCursor"] as? String ?? NSNull()]
        case "create_event", "update_event":
            guard let calendarID = p["calendarID"] as? String, let key,
                  let item = core["item"] as? [String: Any],
                  let event = eventReceipt(item, p, zone: zone) else { return nil }
            result = ["calendar_id": calendarID, "event": event, "idempotency_key": key]
        case "create_reminder", "update_reminder", "complete_reminder":
            guard let listID = p["listID"] as? String, let key else { return nil }
            result = ["list_id": listID, "idempotency_key": key]
            if let item = core["item"] as? [String: Any] {
                guard let reminder = reminderRow(item, zone: zone) else { return nil }
                result["reminder"] = reminder
            } else {
                // A repeating completion: the completed copy and the series' next occurrence.
                guard let completed = (core["completedOccurrence"] as? [String: Any])
                        .flatMap({ reminderRow($0, zone: zone) }),
                      let next = (core["nextOccurrence"] as? [String: Any])
                        .flatMap({ reminderRow($0, zone: zone) }) else { return nil }
                result["reminder"] = completed
                result["next_occurrence"] = next
            }
        case "delete_event", "delete_reminder":
            guard let key, bool(core["deleted"]) == true else { return nil }
            result = ["deleted": true, "idempotency_key": key]
        default:
            return nil
        }
        if bool(core["repeated"]) == true { result["repeated"] = true }
        return result
    }

    private static func collections(_ core: [String: Any], zone: TimeZone,
                                    now: Date) -> [String: Any]? {
        guard let rows = core["collections"] as? [[String: Any]] else { return nil }
        let bits = [("read", 1), ("create", 2), ("edit", 4), ("delete", 8), ("complete", 16)]
        var calendars = [[String: Any]](), lists = [[String: Any]]()
        for row in rows {
            guard let id = row["id"] as? String, let mask = integer(row["mask"]) else { return nil }
            let entry: [String: Any] = [
                "id": id, "name": row["name"] as? String ?? NSNull(),
                "account": row["account"] as? String ?? NSNull(),
                "available": bool(row["available"]) ?? false,
                "writable": bool(row["writable"]) ?? false,
                "actions": bits.filter { mask & $0.1 != 0 }.map(\.0),
            ]
            switch row["resource"] as? String {
            case "calendar": calendars.append(entry)
            case "reminderList": lists.append(entry)
            default: return nil
            }
        }
        let states: Set = ["full", "not_determined", "denied", "write_only", "restricted"]
        func access(_ value: Any?) -> String {
            (value as? String).flatMap { states.contains($0) ? $0 : nil } ?? "denied"
        }
        return ["now": MCPTime.format(now.timeIntervalSince1970, zone: zone),
                "time_zone": zone.identifier, "calendars": calendars, "reminder_lists": lists,
                "macos_access": ["calendars": access(core["calendarsAccess"]),
                                 "reminders": access(core["remindersAccess"])]]
    }

    private static func eventRow(_ row: [String: Any], zone: TimeZone) -> [String: Any]? {
        guard let id = row["id"] as? String, let title = row["title"] as? String,
              let start = number(row["start"]), let end = number(row["end"]) else { return nil }
        let eventZone = row["timeZone"] as? String ?? ""
        let allDay = bool(row["allDay"]) ?? false
        let recurring = bool(row["recurring"]) ?? false
        let hasAttendees = bool(row["hasAttendees"]) ?? false
        var event: [String: Any] = [
            "id": id, "title": title, "start": MCPTime.format(start, zone: zone),
            "end": MCPTime.format(end, zone: zone), "all_day": allDay, "recurring": recurring,
            "time_zone": eventZone.isEmpty ? NSNull() : eventZone,
            "editable": !recurring && !allDay && !hasAttendees && !eventZone.isEmpty,
        ]
        if let version = row["version"] as? String { event["version"] = version }
        if let truncated = bool(row["titleTruncated"]) { event["title_truncated"] = truncated }
        if allDay {
            let dates = MCPTime.allDayDates(start: start, end: end,
                                            zone: TimeZone(identifier: eventZone) ?? zone)
            event["start_date"] = dates.startDate
            event["end_date"] = dates.endDate
        }
        return event
    }

    private static func eventReceipt(_ item: [String: Any], _ p: [String: Any],
                                     zone: TimeZone) -> [String: Any]? {
        guard let id = item["id"] as? String else { return nil }
        var event: [String: Any] = ["id": id]
        if let version = item["version"] as? String { event["version"] = version }
        if bool(item["allDayVerified"]) == true, let start = number(item["start"]),
           let end = number(item["end"]) {
            let allDayZone = (p["timeZone"] as? String).flatMap(TimeZone.init(identifier:)) ?? zone
            let dates = MCPTime.allDayDates(start: start, end: end, zone: allDayZone)
            event["start_date"] = dates.startDate
            event["end_date"] = dates.endDate
            event["verified"] = true
        } else if p["allDay"] == nil, let start = number(p["start"]), let end = number(p["end"]) {
            // Timed writes save exactly the requested instants.
            event["start"] = MCPTime.format(start, zone: zone)
            event["end"] = MCPTime.format(end, zone: zone)
        }
        return event
    }

    private static func reminderRow(_ row: [String: Any], zone: TimeZone) -> [String: Any]? {
        guard let id = row["id"] as? String, let title = row["title"] as? String else { return nil }
        var reminder: [String: Any] = [
            "id": id, "title": title,
            "completed": bool(row["completed"]) ?? false,
            "recurring": bool(row["recurring"]) ?? false,
            "due": due(row["due"], zone: zone),
            "recurrence": recurrence(row["recurrence"], zone: zone),
            "alarms": (row["alarms"] as? [[String: Any]] ?? []).compactMap { alarm($0, zone: zone) },
        ]
        if let version = row["version"] as? String { reminder["version"] = version }
        if let truncated = bool(row["titleTruncated"]) { reminder["title_truncated"] = truncated }
        if bool(row["alarmsTruncated"]) == true { reminder["alarms_truncated"] = true }
        if let candidate = row["completionCandidate"] as? [String: Any],
           let at = number(candidate["occurrenceDue"]),
           let fingerprint = candidate["occurrenceFingerprint"] as? String {
            reminder["completion_candidate"] = ["occurrence_due": MCPTime.format(at, zone: zone),
                                                "occurrence_fingerprint": fingerprint]
        }
        return reminder
    }

    private static func due(_ value: Any?, zone: TimeZone) -> Any {
        guard let due = value as? [String: Any], let kind = due["kind"] as? String else { return NSNull() }
        let dueZone: Any = due["timeZone"] as? String ?? NSNull()
        switch (kind, due["date"] as? String, number(due["at"]), wallClock(due["local"])) {
        case ("all_day", let date?, _, _):
            return ["date": date, "time_zone": dueZone]
        case ("floating_all_day", let date?, _, _):
            return ["date": date, "time_zone": NSNull(), "floating": true]
        case ("timed", _, let at?, _):
            return ["date_time": MCPTime.format(at, zone: zone), "time_zone": dueZone]
        case ("floating_timed", _, _, let local?):
            return ["date_time": local, "time_zone": NSNull(), "floating": true]
        default:
            return ["supported": false, "time_zone": dueZone]
        }
    }

    // The core's `local` is YYYY-MM-DDTHH:MM:SS; anything else is unsupported.
    private static func wallClock(_ value: Any?) -> String? {
        guard let text = value as? String, text.utf8.count == 19 else { return nil }
        let parts = text.split(whereSeparator: { !$0.isASCII || !$0.isNumber }).compactMap { Int($0) }
        guard parts.count == 6 else { return nil }
        let local = MCPTime.formatFloating(year: parts[0], month: parts[1], day: parts[2],
                                           hour: parts[3], minute: parts[4], second: parts[5])
        return local == text ? local : nil
    }

    private static func recurrence(_ value: Any?, zone: TimeZone) -> Any {
        guard let rule = value as? [String: Any], rule["kind"] as? String != "none" else { return NSNull() }
        guard rule["kind"] as? String == "rule", bool(rule["supported"]) == true,
              let frequency = rule["frequency"] as? String,
              let interval = integer(rule["interval"]) else { return ["supported": false] }
        var result: [String: Any] = ["frequency": frequency, "interval": interval, "supported": true]
        if let weekdays = rule["weekdays"] as? [String] { result["weekdays"] = weekdays }
        if let day = integer(rule["dayOfMonth"]) { result["day_of_month"] = day }
        if let end = rule["end"] as? [String: Any] {
            if let count = integer(end["count"]) {
                result["end_count"] = count
            } else if let at = number(end["at"]) {
                result["end_until"] = MCPTime.format(at, zone: zone)
            }
        }
        return result
    }

    private static func alarm(_ row: [String: Any], zone: TimeZone) -> [String: Any]? {
        switch row["kind"] as? String {
        case "absolute":
            return number(row["at"]).map { ["at": MCPTime.format($0, zone: zone)] }
        case "relative":
            // Core offsets are seconds relative to the due time, negative before it.
            guard let offset = number(row["offset"]) else { return nil }
            let minutes = -offset / 60
            let whole = minutes.rounded() == minutes && abs(minutes) < 1e15
            return ["minutes_before_due": whole ? Int(minutes) as Any : minutes as Any]
        default:
            return nil
        }
    }

    // MARK: - JSON values

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = number(value), number.rounded() == number else { return nil }
        return Int(exactly: number)
    }

    private static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }
}
