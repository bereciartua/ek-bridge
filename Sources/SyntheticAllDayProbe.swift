#if EVENTKIT_SYNTHETIC_TEST
import EventKit
import Foundation
import Darwin

@MainActor
enum SyntheticAllDayProbe {
    private static let key = "allDayProbeCalendarID"
    private static let name = "EK Bridge All Day Probe"
    private static let title = "EK Bridge Synthetic All Day"

    static func run() {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess,
              !FileManager.default.fileExists(atPath: AppIdentity.bridgeRoot + "/current.json"),
              UserDefaults.standard.string(forKey: key) == nil else {
            report(["outcome": "precondition_failed"]); return
        }
        let store = EKEventStore()
        guard !store.calendars(for: .event).contains(where: { $0.title == name }),
              let source = store.sources.first(where: {
                  $0.title == "iCloud" && !$0.isDelegate && !$0.calendars(for: .event).isEmpty
              }) else { report(["outcome": "unique_icloud_source_unavailable"]); return }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = name
        calendar.source = source
        do { try store.saveCalendar(calendar, commit: true) }
        catch { report(["outcome": "calendar_create_failed", "error": code(error)]); return }
        let id = calendar.calendarIdentifier
        guard !id.isEmpty else {
            try? store.removeCalendar(calendar, commit: true)
            report(["outcome": "calendar_id_unavailable"]); return
        }
        UserDefaults.standard.set(id, forKey: key)
        guard UserDefaults.standard.synchronize() else {
            try? store.removeCalendar(calendar, commit: true)
            UserDefaults.standard.removeObject(forKey: key)
            report(["outcome": "calendar_id_persistence_failed"]); return
        }

        let zone = TimeZone(identifier: "America/New_York")!
        var local = Calendar(identifier: .gregorian)
        local.timeZone = zone
        let start = local.date(from: DateComponents(year: 2026, month: 10, day: 14))!
        let end = local.date(from: DateComponents(year: 2026, month: 10, day: 16))!
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.startDate = start
        event.endDate = end
        event.timeZone = zone
        event.isAllDay = true
        event.notes = "Synthetic all-day readback probe"
        var result: [String: Any] = ["outcome": "probe", "calendarID": id,
                                     "requestedStart": start.timeIntervalSince1970,
                                     "requestedEnd": end.timeIntervalSince1970]
        do {
            try store.save(event, span: .thisEvent)
            result["savedID"] = event.eventIdentifier ?? ""
            result["savedObject"] = snapshot(event, local: local)
            if let identifier = event.eventIdentifier,
               let readback = store.event(withIdentifier: identifier) {
                result["readback"] = snapshot(readback, local: local)
            } else { result["readback"] = "missing" }
        } catch {
            result["outcome"] = "event_save_failed"
            result["error"] = code(error)
        }
        cleanup(store, id: id, result: &result)
        report(result)
    }

    static func cleanupOnly() {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess,
              !FileManager.default.fileExists(atPath: AppIdentity.bridgeRoot + "/current.json"),
              let id = UserDefaults.standard.string(forKey: key) else {
            report(["outcome": "cleanup_precondition_failed"]); return
        }
        var result: [String: Any] = ["outcome": "cleanup_checked", "calendarID": id]
        cleanup(EKEventStore(), id: id, result: &result)
        report(result)
    }

    private static func cleanup(_ store: EKEventStore, id: String,
                                result: inout [String: Any]) {
        guard let calendar = store.calendars(for: .event).first(where: {
                  $0.calendarIdentifier == id && $0.title == name
              }) else { result["cleanup"] = "refused_identity_mismatch"; return }
        // A newly created, ID-verified calendar is removed as a unit so a
        // provider-created duplicate occurrence cannot be left behind.
        do {
            try store.removeCalendar(calendar, commit: true)
            UserDefaults.standard.removeObject(forKey: key)
            result["cleanup"] = UserDefaults.standard.synchronize() ? "removed_calendar" : "removed_calendar_state_not_synced"
        } catch { result["cleanup"] = "failed: \(code(error))" }
    }

    private static func snapshot(_ event: EKEvent, local: Calendar) -> [String: Any] {
        let formatter = DateFormatter()
        formatter.calendar = local
        formatter.timeZone = local.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZ"
        return ["calendarID": event.calendar.calendarIdentifier,
                "title": event.title ?? "", "allDay": event.isAllDay,
                "timeZone": event.timeZone?.identifier ?? "",
                "notes": event.notes ?? "",
                "start": event.startDate.timeIntervalSince1970,
                "end": event.endDate.timeIntervalSince1970,
                "localStart": formatter.string(from: event.startDate),
                "localEnd": formatter.string(from: event.endDate)]
    }

    private static func code(_ error: Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }

    private static func report(_ fields: [String: Any]) {
        UserDefaults.standard.set(fields, forKey: "allDayProbeLastResult")
        _ = UserDefaults.standard.synchronize()
        if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data + Data([10]))
        }
    }
}
#endif
