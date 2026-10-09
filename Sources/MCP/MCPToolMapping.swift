import Foundation

/// A tool call the mapping refused. `message` is the agent-facing detail, e.g.
/// `start: expected an ISO 8601 date-time …`; AgentOutcomeText adds label and code.
struct MCPToolFailure: Error, Equatable {
    let code: String
    let message: String
}

// Pure MCP ⇄ core translation (plan 02 §9.3–9.6, plan 03 §15). One tool call
// builds exactly one BridgeRequest; one core result becomes one CallToolResult.
// Arguments have already passed MCPToolCatalog's schema check, but nothing
// here trusts that.
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
            // Only the access request's answer is passed on as a detail (C04).
            let detail = code == "forbidden" ? core["detail"] as? String : nil
            return errorResult(tool: tool, code: code, detail: detail, request: request,
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
            try a.only(["calendar_id", "start", "end", "limit", "cursor"])
            let calendarID = try a.required("calendar_id")
            let (start, end) = try timedRange(a, zone: zone, maxDays: 31)
            var p: [String: Any] = ["calendarID": calendarID, "start": start, "end": end, "limit": try limit(a)]
            if let cursor = try a.string("cursor") {
                guard cursor.utf8.count <= 600, EventPageKey(cursor: cursor) != nil else {
                    throw invalid("cursor: expected next_cursor from the previous page, unchanged")
                }
                p["afterKey"] = cursor
            }
            return (.readEvents, p)
        case "get_event":
            try a.only(["calendar_id", "event_id", "occurrence_start"])
            var p: [String: Any] = ["calendarID": try a.required("calendar_id"),
                                    "itemID": try identifier(try a.required("event_id"), "event_id", 512)]
            if a.has("occurrence_start") { p["occurrenceStart"] = try instant(a, "occurrence_start", zone: zone) }
            return (.getEvent, p)
        case "create_event":
            try a.only(["calendar_id", "title", "start", "end", "all_day", "start_date", "end_date",
                        "time_zone", "notes", "location", "structured_location", "url", "alarms",
                        "availability", "recurrence", "idempotency_key"])
            var p: [String: Any] = ["calendarID": try a.required("calendar_id"),
                                    "title": try title(a)]
            let eventZone = try timeZone(a, "time_zone", default: zone)
            if try a.bool("all_day") == true {
                for key in ["start", "end"] where a.has(key) {
                    throw invalid("\(key): not used for an all-day event; "
                        + "pass start_date and end_date (inclusive) instead")
                }
                let (start, end) = try allDayRange(a, zone: eventZone)
                p["start"] = start
                p["end"] = end
                p["allDay"] = true
            } else {
                for key in ["start_date", "end_date"] where a.has(key) {
                    throw invalid("\(key): only for all-day events; pass all_day true, "
                        + "or use start and end for a timed event")
                }
                let (start, end) = try timedRange(a, zone: eventZone, maxDays: 31, missing:
                    " for a timed event (or pass all_day true with start_date)")
                p["start"] = start
                p["end"] = end
            }
            p["timeZone"] = try coreZone(eventZone, field: "time_zone")
            try eventFields(a, into: &p, creating: true, zone: eventZone)
            p["idempotencyKey"] = try idempotencyKey(a, now: now)
            return (.createEvent, p)
        case "update_event":
            try a.only(["calendar_id", "event_id", "version", "occurrence_start", "span", "title", "start",
                        "end", "all_day", "start_date", "end_date", "time_zone", "notes", "location",
                        "structured_location", "url", "alarms", "availability", "recurrence",
                        "replace_unsupported_alarms", "target_calendar_id", "idempotency_key"])
            var p = try itemTarget(a, collection: "calendar_id", item: "event_id")
            if a.has("occurrence_start") { p["occurrenceStart"] = try instant(a, "occurrence_start", zone: zone) }
            if let span = try a.string("span") {
                guard ["this", "future", "all"].contains(span) else {
                    throw invalid("span: expected this, future or all")
                }
                p["span"] = span
            }
            if a.has("title") { p["title"] = try title(a) }
            try eventTimes(a, into: &p, zone: zone)
            try eventFields(a, into: &p, creating: false,
                            zone: try a.has("time_zone") ? timeZone(a, "time_zone", default: zone) : zone)
            if let flag = try a.bool("replace_unsupported_alarms") { p["replaceUnsupportedAlarms"] = flag }
            if let destination = try a.string("target_calendar_id") {
                p["targetCalendarID"] = try identifier(destination, "target_calendar_id", 512)
            }
            let changing = ["title", "start", "end", "all_day", "start_date", "end_date", "time_zone", "notes",
                            "location", "structured_location", "url", "alarms", "availability",
                            "recurrence", "target_calendar_id"]
            guard changing.contains(where: a.has) else {
                throw MCPToolFailure(code: "nothing_to_change", message: "send at least one field to change, "
                    + "like title, start, notes or recurrence")
            }
            p["idempotencyKey"] = try idempotencyKey(a, now: now)
            return (.updateEvent, p)
        case "delete_event":
            try a.only(["calendar_id", "event_id", "version", "occurrence_start", "span", "idempotency_key"])
            var p = try itemTarget(a, collection: "calendar_id", item: "event_id")
            if a.has("occurrence_start") { p["occurrenceStart"] = try instant(a, "occurrence_start", zone: zone) }
            if let span = try a.string("span") {
                guard ["this", "future", "all"].contains(span) else {
                    throw invalid("span: expected this, future or all")
                }
                p["span"] = span
            }
            p["idempotencyKey"] = try idempotencyKey(a, now: now)
            return (.deleteEvent, p)
        case "read_reminders":
            try a.only(["list_id", "limit", "cursor", "status", "due_after", "due_before"])
            var p: [String: Any] = ["listID": try a.required("list_id"), "limit": try limit(a)]
            if let cursor = try a.string("cursor") { p["afterID"] = try identifier(cursor, "cursor", 512) }
            let status = try a.string("status") ?? "incomplete"
            guard ["incomplete", "completed", "all"].contains(status) else {
                throw invalid("status: expected incomplete, completed or all")
            }
            p["status"] = status
            if a.has("due_after") { p["dueAfter"] = try instant(a, "due_after", zone: zone) }
            if a.has("due_before") { p["dueBefore"] = try instant(a, "due_before", zone: zone) }
            if let after = p["dueAfter"] as? Int, let before = p["dueBefore"] as? Int, before <= after {
                throw invalid("due_before: must be after due_after")
            }
            return (.readReminders, p)
        case "get_reminder":
            try a.only(["list_id", "reminder_id"])
            return (.getReminder, ["listID": try a.required("list_id"),
                                   "itemID": try identifier(try a.required("reminder_id"), "reminder_id", 512)])
        case "create_reminder":
            try reminderLocation(a)
            try a.only(["list_id", "title", "due", "start", "alarm", "alarms", "recurrence", "notes", "url",
                        "priority", "idempotency_key"])
            var p: [String: Any] = ["listID": try a.required("list_id"), "title": try title(a)]
            p.merge(try schedule(a, creating: true, zone: zone)) { _, new in new }
            try reminderFields(a, into: &p, creating: true)
            p["idempotencyKey"] = try idempotencyKey(a, now: now)
            return (.createReminder, p)
        case "update_reminder":
            try reminderLocation(a)
            try a.only(["list_id", "reminder_id", "version", "title", "due", "start", "alarm", "alarms",
                        "recurrence", "notes", "url", "priority", "completed",
                        "replace_unsupported_alarms", "target_list_id", "idempotency_key"])
            var p = try itemTarget(a, collection: "list_id", item: "reminder_id")
            if a.has("title") { p["title"] = try title(a) }
            p.merge(try schedule(a, creating: false, zone: zone)) { _, new in new }
            try reminderFields(a, into: &p, creating: false)
            if let completed = try a.bool("completed") { p["completed"] = completed }
            if let flag = try a.bool("replace_unsupported_alarms") { p["replaceUnsupportedAlarms"] = flag }
            if let destination = try a.string("target_list_id") {
                p["targetListID"] = try identifier(destination, "target_list_id", 512)
            }
            let changing = ["title", "due", "start", "alarm", "alarms", "recurrence", "notes", "url",
                            "priority", "completed", "target_list_id"]
            guard changing.contains(where: a.has) else {
                throw MCPToolFailure(code: "nothing_to_change", message: "send at least one field to change, "
                    + "like title, due, notes or completed")
            }
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
            try a.only(["list_id", "reminder_id", "version", "scope", "idempotency_key"])
            var p = try itemTarget(a, collection: "list_id", item: "reminder_id")
            if let scope = try a.string("scope") {
                guard scope == "series" else { throw invalid("scope: expected \"series\"") }
                p["recurrenceScope"] = "series"
            }
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
        guard !title.contains("\u{0000}"), title.utf8.count <= 200 else {
            throw invalid("title: at most 200 bytes, without NUL characters")
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

    // MARK: Events

    /// update_event's times: any of start/end, all-day dates (which make the
    /// event all-day), a conversion, or just a new zone (§6, §11.4).
    private static func eventTimes(_ a: Arguments, into p: inout [String: Any],
                                   zone: TimeZone) throws(MCPToolFailure) {
        let given = a.has("time_zone") ? try timeZone(a, "time_zone", default: zone) : nil
        let eventZone = given ?? zone
        let allDay = try a.bool("all_day")
        let dates = a.has("start_date") || a.has("end_date")
        if allDay == true || (allDay == nil && dates) {
            for key in ["start", "end"] where a.has(key) {
                throw invalid("\(key): not used for an all-day event; pass start_date and end_date (inclusive)")
            }
            let (start, end) = try allDayRange(a, zone: eventZone)
            p["start"] = start
            p["end"] = end
            p["allDay"] = true
            p["timeZone"] = try coreZone(eventZone, field: "time_zone")
            return
        }
        for key in ["start_date", "end_date"] where a.has(key) {
            throw invalid("\(key): only for all-day events; use start and end for a timed event")
        }
        if allDay == false {
            for key in ["start", "end"] where !a.has(key) {
                throw invalid("\(key): required to change an all-day event into a timed one")
            }
            p["allDay"] = false
        }
        if a.has("start") { p["start"] = try instant(a, "start", zone: eventZone) }
        if a.has("end") { p["end"] = try instant(a, "end", zone: eventZone) }
        if let start = p["start"] as? Int, let end = p["end"] as? Int {
            guard end > start else { throw invalid("end: must be after start") }
            guard end - start <= 31 * 86_400 else { throw invalid("end: must be at most 31 days after start") }
        }
        if let given { p["timeZone"] = try coreZone(given, field: "time_zone") }
    }

    /// Notes, location, URL, alarms, availability and recurrence of an event.
    private static func eventFields(_ a: Arguments, into p: inout [String: Any], creating: Bool,
                                    zone: TimeZone) throws(MCPToolFailure) {
        try text(a, "notes", into: &p, creating: creating) { ItemText.notes($0, present: true, creating: creating) }
        try text(a, "location", into: &p, creating: creating) {
            ItemText.location($0, present: true, creating: creating)
        }
        try text(a, "url", into: &p, creating: creating) { ItemText.url($0, present: true, creating: creating) }
        if a.has("structured_location") {
            if a.values["structured_location"] is NSNull {
                guard !creating else { throw invalid("structured_location: leave it out instead of null") }
                p["structuredLocation"] = NSNull()
            } else {
                guard let place = try a.object("structured_location") else { return }
                p["structuredLocation"] = try self.place(place, field: "structured_location")
            }
        }
        if let place = p["structuredLocation"] as? [String: Any] {
            if p["location"] is NSNull {
                throw invalid("location: can't be null while setting structured_location")
            }
            if let text = p["location"] as? String, text != place["title"] as? String {
                throw invalid("location: must be the same as structured_location.title (Calendar keeps "
                    + "one value), or leave it out")
            }
        }
        if a.has("alarms") { p["alarms"] = try alarms(a, creating: creating, zone: zone, reminders: false) }
        if a.has("availability") {
            if a.values["availability"] is NSNull {
                guard !creating else { throw invalid("availability: leave it out instead of null") }
                p["availability"] = NSNull()
            } else {
                let value = try a.required("availability")
                guard EventAvailability(rawValue: value) != nil else {
                    throw invalid("availability: expected busy, free, tentative or unavailable")
                }
                p["availability"] = value
            }
        }
        if let recurrence = try a.object("recurrence") {
            if recurrence.has("none") {
                guard try recurrence.bool("none") == true, recurrence.values.count == 1 else {
                    throw invalid("recurrence: {\"none\": true} can't be combined with other fields")
                }
                guard !creating else {
                    throw invalid("recurrence: {\"none\": true} only works in update_event; "
                        + "leave out recurrence for an event that doesn't repeat")
                }
                p["recurrence"] = ["kind": "none"]
            } else {
                p["recurrence"] = try rule(recurrence, zone: zone)
            }
        }
    }

    /// A text field through the core's own rules (§9), so a refusal here is
    /// exactly what the core would say.
    private static func text(_ a: Arguments, _ key: String, into p: inout [String: Any], creating: Bool,
                             _ check: (Any) -> Result<ItemText.Change<String>, FieldError>) throws(MCPToolFailure) {
        guard let raw = a.values[key] else { return }
        if !(raw is NSNull) { _ = try a.string(key) }
        switch check(raw) {
        case .success(.set(let value)): p[coreKey(key)] = value
        case .success(.clear): p[coreKey(key)] = NSNull()
        case .success(.keep): break
        case .failure(let error):
            switch error.code {
            case "url_scheme_not_allowed":
                throw MCPToolFailure(code: error.code, message: "\(key): only http, https, mailto and tel "
                    + "links can be written")
            case "invalid_url":
                throw MCPToolFailure(code: error.code, message: "\(key): expected a complete URL like "
                    + "https://example.com/page, with no spaces")
            case "notes_too_long", "location_too_long":
                throw invalid("\(key): too long")
            default:
                throw invalid("\(key): " + (creating && (raw is NSNull ||
                        (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true)
                    ? "must not be blank; leave it out instead"
                    : "control characters other than tab and newline aren't allowed"
                        + (key == "location" ? ", and it must be one line" : "")))
            }
        }
    }

    private static func coreKey(_ key: String) -> String {
        ["notes": "notes", "location": "location", "url": "url"][key] ?? key
    }

    private static func place(_ a: Arguments, field: String) throws(MCPToolFailure) -> [String: Any] {
        try a.only(["title", "latitude", "longitude", "radius_m"])
        var core: [String: Any] = ["title": try a.required("title")]
        for key in ["latitude", "longitude"] {
            guard let value = a.values[key] as? NSNumber, MCPToolMapping.bool(value) == nil,
                  value.doubleValue.isFinite else { throw invalid("\(field).\(key): required, a number") }
            core[key] = value.doubleValue
        }
        if let radius = a.values["radius_m"] {
            guard let value = radius as? NSNumber, MCPToolMapping.bool(value) == nil else {
                throw invalid("\(field).radius_m: expected a number of meters")
            }
            core["radius"] = value.doubleValue
        }
        guard PlaceSpec.parse(core) != nil else {
            throw invalid("\(field): expected a one-line title up to 500 bytes, latitude -90 to 90, "
                + "longitude -180 to 180 and radius_m 1 to 100000")
        }
        return core
    }

    /// The `alarms` list (§10). minutes_before counts back from an event's
    /// start or a reminder's due time.
    private static func alarms(_ a: Arguments, creating: Bool, zone: TimeZone,
                               reminders: Bool) throws(MCPToolFailure) -> Any {
        if a.values["alarms"] is NSNull {
            guard !creating else { throw invalid("alarms: leave it out instead of null") }
            return NSNull()
        }
        guard let list = a.values["alarms"] as? [Any] else { throw invalid("alarms: expected an array") }
        guard list.count <= AlarmSpec.maxCount else { throw invalid("alarms: at most 5") }
        var result = [[String: Any]]()
        for (index, item) in list.enumerated() {
            let path = "alarms[\(index)]"
            guard let object = item as? [String: Any] else { throw invalid("\(path): expected an object") }
            let alarm = Arguments(values: object, path: "\(path).")
            try alarm.only(["minutes_before", "at", "location", "proximity"])
            let forms = ["minutes_before", "at", "location"].filter(alarm.has)
            guard forms.count == 1 else {
                throw invalid("\(path): expected exactly one of minutes_before, at, or location with proximity")
            }
            switch forms[0] {
            case "minutes_before":
                if alarm.has("proximity") { throw invalid("\(path).proximity: only with location") }
                let minutes = try alarm.integer("minutes_before")!
                guard (-1_440...40_320).contains(minutes) else {
                    throw invalid("\(path).minutes_before: expected -1440 to 40320 (4 weeks)")
                }
                result.append(["kind": "relative", "offset": -minutes * 60])
            case "at":
                if alarm.has("proximity") { throw invalid("\(path).proximity: only with location") }
                result.append(["kind": "absolute", "at": try instant(alarm, "at", zone: zone)])
            default:
                guard let proximity = try alarm.string("proximity"), ["arrive", "leave"].contains(proximity)
                else { throw invalid("\(path).proximity: expected arrive or leave") }
                let place = try self.place(try alarm.object("location")!, field: "\(path).location")
                result.append(["kind": "location", "location": place, "proximity": proximity])
            }
            let parsed = result.last.flatMap(AlarmSpec.parse)
            if let parsed, result.dropLast().compactMap(AlarmSpec.parse).contains(parsed) {
                throw invalid("\(path): the same alarm appears twice")
            }
        }
        return result
    }

    // MARK: Reminders

    // The due date, its alarm and the repeat rule (§9.3 cross-field rules, §9.4 rows).
    private static func schedule(_ a: Arguments, creating: Bool,
                                 zone: TimeZone) throws(MCPToolFailure) -> [String: Any] {
        var p = [String: Any]()
        let alarm = try a.string("alarm")
        if alarm != nil && a.has("alarms") {
            throw invalid("alarm: use alarms or the older alarm, not both")
        }
        var dueZone = zone
        var dueForm: String?
        if let due = try a.object("due") {
            let (spec, form, specZone) = try dueSpec(due, field: "due", creating: creating, zone: zone)
            dueForm = form
            dueZone = specZone
            if form == "none" {
                if alarm != nil {
                    throw invalid("alarm: not used when removing the due date; leave it out")
                }
                p["due"] = spec
            } else {
                var spec = spec
                switch alarm {
                case nil:
                    break  // Core default: at the due time for a new timed due.
                case "at_due":
                    guard form == "date_time" else {
                        throw invalid("alarm: at_due needs a due time (due.date_time); for a due "
                            + "day use none or an ISO 8601 date-time")
                    }
                    spec["alarmAt"] = spec["at"]
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
        if a.has("start") {
            if a.values["start"] is NSNull {
                guard !creating else { throw invalid("start: leave it out instead of null") }
                p["start"] = NSNull()
            } else if let start = try a.object("start") {
                p["start"] = try dueSpec(start, field: "start", creating: creating, zone: zone).spec
            }
        }
        if a.has("alarms") { p["alarms"] = try alarms(a, creating: creating, zone: zone, reminders: true) }
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

    /// A due or start date: {date}, {date_time, time_zone?} or {none: true}.
    private static func dueSpec(_ due: Arguments, field: String, creating: Bool,
                                zone: TimeZone) throws(MCPToolFailure) -> (spec: [String: Any], form: String,
                                                                           zone: TimeZone) {
        try due.only(["date", "date_time", "time_zone", "none"])
        let forms = ["date", "date_time", "none"].filter(due.has)
        guard forms.count == 1, let form = forms.first else {
            throw invalid("\(field): expected exactly one of date, date_time or none")
        }
        if form == "none" {
            guard try due.bool("none") == true else { throw invalid("\(field).none: expected true") }
            guard !creating else {
                throw invalid("\(field): {\"none\": true} only works in update_reminder; "
                    + "leave out \(field) for a reminder without one")
            }
            if due.has("time_zone") { throw invalid("\(field).time_zone: not used with none") }
            return (["kind": "none"], form, zone)
        }
        let dueZone = try timeZone(due, "time_zone", default: zone)
        var spec: [String: Any] = ["timeZone": try coreZone(dueZone, field: "\(field).time_zone")]
        if form == "date" {
            let date = try due.required("date")
            guard MCPTime.date(date) != nil else {
                throw invalid("\(field).date: \(MCPTimeError.invalidDate(date).message)")
            }
            spec["kind"] = "all_day"
            spec["date"] = date
        } else {
            let at = try instant(due, "date_time", zone: dueZone)
            try checkWallClock(at, zone: dueZone, field: field)
            spec["kind"] = "timed"
            spec["at"] = at
        }
        return (spec, form, dueZone)
    }

    /// EventKit ignores a reminder's location text, so say what works instead.
    private static func reminderLocation(_ a: Arguments) throws(MCPToolFailure) {
        if a.has("location") {
            throw invalid("location: a reminder's location can't be set through EventKit; add an alarm with "
                + "location and proximity instead")
        }
    }

    private static func reminderFields(_ a: Arguments, into p: inout [String: Any],
                                       creating: Bool) throws(MCPToolFailure) {
        try text(a, "notes", into: &p, creating: creating) { ItemText.notes($0, present: true, creating: creating) }
        try text(a, "url", into: &p, creating: creating) { ItemText.url($0, present: true, creating: creating) }
        if let priority = try a.string("priority") {
            guard ReminderPriority(rawValue: priority) != nil else {
                throw invalid("priority: expected none, low, medium or high")
            }
            p["priority"] = priority
        }
    }

    /// The shared repeat rule (§7.1), with the 0.5 names as aliases.
    private static func rule(_ r: Arguments, zone: TimeZone) throws(MCPToolFailure) -> [String: Any] {
        try r.only(["frequency", "interval", "weekdays", "month_days", "months", "set_positions", "end",
                    "day_of_month", "end_count", "end_until"])
        guard let name = try r.string("frequency"), let frequency = RecurrenceSpec.Frequency(rawValue: name) else {
            throw invalid("recurrence.frequency: expected daily, weekly, monthly or yearly")
        }
        var spec = RecurrenceSpec(frequency: frequency)
        spec.interval = try r.integer("interval") ?? 1
        if let codes = try r.strings("weekdays") {
            var days = [RecurrenceSpec.Weekday]()
            for code in codes {
                guard let day = RecurrenceSpec.Weekday(code: code) else {
                    throw invalid("recurrence.weekdays: expected codes like MO, or 2TU and -1FR in monthly "
                        + "and yearly rules; got \(quoted(code))")
                }
                days.append(day)
            }
            spec.weekdays = days
        }
        spec.monthDays = try r.integers("month_days") ?? []
        if let day = try r.integer("day_of_month") {
            guard spec.monthDays.isEmpty else {
                throw invalid("recurrence: pass month_days or day_of_month, not both")
            }
            guard frequency == .monthly else { throw invalid("recurrence.day_of_month: only for monthly rules") }
            spec.monthDays = [day]
        }
        spec.months = try r.integers("months") ?? []
        spec.setPositions = try r.integers("set_positions") ?? []
        var ends = [RecurrenceSpec.End]()
        if let end = try r.object("end") {
            try end.only(["count", "until"])
            guard end.values.count == 1 else { throw invalid("recurrence.end: expected exactly one of count or until") }
            if let count = try end.integer("count") { ends.append(.count(count)) }
            if end.has("until") { ends.append(.until(try until(end, "until", zone: zone))) }
        }
        if let count = try r.integer("end_count") { ends.append(.count(count)) }
        if r.has("end_until") { ends.append(.until(try until(r, "end_until", zone: zone))) }
        guard ends.count <= 1 else { throw invalid("recurrence: give one end, a count or an until") }
        spec.end = ends.first
        if let problem = spec.problem { throw invalid("recurrence.\(problem)") }
        var core = spec.core(zone: nil)
        for key in ["supported", "rrule", "summary"] { core[key] = nil }
        return core
    }

    /// An until: a date-time, or a whole day (its last second in `zone`).
    private static func until(_ a: Arguments, _ key: String, zone: TimeZone) throws(MCPToolFailure) -> Int64 {
        let text = try a.required(key)
        if let day = MCPTime.date(text) {
            return Int64(MCPTime.startOfDay(year: day.year, month: day.month, day: day.day, zone: zone,
                                            adding: 1) - 1)
        }
        return Int64(try instant(a, key, zone: zone))
    }

    // Reminders store a timed due as wall-clock time in its zone, so the second
    // pass through a DST fold can't be saved exactly (the core would refuse it).
    private static func checkWallClock(_ at: Int, zone: TimeZone, field: String) throws(MCPToolFailure) {
        let local = String(MCPTime.format(Double(at), zone: zone).prefix(19))
        if case .failure(.ambiguousLocalTime(_, _, let offsets, let instants)) =
            MCPTime.instant(local, zone: zone), instants.first != at {
            throw invalid("\(field).date_time: \(local) happens twice in \(zone.identifier), and a "
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

        func integers(_ key: String) throws(MCPToolFailure) -> [Int]? {
            guard let value = values[key] else { return nil }
            guard let list = value as? [Any] else { throw wrongType(key, "an array of integers") }
            let numbers = list.compactMap(MCPToolMapping.integer)
            guard numbers.count == list.count else { throw wrongType(key, "an array of integers") }
            return numbers
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
            return ["calendar_id": calendarID, "events": events,
                    "truncated": bool(core["truncated"]) ?? false,
                    "next_cursor": core["nextCursor"] as? String ?? NSNull()]
        case "get_event":
            guard let calendarID = p["calendarID"] as? String,
                  let event = (core["item"] as? [String: Any]).flatMap({ eventRow($0, zone: zone) })
            else { return nil }
            return ["calendar_id": calendarID, "event": event]
        case "read_reminders":
            guard let listID = p["listID"] as? String,
                  let items = core["items"] as? [[String: Any]] else { return nil }
            let reminders = items.compactMap { reminderRow($0, zone: zone) }
            guard reminders.count == items.count else { return nil }
            return ["list_id": listID, "reminders": reminders,
                    "next_cursor": core["nextCursor"] as? String ?? NSNull()]
        case "get_reminder":
            guard let listID = p["listID"] as? String,
                  let reminder = (core["item"] as? [String: Any]).flatMap({ reminderRow($0, zone: zone) })
            else { return nil }
            return ["list_id": listID, "reminder": reminder]
        case "create_event", "update_event":
            guard let calendarID = p["calendarID"] as? String, let key,
                  let item = core["item"] as? [String: Any],
                  let event = eventReceipt(item, p, zone: zone) else { return nil }
            result = ["calendar_id": item["calendarID"] as? String ?? calendarID, "event": event,
                      "idempotency_key": key]
        case "create_reminder", "update_reminder", "complete_reminder":
            guard let listID = p["listID"] as? String, let key else { return nil }
            result = ["list_id": listID, "idempotency_key": key]
            if let item = core["item"] as? [String: Any] {
                guard let reminder = reminderRow(item, zone: zone) else { return nil }
                result["reminder"] = reminder
                if let moved = item["listID"] as? String, !moved.isEmpty { result["list_id"] = moved }
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
            var entry: [String: Any] = [
                "id": id, "name": row["name"] as? String ?? NSNull(),
                "account": row["account"] as? String ?? NSNull(),
                "available": bool(row["available"]) ?? false,
                "writable": bool(row["writable"]) ?? false,
                "actions": bits.filter { mask & $0.1 != 0 }.map(\.0),
            ]
            switch row["resource"] as? String {
            case "calendar":
                if let values = row["availabilities"] as? [String] {
                    entry["availabilities"] = values.filter { EventAvailability(rawValue: $0) != nil }
                }
                calendars.append(entry)
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

    /// Times in the event's own zone (F3); floating events in the Mac's,
    /// without an offset.
    private static func eventClock(_ seconds: Double, eventZone: TimeZone?, zone: TimeZone) -> String {
        guard let eventZone else { return String(MCPTime.format(seconds, zone: zone).prefix(19)) }
        return MCPTime.format(seconds, zone: eventZone)
    }

    private static func eventRow(_ row: [String: Any], zone: TimeZone) -> [String: Any]? {
        guard let id = row["id"] as? String, let title = row["title"] as? String,
              let start = number(row["start"]), let end = number(row["end"]) else { return nil }
        let zoneID = row["timeZone"] as? String ?? ""
        let eventZone: TimeZone? = zoneID.isEmpty ? nil : (TimeZone(identifier: zoneID) ?? zone)
        let allDay = bool(row["allDay"]) ?? false
        let recurring = bool(row["recurring"]) ?? false
        let hasAttendees = bool(row["hasAttendees"]) ?? false
        var event: [String: Any] = [
            "id": id, "title": title,
            "start": eventClock(start, eventZone: eventZone, zone: zone),
            "end": eventClock(end, eventZone: eventZone, zone: zone),
            "all_day": allDay, "recurring": recurring,
            "time_zone": zoneID.isEmpty ? NSNull() : zoneID,
            "floating": zoneID.isEmpty,
            "occurrence_start": number(row["occurrenceStart"])
                .map { eventClock($0, eventZone: eventZone, zone: zone) as Any } ?? NSNull(),
            "recurrence": recurrence(row["recurrence"], zone: eventZone ?? zone),
        ]
        if let version = row["version"] as? String { event["version"] = version }
        if let truncated = bool(row["titleTruncated"]) { event["title_truncated"] = truncated }
        if allDay {
            let dates = MCPTime.allDayDates(start: start, end: end, zone: eventZone ?? zone)
            event["start_date"] = dates.startDate
            event["end_date"] = dates.endDate
        }
        if let detached = bool(row["detached"]) { event["detached"] = detached }
        copyText(row, "notesPreview", "notes_preview", into: &event)
        copyText(row, "notes", "notes", into: &event)
        copyBool(row, "hasNotes", "has_notes", into: &event)
        copyBool(row, "notesTruncated", "notes_truncated", into: &event)
        copyText(row, "location", "location", into: &event)
        copyBool(row, "locationTruncated", "location_truncated", into: &event)
        if row.keys.contains("structuredLocation") {
            event["structured_location"] = (row["structuredLocation"] as? [String: Any]).flatMap(place) ?? NSNull()
        }
        copyText(row, "url", "url", into: &event)
        if row["url"] is String { copyBool(row, "urlSchemeAllowed", "url_scheme_allowed", into: &event) }
        if let alarms = row["alarms"] as? [[String: Any]] {
            event["alarms"] = alarms.compactMap { alarm($0, zone: eventZone ?? zone) }
        }
        copyBool(row, "alarmsTruncated", "alarms_truncated", into: &event)
        if row.keys.contains("availability") {
            event["availability"] = (row["availability"] as? String)
                .flatMap { EventAvailability(rawValue: $0)?.rawValue } ?? NSNull()
        }
        if let status = row["status"] as? String,
           ["none", "confirmed", "tentative", "canceled"].contains(status) { event["status"] = status }
        for (coreKey, key) in [("created", "created"), ("modified", "modified")] where row.keys.contains(coreKey) {
            event[key] = number(row[coreKey]).map { MCPTime.format($0, zone: zone) as Any } ?? NSNull()
        }
        copyText(row, "externalID", "external_id", into: &event)
        if let count = integer(row["attendeeCount"]) { event["attendee_count"] = count }
        copyBool(row, "organizerIsYou", "organizer_is_you", into: &event)
        if row.keys.contains("yourStatus") {
            event["your_status"] = (row["yourStatus"] as? String).flatMap(participantStatus) ?? NSNull()
        }
        if row.keys.contains("organizer") {
            event["organizer"] = (row["organizer"] as? [String: Any]).map(participant) ?? NSNull()
        }
        if let attendees = row["attendees"] as? [[String: Any]] { event["attendees"] = attendees.map(participant) }
        copyBool(row, "attendeesTruncated", "attendees_truncated", into: &event)
        if let editable = row["editable"] as? [String: Any] {
            let reasons: Set = ["read_only_calendar", "invitation", "floating_time", "unsupported_recurrence"]
            let reason: Any = (editable["reason"] as? String).flatMap { reasons.contains($0) ? $0 : nil }
                ?? NSNull()
            let fields: Bool = bool(editable["fields"]) ?? false
            let times: Bool = bool(editable["times"]) ?? false
            let rule: Bool = bool(editable["recurrence"]) ?? false
            event["editable"] = ["fields": fields, "times": times, "recurrence": rule, "reason": reason]
        } else {
            // A row from an older core: what 0.5 could change.
            let fixed = recurring || allDay || hasAttendees || zoneID.isEmpty
            let reason: Any = hasAttendees ? "invitation" as Any
                : zoneID.isEmpty && !allDay ? "floating_time" as Any : NSNull()
            event["editable"] = ["fields": !fixed, "times": !fixed, "recurrence": false, "reason": reason]
        }
        return event
    }

    private static func participant(_ row: [String: Any]) -> [String: Any] {
        let roles: Set = ["required", "optional", "chair", "non_participant", "unknown"]
        let types: Set = ["person", "room", "resource", "group", "unknown"]
        return ["name": row["name"] as? String ?? NSNull(), "email": row["email"] as? String ?? NSNull(),
                "role": (row["role"] as? String).flatMap { roles.contains($0) ? $0 : nil } ?? "unknown",
                "status": (row["status"] as? String).flatMap(participantStatus) ?? "unknown",
                "type": (row["type"] as? String).flatMap { types.contains($0) ? $0 : nil } ?? "unknown",
                "is_you": bool(row["isYou"]) ?? false]
    }

    private static func participantStatus(_ value: String) -> String? {
        ["pending", "accepted", "declined", "tentative", "delegated", "completed", "in_process", "unknown"]
            .contains(value) ? value : nil
    }

    private static func eventReceipt(_ item: [String: Any], _ p: [String: Any],
                                     zone: TimeZone) -> [String: Any]? {
        guard let id = item["id"] as? String else { return nil }
        var event: [String: Any] = ["id": id]
        if let version = item["version"] as? String { event["version"] = version }
        let zoneID = item["timeZone"] as? String ?? p["timeZone"] as? String ?? ""
        let eventZone: TimeZone? = zoneID.isEmpty ? nil : (TimeZone(identifier: zoneID) ?? zone)
        let allDay = bool(item["allDay"]) ?? (p["allDay"] as? Bool ?? false)
        if let start = number(item["start"]) ?? number(p["start"]),
           let end = number(item["end"]) ?? number(p["end"]) {
            if allDay {
                let dates = MCPTime.allDayDates(start: start, end: end, zone: eventZone ?? zone)
                event["start_date"] = dates.startDate
                event["end_date"] = dates.endDate
            } else {
                event["start"] = eventClock(start, eventZone: eventZone, zone: zone)
                event["end"] = eventClock(end, eventZone: eventZone, zone: zone)
            }
        }
        if item["start"] != nil || item["timeZone"] != nil {
            event["all_day"] = allDay
            event["time_zone"] = zoneID.isEmpty ? NSNull() : zoneID
        }
        if let recurring = bool(item["recurring"]) { event["recurring"] = recurring }
        if let occurrence = number(item["occurrenceStart"]) {
            event["occurrence_start"] = eventClock(occurrence, eventZone: eventZone, zone: zone)
        }
        if let verified = item["verified"] as? [String] {
            event["verified"] = verified
        } else if bool(item["allDayVerified"]) == true {
            // A 0.5 all-day receipt replayed from the journal.
            event["verified"] = ["title", "start", "end", "all_day", "notes"]
        }
        return event
    }

    private static func reminderRow(_ row: [String: Any], zone: TimeZone) -> [String: Any]? {
        guard let id = row["id"] as? String, let title = row["title"] as? String else { return nil }
        let dueZone = ((row["due"] as? [String: Any])?["timeZone"] as? String).flatMap(TimeZone.init(identifier:))
        var reminder: [String: Any] = [
            "id": id, "title": title,
            "completed": bool(row["completed"]) ?? false,
            "recurring": bool(row["recurring"]) ?? false,
            "due": due(row["due"], zone: zone),
            "recurrence": recurrence(row["recurrence"], zone: dueZone ?? zone),
            "alarms": (row["alarms"] as? [[String: Any]] ?? []).compactMap { alarm($0, zone: zone) },
        ]
        if row.keys.contains("start") { reminder["start"] = due(row["start"], zone: zone) }
        if let version = row["version"] as? String { reminder["version"] = version }
        if let truncated = bool(row["titleTruncated"]) { reminder["title_truncated"] = truncated }
        if bool(row["alarmsTruncated"]) == true { reminder["alarms_truncated"] = true }
        if row.keys.contains("completedAt") {
            reminder["completed_at"] = number(row["completedAt"]).map { MCPTime.format($0, zone: zone) as Any }
                ?? NSNull()
        }
        copyText(row, "notesPreview", "notes_preview", into: &reminder)
        copyText(row, "notes", "notes", into: &reminder)
        copyBool(row, "hasNotes", "has_notes", into: &reminder)
        copyBool(row, "notesTruncated", "notes_truncated", into: &reminder)
        copyText(row, "url", "url", into: &reminder)
        if row["url"] is String { copyBool(row, "urlSchemeAllowed", "url_scheme_allowed", into: &reminder) }
        copyText(row, "location", "location", into: &reminder)
        copyBool(row, "locationTruncated", "location_truncated", into: &reminder)
        if row.keys.contains("priority") {
            reminder["priority"] = (row["priority"] as? String)
                .flatMap { ReminderPriority(rawValue: $0)?.rawValue } ?? NSNull()
        }
        if let raw = integer(row["priorityRaw"]) { reminder["priority_raw"] = raw }
        for key in ["created", "modified"] where row.keys.contains(key) {
            reminder[key] = number(row[key]).map { MCPTime.format($0, zone: zone) as Any } ?? NSNull()
        }
        copyText(row, "externalID", "external_id", into: &reminder)
        if let verified = row["verified"] as? [String] { reminder["verified"] = verified }
        if let candidate = row["completionCandidate"] as? [String: Any],
           let at = number(candidate["occurrenceDue"]),
           let fingerprint = candidate["occurrenceFingerprint"] as? String {
            reminder["completion_candidate"] = ["occurrence_due": MCPTime.format(at, zone: zone),
                                                "occurrence_fingerprint": fingerprint]
        }
        return reminder
    }

    private static func copyText(_ row: [String: Any], _ coreKey: String, _ key: String,
                                 into result: inout [String: Any]) {
        guard row.keys.contains(coreKey) else { return }
        result[key] = row[coreKey] as? String ?? NSNull()
    }

    private static func copyBool(_ row: [String: Any], _ coreKey: String, _ key: String,
                                 into result: inout [String: Any]) {
        if let value = bool(row[coreKey]) { result[key] = value }
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
              RecurrenceSpec.Frequency(rawValue: frequency) != nil,
              let interval = integer(rule["interval"]) else {
            var unsupported: [String: Any] = ["supported": false]
            if let summary = rule["summary"] as? String { unsupported["summary"] = summary }
            return unsupported
        }
        var result: [String: Any] = ["frequency": frequency, "interval": interval, "supported": true]
        if let weekdays = rule["weekdays"] as? [String] { result["weekdays"] = weekdays }
        if let days = (rule["monthDays"] as? [Any])?.compactMap(integer) { result["month_days"] = days }
        if let day = integer(rule["dayOfMonth"]) { result["month_days"] = [day] }  // A 0.5 row.
        if let months = (rule["months"] as? [Any])?.compactMap(integer) { result["months"] = months }
        if let positions = (rule["setPositions"] as? [Any])?.compactMap(integer) {
            result["set_positions"] = positions
        }
        if let start = rule["weekStart"] as? String, ["MO", "SU"].contains(start) { result["week_start"] = start }
        if let end = rule["end"] as? [String: Any] {
            if let count = integer(end["count"]) {
                result["end"] = ["count": count]
            } else if let at = number(end["at"]) {
                result["end"] = ["until": MCPTime.format(at, zone: zone)]
            }
        }
        if let text = rule["rrule"] as? String { result["rrule"] = text }
        if let text = rule["summary"] as? String { result["summary"] = text }
        return result
    }

    private static func place(_ row: [String: Any]) -> [String: Any]? {
        guard let title = row["title"] as? String, let latitude = number(row["latitude"]),
              let longitude = number(row["longitude"]) else { return nil }
        var result: [String: Any] = ["title": title, "latitude": latitude, "longitude": longitude]
        if let radius = number(row["radius"]) { result["radius_m"] = radius }
        return result
    }

    private static func alarm(_ row: [String: Any], zone: TimeZone) -> [String: Any]? {
        switch row["kind"] as? String {
        case "absolute":
            return number(row["at"]).map { ["at": MCPTime.format($0, zone: zone)] }
        case "relative":
            // Core offsets are seconds relative to the start or due time, negative before it.
            guard let offset = number(row["offset"]) else { return nil }
            let minutes = -offset / 60
            let whole = minutes.rounded() == minutes && abs(minutes) < 1e15
            return ["minutes_before": whole ? Int(minutes) as Any : minutes as Any]
        case "location":
            guard let place = (row["location"] as? [String: Any]).flatMap(place),
                  let proximity = row["proximity"] as? String, ["arrive", "leave"].contains(proximity)
            else { return nil }
            return ["location": place, "proximity": proximity]
        case "unsupported":
            return ["supported": false, "summary": row["summary"] as? String ?? "an alarm the bridge can't express"]
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
