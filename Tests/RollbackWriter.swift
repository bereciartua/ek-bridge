import Foundation

// build/rollback-writer: the current registry and activity store.
// `rollback-writer write <data folder>` fills a data folder with everything
// 0.10 can write (connections of every kind, grants, Ask before changes,
// paused, cloud access, a removed one, more than 500 Activity rows with item
// IDs and access-request answers) and prints the client IDs as JSON.
// `rollback-writer check <data folder> <rows>` reloads it after 0.8.2 wrote
// to it, and checks the import: 0.8.2's rows are in the activity store and
// the registry's own list is empty again.
@main
struct RollbackWriter {
    static func main() throws {
        let arguments = CommandLine.arguments
        let folder = URL(fileURLWithPath: arguments[2])
        try MainActor.assumeIsolated {
            switch arguments[1] {
            case "write": try write(folder)
            case "check": try check(folder, rowsBefore: Int(arguments[3])!)
            default: exit(2)
            }
        }
    }

    @MainActor
    static func write(_ folder: URL) throws {
        let registry = ClientRegistry(directory: folder)
        func id(_ result: Result<(id: String, signingKey: String?, mcpToken: String?), ClientRegistryError>) -> String {
            guard case .success(let value) = result else { fatalError("\(result)") }
            return value.id
        }
        let agent = id(registry.createClient(name: "Agent", credentials: [.mcpToken], approval: .ask))
        let script = id(registry.createClient(name: "Script"))
        let both = id(registry.createClient(name: "Both", credentials: [.signingKey, .mcpToken]))
        let paused = id(registry.createClient(name: "Paused", credentials: [.mcpToken]))
        let removed = id(registry.createClient(name: "Removed", credentials: [.mcpToken]))
        let grants = [ClientGrant(resource: .calendar, targetID: "CAL-A", mask: 15),
                      ClientGrant(resource: .reminderList, targetID: "LIST-A", mask: 31)]
        for client in [agent, script, both, paused] {
            guard case .success = registry.replaceGrants(clientID: client, grants: grants) else { fatalError() }
        }
        guard case .success = registry.setPaused(clientID: paused, true),
              case .success = registry.setCloudAccess(clientID: both, true),
              case .success = registry.issueRemoteToken(clientID: both),
              case .success = registry.revoke(clientID: removed) else { fatalError() }
        WriterHooks.afterClients(registry, agent: agent)
        // 600 requests (1,200 rows): reads, writes with item IDs, refusals with
        // the missing bit, and every approval answer, old and new.
        let answers = ["user", "window", "denied", "timeout",
                       "access_once", "access_always", "access_denied", "access_timeout"]
        for n in 0..<600 {
            let write = n % 2 == 0
            let request = BridgeRequest(
                id: "r\(n)", command: write ? .createReminder : .readReminders,
                parameters: write ? ["listID": "LIST-A", "title": "t"] : ["listID": "LIST-A", "limit": 5])
            guard case .success(var call) = registry.authorize(clientID: agent, request: request,
                                                                origin: .mcp(agent: "Agent 1.0")) else { fatalError() }
            call.approvalDetail = write ? answers[n / 2 % answers.count] : nil
            guard registry.recordResult(call, outcome: "success",
                                        item: write ? ItemRef(kind: "reminder", id: "R\(n)") : nil) else { fatalError() }
        }
        let refused = BridgeRequest(id: "refused", command: .createEvent, parameters: ["calendarID": "CAL-B"])
        guard case .failure(.forbidden) = registry.authorize(clientID: agent, request: refused, origin: .cli)
        else { fatalError() }
        let file = folder.appendingPathComponent("client-registry.json")
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        precondition(saved["version"] as? Int == 4, "the registry version never changes")
        precondition((saved["activity"] as? [Any])?.isEmpty == true, "Activity isn't written to the registry")
        precondition(registry.activity()!.count == 1_201)
        let ids = registry.clients()!.map(\.id).sorted()
        print(String(data: try JSONSerialization.data(withJSONObject: ["clientIDs": ids]), encoding: .utf8)!)
    }

    @MainActor
    static func check(_ folder: URL, rowsBefore: Int) throws {
        let registry = ClientRegistry(directory: folder)
        let rows = registry.activity()!
        // 0.8.2 added a start and a result row; both were imported.
        precondition(rows.count == rowsBefore + 2, "\(rows.count) rows, expected \(rowsBefore + 2)")
        precondition(rows.prefix(2).allSatisfy { $0.id.hasPrefix("legacy|") && $0.command == "scope_status" })
        let file = folder.appendingPathComponent("client-registry.json")
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        precondition((saved["activity"] as? [Any])?.isEmpty == true)
        precondition(saved["version"] as? Int == 4)
        // Importing again (another launch) adds nothing.
        precondition(ClientRegistry(directory: folder).activity()!.count == rows.count)
        print("rollback: 0.8.2's rows imported once")
    }
}

/// Phase C fields on the registry record, set by the work packages that add them.
enum WriterHooks {
    @MainActor
    static func afterClients(_ registry: ClientRegistry, agent: String) {
        // C04: "Let it ask for more access" turned off is stored on the record.
        guard case .success = registry.setAsksForAccess(clientID: agent, false) else { fatalError() }
    }
}
