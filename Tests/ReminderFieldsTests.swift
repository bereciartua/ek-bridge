import Foundation

// Reminder writes as values (plan 03 §5, §10, §12, §14): parsing, the
// resolver that merges a partial update with the current reminder, and the
// readback verifier. No event store.
@main
struct ReminderFieldsTests {
    nonisolated(unsafe) static var checks = 0
    static let now = Date(timeIntervalSince1970: 1_791_216_000)  // 2026-10-05T12:00:00-04:00
    static let oct6at9: Int64 = 1_791_291_600                    // 2026-10-06T09:00:00-04:00

    static func main() {
        priorities()
        parsing()
        creating()
        dueChanges()
        alarmLists()
        recurrence()
        completion()
        verifier()
        print("Reminder fields: \(checks) checks of priority, parse, resolve (start, alarms, recurrence, "
              + "completion, moves) and readback verification passed")
    }

    static func check(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
        checks += 1
        if !condition {
            print("FAIL line \(line): \(message())")
            exit(1)
        }
    }

    static func due(_ at: Int64, zone: String = "America/New_York", alarm: Any? = nil) -> [String: Any] {
        var spec: [String: Any] = ["kind": "timed", "at": at, "timeZone": zone]
        if let alarm { spec["alarmAt"] = alarm }
        return spec
    }

    static func resolve(_ p: [String: Any], current: ReminderFields? = nil)
        -> Result<(target: ReminderFields, touched: Set<ReminderField>), FieldError> {
        ReminderChange.parse(p, creating: current == nil).flatMap {
            ReminderPlan.resolve($0, current: current, listID: "LIST", now: now)
        }
    }

    static func plan(_ p: [String: Any], current: ReminderFields? = nil,
                     line: Int = #line) -> (target: ReminderFields, touched: Set<ReminderField>) {
        switch resolve(p, current: current) {
        case .success(let value): return value
        case .failure(let error):
            print("FAIL line \(line): \(error.code)")
            exit(1)
        }
    }

    static func error(_ p: [String: Any], current: ReminderFields? = nil) -> String? {
        if case .failure(let error) = resolve(p, current: current) { return error.code }
        return nil
    }

    static func priorities() {
        check(ReminderPriority.allCases.map(\.raw) == [0, 9, 5, 1], "RFC 5545 values")
        check((0...9).map { ReminderPriority.read($0)?.rawValue ?? "?" } ==
              ["none", "high", "high", "high", "high", "medium", "low", "low", "low", "low"], "reads")
        check(ReminderPriority.read(10) == nil, "out of range")
    }

    static func parsing() {
        let item: [String: Any] = [:]
        check(error(item, current: .blank(listID: "LIST")) == "nothing_to_change", "nothing to change")
        check(error(["title": "x", "completed": true]) == "invalid_parameters_or_target", "completed on create")
        check(error(["title": "x", "start": NSNull()]) == "invalid_schedule", "null start on create")
        check(error(["title": "x", "priority": "urgent"]) == "invalid_parameters_or_target", "bad priority")
        check(error(["title": "x", "due": due(oct6at9, alarm: oct6at9), "alarms": []]) == "invalid_alarms",
              "the 0.5 alarm and the list together")
        check(error(["title": "x", "recurrence": ["kind": "rule", "frequency": "daily"]]) == "recurrence_requires_due",
              "rule without due")
        check(error(["title": "x", "url": "ftp://x.test"]) == "url_scheme_not_allowed", "url")
    }

    static func creating() {
        // The 0.5 default: a timed due gets an alarm at the due time; start = due.
        let simple = plan(["title": "Pay rent", "due": due(oct6at9)])
        check(simple.target.alarms == [.absolute(oct6at9)], "default alarm at a timed due")
        check(ReminderFields.sameDate(simple.target.start, simple.target.due), "start defaults to due")
        let day = plan(["title": "x", "due": ["kind": "all_day", "date": "2026-10-06", "timeZone": "UTC"]])
        check(day.target.alarms.isEmpty, "no default alarm for a due day")
        let silent = plan(["title": "x", "due": due(oct6at9, alarm: NSNull())])
        check(silent.target.alarms.isEmpty, "alarmAt null")
        let listed = plan(["title": "x", "due": due(oct6at9), "alarms": [["kind": "relative", "offset": -3_600]]])
        check(listed.target.alarms == [.relative(-3_600)], "alarms replace the default")
        let started = plan(["title": "x", "due": due(oct6at9), "start": due(oct6at9 - 86_400)])
        check(!ReminderFields.sameDate(started.target.start, started.target.due), "explicit start")
        let full = plan(["title": "x", "notes": "n", "url": "https://example.com", "priority": "medium"])
        check(full.target.notes == "n" && full.target.url == "https://example.com" && full.target.priority == 5,
              "text fields and priority")
        check(full.touched.isSuperset(of: [.title, .notes, .url, .priority, .list]), "touched")
        check(error(["title": "x", "location": "Home"]) == nil && !plan(["title": "x"]).touched.contains(.location),
              "a reminder's location text isn't parsed (EventKit can't set it; the key is refused earlier)")
        check(error(["title": "x", "due": due(Int64(now.timeIntervalSince1970) - 60)]) == "alarm_in_past",
              "default alarm in the past")
        check(error(["title": "x", "alarms": [["kind": "relative", "offset": 0]]]) == "alarm_requires_due",
              "relative alarm needs due")
    }

    static func current(_ changes: (inout ReminderFields) -> Void = { _ in }) -> ReminderFields {
        guard case .success(let created) = resolve(["title": "Pay rent", "due": due(oct6at9)]) else {
            fatalError("base reminder")
        }
        var fields = created.target
        changes(&fields)
        return fields
    }

    static func dueChanges() {
        let base = current()
        // Partial update: a title alone.
        let titled = plan(["title": "Pay rent now"], current: base)
        check(titled.touched == [.title] && titled.target.alarms == base.alarms, "title only")
        // The due moves; the start (equal to it) and the alarm at it follow.
        let later = plan(["due": due(oct6at9 + 86_400)], current: base)
        check(ReminderFields.sameDate(later.target.start, later.target.due), "start follows due")
        check(later.target.alarms == [.absolute(oct6at9 + 86_400)], "the alarm at the old due follows")
        // A start that differs from the due stays put (the 0.5 complex_start block is gone).
        let independent = current {
            var start = $0.due!
            start.day = 1
            $0.start = start
        }
        // EventKit stores an all-day start as midnight; it still follows an all-day due.
        var midnight = DateComponents(year: 2026, month: 10, day: 6, hour: 0, minute: 0, second: 0)
        midnight.timeZone = TimeZone(identifier: "America/New_York")
        var day = DateComponents(year: 2026, month: 10, day: 6)
        day.timeZone = TimeZone(identifier: "America/New_York")
        check(ReminderFields.sameStart(day, midnight) && !ReminderFields.sameStart(midnight, day) &&
              !ReminderFields.sameDate(day, midnight), "an all-day start saved as midnight")
        let allDayDue = plan(["title": "x", "due": ["kind": "all_day", "date": "2026-10-06",
                                                    "timeZone": "America/New_York"]]).target
        var stored = allDayDue
        stored.start = midnight
        check(ReminderWriteVerifier.mismatches(allDayDue, stored, touched: [.start]).isEmpty, "verifier accepts it")
        let follows = plan(["due": ["kind": "all_day", "date": "2026-10-08", "timeZone": "America/New_York"]],
                           current: stored)
        check(follows.target.start?.day == 8 && follows.touched.contains(.start), "and it follows the due date")
        let moved = plan(["due": due(oct6at9 + 86_400)], current: independent)
        check(moved.target.start?.day == 1 && !moved.touched.contains(.start), "an independent start stays")
        // Other alarms stay; a relative one is kept.
        let mixed = current { $0.alarms = [.absolute(oct6at9), .absolute(oct6at9 - 3_600), .relative(-600), nil] }
        let shifted = plan(["due": due(oct6at9 + 86_400)], current: mixed)
        check(shifted.target.alarms == [.absolute(oct6at9 + 86_400), .absolute(oct6at9 - 3_600), .relative(-600), nil],
              "only the alarm at the due moves; unsupported ones stay in place")
        // A due day drops the alarm at the old due time.
        let toDay = plan(["due": ["kind": "all_day", "date": "2026-10-07", "timeZone": "America/New_York"]],
                         current: base)
        check(toDay.target.alarms.isEmpty, "alarm at the due dropped for a due day")
        // Clearing the due clears a matching start and relative alarms.
        let cleared = plan(["due": ["kind": "none"]], current: current { $0.alarms = [.relative(-600)] })
        check(cleared.target.due == nil && cleared.target.start == nil && cleared.target.alarms.isEmpty, "cleared")
        // The explicit 0.5 alarm replaces everything, unless something can't be expressed.
        check(error(["due": due(oct6at9, alarm: oct6at9 - 600)], current: mixed) == "alarms_unsupported",
              "unsupported alarms block the 0.5 alarm")
        let replaced = plan(["due": due(oct6at9, alarm: oct6at9 - 600), "replaceUnsupportedAlarms": true],
                            current: mixed)
        check(replaced.target.alarms == [.absolute(oct6at9 - 600)], "replaced with consent")
        // Completed reminders keep their schedule unless reopened.
        let done = current { $0.completed = true }
        check(error(["due": due(oct6at9 + 60)], current: done) == "completed_reminder_due_unsupported", "completed")
        check(plan(["due": due(oct6at9 + 60), "completed": false], current: done).target.completed == false,
              "reopen and move")
    }

    static func alarmLists() {
        let base = current()
        let listed = plan(["alarms": [["kind": "relative", "offset": -900], ["kind": "absolute", "at": oct6at9 - 60]]],
                          current: base)
        check(listed.target.alarms == [.relative(-900), .absolute(oct6at9 - 60)] && listed.touched == [.alarms],
              "replace the list")
        check(plan(["alarms": NSNull()], current: base).target.alarms.isEmpty, "null clears")
        check(error(["alarms": []], current: current { $0.alarms = [nil] }) == "alarms_unsupported",
              "unsupported alarms")
        check(plan(["alarms": [], "replaceUnsupportedAlarms": true], current: current { $0.alarms = [nil] })
                .target.alarms.isEmpty, "unsupported alarms replaced with consent")
        let place = ["title": "Home", "latitude": 1, "longitude": 2] as [String: Any]
        let located = plan(["alarms": [["kind": "location", "location": place, "proximity": "leave"]]],
                           current: base)
        check(located.target.alarms.count == 1, "location alarm (P4)")
        check(error(["alarms": [["kind": "relative", "offset": -60]], "due": ["kind": "none"]], current: base)
              == "alarm_requires_due", "relative alarm without due")
    }

    static func recurrence() {
        let base = current()
        let daily: [String: Any] = ["kind": "rule", "frequency": "daily"]
        // A one-off becoming repeating: its alarm at the due time becomes relative.
        let repeating = plan(["recurrence": daily], current: base)
        check(repeating.target.alarms == [.relative(0)] && repeating.touched.contains(.alarms), "alarm made relative")
        check(error(["recurrence": daily], current: current { $0.alarms = [.absolute(oct6at9 - 600)] })
              == "recurrence_requires_relative_alarm", "another absolute alarm blocks it")
        check(error(["recurrence": daily, "alarms": [["kind": "absolute", "at": oct6at9]]], current: base)
              == "recurrence_requires_relative_alarm", "absolute alarms on a repeating reminder")
        // The 0.5 explicit alarm on a repeating reminder becomes relative.
        let legacy = plan(["title": "x", "due": due(oct6at9, alarm: oct6at9 - 300), "recurrence": daily])
        check(legacy.target.alarms == [.relative(-300)], "0.5 alarm made relative")
        // Anchors.
        let wednesdays: [String: Any] = ["kind": "rule", "frequency": "weekly", "weekdays": ["WE"]]
        check(error(["recurrence": wednesdays], current: base) == "recurrence_anchor_mismatch", "Tuesday due")
        check(plan(["recurrence": wednesdays, "due": due(oct6at9 + 86_400)], current: base)
                .target.recurrence.spec?.weekdays.first?.day == 4, "moved to a Wednesday")
        let rule = plan(["recurrence": daily], current: base).target
        check(error(["due": ["kind": "none"]], current: rule) == "recurrence_requires_due", "rule keeps needing due")
        check(error(["due": due(oct6at9 + 3_600)], current: current {
            $0.recurrence = .unsupported(reason: "complex_rule", summary: "FREQ=YEARLY;BYWEEKNO=20")
        }) == "recurrence_unsupported", "an unsupported rule isn't rewritten")
        check(plan(["notes": "fine"], current: current {
            $0.recurrence = .unsupported(reason: "complex_rule", summary: "FREQ=YEARLY;BYWEEKNO=20")
        }).touched == [.notes], "other fields of an unsupported rule are fine")
    }

    static func completion() {
        let base = current()
        check(plan(["completed": true], current: base).target.completed, "complete")
        let rule = plan(["recurrence": ["kind": "rule", "frequency": "daily"]], current: base).target
        check(error(["completed": true], current: rule) == "recurrence_scope_required", "repeating → complete_reminder")
        check(error(["completed": false], current: current {
            $0.completed = true
            $0.recurrence = rule.recurrence
        }) == "recurrence_uncomplete_unsupported", "uncomplete a repeating one")
        check(plan(["completed": false], current: current { $0.completed = true }).target.completed == false,
              "reopen a one-off")
        let moved = plan(["targetListID": "OTHER"], current: base)
        check(moved.target.listID == "OTHER" && moved.touched == [.list], "move")
    }

    static func verifier() {
        let plan = plan(["title": "x", "due": due(oct6at9), "notes": "n", "priority": "high",
                         "alarms": [["kind": "relative", "offset": -60]]])
        var saved = plan.target
        check(ReminderWriteVerifier.mismatches(plan.target, saved, touched: plan.touched).isEmpty, "match")
        saved.priority = 2
        saved.notes = "n\n"
        check(ReminderWriteVerifier.mismatches(plan.target, saved, touched: plan.touched) == [.notes, .priority],
              "mismatches in field order")
        saved = plan.target
        saved.due?.minute = 1
        check(ReminderWriteVerifier.mismatches(plan.target, saved, touched: plan.touched) == [.due], "due")
        saved = plan.target
        saved.due?.timeZone = TimeZone(identifier: "Europe/Kiev")
        check(ReminderWriteVerifier.mismatches(plan.target, saved, touched: plan.touched) == [.due], "due zone")
        saved = plan.target
        saved.alarms = [.relative(-60), nil]
        check(ReminderWriteVerifier.mismatches(plan.target, saved, touched: plan.touched) == [.alarms],
              "an extra alarm")
        check(ReminderWriteVerifier.code([.priority], "restored") == "priority_readback_failed_restored", "code")
        // EventKit keeps a due day floating (live probe, Oct 2026).
        let day = Self.plan(["title": "x", "due": ["kind": "all_day", "date": "2026-10-15",
                                                   "timeZone": "America/New_York"]])
        var floating = day.target
        floating.due?.timeZone = nil
        floating.start = DateComponents(year: 2026, month: 10, day: 15, hour: 0, minute: 0, second: 0)
        check(ReminderWriteVerifier.mismatches(day.target, floating, touched: day.touched).isEmpty,
              "a floating due day and midnight start match")
        floating.due?.day = 16
        check(ReminderWriteVerifier.mismatches(day.target, floating, touched: day.touched) == [.due], "another day")
    }
}
