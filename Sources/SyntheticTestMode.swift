#if EVENTKIT_SYNTHETIC_TEST
import AppKit
import Darwin
import EventKit
import Foundation

// Built only for the bounded supervised test. It uses the app's own EventKit
// identity and registry APIs; the ordinary installed build omits this route.
@MainActor
enum SyntheticTestMode {
    private static let clientIDKey = "durableSyntheticClientID"
    private static let clientName = "Durable Synthetic Test"

    static func run(_ argument: String) {
        guard CommandLine.arguments.count == 2 else { report("invalid_arguments"); return }
        switch argument {
        case "--synthetic-status": status()
        case "--synthetic-setup": setup()
        case "--synthetic-cleanup": cleanup()
        case "--synthetic-recurrence-probe": SyntheticRecurrenceProbe.run()
        case "--synthetic-recurrence-sync-stage": SyntheticRecurrenceProbe.run(keepForRestart: true)
        case "--synthetic-recurrence-sync-verify": SyntheticRecurrenceProbe.verifyAfterRestart()
        case "--synthetic-recurrence-cleanup": SyntheticRecurrenceProbe.cleanupOnly()
        case "--synthetic-phone-sync-stage": SyntheticPhoneSyncProbe.stage()
        case "--synthetic-phone-sync-complete": SyntheticPhoneSyncProbe.completeAfterPhoneObservation()
        case "--synthetic-phone-sync-verify": SyntheticPhoneSyncProbe.verifyAfterCompletion()
        case "--synthetic-phone-sync-cleanup": SyntheticPhoneSyncProbe.cleanupAfterPhoneObservation()
        case "--synthetic-phone-sync-verify-cleanup": SyntheticPhoneSyncProbe.verifyCleanup()
        case "--synthetic-all-day-probe": SyntheticAllDayProbe.run()
        case "--synthetic-all-day-cleanup": SyntheticAllDayProbe.cleanupOnly()
        default: report("invalid_arguments")
        }
    }

    private static func status() {
        let registry = ClientRegistry()
        let collections = TestCollections(store: EKEventStore())
        let clients = registry.clients()
        report("status", [
            "calendarAccess": EKEventStore.authorizationStatus(for: .event).rawValue,
            "remindersAccess": EKEventStore.authorizationStatus(for: .reminder).rawValue,
            "bridgeEnabled": BridgeEnablement().isEnabled,
            "activeClients": clients?.filter { !$0.revoked }.count ?? -1,
            "testCalendarID": collections.calendarID ?? "",
            "testReminderListID": collections.reminderListID ?? "",
            "testClientID": UserDefaults.standard.string(forKey: clientIDKey) ?? "",
        ])
    }

    private static func setup() {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess,
              EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            report("full_access_required"); return
        }
        let registry = ClientRegistry()
        guard let clients = registry.clients(),
              !clients.contains(where: { !$0.revoked && $0.name == clientName }),
              UserDefaults.standard.string(forKey: clientIDKey) == nil,
              !FileManager.default.fileExists(atPath:
                "/tmp/eventkit-bridge-\(getuid())/current.json") else {
            report("setup_requires_stopped_bridge_and_no_test_client"); return
        }
        let collections = TestCollections(store: EKEventStore())
        let creation = collections.create()
        guard creation.hasPrefix("Created both empty test collections."),
              let calendarID = collections.calendarID,
              let listID = collections.reminderListID else {
            report("test_collection_creation_failed", ["detail": creation]); return
        }
        let issued: (id: String, key: String)
        switch registry.createClient(name: clientName) {
        case .success(let value): issued = value
        case .failure(let error):
            report("client_creation_failed", ["detail": error.rawValue]); return
        }
        let credentials = ClientCredentialFiles()
        guard case .success(let credentialURL) = credentials.saveNew(
            clientID: issued.id, key: issued.key) else {
            _ = registry.revoke(clientID: issued.id)
            _ = credentials.remove(clientID: issued.id)
            report("credential_save_failed"); return
        }
        let grants = [
            ClientGrant(resource: .calendar, targetID: calendarID, mask: 15),
            ClientGrant(resource: .reminderList, targetID: listID, mask: 31),
        ]
        guard case .success = registry.replaceGrants(clientID: issued.id, grants: grants) else {
            _ = registry.revoke(clientID: issued.id)
            _ = credentials.remove(clientID: issued.id)
            report("grant_save_failed"); return
        }
        UserDefaults.standard.set(issued.id, forKey: clientIDKey)
        guard UserDefaults.standard.synchronize() else {
            _ = registry.revoke(clientID: issued.id)
            _ = credentials.remove(clientID: issued.id)
            report("test_state_save_failed"); return
        }
        report("setup_complete", [
            "calendarID": calendarID, "reminderListID": listID,
            "clientID": issued.id, "credentialPath": credentialURL.path,
        ])
    }

    private static func cleanup() {
        let collections = TestCollections(store: EKEventStore())
        guard !FileManager.default.fileExists(atPath:
            "/tmp/eventkit-bridge-\(getuid())/current.json") else {
            report("stop_bridge_before_cleanup"); return
        }
        guard let id = UserDefaults.standard.string(forKey: clientIDKey),
              let calendarID = collections.calendarID,
              let listID = collections.reminderListID else {
            report("test_identity_missing"); return
        }
        let registry = ClientRegistry()
        guard let client = registry.clients()?.first(where: { $0.id == id }),
              client.name == clientName,
              client.grants.count == 2,
              Set(client.grants.map { "\($0.resource.rawValue):\($0.targetID):\($0.mask)" }) ==
              Set(["calendar:\(calendarID):15", "reminderList:\(listID):31"]) else {
            report("test_client_identity_mismatch"); return
        }
        var message: String?
        collections.removeEmpty { message = $0 }
        let deadline = Date().addingTimeInterval(30)
        while message == nil && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        guard let message, message == "Removed the empty app-created test collections." else {
            report("collections_not_removed", ["detail": message ?? "cleanup_timed_out"])
            return
        }
        if !client.revoked {
            guard case .success = registry.revoke(clientID: id) else {
                report("client_revoke_failed"); return
            }
        }
        guard case .success = ClientCredentialFiles().remove(clientID: id) else {
            report("credential_remove_failed"); return
        }
        UserDefaults.standard.removeObject(forKey: clientIDKey)
        _ = UserDefaults.standard.synchronize()
        report("cleanup_complete")
    }

    private static func report(_ outcome: String, _ fields: [String: Any] = [:]) {
        var result = fields
        result["outcome"] = outcome
        UserDefaults.standard.set(result, forKey: "durableSyntheticLastResult")
        _ = UserDefaults.standard.synchronize()
        guard let data = try? JSONSerialization.data(withJSONObject: result,
                                                       options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(data + Data([10]))
    }
}
#endif
