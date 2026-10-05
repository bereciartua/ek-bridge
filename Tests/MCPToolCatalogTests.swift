import Foundation

@main
struct MCPToolCatalogTests {
    static let allNames = ["list_collections", "read_events", "create_event", "update_event",
                           "delete_event", "read_reminders", "create_reminder", "update_reminder",
                           "complete_reminder", "delete_reminder"]

    static func main() throws {
        precondition(CommandLine.arguments.count == 2, "usage: mcp-tool-catalog-tests <path to tools.json>")
        try contract(URL(fileURLWithPath: CommandLine.arguments[1]))
        let visibility = visibilityTable()
        let messages = validatorGoldens()
        noCollectionIDs()
        annotations()
        print("MCP tool catalog: tools.json contract and instructions, \(visibility) visibility rows, "
              + "\(messages) validator messages, no collection IDs, write annotations passed")
    }

    // MARK: The contract

    static func contract(_ file: URL) throws {
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        var shared = fixture["$defs"] as! [String: Any]
        shared["$comment"] = nil
        let expected = (fixture["tools"] as! [Any]).map { inline($0, shared) }
        let actual = MCPToolCatalog.tools.map(\.definition)
        let expectedData = try canonical(expected)
        let actualData = try canonical(actual)
        if expectedData != actualData {
            for (index, tool) in actual.enumerated() where index < expected.count {
                if try canonical(tool) != canonical(expected[index]) {
                    FileHandle.standardError.write(Data("differs: \(tool["name"] ?? index)\n".utf8))
                }
            }
        }
        precondition(expectedData == actualData, "the catalog matches tools.json after inlining")
        precondition(MCPToolCatalog.tools.map(\.name) == allNames, "tools/list order")
        precondition(MCPToolCatalog.tools.map(\.command.rawValue) == allNames)
        precondition(MCPToolCatalog.serverInstructions == fixture["serverInstructions"] as? String)
        precondition(!MCPToolCatalog.serverInstructions.isEmpty)
        // Nothing refers to the shared fragments any more; a tool's own $defs stay.
        let text = String(decoding: actualData, as: UTF8.self)
        precondition(!text.contains("#/$defs/dueInput") && !text.contains("#/$defs/eventWrite"))
        precondition(!text.contains("$comment"))
        for tool in MCPToolCatalog.tools {
            precondition(MCPToolCatalog.tool(named: tool.name)?.command == tool.command)
            precondition(tool.inputSchema["type"] as? String == "object")
            precondition(tool.inputSchema["additionalProperties"] as? Bool == false)
        }
        precondition(MCPToolCatalog.tool(named: "authorization_status") == nil)
        precondition(MCPToolCatalog.tool(named: "scope_status") == nil)
    }

    static func inline(_ value: Any, _ shared: [String: Any]) -> Any {
        if let object = value as? [String: Any] {
            if object.count == 1, let reference = object["$ref"] as? String,
               reference.hasPrefix("#/$defs/"), let fragment = shared[String(reference.dropFirst(8))] {
                return inline(fragment, shared)
            }
            return object.mapValues { inline($0, shared) }
        }
        if let array = value as? [Any] { return array.map { inline($0, shared) } }
        return value
    }

    static func canonical(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: Who sees what

    static func visibilityTable() -> Int {
        let r = ClientGrant.read, c = ClientGrant.create, e = ClientGrant.edit
        let d = ClientGrant.delete, done = ClientGrant.complete
        func cal(_ mask: Int, _ id: String = "CAL-1") -> ClientGrant {
            ClientGrant(resource: .calendar, targetID: id, mask: mask)
        }
        func list(_ mask: Int, _ id: String = "LIST-1") -> ClientGrant {
            ClientGrant(resource: .reminderList, targetID: id, mask: mask)
        }
        let table: [(String, [ClientGrant], [String])] = [
            ("no grants", [], ["list_collections"]),
            ("calendar read", [cal(r)], ["list_collections", "read_events"]),
            ("calendar create without read", [cal(c)], ["list_collections", "create_event"]),
            ("calendar edit and delete", [cal(e | d)], ["list_collections", "update_event", "delete_event"]),
            ("reminders complete only", [list(done)], ["list_collections", "complete_reminder"]),
            ("everything", [cal(15), list(31)], allNames),
            ("read-only calendar + full list", [cal(r), list(31)],
             ["list_collections", "read_events", "read_reminders", "create_reminder", "update_reminder",
              "complete_reminder", "delete_reminder"]),
            ("full calendar only", [cal(15)],
             ["list_collections", "read_events", "create_event", "update_event", "delete_event"]),
            ("two calendars, read on one and create on the other", [cal(r, "A"), cal(c, "B")],
             ["list_collections", "read_events", "create_event"]),
            ("two lists, read+create and delete", [list(r | c, "A"), list(d, "B")],
             ["list_collections", "read_reminders", "create_reminder", "delete_reminder"]),
            ("list edit only", [list(e)], ["list_collections", "update_reminder"]),
            ("grant order doesn't change tool order", [list(r), cal(r)],
             ["list_collections", "read_events", "read_reminders"]),
        ]
        for (name, grants, expected) in table {
            let visible = MCPToolCatalog.visibleTools(grants: grants).map(\.name)
            precondition(visible == expected, "\(name): \(visible)")
        }
        return table.count
    }

    // MARK: Validator messages

    static func validatorGoldens() -> Int {
        let long197 = String(repeating: "a", count: 197)
        let table: [(String, String, String?)] = [
            // Happy paths.
            ("list_collections", "{}", nil),
            ("read_events", #"{"calendar_id":"C","start":"2026-10-06T09:00:00Z","end":"2026-10-06T10:00:00Z","limit":2.0}"#, nil),
            ("create_reminder", #"{"list_id":"L","title":"t","due":{"date":"2026-10-06"},"recurrence":{"frequency":"weekly","weekdays":["MO","TU"],"interval":1}}"#, nil),
            ("create_event", #"{"calendar_id":"C","title":"\#(long197)é"}"#, nil), // 200 bytes
            // Missing required, first in schema order.
            ("read_events", "{}", "calendar_id: is required"),
            ("read_events", #"{"calendar_id":"C","end":"x"}"#, "start: is required"),
            ("complete_reminder", #"{"list_id":"L","reminder_id":"R","version":"1","occurrence":{}}"#,
             "occurrence.occurrence_due: is required"),
            // Unknown arguments.
            ("list_collections", #"{"foo":1}"#, "foo: isn't a known argument; this tool takes none"),
            ("read_reminders", #"{"list_id":"L","page":2}"#,
             "page: isn't a known argument (expected: cursor, limit, list_id)"),
            ("create_reminder", #"{"list_id":"L","title":"t","due":{"date":"2026-10-06","at":"9"}}"#,
             "due.at: isn't a known argument (expected: date, date_time, none, time_zone)"),
            // Wrong types.
            ("read_events", #"{"calendar_id":5,"start":"s","end":"e"}"#, "calendar_id: expected a string, got 5"),
            ("create_reminder", #"{"list_id":"L","title":"t","due":"tomorrow"}"#,
             #"due: expected an object, got "tomorrow""#),
            ("create_reminder", #"{"list_id":"L","title":"t","due":{"date_time":5}}"#,
             "due.date_time: expected a string, got 5"),
            ("create_reminder", #"{"list_id":"L","title":"t","recurrence":{"frequency":"weekly","weekdays":"MO"}}"#,
             #"recurrence.weekdays: expected an array, got "MO""#),
            ("read_reminders", #"{"list_id":null}"#, "list_id: expected a string, got null"),
            ("read_reminders", #"{"list_id":["L"]}"#, "list_id: expected a string, got an array"),
            // Booleans aren't integers, and integers aren't booleans.
            ("read_events", #"{"calendar_id":"C","start":"s","end":"e","limit":true}"#,
             "limit: expected a whole number, got true"),
            ("read_events", #"{"calendar_id":"C","start":"s","end":"e","limit":2.5}"#,
             "limit: expected a whole number, got 2.5"),
            ("read_events", #"{"calendar_id":"C","start":"s","end":"e","limit":"5"}"#,
             #"limit: expected a whole number, got "5""#),
            ("create_event", #"{"calendar_id":"C","title":"t","all_day":1}"#,
             "all_day: expected true or false, got 1"),
            ("create_event", #"{"calendar_id":"C","title":"t","all_day":"true"}"#,
             #"all_day: expected true or false, got "true""#),
            ("create_reminder", #"{"list_id":"L","title":"t","due":{"none":1}}"#,
             "due.none: expected true or false, got 1"),
            // Lengths in UTF-8 bytes: 199 characters, 201 bytes.
            ("create_event", #"{"calendar_id":"C","title":"\#(long197)éé"}"#,
             "title: must be at most 200 bytes of UTF-8, got 201"),
            ("create_event", #"{"calendar_id":"C","title":""}"#, "title: must not be empty"),
            ("create_event", #"{"calendar_id":"C","title":"t","notes":"\#(String(repeating: "€", count: 667))"}"#,
             "notes: must be at most 2000 bytes of UTF-8, got 2001"),
            // enum and const.
            ("create_reminder", #"{"list_id":"L","title":"t","recurrence":{"frequency":"hourly"}}"#,
             #"recurrence.frequency: expected one of "daily", "weekly", "monthly", "yearly", got "hourly""#),
            ("update_reminder", #"{"list_id":"L","reminder_id":"R","version":"1","title":"t","due":{"none":false}}"#,
             "due.none: must be true"),
            ("update_reminder", #"{"list_id":"L","reminder_id":"R","version":"1","title":"t","recurrence":{"none":false}}"#,
             "recurrence.none: must be true"),
            // minimum and maximum.
            ("read_events", #"{"calendar_id":"C","start":"s","end":"e","limit":0}"#, "limit: must be at least 1"),
            ("read_events", #"{"calendar_id":"C","start":"s","end":"e","limit":101}"#, "limit: must be at most 100"),
            ("read_reminders", #"{"list_id":"L","limit":-3}"#, "limit: must be at least 1"),
            ("create_reminder", #"{"list_id":"L","title":"t","recurrence":{"frequency":"daily","interval":367}}"#,
             "recurrence.interval: must be at most 366"),
            ("create_reminder", #"{"list_id":"L","title":"t","recurrence":{"frequency":"monthly","day_of_month":0}}"#,
             "recurrence.day_of_month: must be at least 1"),
            ("create_reminder", #"{"list_id":"L","title":"t","recurrence":{"frequency":"daily","end_count":10001}}"#,
             "recurrence.end_count: must be at most 10000"),
            // minItems, maxItems, uniqueItems and item enums.
            ("create_reminder", #"{"list_id":"L","title":"t","recurrence":{"frequency":"weekly","weekdays":[]}}"#,
             "recurrence.weekdays: needs at least 1 item"),
            ("create_reminder", #"{"list_id":"L","title":"t","recurrence":{"frequency":"weekly","weekdays":["MO","TU","MO"]}}"#,
             #"recurrence.weekdays: "MO" appears more than once"#),
            ("create_reminder", #"{"list_id":"L","title":"t","recurrence":{"frequency":"weekly","weekdays":["MO","TU","WE","TH","FR","SA","SU","MO"]}}"#,
             "recurrence.weekdays: allows at most 7 items"),
            ("create_reminder", #"{"list_id":"L","title":"t","recurrence":{"frequency":"weekly","weekdays":["MO","XX"]}}"#,
             #"recurrence.weekdays[1]: expected one of "MO", "TU", "WE", "TH", "FR", "SA", "SU", got "XX""#),
            // Long values are shortened in messages.
            ("read_events", #"{"calendar_id":"C","start":"s","end":"e","limit":"\#(String(repeating: "x", count: 70))"}"#,
             #"limit: expected a whole number, got ""# + String(repeating: "x", count: 64) + #"…""#),
        ]
        for (name, json, expected) in table {
            let arguments = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
            let tool = MCPToolCatalog.tool(named: name)!
            let message = MCPToolCatalog.validate(tool, arguments)
            precondition(message == expected,
                         "\(name) \(json.prefix(80)): expected \(expected ?? "nil"), got \(message ?? "nil")")
        }
        // The 201-byte title really is 199 characters.
        precondition((long197 + "éé").count == 199 && (long197 + "éé").utf8.count == 201)
        return table.count
    }

    // MARK: No collection IDs in definitions

    static func noCollectionIDs() {
        let grants = [
            ClientGrant(resource: .calendar, targetID: "CAL-SECRET-7F3A", mask: 15),
            ClientGrant(resource: .reminderList, targetID: "LIST-SECRET-9B2C", mask: 31),
        ]
        let visible = MCPToolCatalog.visibleTools(grants: grants)
        let data = try! canonical(visible.map(\.definition))
        let text = String(decoding: data, as: UTF8.self)
        precondition(!text.contains("SECRET"), "grants never reach definitions")
        precondition(data == (try! canonical(MCPToolCatalog.tools.map(\.definition))),
                     "definitions don't depend on grants")
        for tool in MCPToolCatalog.tools {
            let properties = tool.inputSchema["properties"] as? [String: Any] ?? [:]
            for key in ["calendar_id", "list_id"] {
                guard let schema = properties[key] as? [String: Any] else { continue }
                precondition(schema["enum"] == nil && schema["const"] == nil, "\(tool.name).\(key)")
                precondition(schema["type"] as? String == "string")
            }
        }
    }

    // MARK: Annotations

    static func annotations() {
        precondition(MCPToolCatalog.writesEnabled)
        for tool in MCPToolCatalog.tools {
            let annotations = tool.definition["annotations"] as! [String: Any]
            precondition(annotations["openWorldHint"] as? Bool == false, tool.name)
            precondition(annotations["readOnlyHint"] as? Bool == !tool.isWrite, tool.name)
            precondition(tool.isWrite == tool.command.isWrite)
            if tool.isWrite {
                precondition(annotations["destructiveHint"] is Bool && annotations["idempotentHint"] is Bool)
            }
        }
        let destructive = MCPToolCatalog.tools.filter {
            ($0.definition["annotations"] as! [String: Any])["destructiveHint"] as? Bool == true
        }.map(\.name)
        precondition(destructive == ["update_event", "delete_event", "update_reminder", "delete_reminder"])
        precondition(MCPToolCatalog.tools.filter(\.isWrite).count == 7)
    }
}
