import Foundation

@main
struct ReminderDueTests {
    static func main() {
        let zone = "America/New_York"
        let dueAt = seconds("2026-10-04T21:33:15Z")
        guard case .keep = ReminderDueChange.parse(parameters: [:]) else {
            preconditionFailure("missing due should preserve an existing schedule")
        }
        guard case .clear = ReminderDueChange.parse(parameters: [
            "due": ["kind": "none"]]) else { preconditionFailure("clear") }
        let timed: [String: Any] = ["kind": "timed", "at": dueAt, "timeZone": zone]
        guard case .set(let exact)? = ReminderDueChange.parse(parameters: ["due": timed]) else {
            preconditionFailure("timed due")
        }
        let parts = exact.components
        precondition(parts.year == 2026 && parts.month == 10 && parts.day == 4)
        precondition(parts.hour == 17 && parts.minute == 33 && parts.second == 15)
        precondition(parts.timeZone?.identifier == zone && exact.roundTrips)
        precondition(exact.alarmAt?.timeIntervalSince1970 == Double(dueAt))
        let described = ReminderDueSpec.readback(parts) as! [String: Any]
        precondition(described["kind"] as? String == "timed")
        precondition(described["at"] as? Double == Double(dueAt))
        precondition(described["timeZone"] as? String == zone)
        guard case .set(let silent)? = ReminderDueChange.parse(parameters: [
            "due": ["kind": "timed", "at": dueAt, "timeZone": zone,
                    "alarmAt": NSNull()]]) else { preconditionFailure("silent timed due") }
        precondition(silent.alarmAt == nil)
        let day: [String: Any] = ["kind": "all_day", "date": "2026-03-08",
                                  "timeZone": zone]
        guard case .set(let allDay)? = ReminderDueChange.parse(parameters: ["due": day]) else {
            preconditionFailure("all day")
        }
        precondition(allDay.components.hour == nil && allDay.components.minute == nil)
        precondition(allDay.alarmAt == nil)
        let allDayReadback = ReminderDueSpec.readback(allDay.components) as! [String: Any]
        precondition(allDayReadback["kind"] as? String == "all_day")
        precondition(allDayReadback["date"] as? String == "2026-03-08")
        guard case .set(let alertedDay)? = ReminderDueChange.parse(parameters: [
            "due": ["kind": "all_day", "date": "2026-03-08",
                    "timeZone": zone, "alarmAt": seconds("2026-03-08T13:00:00Z")]])
        else { preconditionFailure("all-day explicit alarm") }
        precondition(alertedDay.alarmAt?.timeIntervalSince1970 ==
                     Double(seconds("2026-03-08T13:00:00Z")))
        for invalid: [String: Any] in [
            ["kind": "timed", "at": dueAt, "timeZone": "Not/A_Zone"],
            ["kind": "timed", "at": Double(dueAt) + 0.5, "timeZone": zone],
            ["kind": "timed", "at": true, "timeZone": zone],
            ["kind": "timed", "at": dueAt, "timeZone": zone, "extra": true],
            ["kind": "all_day", "date": "2026-02-30", "timeZone": zone],
            ["kind": "all_day", "date": "2026-3-8", "timeZone": zone],
            ["kind": "none", "at": dueAt],
        ] {
            precondition(ReminderDueChange.parse(parameters: ["due": invalid]) == nil)
        }
        let firstFold = seconds("2026-11-01T05:30:00Z")
        let secondFold = seconds("2026-11-01T06:30:00Z")
        let firstAccepted = ReminderDueChange.parse(parameters: ["due": [
            "kind": "timed", "at": firstFold, "timeZone": zone]]) != nil
        let secondAccepted = ReminderDueChange.parse(parameters: ["due": [
            "kind": "timed", "at": secondFold, "timeZone": zone]]) != nil
        precondition(firstAccepted != secondAccepted,
                     "one repeated wall time must be rejected rather than silently moved")
        let foldComponents = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: zone)!,
                                             from: Date(timeIntervalSince1970: Double(firstFold)))
        let folded = ReminderDueSpec.readback(foldComponents) as! [String: Any]
        precondition(folded["kind"] as? String == "ambiguous_timed")
        precondition(folded["at"] == nil)
        var floatingDay = allDay.components
        floatingDay.timeZone = nil
        floatingDay.calendar = nil
        let floating = ReminderDueSpec.readback(floatingDay) as! [String: Any]
        precondition(floating["kind"] as? String == "floating_all_day")
        var missingSecond = parts
        missingSecond.second = nil
        precondition(ReminderDueSpec.sameDayAndTime(missingSecond, parts) == false)
        var zeroSecond = parts
        zeroSecond.second = 0
        precondition(ReminderDueSpec.sameDayAndTime(missingSecond, zeroSecond))
        print("Reminder due: exact seconds, timezone, DST fold, all-day, clear, alarms, invalid shapes passed")
    }

    private static func seconds(_ value: String) -> Int64 {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        return Int64(parser.date(from: value)!.timeIntervalSince1970)
    }
}
