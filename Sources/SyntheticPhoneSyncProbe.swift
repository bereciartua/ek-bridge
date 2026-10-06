#if EVENTKIT_SYNTHETIC_TEST
import Darwin
import EventKit
import Foundation

// Supervised two-device probe. Each phase is a separate, test-only app launch.
// It never creates a bridge client or edits a collection outside its own list.
@MainActor
enum SyntheticPhoneSyncProbe {
    private static let key = "phoneProbeReminderListID"
    private static let clientKey = "phoneProbeBridgeClientID"
    private static let clientName = "Daily Completion Probe"
    private static let resultKey = "phoneProbeLastResult"
    private static let listName = "EK Bridge Phone Sync Test"
    private static let itemTitle = "EK Bridge Phone Sync Test — daily"

    static func stage() {
        guard ready(), UserDefaults.standard.string(forKey: key) == nil else {
            report("stage_precondition_failed"); return
        }
        let store = EKEventStore()
        let pinnedSourceID = Bundle.main.object(
            forInfoDictionaryKey: "EKBridgeVerifiedICloudReminderSourceID") as? String
        guard !store.calendars(for: .reminder).contains(where: { $0.title == listName }),
              let source = store.sources.first(where: {
                  $0.title == "iCloud" && $0.sourceType == .calDAV &&
                  $0.sourceIdentifier == pinnedSourceID && !$0.isDelegate &&
                  !$0.calendars(for: .reminder).isEmpty
              }),
              store.sources.filter({ $0.sourceIdentifier == source.sourceIdentifier }).count == 1
        else {
            report("unique_icloud_source_unavailable"); return
        }
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = listName
        list.source = source
        do { try store.saveCalendar(list, commit: true) }
        catch { report("list_create_failed", ["error": code(error)]); return }
        let id = list.calendarIdentifier
        guard !id.isEmpty else {
            try? store.removeCalendar(list, commit: true)
            report("list_id_unavailable"); return
        }
        UserDefaults.standard.set(id, forKey: key)
        guard UserDefaults.standard.synchronize() else {
            try? store.removeCalendar(list, commit: true)
            UserDefaults.standard.removeObject(forKey: key)
            report("list_id_persistence_failed"); return
        }

        let calendar = Calendar.current
        guard let tomorrow = calendar.date(byAdding: .day, value: 1,
                                            to: calendar.startOfDay(for: Date())),
              let due = calendar.date(byAdding: .hour, value: 9, to: tomorrow) else {
            var fields: [String: Any] = ["listID": id]
            cleanup(store, id: id, fields: &fields)
            report("due_calculation_failed", fields); return
        }
        let components = calendar.dateComponents(in: calendar.timeZone, from: due)
        let reminder = EKReminder(eventStore: store)
        reminder.title = itemTitle
        reminder.calendar = list
        reminder.startDateComponents = components
        reminder.dueDateComponents = components
        reminder.recurrenceRules = [EKRecurrenceRule(recurrenceWith: .daily,
                                                     interval: 1, end: nil)]
        var fields: [String: Any] = ["listID": id, "list": listName,
                                     "title": itemTitle, "dueLocal": local(due),
                                     "dueUTC": ISO8601DateFormatter().string(from: due),
                                     "recurrence": "daily, every 1 day, no end"]
        do {
            try store.save(reminder, commit: true)
            guard let rows = reminders(store, list), rows.count == 1,
                  let row = rows.first, row.title == itemTitle,
                  !row.isCompleted, row.recurrenceRules?.count == 1 else {
                fields["failure"] = "initial_readback_mismatch"
                cleanup(store, id: id, fields: &fields)
                report("stage_failed", fields); return
            }
            fields["itemID"] = row.calendarItemIdentifier
            fields["initial"] = snapshot(row)
            report("awaiting_first_phone_observation", fields)
        } catch {
            fields["error"] = code(error)
            cleanup(store, id: id, fields: &fields)
            report("stage_failed", fields)
        }
    }

    // A test-only client grants read and complete on the app-owned list only.
    // It has no create, edit, delete, or access to any real collection.
    static func enrollBridgeClient() {
        guard ready(), UserDefaults.standard.string(forKey: clientKey) == nil,
              let id = UserDefaults.standard.string(forKey: key) else {
            report("client_setup_precondition_failed"); return
        }
        let store = EKEventStore()
        guard let list = matchingList(store, id: id),
              list.calendarIdentifier == id,
              list.source.sourceIdentifier == Bundle.main.object(
                forInfoDictionaryKey: "EKBridgeVerifiedICloudReminderSourceID") as? String,
              let rows = reminders(store, list), rows.count == 1,
              rows[0].title == itemTitle, !rows[0].isCompleted,
              rows[0].hasRecurrenceRules, !rows[0].hasAlarms else {
            report("client_setup_item_mismatch"); return
        }
        let registry = ClientRegistry()
        guard let clients = registry.clients(),
              !clients.contains(where: { !$0.revoked && $0.name == clientName }) else {
            report("client_setup_existing_client"); return
        }
        let issued: (id: String, key: String)
        switch registry.createClient(name: clientName) {
        case .success(let value): issued = (value.id, value.signingKey!)
        case .failure: report("client_setup_create_failed"); return
        }
        let credentials = ClientCredentialFiles()
        guard case .success(let path) = credentials.saveNew(
            clientID: issued.id, key: issued.key) else {
            _ = registry.revoke(clientID: issued.id)
            report("client_setup_credential_failed"); return
        }
        let grants = [ClientGrant(resource: .reminderList, targetID: id, mask: 17)]
        guard case .success = registry.replaceGrants(clientID: issued.id, grants: grants) else {
            _ = registry.revoke(clientID: issued.id)
            _ = credentials.remove(clientID: issued.id)
            report("client_setup_grant_failed"); return
        }
        UserDefaults.standard.set(issued.id, forKey: clientKey)
        guard UserDefaults.standard.synchronize() else {
            _ = registry.revoke(clientID: issued.id)
            _ = credentials.remove(clientID: issued.id)
            UserDefaults.standard.removeObject(forKey: clientKey)
            report("client_setup_state_failed"); return
        }
        report("client_setup_complete", ["clientID": issued.id,
                                         "credentialPath": path.path, "listID": id,
                                         "grantMask": 17])
    }

    static func revokeBridgeClient() {
        guard ready(), let clientID = UserDefaults.standard.string(forKey: clientKey),
              let id = UserDefaults.standard.string(forKey: key) else {
            report("client_revoke_precondition_failed"); return
        }
        let registry = ClientRegistry()
        guard let client = registry.clients()?.first(where: { $0.id == clientID }),
              client.name == clientName, client.grants.count == 1,
              client.grants[0].resource == .reminderList,
              client.grants[0].targetID == id, client.grants[0].mask == 17 else {
            report("client_revoke_identity_mismatch"); return
        }
        if !client.revoked {
            guard case .success = registry.revoke(clientID: clientID) else {
                report("client_revoke_failed"); return
            }
        }
        guard case .success = ClientCredentialFiles().remove(clientID: clientID) else {
            report("client_credential_remove_failed"); return
        }
        UserDefaults.standard.removeObject(forKey: clientKey)
        _ = UserDefaults.standard.synchronize()
        report("client_revoke_complete", ["listID": id])
    }

    static func completeAfterPhoneObservation() {
        guard ready(), let id = UserDefaults.standard.string(forKey: key) else {
            report("complete_precondition_failed"); return
        }
        let store = EKEventStore()
        store.refreshSourcesIfNecessary()
        guard let list = matchingList(store, id: id),
              let before = reminders(store, list), before.count == 1,
              let row = before.first, row.title == itemTitle,
              !row.isCompleted, row.hasRecurrenceRules else {
            report("complete_refused_identity_or_contents_mismatch", ["listID": id]); return
        }
        var fields: [String: Any] = ["listID": id, "before": before.map(snapshot)]
        row.isCompleted = true
        do {
            try store.save(row, commit: true)
            guard let after = reminders(store, list) else {
                report("completion_readback_unavailable", fields); return
            }
            fields["after"] = after.map(snapshot)
            fields["completedOccurrenceCount"] = after.filter {
                $0.title == itemTitle && $0.isCompleted && !$0.hasRecurrenceRules
            }.count
            fields["nextRecurringCount"] = after.filter {
                $0.title == itemTitle && !$0.isCompleted && $0.hasRecurrenceRules
            }.count
            report("awaiting_second_phone_observation", fields)
        } catch {
            fields["error"] = code(error)
            report("completion_failed", fields)
        }
    }

    static func verifyAfterCompletion() {
        guard ready(), let id = UserDefaults.standard.string(forKey: key),
              let prior = UserDefaults.standard.dictionary(forKey: resultKey),
              prior["outcome"] as? String == "awaiting_second_phone_observation",
              let before = prior["before"] as? [[String: Any]],
              let firstDueText = before.first?["dueUTC"] as? String,
              let firstDue = ISO8601DateFormatter().date(from: firstDueText),
              let nextDue = Calendar.current.date(byAdding: .day, value: 1, to: firstDue) else {
            report("verify_precondition_failed"); return
        }
        let store = EKEventStore()
        store.refreshSourcesIfNecessary()
        guard let list = matchingList(store, id: id),
              let rows = reminders(store, list) else {
            report("verify_refetch_unavailable", ["listID": id]); return
        }
        let completed = rows.filter { $0.title == itemTitle && $0.isCompleted &&
            !$0.hasRecurrenceRules &&
            abs(($0.dueDateComponents?.date ?? .distantPast).timeIntervalSince(firstDue)) < 1 }
        let advanced = rows.filter { $0.title == itemTitle && !$0.isCompleted &&
            $0.hasRecurrenceRules &&
            abs(($0.dueDateComponents?.date ?? .distantPast).timeIntervalSince(nextDue)) < 1 }
        let verified = rows.count == 2 && completed.count == 1 && advanced.count == 1
        report(verified ? "fresh_store_completion_verified" : "fresh_store_completion_mismatch", [
            "listID": id, "rows": rows.map(snapshot),
            "completedOriginalDueUTC": firstDueText,
            "nextDueUTC": ISO8601DateFormatter().string(from: nextDue),
            "completedCount": completed.count, "advancedCount": advanced.count,
        ])
    }

    static func cleanupAfterPhoneObservation() {
        guard ready(), let id = UserDefaults.standard.string(forKey: key) else {
            report("cleanup_precondition_failed"); return
        }
        var fields: [String: Any] = ["listID": id]
        cleanup(EKEventStore(), id: id, fields: &fields)
        report("cleanup_checked", fields)
    }

    static func verifyCleanup() {
        guard ready() else { report("cleanup_verify_precondition_failed"); return }
        let store = EKEventStore()
        store.refreshSourcesIfNecessary()
        let remaining = store.calendars(for: .reminder).filter {
            $0.title == listName && $0.source.title == "iCloud" && !$0.source.isDelegate
        }
        let markerAbsent = UserDefaults.standard.string(forKey: key) == nil
        report(remaining.isEmpty && markerAbsent ? "cleanup_absence_verified" :
            "cleanup_absence_unverified", ["matchingListCount": remaining.count,
                                           "markerAbsent": markerAbsent])
    }

    private static func ready() -> Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .fullAccess &&
            !FileManager.default.fileExists(atPath: AppIdentity.bridgeRoot + "/current.json")
    }

    private static func matchingList(_ store: EKEventStore, id: String) -> EKCalendar? {
        let lists = store.calendars(for: .reminder).filter {
            $0.title == listName && $0.source.title == "iCloud" && !$0.source.isDelegate
        }
        if let exact = lists.first(where: { $0.calendarIdentifier == id }) { return exact }
        return lists.count == 1 ? lists[0] : nil
    }

    private static func cleanup(_ store: EKEventStore, id: String,
                                fields: inout [String: Any]) {
        guard let list = matchingList(store, id: id),
              let rows = reminders(store, list),
              rows.allSatisfy({ $0.calendar.calendarIdentifier == list.calendarIdentifier &&
                  $0.title == itemTitle }) else {
            fields["cleanup"] = "refused_identity_or_contents_mismatch"; return
        }
        do {
            try store.removeCalendar(list, commit: true)
            UserDefaults.standard.removeObject(forKey: key)
            fields["cleanup"] = UserDefaults.standard.synchronize() ?
                "removed_list" : "removed_list_state_not_synced"
        } catch { fields["cleanup"] = "failed: \(code(error))" }
    }

    private static func reminders(_ store: EKEventStore, _ list: EKCalendar) -> [EKReminder]? {
        var value: [EKReminder]??
        store.fetchReminders(matching: store.predicateForReminders(in: [list])) { rows in
            DispatchQueue.main.async { value = rows }
        }
        let deadline = Date().addingTimeInterval(30)
        while value == nil && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        return value ?? nil
    }

    private static func snapshot(_ row: EKReminder) -> [String: Any] {
        ["title": row.title ?? "", "id": row.calendarItemIdentifier,
         "completed": row.isCompleted,
         "dueUTC": row.dueDateComponents?.date.map {
             ISO8601DateFormatter().string(from: $0)
         } ?? "", "ruleCount": row.recurrenceRules?.count ?? 0]
    }

    private static func local(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = Calendar.current.timeZone
        format.dateFormat = "yyyy-MM-dd HH:mm zzz"
        return format.string(from: date)
    }

    private static func code(_ error: Error) -> String {
        let value = error as NSError
        return "\(value.domain) \(value.code)"
    }

    private static func report(_ outcome: String, _ fields: [String: Any] = [:]) {
        var result = fields
        result["outcome"] = outcome
        UserDefaults.standard.set(result, forKey: resultKey)
        _ = UserDefaults.standard.synchronize()
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data + Data([10]))
        }
    }
}
#endif
