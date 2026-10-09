import Foundation

/// Item references from real core results (`Tests/mcp-fixtures/*.json`,
/// the `core` value each `runAuthorized` returned) and the core parameters
/// the MCP mapping builds for those arguments.
@main
struct ActivityItemsTests {
    static func main() throws {
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
        func core(_ name: String) -> [String: Any] {
            let object = try! JSONSerialization.jsonObject(
                with: try! Data(contentsOf: fixtures.appendingPathComponent("core-result.\(name).json"))) as! [String: Any]
            return object["core"] as! [String: Any]
        }
        func ref(_ command: BridgeCommand, _ parameters: [String: Any], _ result: [String: Any]) -> ItemRef? {
            ActivityItems.ref(command: command, parameters: parameters, result: result)
        }

        // create_event / update_event / move: the receipt's ID and occurrence.
        precondition(ref(.createEvent, ["calendarID": "CAL-WORK", "title": "Dentist"],
                         core("create-event-timed")) == ItemRef(kind: "event", id: "EV2"))
        precondition(ref(.updateEvent, ["calendarID": "CAL-WORK", "itemID": "EV1", "targetCalendarID": "CAL-HOME"],
                         core("update-event-move")) == ItemRef(kind: "event", id: "EV1"))
        precondition(ref(.updateEvent, ["calendarID": "CAL-WORK", "itemID": "EV-M", "span": "future",
                                        "occurrenceStart": 1_793_091_600],
                         core("update-event-future")) ==
                     ItemRef(kind: "event", id: "EV-M2", occurrence: 1_793_095_200, span: "future"))
        // delete_event: the result is only {"deleted": true}, so the request names it.
        precondition(ref(.deleteEvent, ["calendarID": "CAL-WORK", "itemID": "EV1"], core("delete-event")) ==
                     ItemRef(kind: "event", id: "EV1"))
        precondition(ref(.deleteEvent, ["calendarID": "CAL-WORK", "itemID": "EV-M", "span": "this",
                                        "occurrenceStart": 1_793_091_600], ["deleted": true]) ==
                     ItemRef(kind: "event", id: "EV-M", occurrence: 1_793_091_600, span: "this"))
        // Reminders.
        precondition(ref(.createReminder, ["listID": "LIST-GROC", "title": "Buy oat milk"],
                         core("create-reminder-a2")) == ItemRef(kind: "reminder", id: "R9"))
        precondition(ref(.updateReminder, ["listID": "LIST-GROC", "itemID": "R9"], core("update-reminder")) ==
                     ItemRef(kind: "reminder", id: "R9"))
        precondition(ref(.updateReminder, ["listID": "LIST-GROC", "itemID": "R7", "targetListID": "LIST-HOME"],
                         core("update-reminder-move")).map(\.id) == "R7")
        precondition(ref(.completeReminder, ["listID": "LIST-GROC", "itemID": "R9"],
                         core("complete-reminder")) == ItemRef(kind: "reminder", id: "R9"))
        // A repeating reminder: the completed occurrence is its own item.
        precondition(ref(.completeReminder, ["listID": "LIST-GROC", "itemID": "R7", "recurrenceScope": "occurrence"],
                         core("complete-recurring")) ==
                     ItemRef(kind: "reminder", id: "R7-DONE", occurrence: 1_791_291_600, span: "occurrence"))
        precondition(ref(.deleteReminder, ["listID": "LIST-GROC", "itemID": "R9"],
                         core("delete-reminder-repeated")) == ItemRef(kind: "reminder", id: "R9"))
        // Refused or failed writes keep the requested ID when there is one.
        precondition(ref(.updateEvent, ["calendarID": "CAL-WORK", "itemID": "EV1"], ["error": "conflict"]) ==
                     ItemRef(kind: "event", id: "EV1"))
        precondition(ref(.deleteReminder, ["listID": "L", "itemID": "R1"], ["error": "forbidden"]) ==
                     ItemRef(kind: "reminder", id: "R1"))
        precondition(ref(.createEvent, ["calendarID": "CAL-WORK", "title": "x"], ["error": "rate_limited"]) == nil)
        // A create that couldn't be rolled back names the item it left.
        precondition(ref(.createEvent, ["calendarID": "CAL-WORK"],
                         ["error": "recurrence_readback_failed_cleanup_needed", "itemID": "EV9"]) ==
                     ItemRef(kind: "event", id: "EV9"))
        // Reads never get one, even with an item ID.
        precondition(ref(.getEvent, ["calendarID": "CAL-WORK", "itemID": "EV1"], core("get-event-full")) == nil)
        precondition(ref(.readReminders, ["listID": "LIST-GROC"], core("read-reminders")) == nil)
        precondition(ref(.listCollections, [:], core("list-collections")) == nil)
        // Odd IDs aren't kept.
        precondition(ref(.deleteEvent, ["itemID": "bad\nid"], [:]) == nil)
        precondition(ref(.deleteEvent, ["itemID": String(repeating: "a", count: 513)], [:]) == nil)
        precondition(ref(.deleteEvent, ["itemID": "EV1", "occurrenceStart": true], [:])?.occurrence == nil)
        // Never any content: an ItemRef has no field that could hold a title.
        let encoded = String(data: try JSONEncoder().encode(
            ref(.createReminder, ["listID": "LIST-GROC"], core("create-reminder-a2"))!), encoding: .utf8)!
        precondition(!encoded.contains("oat milk"), encoded)
        print("Activity items: every write command from real core results, refusals, reads and odd IDs passed")
    }
}
