import Foundation

// The approval panel's rows (plan 03 §17), built from the request and a
// lookup of the current item with the same resolvers the write uses. Values
// are checked for their locale-independent parts.
@main
struct ApprovalSummariesTests {
    nonisolated(unsafe) static var checks = 0
    static let ny = TimeZone(identifier: "America/New_York")!
    static let now = Date(timeIntervalSince1970: 1_791_216_000)
    static let collections = [
        CollectionInfo(resource: .calendar, id: "CAL", name: "Work", account: "iCloud", writable: true, color: nil),
        CollectionInfo(resource: .calendar, id: "HOME", name: "Personal", account: "iCloud", writable: true, color: nil),
        CollectionInfo(resource: .reminderList, id: "LIST", name: "Errands", account: "iCloud", writable: true,
                       color: nil),
        CollectionInfo(resource: .reminderList, id: "LIST2", name: "Home", account: "iCloud", writable: true,
                       color: nil),
    ]

    static func main() {
        createEvent()
        updateEvent()
        recurringEvent()
        reminders()
        print("Approval summaries: \(checks) checks of every row type, before → after, spans with counts, "
              + "moves, refused changes and failed lookups passed")
    }

    static func check(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
        checks += 1
        if !condition {
            print("FAIL line \(line): \(message())")
            exit(1)
        }
    }

    static func summary(_ command: BridgeCommand, _ p: [String: Any], _ lookup: ApprovalLookup = ApprovalLookup())
        -> ApprovalSummary {
        let request = BridgeRequest(id: UUID().uuidString, command: command, parameters: p)
        let approval = ApprovalRequest(clientID: "c", clientName: "Claude Code", agent: nil, request: request,
                                       targetID: (p["calendarID"] ?? p["listID"]) as? String)
        return ApprovalSummaries.build(approval, lookup: lookup, collections: collections, zone: ny, now: now)
    }

    static func row(_ summary: ApprovalSummary, _ label: String) -> ApprovalSummary.Row? {
        summary.rows.first { $0.label == label }
    }

    static func createEvent() {
        let notes = (1...6).map { "Line \($0)" }.joined(separator: "\n")
        let s = summary(.createEvent, [
            "calendarID": "CAL", "title": "Weekly sync", "start": 1_791_878_400, "end": 1_791_882_000,
            "timeZone": "Europe/Madrid", "notes": notes, "location": "Sala 2",
            "structuredLocation": ["title": "Sala 2", "latitude": 40.4, "longitude": -3.7],
            "url": "https://meet.example.com/abc", "availability": "free",
            "alarms": [["kind": "relative", "offset": -900], ["kind": "relative", "offset": -86_400],
                       ["kind": "location", "location": ["title": "Office", "latitude": 1, "longitude": 2],
                        "proximity": "arrive"]],
            "recurrence": ["kind": "rule", "frequency": "weekly", "weekdays": ["TU"],
                           "end": ["kind": "count", "count": 10]],
            "idempotencyKey": "k"])
        check(s.title == "Claude Code wants to add an event" && s.subtitle == "Work · iCloud" && !s.isDelete, s.title)
        check(s.rows.map(\.label) == ["Event", "When", "Repeats", "Where", "Notes", "Link", "Alerts", "Show as"],
              "\(s.rows.map(\.label))")
        check(row(s, "When")!.value.hasSuffix("(Europe/Madrid)"), "the zone is named when it isn't the Mac's")
        check(row(s, "Repeats")!.value == "Weekly on Tuesday, 10 times", row(s, "Repeats")!.value)
        check(row(s, "Where")!.value == "Sala 2 (map pin)", row(s, "Where")!.value)
        check(row(s, "Notes")!.value.hasPrefix("Line 1\nLine 2\nLine 3… ") && row(s, "Notes")!.full == notes,
              "first 3 lines, full text in the tooltip")
        check(row(s, "Link")!.emphasis == "meet.example.com", "the host is bold")
        check(row(s, "Alerts")!.value == "15 min before, 1 day before, arriving at Office", row(s, "Alerts")!.value)
        check(row(s, "Show as")!.value == "Free", "availability")
        let mac = summary(.createEvent, ["calendarID": "CAL", "title": "x", "start": 1_791_295_200,
                                         "end": 1_791_298_800, "timeZone": "America/New_York", "idempotencyKey": "k"])
        check(!row(mac, "When")!.value.contains("("), "no zone label in the Mac's zone")
        let phone = summary(.createEvent, ["calendarID": "CAL", "title": "x", "start": 1_791_295_200,
                                           "end": 1_791_298_800, "url": "tel:+15555550100", "idempotencyKey": "k"])
        check(row(phone, "Link")!.value == "Phone link: tel:+15555550100" && row(phone, "Link")!.emphasis == nil,
              "non-http links are labeled")
        let refused = summary(.createEvent, ["calendarID": "CAL", "title": "x", "start": 1_791_295_200,
                                             "end": 1_791_298_800, "idempotencyKey": "k",
                                             "recurrence": ["kind": "rule", "frequency": "weekly",
                                                            "weekdays": ["WE"]]])
        check(row(refused, "Problem")?.value.contains("recurrence_anchor_mismatch") == true,
              "a change the bridge will refuse says so")
    }

    static func current() -> EventFields {
        EventFields(calendarID: "CAL", title: "Design review", start: 1_791_295_200, end: 1_791_298_800,
                    allDay: false, timeZone: "America/New_York", notes: "Old notes", location: nil, place: nil,
                    url: nil, alarms: [.relative(-600)], availability: .busy, recurrence: .none)
    }

    static func updateEvent() {
        let lookup = ApprovalLookup(event: current())
        let titled = summary(.updateEvent, ["calendarID": "CAL", "itemID": "E", "expectedVersion": "1",
                                            "title": "Design review v2", "idempotencyKey": "k"], lookup)
        check(titled.rows.map(\.label) == ["Event", "When"], "only the changed field, plus when for context")
        check(row(titled, "Event")!.before == "Design review" && row(titled, "When")!.before == nil, "before → after")
        let cleared = summary(.updateEvent, ["calendarID": "CAL", "itemID": "E", "expectedVersion": "1",
                                             "notes": NSNull(), "alarms": NSNull(), "idempotencyKey": "k"], lookup)
        check(row(cleared, "Notes")!.value == "None" && row(cleared, "Notes")!.before == "Old notes", "notes cleared")
        check(row(cleared, "Alerts")!.value == "None" && row(cleared, "Alerts")!.before == "10 min before", "alerts")
        let moved = summary(.updateEvent, ["calendarID": "CAL", "itemID": "E", "expectedVersion": "1",
                                           "targetCalendarID": "HOME", "idempotencyKey": "k"], lookup)
        check(row(moved, "Calendar")!.value == "Work → Personal", "move")
        let zoned = summary(.updateEvent, ["calendarID": "CAL", "itemID": "E", "expectedVersion": "1",
                                           "timeZone": "Europe/Madrid", "idempotencyKey": "k"], lookup)
        check(row(zoned, "When")!.value.hasSuffix("(Europe/Madrid)") && row(zoned, "When")!.before != nil,
              "moving zones shows the new wall time")
        let unknown = summary(.updateEvent, ["calendarID": "CAL", "itemID": "E", "expectedVersion": "1",
                                             "title": "x", "idempotencyKey": "k"])
        check(unknown.lookupFailed && row(unknown, "Event")!.value == "x", "lookup failed, rows still shown")
    }

    static func recurringEvent() {
        var fields = current()
        fields.recurrence = .rule(RecurrenceSpec(frequency: .weekly))
        let start = Date(timeIntervalSince1970: 1_792_504_800)  // Oct 20
        let lookup = ApprovalLookup(event: fields, recurring: true, occurrenceStart: start, occurrences: 37)
        let base: [String: Any] = ["calendarID": "CAL", "itemID": "E", "expectedVersion": "1",
                                   "occurrenceStart": 1_792_504_800, "idempotencyKey": "k"]
        let future = summary(.deleteEvent, base.merging(["span": "future"]) { _, new in new }, lookup)
        check(future.isDelete && row(future, "Applies to")!.value.hasPrefix("Deletes ") &&
              row(future, "Applies to")!.value.hasSuffix(" and 36 later occurrences"), row(future, "Applies to")!.value)
        let all = summary(.deleteEvent, base.merging(["span": "all"]) { _, new in new }, lookup)
        check(row(all, "Applies to")!.value == "Deletes every occurrence (about 37 in the next 400 days)",
              row(all, "Applies to")!.value)
        let one = summary(.updateEvent, base.merging(["notes": "Only this week"]) { _, new in new },
                          ApprovalLookup(event: fields, recurring: true, occurrenceStart: start))
        check(row(one, "Applies to")!.value.hasPrefix("Only "), row(one, "Applies to")!.value)
        let rule = summary(.updateEvent, base.merging([
            "span": "future", "recurrence": ["kind": "rule", "frequency": "weekly", "interval": 2]]) { _, new in new },
                           lookup)
        check(row(rule, "Repeats")!.value == "Every 2 weeks" && row(rule, "Repeats")!.before == "Weekly",
              "the rule in words, before → after")
        check(row(rule, "Applies to")!.value.contains("and later (about 37 occurrences)"),
              row(rule, "Applies to")!.value)
    }

    static func reminders() {
        let s = summary(.createReminder, [
            "listID": "LIST", "title": "Pay rent", "idempotencyKey": "k",
            "due": ["kind": "timed", "at": 1_793_541_600, "timeZone": "America/New_York"],
            "start": ["kind": "all_day", "date": "2026-10-30", "timeZone": "America/New_York"],
            "notes": "Transfer", "url": "mailto:landlord@example.com", "location": "Home", "priority": "high",
            "alarms": [["kind": "relative", "offset": 0], ["kind": "relative", "offset": 3_600]]])
        check(s.rows.map(\.label) == ["Reminder", "Due", "Starts", "Notes", "Link", "Where", "Alerts", "Priority"],
              "\(s.rows.map(\.label))")
        check(row(s, "Link")!.value == "Email link: mailto:landlord@example.com", "email link")
        check(row(s, "Alerts")!.value == "At the due time, 1 h after", row(s, "Alerts")!.value)
        check(row(s, "Priority")!.value == "High", "priority")
        guard case .success(let created) = ReminderChange.parse([
            "title": "Pay rent", "due": ["kind": "timed", "at": 1_793_541_600, "timeZone": "America/New_York"]],
                                                                 creating: true).flatMap({
            ReminderPlan.resolve($0, current: nil, listID: "LIST", now: now)
        }) else { check(false, "base reminder"); return }
        var done = created.target
        done.completed = true
        let reopen = summary(.updateReminder, ["listID": "LIST", "itemID": "R", "expectedVersion": "1",
                                               "completed": false, "targetListID": "LIST2", "idempotencyKey": "k"],
                             ApprovalLookup(reminder: done))
        check(row(reopen, "Completed")!.value == "Not completed" && row(reopen, "Completed")!.before == "Completed",
              "un-completing")
        check(row(reopen, "List")!.value == "Errands → Home", "reminder move")
        let series = summary(.deleteReminder, ["listID": "LIST", "itemID": "R", "expectedVersion": "1",
                                               "recurrenceScope": "series", "idempotencyKey": "k"],
                             ApprovalLookup(reminder: created.target, recurring: true))
        check(series.isDelete && row(series, "Repeats")!.value ==
              "Deletes this repeating reminder and all its future occurrences", "series delete")
    }
}
