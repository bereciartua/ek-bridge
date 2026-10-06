import EventKit
import Foundation

// ReminderSchedule against in-memory EKReminder objects: what a resolved
// write sets, what reads back, the rows read results show, and restoring a
// snapshot. No store access.
@main
struct ReminderScheduleTests {
    static func main() {
        let store = EKEventStore()
        let now = Date()
        let future = Int64(now.timeIntervalSince1970) + 30 * 86_400
        func plan(_ p: [String: Any], current: ReminderFields? = nil)
            -> (target: ReminderFields, touched: Set<ReminderField>) {
            guard case .success(let value) = ReminderChange.parse(p, creating: current == nil).flatMap({
                ReminderPlan.resolve($0, current: current, listID: "", now: now)
            }) else { preconditionFailure("plan \(p)") }
            return value
        }
        let due: [String: Any] = ["kind": "timed", "at": future, "timeZone": "UTC"]
        let daily: [String: Any] = ["kind": "rule", "frequency": "daily", "interval": 1]

        // A repeating reminder: its default alarm is relative.
        let recurring = EKReminder(eventStore: store)
        let created = plan(["title": "Daily", "due": due, "recurrence": daily])
        ReminderSchedule.apply(created.target, created.touched, to: recurring, list: nil)
        precondition(recurring.hasRecurrenceRules)
        precondition(recurring.alarms?.count == 1 && recurring.alarms?.first?.absoluteDate == nil)
        precondition(recurring.alarms?.first?.relativeOffset == 0)
        precondition(ReminderWriteVerifier.mismatches(created.target, ReminderSchedule.fields(recurring),
                                                      touched: created.touched.subtracting([.list])).isEmpty)
        let row = ReminderSchedule.describe(recurring)
        precondition((row["recurrence"] as? [String: Any])?["frequency"] as? String == "daily")
        precondition((row["recurrence"] as? [String: Any])?["summary"] as? String == "Daily")
        precondition((row["alarms"] as? [[String: Any]])?.first?["kind"] as? String == "relative")
        precondition(row["priority"] as? String == "none" && row["priorityRaw"] as? Int == 0)
        precondition(row["notesPreview"] is NSNull && row["hasNotes"] as? Bool == false)

        // Every field, then a readback match and a list row.
        let full = EKReminder(eventStore: store)
        let notes = String(repeating: "line\n", count: 100)
        let all = plan(["title": "Full", "due": due, "notes": notes, "url": "https://example.com/x",
                        "location": "Home", "priority": "high",
                        "alarms": [["kind": "relative", "offset": -900], ["kind": "absolute", "at": future - 60],
                                   ["kind": "location", "location": ["title": "Home", "latitude": 1,
                                                                     "longitude": 2, "radius": 100],
                                    "proximity": "arrive"]]])
        ReminderSchedule.apply(all.target, all.touched, to: full, list: nil)
        precondition(full.priority == 1 && full.notes == notes && full.url?.absoluteString == "https://example.com/x")
        precondition(ReminderWriteVerifier.mismatches(all.target, ReminderSchedule.fields(full),
                                                      touched: all.touched.subtracting([.list])).isEmpty)
        let fullRow = ReminderSchedule.describe(full)
        precondition((fullRow["notesPreview"] as? String)?.utf8.count == 300 &&
                     fullRow["notesTruncated"] as? Bool == true && fullRow["hasNotes"] as? Bool == true)
        precondition(ReminderSchedule.describe(full, full: true)["notes"] as? String == notes)
        precondition(fullRow["url"] as? String == "https://example.com/x" && fullRow["urlSchemeAllowed"] as? Bool == true)
        precondition(fullRow["priority"] as? String == "high")
        // EventKit keeps alarms in its own order.
        precondition(Set((fullRow["alarms"] as? [[String: Any]] ?? []).compactMap { $0["kind"] as? String }) ==
                     ["relative", "absolute", "location"], "location alarms are no longer dropped")

        // A snapshot restores everything, including an alarm the bridge can't express.
        let custom = EKReminder(eventStore: store)
        ReminderSchedule.apply(all.target, all.touched, to: custom, list: nil)
        let sound = EKAlarm(relativeOffset: -60)
        sound.soundName = "test-sound"
        custom.alarms = (custom.alarms ?? []) + [sound]
        let snapshot = ReminderSnapshot(custom)
        let changed = plan(["title": "Changed", "notes": NSNull(), "priority": "low"],
                           current: ReminderSchedule.fields(custom))
        ReminderSchedule.apply(changed.target, changed.touched, to: custom, list: nil)
        precondition(custom.title == "Changed" && custom.notes == nil && custom.priority == 9)
        precondition(custom.alarms?.contains { $0.soundName == "test-sound" } == true, "untouched alarms stay")
        snapshot.restore(to: custom)
        precondition(custom.title == "Full" && custom.notes == notes && custom.priority == 1)
        precondition(custom.alarms?.count == 4 && custom.alarms?.contains { $0.soundName == "test-sound" } == true,
                     "restored alarms: \((custom.alarms ?? []).map { "\($0.relativeOffset) \($0.soundName ?? "-")" })")

        // Moving the due keeps an unsupported alarm in place (it is copied, not dropped).
        let moved = plan(["due": ["kind": "timed", "at": future + 3_600, "timeZone": "UTC"]],
                         current: ReminderSchedule.fields(custom))
        ReminderSchedule.apply(moved.target, moved.touched, to: custom, list: nil)
        precondition(custom.alarms?.count == 4 && custom.alarms?.contains { $0.soundName == "test-sound" } == true)

        // Clearing the due date and the rule.
        let cleared = plan(["due": ["kind": "none"], "recurrence": ["kind": "none"]],
                           current: ReminderSchedule.fields(recurring))
        ReminderSchedule.apply(cleared.target, cleared.touched, to: recurring, list: nil)
        precondition(recurring.dueDateComponents == nil && !recurring.hasRecurrenceRules)
        precondition((recurring.alarms ?? []).isEmpty)
        print("Reminder schedule: apply, readback, rows, relative recurring alarms, location alarms, "
              + "snapshot restore and clear passed")
    }
}
