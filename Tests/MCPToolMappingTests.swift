import Foundation

// Golden tests for MCPToolMapping and AgentOutcomeText. Usage:
//   mcp-tool-mapping-tests Tests/mcp-fixtures      (UPDATE_GOLDENS=1 rewrites the goldens)
// `<tool>.<case>.args.json` → `<tool>.<case>.core.json`: the core parameters, or
// {"$failure": …}. A generated idempotency key is shown as "$generated".
// `core-result.<case>.json` ({tool, arguments, core}) → `core-result.<case>.structured.json`:
// structuredContent, or {"$isError": true, "text": …}.
@main
struct MCPToolMappingTests {
    static let newYork = TimeZone(identifier: "America/New_York")!
    static let now = Date(timeIntervalSince1970: 1_791_216_000)
    static let fixedKey = "ekb3_1791216000_6f0c1d2e-3a4b-4c5d-8e6f-7a8b9c0d1e2f"
    static let update = ProcessInfo.processInfo.environment["UPDATE_GOLDENS"] == "1"
    nonisolated(unsafe) static var fixtures = URL(fileURLWithPath: ".")
    nonisolated(unsafe) static var catalog = [String: Any]()
    nonisolated(unsafe) static var written = 0

    static func main() {
        guard CommandLine.arguments.count == 2 else {
            print("usage: mcp-tool-mapping-tests <Tests/mcp-fixtures>")
            exit(2)
        }
        fixtures = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        catalog = readJSON("tools.json") as! [String: Any]
        let requests = requestGoldens()
        let results = resultGoldens()
        appendixExamples()
        outcomeTexts()
        coreAgreement()
        sizeCap()
        wrongTypes()
        print("MCP tool mapping: \(requests) request and \(results) result goldens, Appendix A, "
            + "outcome texts and coverage, CommandPolicy, output schemas, size cap and wrong types passed"
            + (update ? " (\(written) goldens rewritten)" : ""))
    }

    // MARK: - Request goldens

    static func requestGoldens() -> Int {
        let names = fixtureNames(suffix: ".args.json")
        var succeeded = Set<String>()
        for name in names {
            let base = String(name.dropLast(".args.json".count))
            let tool = String(base.split(separator: ".")[0])
            let args = readJSON(name) as! [String: Any]
            switch MCPToolMapping.request(tool: tool, arguments: args, zone: newYork, now: now) {
            case .success(let request):
                succeeded.insert(tool)
                check(request.command.rawValue == tool, "\(base): one tool, one command")
                check(UUID(uuidString: request.id) != nil && request.id == request.id.lowercased(),
                      "\(base): request id")
                checkIntegers(request.parameters, base)
                checkPolicy(request, base)
                var parameters = request.parameters
                if request.command.isWrite {
                    let key = parameters["idempotencyKey"] as? String
                    if let given = args["idempotency_key"] {
                        check(key == given as? String, "\(base): key passed through unchanged")
                    } else {
                        check(WriteIdempotencyKey.timestamp(key) == now.timeIntervalSince1970,
                              "\(base): fresh key from now")
                        parameters["idempotencyKey"] = "$generated"
                    }
                }
                golden(base + ".core.json", parameters)
            case .failure(let failure):
                let text = MCPToolMapping.errorResult(tool: tool, code: failure.code,
                                                      detail: failure.message, request: nil,
                                                      retryAfter: nil)
                golden(base + ".core.json", ["$failure": ["code": failure.code, "message": failure.message,
                                                          "text": errorText(text)]])
            }
        }
        check(succeeded == Set(toolNames()), "a happy-path golden for every tool: \(succeeded)")
        return names.count
    }

    static func checkPolicy(_ request: BridgeRequest, _ name: String) {
        let p = request.parameters
        // A move's destination is in scope when the registry found Create on it.
        let scope = BridgeScope(calendarID: p["calendarID"] as? String,
                                reminderListID: p["listID"] as? String,
                                moveTargetID: (p["targetCalendarID"] ?? p["targetListID"]) as? String)
        let error = CommandPolicy.validate(request, scope: scope)
        check(error == nil, "\(name): CommandPolicy says \(error ?? "")")
        // The scope must be the request's own target, not just any.
        if p["calendarID"] != nil || p["listID"] != nil {
            let other = CommandPolicy.validate(request, scope: BridgeScope(calendarID: "OTHER",
                                                                           reminderListID: "OTHER"))
            check(other != nil, "\(name): policy accepts a different target")
        }
        check(JSONSerialization.isValidJSONObject(p), "\(name): parameters are JSON")
    }

    // Core timestamps and counts are integers, never doubles; only coordinates aren't.
    static func checkIntegers(_ value: Any, _ name: String) {
        if let object = value as? [String: Any] {
            for (key, item) in object where !["latitude", "longitude", "radius"].contains(key) {
                checkIntegers(item, name)
            }
        } else if let list = value as? [Any] {
            list.forEach { checkIntegers($0, name) }
        } else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            check(!CFNumberIsFloatType(number), "\(name): \(number) is a double")
        }
    }

    // MARK: - Result goldens

    static func resultGoldens() -> Int {
        let names = fixtureNames(suffix: ".json").filter {
            $0.hasPrefix("core-result.") && !$0.hasSuffix(".structured.json")
        }
        for name in names {
            let base = String(name.dropLast(".json".count))
            let fixture = readJSON(name) as! [String: Any]
            let tool = fixture["tool"] as! String
            let core = fixture["core"] as! [String: Any]
            let result = toolResult(tool, fixture["arguments"] as! [String: Any], core)
            if result["isError"] as? Bool == true {
                check(result["structuredContent"] == nil, "\(base): no structuredContent on error")
                golden(base + ".structured.json", ["$isError": true, "text": errorText(result)])
            } else {
                let structured = result["structuredContent"] as! [String: Any]
                checkSuccessShape(result, tool, base)
                golden(base + ".structured.json", structured)
            }
        }
        return names.count
    }

    static func toolResult(_ tool: String, _ arguments: [String: Any],
                           _ core: [String: Any]) -> [String: Any] {
        var args = arguments
        if BridgeCommand(rawValue: tool)?.isWrite == true && args["idempotency_key"] == nil {
            args["idempotency_key"] = fixedKey
        }
        guard case .success(let request) = MCPToolMapping.request(tool: tool, arguments: args,
                                                                  zone: newYork, now: now) else {
            fail("\(tool): fixture arguments don't map")
        }
        return MCPToolMapping.toolResult(tool: tool, request: request, core: core, zone: newYork, now: now)
    }

    static func checkSuccessShape(_ result: [String: Any], _ tool: String, _ name: String) {
        let structured = result["structuredContent"] as! [String: Any]
        let content = result["content"] as! [[String: Any]]
        let compact = String(data: try! JSONSerialization.data(
            withJSONObject: structured, options: [.sortedKeys, .withoutEscapingSlashes]), encoding: .utf8)!
        check(Set(result.keys) == ["content", "structuredContent", "isError"] &&
              result["isError"] as? Bool == false && content.count == 1 &&
              content[0]["type"] as? String == "text" && content[0]["text"] as? String == compact,
              "\(name): CallToolResult shape")
        let schema = toolSchema(tool)["outputSchema"] as! [String: Any]
        validate(structured, schema, root: schema, path: name)
        // reminderWrite only says "object"; hold it to the read_reminders item shape.
        let item = ((((toolSchema("read_reminders")["outputSchema"] as! [String: Any])["properties"]
            as! [String: Any])["reminders"] as! [String: Any])["items"] as! [String: Any])
        for key in ["reminder", "next_occurrence"] {
            if let reminder = structured[key] { validate(reminder, item, root: item, path: "\(name).\(key)") }
        }
    }

    // MARK: - Appendix A

    static func appendixExamples() {
        // A.1
        let a1 = request("read_events", ["calendar_id": "CAL-WORK", "start": "2026-10-06T00:00:00-04:00",
                                         "end": "2026-10-07T00:00:00-04:00"])
        check(canonical(a1.parameters) == canonical(
            ["calendarID": "CAL-WORK", "start": 1_791_259_200, "end": 1_791_345_600, "limit": 50]), "A.1 core")
        // A row from a 0.5 core (no plan 03 keys) still maps; times use the event's own zone (F3).
        let a1Result = MCPToolMapping.toolResult(tool: "read_events", request: a1, core: [
            "items": [["id": "EV1", "version": "1791200000.123456", "title": "Design review",
                       "titleTruncated": false, "start": 1_791_295_200.0, "end": 1_791_298_800.0,
                       "recurring": false, "allDay": false, "timeZone": "GMT", "hasAttendees": false]],
            "truncated": false,
        ], zone: newYork, now: now)
        check(canonical(a1Result["structuredContent"]!) == canonical(json("""
            {"calendar_id":"CAL-WORK","next_cursor":null,"truncated":false,"events":[
            {"id":"EV1","version":"1791200000.123456","title":"Design review","title_truncated":false,
             "start":"2026-10-06T14:00:00+00:00","end":"2026-10-06T15:00:00+00:00","all_day":false,
             "recurring":false,"time_zone":"GMT","floating":false,"occurrence_start":null,"recurrence":null,
             "editable":{"fields":true,"times":true,"recurrence":false,"reason":null}}]}
            """)), "A.1 structuredContent")
        // A.2
        let a2 = request("create_reminder", ["list_id": "LIST-GROC", "title": "Buy oat milk",
                                             "due": ["date_time": "2026-11-05T09:00:00-05:00"],
                                             "idempotency_key": fixedKey])
        check(canonical(a2.parameters) == canonical([
            "listID": "LIST-GROC", "title": "Buy oat milk", "idempotencyKey": fixedKey,
            "due": ["kind": "timed", "at": 1_793_887_200, "timeZone": "America/New_York"],
        ]), "A.2 core")
        let a2Result = MCPToolMapping.toolResult(tool: "create_reminder", request: a2, core: [
            "item": ["id": "R9", "version": "1791216003.000000", "title": "Buy oat milk",
                     "completed": false, "recurring": false,
                     "due": ["kind": "timed", "at": 1_793_887_200.0, "local": "2026-11-05T09:00:00",
                             "timeZone": "America/New_York"],
                     "recurrence": ["kind": "none", "supported": true],
                     "alarms": [["kind": "absolute", "at": 1_793_887_200.0]],
                     "alarmCount": 1, "alarmsTruncated": false],
        ], zone: newYork, now: now)
        check(canonical(a2Result["structuredContent"]!) == canonical(json("""
            {"list_id":"LIST-GROC","idempotency_key":"\(fixedKey)",
             "reminder":{"id":"R9","version":"1791216003.000000","title":"Buy oat milk","completed":false,
               "recurring":false,"due":{"date_time":"2026-11-05T09:00:00-05:00","time_zone":"America/New_York"},
               "recurrence":null,"alarms":[{"at":"2026-11-05T09:00:00-05:00"}]}}
            """)), "A.2 structuredContent")
        // A.3, verbatim.
        let a3Key = "ekb3_1791216000_6f0c…"
        check(AgentOutcomeText.text(code: "forbidden", tool: "delete_event", detail: nil, retryAfter: nil,
                                    idempotencyKey: nil)
              == "Not allowed: this agent can't delete events in that calendar. If it should be able to, "
              + "ask the user to grant Delete for this connection in EK Bridge. Don't retry. (code: forbidden)",
              "A.3 forbidden")
        check(AgentOutcomeText.text(code: "approval_denied", tool: "create_event", detail: nil,
                                    retryAfter: nil, idempotencyKey: nil)
              == "Declined: the user declined this change in EK Bridge. Don't retry it unless the "
              + "user asks you to. (code: approval_denied)", "A.3 declined")
        check(AgentOutcomeText.text(code: "write_committed_journal_pending_review", tool: "create_reminder",
                                    detail: nil, retryAfter: nil, idempotencyKey: a3Key)
              == "Needs review: the change may have been saved, but the bridge couldn't confirm it. Read the "
              + "list to check. If the reminder isn't there, retry this exact call with idempotency_key "
              + "\"\(a3Key)\". Never retry with a new key. (code: write_committed_journal_pending_review)",
              "A.3 uncertain")
        guard case .failure(let failure) = MCPToolMapping.request(
            tool: "read_events", arguments: ["calendar_id": "CAL-WORK", "start": "tomorrow at 9",
                                             "end": "2026-10-07T00:00:00-04:00"], zone: newYork, now: now)
        else { fail("A.3 invalid arguments mapped") }
        let invalid = MCPToolMapping.errorResult(tool: "read_events", code: failure.code,
                                                 detail: failure.message, request: nil, retryAfter: nil)
        check(errorText(invalid) == "Invalid arguments: start: expected an ISO 8601 date-time with an "
              + "offset, like 2026-10-06T09:00:00-04:00; got \"tomorrow at 9\". (code: invalid_arguments)",
              "A.3 invalid arguments")
        check(Set(invalid.keys) == ["content", "isError"] && invalid["isError"] as? Bool == true,
              "error result shape")
        // The key in an uncertain error comes from the request that ran.
        let uncertain = MCPToolMapping.toolResult(tool: "create_reminder", request: a2,
                                                  core: ["error": "timeout"], zone: newYork, now: now)
        check(errorText(uncertain).contains("idempotency_key \"\(fixedKey)\""), "uncertain text has key")
        let limited = MCPToolMapping.toolResult(tool: "read_events", request: a1,
                                                core: ["error": "rate_limited", "retryAfter": 12],
                                                zone: newYork, now: now)
        check(errorText(limited).contains("Wait 12 seconds"), "retryAfter")
    }

    // MARK: - Agent texts

    static func outcomeTexts() {
        let writes = ["create_event", "update_event", "delete_event", "create_reminder", "update_reminder",
                      "complete_reminder", "delete_reminder"]
        var cases: [[String: Any]] = toolNames().filter { $0 != "list_collections" }
            .map { ["code": "forbidden", "tool": $0] }
        for code in AgentOutcomeText.uncertainCodes.sorted() {
            cases += writes.map { ["code": code, "tool": $0, "idempotency_key": fixedKey] }
        }
        cases += [
            ["code": "timeout", "tool": "read_reminders"],
            ["code": "rate_limited", "tool": "read_events", "retry_after": 1],
            ["code": "rate_limited", "tool": "read_events"],
            ["code": "invalid_arguments", "tool": "create_event"],
            ["code": "invalid_parameters_or_target", "tool": "create_event", "detail": "a hint"],
            ["code": "full_access_required", "tool": "list_collections"],
            ["code": "full_access_required", "tool": "read_reminders"],
            ["code": "target_unavailable", "tool": "read_events"],
            ["code": "item_unavailable", "tool": "update_reminder"],
            ["code": "completed_reminder_due_unsupported", "tool": "update_reminder"],
            ["code": "recurrence_unsupported", "tool": "update_event"],
            ["code": "idempotency_pending_review", "tool": "create_event"],
            // Journaled, so a same-key retry would only replay it: tell the user instead.
            ["code": "all_day_readback_failed_cleanup_needed", "tool": "create_event",
             "idempotency_key": fixedKey],
            ["code": "mystery_code", "tool": "read_events"],
            ["code": "forbidden", "tool": "get_event"],
            ["code": "recurrence_scope_required", "tool": "delete_reminder"],
            ["code": "recurrence_scope_required", "tool": "update_reminder"],
            ["code": "recurrence_anchor_mismatch", "tool": "create_event"],
            ["code": "alarms_unsupported", "tool": "update_reminder"],
        ]
        let codes = ["unauthorized", "bridge_off", "client_paused", "target_not_writable", "conflict", "occurrence_conflict",
                     "too_many_events_narrow_range", "nonexistent_local_time", "ambiguous_local_time",
                     "invalid_parameters", "invalid_schedule", "invalid_event_schedule", "invalid_request",
                     "recurrence_requires_due", "recurrence_anchor_mismatch",
                     "recurrence_requires_alarm_reset", "recurrence_scope_required",
                     "recurrence_scope_not_applicable", "recurrence_shape_unsupported",
                     "floating_time_unsupported", "complex_alarm_unsupported", "complex_start_unsupported",
                     "all_day_or_attendees_unsupported", "ambiguous_occurrence", "alarm_in_past",
                     "already_completed", "occurrence_already_requested", "approval_denied",
                     "approval_timed_out", "scope_changed", "scope_changed_after_write",
                     "journal_clock_rollback", "idempotency_conflict", "idempotency_expired",
                     "invalid_idempotency_key", "response_too_large", "cancelled", "save_failed",
                     "fetch_failed", "all_day_readback_failed_rolled_back", "app_unavailable",
                     "client_unavailable", "activity_unavailable", "journal_unavailable", "journal_full",
                     "unavailable",
                     // Plan 03.
                     "nothing_to_change", "occurrence_required", "occurrence_not_found", "span_not_applicable",
                     "recurrence_span_invalid", "invitation_read_only", "floating_time_read_only",
                     "availability_unsupported", "url_scheme_not_allowed", "invalid_url", "invalid_notes",
                     "notes_too_long", "invalid_location", "location_too_long", "invalid_alarms",
                     "invalid_recurrence", "alarms_unsupported", "alarm_requires_due",
                     "recurrence_requires_relative_alarm", "recurrence_uncomplete_unsupported",
                     "recurrence_unsupported", "move_across_accounts_unsupported", "already_applied",
                     "time_zone_readback_failed_rolled_back", "start_readback_failed_cleanup_needed",
                     "alarms_readback_failed_restored", "notes_readback_failed_restore_failed",
                     "priority_readback_failed_restored", "write_readback_failed_rolled_back"]
        cases += codes.map { code -> [String: Any] in
            let events = code.contains("event") || ["invitation_read_only", "floating_time_read_only",
                                                    "availability_unsupported", "occurrence_required",
                                                    "occurrence_not_found", "span_not_applicable",
                                                    "recurrence_span_invalid", "already_applied"].contains(code)
                || code.hasPrefix("time_zone_") || code.hasPrefix("start_")
            return ["code": code, "tool": events ? "update_event" : code.hasPrefix("priority_") || code.hasPrefix("alarms_")
                        || code.hasPrefix("notes_readback") ? "update_reminder" : "complete_reminder"]
        }
        var table = [[String: Any]]()
        for item in cases {
            let code = item["code"] as! String
            let text = AgentOutcomeText.text(code: code, tool: item["tool"] as? String,
                                             detail: item["detail"] as? String,
                                             retryAfter: item["retry_after"] as? Int,
                                             idempotencyKey: item["idempotency_key"] as? String)
            check(text.hasSuffix(". (code: \(code))") && !text.contains(".."), "text form: \(text)")
            if let key = item["idempotency_key"] as? String,
               AgentOutcomeText.uncertainCodes.contains(code) {
                check(text.contains("idempotency_key \"\(key)\"") && text.contains("Never retry with a new key"),
                      "uncertain text names the key: \(text)")
            }
            if code.hasSuffix("_cleanup_needed") || code.hasSuffix("_restore_failed") {
                check(text.contains("don't retry") && !text.contains("idempotency_key"), "cleanup: \(text)")
            }
            check(AgentOutcomeText.isKnown(code) == (code != "mystery_code"), "isKnown \(code)")
            table.append(item.merging(["text": text]) { _, new in new })
        }
        golden("agent-outcome-texts.json", table)
        check(AgentOutcomeText.text(code: "mystery_code", tool: nil, detail: nil, retryAfter: nil,
                                    idempotencyKey: nil)
              == "Error: EK Bridge returned mystery_code. Tell the user. (code: mystery_code)", "fallback")
        check(AgentOutcomeText.text(code: "bridge_off", tool: nil, detail: nil, retryAfter: nil,
                                    idempotencyKey: nil)
              == "Paused: EK Bridge is paused. Ask the user to turn it on from the menu bar; "
              + "don't retry until they do. (code: bridge_off)", "bridge_off")
        check(AgentOutcomeText.text(code: "client_paused", tool: nil, detail: nil, retryAfter: nil,
                                    idempotencyKey: nil)
              == "Paused: the user paused this agent's access in EK Bridge. Its access isn't removed; "
              + "ask the user to resume this connection if they want you to continue, and don't retry until "
              + "they do. (code: client_paused)", "client_paused")

        // Every code the core and pipeline can return has a specific text.
        let sources = fixtures.appendingPathComponent("../../Sources").standardized
        let patterns = [#""error": "([a-z_]+)""#, #"\.reject\("([a-z_]+)"\)"#,
                        #"return "([a-z]+(?:_[a-z]+)+)""#, #"\? nil : "([a-z]+(?:_[a-z]+)+)""#,
                        #"FieldError\("([a-z_]+)"\)"#]
            .map { try! NSRegularExpression(pattern: $0) }
        var emitted: Set = ["unauthorized", "forbidden", "unavailable", "bridge_off", "rate_limited",
                            "approval_denied", "approval_timed_out", "timeout", "cancelled"]
        for file in ["CommandPolicy", "EventKitCommands", "EventCommands", "ReminderCommands", "EventFields",
                     "ReminderFields", "ItemText", "MutationPolicy", "ReminderSchedule", "RequestPipeline",
                     "WriteJournal"] {
            let text = try! String(contentsOf: sources.appendingPathComponent("\(file).swift"), encoding: .utf8)
            for pattern in patterns {
                for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    emitted.insert(String(text[Range(match.range(at: 1), in: text)!]))
                }
            }
        }
        check(emitted.count > 40, "scan found \(emitted.count) codes")
        let missing = emitted.filter { !AgentOutcomeText.isKnown($0) }.sorted()
        check(missing.isEmpty, "no agent text for \(missing)")
    }

    // The mapping's DST-fold check agrees with the core's own due parsing.
    static func coreAgreement() {
        for (at, accepted) in [(1_793_511_000, true), (1_793_514_600, false)] {
            let due: [String: Any] = ["kind": "timed", "at": at, "timeZone": "America/New_York"]
            check((ReminderDueChange.parse(parameters: ["due": due]) != nil) == accepted, "core fold \(at)")
        }
    }

    static func sizeCap() {
        let request = request("read_reminders", ["list_id": "LIST-GROC", "limit": 100])
        let row: [String: Any] = ["id": "R", "title": String(repeating: "x", count: 200), "completed": false,
                                  "recurring": false, "due": NSNull(),
                                  "recurrence": ["kind": "none", "supported": true], "alarms": []]
        func result(_ count: Int) -> [String: Any] {
            MCPToolMapping.toolResult(tool: "read_reminders", request: request,
                                      core: ["items": Array(repeating: row, count: count), "truncated": false],
                                      zone: newYork, now: now)
        }
        check(result(100)["isError"] as? Bool == false, "100 reminders fit")
        check(errorText(result(1_000)).hasSuffix("(code: response_too_large)"), "size cap")
        let malformed = MCPToolMapping.toolResult(tool: "read_events", request: nil,
                                                  core: ["items": [["id": "x"]]], zone: newYork, now: now)
        check(errorText(malformed).hasSuffix("(code: unexpected_result)"), "malformed core result")
    }

    // Wrong JSON types never crash; anything that maps still passes CommandPolicy.
    static func wrongTypes() {
        let happy: [String: [String: Any]] = [
            "read_events": ["calendar_id": "C", "start": "2026-10-06T00:00:00Z", "end": "2026-10-07T00:00:00Z",
                            "limit": 5],
            "create_event": ["calendar_id": "C", "title": "T", "all_day": true, "start_date": "2026-10-06",
                             "end_date": "2026-10-07", "time_zone": "UTC", "notes": "N",
                             "idempotency_key": fixedKey],
            "update_event": ["calendar_id": "C", "event_id": "E", "version": "1", "title": "T",
                             "start": "2026-10-06T09:00:00Z", "end": "2026-10-06T10:00:00Z",
                             "occurrence_start": "2026-10-06T09:00:00Z", "span": "future", "notes": "N",
                             "location": "HQ", "url": "https://example.com", "availability": "free",
                             "structured_location": ["title": "HQ", "latitude": 1, "longitude": 2, "radius_m": 50],
                             "alarms": [["minutes_before": 10]],
                             "recurrence": ["frequency": "weekly", "weekdays": ["TU"], "end": ["count": 3]],
                             "time_zone": "UTC", "replace_unsupported_alarms": true, "target_calendar_id": "C"],
            "delete_event": ["calendar_id": "C", "event_id": "E", "version": "1",
                             "occurrence_start": "2026-10-06T09:00:00Z", "span": "all"],
            "get_event": ["calendar_id": "C", "event_id": "E", "occurrence_start": "2026-10-06T09:00:00Z"],
            "read_reminders": ["list_id": "L", "limit": 5, "cursor": "R", "status": "all",
                               "due_after": "2026-10-06T09:00:00Z", "due_before": "2026-10-07T09:00:00Z"],
            "get_reminder": ["list_id": "L", "reminder_id": "R"],
            "create_reminder": ["list_id": "L", "title": "T", "due": ["date": "2026-11-05", "time_zone": "UTC"],
                                "alarm": "none", "recurrence": ["frequency": "monthly", "day_of_month": 5,
                                                                "interval": 2, "end_count": 3]],
            "update_reminder": ["list_id": "L", "reminder_id": "R", "version": "1", "title": "T",
                                "due": ["date_time": "2026-11-05T09:00:00Z"], "alarm": "at_due",
                                "recurrence": ["frequency": "weekly", "weekdays": ["TH"],
                                               "end_until": "2027-01-01T00:00:00Z"],
                                "start": ["date": "2026-11-01"], "notes": "N", "url": "https://example.com",
                                "priority": "low", "completed": false,
                                "replace_unsupported_alarms": true, "target_list_id": "L"],
            "complete_reminder": ["list_id": "L", "reminder_id": "R", "version": "1",
                                  "occurrence": ["occurrence_due": "2026-11-05T09:00:00Z",
                                                 "occurrence_fingerprint": String(repeating: "a", count: 64)]],
            "delete_reminder": ["list_id": "L", "reminder_id": "R", "version": "1"],
            "list_collections": [:],
        ]
        check(Set(happy.keys) == Set(toolNames()), "every tool covered")
        let junk: [Any] = [NSNull(), 7, 1.5, true, "x", [String: Any](), [Any](), ["x"], ["none": false]]
        var mapped = 0
        for (tool, args) in happy {
            guard case .success(let base) = MCPToolMapping.request(tool: tool, arguments: args, zone: newYork,
                                                                   now: now) else { fail("\(tool) happy") }
            checkPolicy(base, "\(tool) happy")
            var variants = [[String: Any]]()
            for key in args.keys {
                for value in junk { variants.append(args.merging([key: value]) { _, new in new }) }
                if let nested = args[key] as? [String: Any] {
                    for inner in nested.keys {
                        for value in junk {
                            variants.append(args.merging([key: nested.merging([inner: value]) { _, new in new }])
                                            { _, new in new })
                        }
                    }
                }
            }
            variants.append(args.merging(["unexpected": 1]) { _, new in new })
            for variant in variants {
                switch MCPToolMapping.request(tool: tool, arguments: variant, zone: newYork, now: now) {
                case .success(let request):
                    mapped += 1
                    checkPolicy(request, "\(tool) \(variant)")
                case .failure(let failure):
                    check(["invalid_arguments", "invalid_idempotency_key", "invalid_url", "url_scheme_not_allowed",
                           "nothing_to_change"].contains(failure.code) &&
                          !failure.message.isEmpty, "\(tool): \(failure)")
                }
            }
            guard case .failure(let unknown) = MCPToolMapping.request(
                tool: tool, arguments: ["__x": 1], zone: newYork, now: now) else { fail("\(tool) __x") }
            check(unknown.message.hasPrefix("__x: unknown argument") || unknown.message.hasSuffix(": required"),
                  "\(tool) handles its own name: \(unknown.message)")
        }
        check(mapped > 0, "some variants map")
        guard case .failure(let failure) = MCPToolMapping.request(tool: "make_coffee", arguments: [:],
                                                                  zone: newYork, now: now),
              failure.code == "invalid_arguments" else { fail("unknown tool") }
    }

    // MARK: - Helpers

    static func request(_ tool: String, _ args: [String: Any]) -> BridgeRequest {
        guard case .success(let request) = MCPToolMapping.request(tool: tool, arguments: args, zone: newYork,
                                                                  now: now) else { fail("\(tool) didn't map") }
        return request
    }

    static func toolNames() -> [String] {
        (catalog["tools"] as! [[String: Any]]).map { $0["name"] as! String }
    }

    static func toolSchema(_ name: String) -> [String: Any] {
        (catalog["tools"] as! [[String: Any]]).first { $0["name"] as? String == name }!
    }

    // A JSON Schema subset: the keywords tools.json's output schemas use.
    static func validate(_ value: Any, _ schema: [String: Any], root: [String: Any], path: String) {
        if let ref = schema["$ref"] as? String {
            let name = String(ref.dropFirst("#/$defs/".count))
            let local = (root["$defs"] as? [String: Any])?[name]
            let shared = (catalog["$defs"] as? [String: Any])?[name]
            guard let target = (local ?? shared) as? [String: Any] else { fail("\(path): no \(ref)") }
            validate(value, target, root: root, path: path)
            return
        }
        let type = jsonType(value)
        if let declared = schema["type"] {
            let types = declared as? [String] ?? [declared as! String]
            check(types.contains(type) || (type == "integer" && types.contains("number")),
                  "\(path): \(type) isn't \(types)")
        }
        if let options = schema["enum"] as? [Any] {
            check(options.contains { canonical($0) == canonical(value) }, "\(path): \(value) not in enum")
        }
        if let constant = schema["const"] {
            check(canonical(constant) == canonical(value), "\(path): not \(constant)")
        }
        if let object = value as? [String: Any] {
            let properties = schema["properties"] as? [String: Any] ?? [:]
            for key in schema["required"] as? [String] ?? [] {
                check(object[key] != nil, "\(path): missing \(key)")
            }
            for (key, item) in object {
                if let property = properties[key] as? [String: Any] {
                    validate(item, property, root: root, path: "\(path).\(key)")
                } else {
                    check(schema["additionalProperties"] as? Bool != false, "\(path): \(key) not allowed")
                }
            }
        }
        if let list = value as? [Any], let items = schema["items"] as? [String: Any] {
            for (index, item) in list.enumerated() {
                validate(item, items, root: root, path: "\(path)[\(index)]")
            }
        }
    }

    static func jsonType(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if value is String { return "string" }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return "boolean" }
            let double = number.doubleValue
            return !CFNumberIsFloatType(number) || double.rounded() == double ? "integer" : "number"
        }
        if value is [String: Any] { return "object" }
        if value is [Any] { return "array" }
        return "unknown"
    }

    static func errorText(_ result: [String: Any]) -> String {
        check(result["isError"] as? Bool == true, "expected an error result: \(result)")
        return ((result["content"] as! [[String: Any]])[0]["text"] as! String)
    }

    static func fixtureNames(suffix: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: fixtures.path)) ?? []
        return names.filter { $0.hasSuffix(suffix) }.sorted()
    }

    static func readJSON(_ name: String) -> Any {
        guard let data = try? Data(contentsOf: fixtures.appendingPathComponent(name)),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { fail("can't read \(name)") }
        return value
    }

    static func json(_ text: String) -> Any {
        try! JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    static func canonical(_ value: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [
            .prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        return String(data: data, encoding: .utf8)! + "\n"
    }

    static func golden(_ name: String, _ value: Any) {
        let url = fixtures.appendingPathComponent(name)
        let actual = canonical(value)
        if update {
            if (try? String(contentsOf: url, encoding: .utf8)) != actual {
                try! actual.write(to: url, atomically: true, encoding: .utf8)
                written += 1
            }
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            fail("missing golden \(name); run with UPDATE_GOLDENS=1")
        }
        let expected = canonical(try! JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
        check(expected == actual, "\(name) differs from the golden.\nexpected:\n\(expected)actual:\n\(actual)")
    }

    static func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        if !condition { fail(message()) }
    }

    static func fail(_ message: String) -> Never {
        print("FAIL: \(message)")
        exit(1)
    }
}
