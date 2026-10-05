#if EVENTKIT_SYNTHETIC_TEST
import EventKit
import Foundation
import Darwin

// Test-only, direct EventKit probe. It creates one uniquely named reminder list
// and no client credentials or grants. The ordinary app omits this code.
@MainActor
enum SyntheticRecurrenceProbe {
    private static let listKey = "recurrenceProbeReminderListID"
    private static let name = "EventKit Bridge Recurrence Probe"
    private static let marker = "EventKit Bridge Recurrence Probe: "

    static func run() {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            report("full_reminders_access_required"); return
        }
        guard !FileManager.default.fileExists(atPath: "/tmp/eventkit-bridge-\(getuid())/current.json") else {
            report("stop_bridge_first"); return
        }
        guard UserDefaults.standard.string(forKey: listKey) == nil else {
            report("previous_probe_requires_cleanup"); return
        }
        let store = EKEventStore()
        guard !store.calendars(for: .reminder).contains(where: { $0.title == name }),
              let source = store.sources.first(where: {
                  $0.title == "iCloud" && !$0.isDelegate &&
                  !$0.calendars(for: .reminder).isEmpty
              }) else {
            report("unique_icloud_source_unavailable"); return
        }
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = name
        list.source = source
        do { try store.saveCalendar(list, commit: true) }
        catch { report("list_create_failed", ["error": code(error)]); return }
        let id = list.calendarIdentifier
        guard !id.isEmpty else {
            try? store.removeCalendar(list, commit: true)
            report("list_id_unavailable"); return
        }
        UserDefaults.standard.set(id, forKey: listKey)
        guard UserDefaults.standard.synchronize() else {
            try? store.removeCalendar(list, commit: true)
            UserDefaults.standard.removeObject(forKey: listKey)
            report("list_id_persistence_failed"); return
        }

        let due = Date().addingTimeInterval(24 * 60 * 60)
        let components = Calendar.current.dateComponents(in: .current,
            from: due)
        let completion = EKReminder(eventStore: store)
        completion.title = marker + "complete"
        completion.calendar = list
        completion.startDateComponents = components
        completion.dueDateComponents = components
        completion.recurrenceRules = [EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)]
        let deletion = EKReminder(eventStore: store)
        deletion.title = marker + "delete"
        deletion.calendar = list
        deletion.startDateComponents = components
        deletion.dueDateComponents = components
        deletion.recurrenceRules = [EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)]

        var observations: [String: Any] = ["testListID": id]
        do {
            try store.save(completion, commit: true)
            try store.save(deletion, commit: true)
            guard let before = reminders(store, list), before.count == 2,
                  let toComplete = before.first(where: { $0.title == completion.title }),
                  let toDelete = before.first(where: { $0.title == deletion.title }),
                  before.allSatisfy({ $0.calendar.calendarIdentifier == id &&
                      $0.title.hasPrefix(marker) && $0.recurrenceRules?.count == 1 }) else {
                observations["failure"] = "precondition_failed"
                cleanup(store, id: id, result: &observations)
                report("probe_failed", observations)
                return
            }
            observations["before"] = before.map(snapshot)
            toComplete.isCompleted = true
            try store.save(toComplete, commit: true)
            guard let afterComplete = reminders(store, list) else {
                observations["failure"] = "completion_readback_failed"
                cleanup(store, id: id, result: &observations)
                report("probe_failed", observations)
                return
            }
            observations["afterComplete"] = afterComplete.map(snapshot)
            // Delete only the separate, app-created probe series by its saved ID.
            guard let deleteAgain = afterComplete.first(where: {
                $0.calendarItemIdentifier == toDelete.calendarItemIdentifier &&
                $0.title == deletion.title && $0.calendar.calendarIdentifier == id
            }) else {
                observations["failure"] = "deletion_target_missing"
                cleanup(store, id: id, result: &observations)
                report("probe_failed", observations)
                return
            }
            try store.remove(deleteAgain, commit: true)
            guard let afterDelete = reminders(store, list) else {
                observations["failure"] = "deletion_readback_failed"
                cleanup(store, id: id, result: &observations)
                report("probe_failed", observations)
                return
            }
            observations["afterDelete"] = afterDelete.map(snapshot)
            cleanup(store, id: id, result: &observations)
            report("probe_complete", observations)
        } catch {
            observations["error"] = code(error)
            cleanup(store, id: id, result: &observations)
            report("probe_failed", observations)
        }
    }

    static func cleanupOnly() {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess,
              !FileManager.default.fileExists(atPath: "/tmp/eventkit-bridge-\(getuid())/current.json"),
              let id = UserDefaults.standard.string(forKey: listKey) else {
            report("cleanup_precondition_failed"); return
        }
        var result: [String: Any] = ["testListID": id]
        cleanup(EKEventStore(), id: id, result: &result)
        report("cleanup_checked", result)
    }

    private static func cleanup(_ store: EKEventStore, id: String,
                                result: inout [String: Any]) {
        guard let list = store.calendars(for: .reminder).first(where: {
                  $0.calendarIdentifier == id && $0.title == name
              }),
              let rows = reminders(store, list),
              rows.allSatisfy({ $0.calendar.calendarIdentifier == id &&
                  $0.title.hasPrefix(marker) }) else {
            result["cleanup"] = "refused_identity_or_contents_mismatch"
            return
        }
        do {
            try store.removeCalendar(list, commit: true)
            UserDefaults.standard.removeObject(forKey: listKey)
            result["cleanup"] = UserDefaults.standard.synchronize() ? "removed_list" : "removed_list_state_not_synced"
        } catch {
            result["cleanup"] = "failed: \(code(error))"
        }
    }

    private static func reminders(_ store: EKEventStore, _ list: EKCalendar) -> [EKReminder]? {
        var value: [EKReminder]??
        let predicate = store.predicateForReminders(in: [list])
        store.fetchReminders(matching: predicate) { reminders in
            DispatchQueue.main.async { value = reminders }
        }
        let deadline = Date().addingTimeInterval(30)
        while value == nil && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        return value ?? nil
    }

    private static func snapshot(_ reminder: EKReminder) -> [String: Any] {
        ["title": reminder.title ?? "", "id": reminder.calendarItemIdentifier,
         "completed": reminder.isCompleted,
         "completionDate": reminder.completionDate.map { ISO8601DateFormatter().string(from: $0) } ?? "",
         "dueDate": reminder.dueDateComponents?.date.map { ISO8601DateFormatter().string(from: $0) } ?? "",
         "ruleCount": reminder.recurrenceRules?.count ?? 0]
    }

    private static func code(_ error: Error) -> String {
        let value = error as NSError
        return "\(value.domain) \(value.code)"
    }

    private static func report(_ outcome: String, _ fields: [String: Any] = [:]) {
        var result = fields
        result["outcome"] = outcome
        UserDefaults.standard.set(result, forKey: "recurrenceProbeLastResult")
        _ = UserDefaults.standard.synchronize()
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data + Data([10]))
        }
    }
}
#endif
