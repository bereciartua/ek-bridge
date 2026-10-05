import Darwin
import Foundation

// build/mcp-server-test: the real LoopbackHTTPServer, MCPServer, tool catalog,
// mapping, RequestPipeline, ClientRegistry and WriteJournal, with fakes only
// for EventKit and the approval panel. Offline: loopback sockets only.
//
// Environment: EVENTKIT_MCP_TEST_DIR (a private temp folder, required),
// EVENTKIT_MCP_TEST_APPROVAL (allow|deny|timeout|none, default allow).
// Prints {"port":…,"clients":{name:{"id","token"}}} on stdout, then answers
// one JSON control command per stdin line, and exits when stdin closes.

@MainActor
final class FakeCollections: CollectionSource {
    var calendarsAccess = "full"
    var remindersAccess = "full"

    func access(_ resource: ClientResource) -> String {
        resource == .calendar ? calendarsAccess : remindersAccess
    }

    func collections(_ resource: ClientResource) -> [CollectionRecord]? {
        if access(resource) != "full" { return nil }
        return resource == .calendar
            ? [CollectionRecord(id: "CAL-WORK", name: "Work", account: "iCloud", writable: true),
               CollectionRecord(id: "CAL-HOLIDAYS", name: "Holidays", account: "Subscribed", writable: false)]
            : [CollectionRecord(id: "LIST-GROC", name: "Groceries", account: "iCloud", writable: true)]
    }
}

/// Canned core results shaped like EventKitCommands', behind a real journal,
/// so idempotency, `repeated` and cancellation behave as in the app.
@MainActor
final class FakeExecutor: BridgeCommandExecutor {
    let journal: WriteJournal
    var delay: TimeInterval = 0
    private var counter = 0

    init(directory: URL) { journal = WriteJournal(directory: directory) }

    func runAuthorized(_ request: BridgeRequest, clientID: String, selected: BridgeScope,
                       stillAuthorized: @escaping () -> Bool, isCancelled: @escaping () -> Bool,
                       completion: @escaping ([String: Any]) -> Void) {
        let p = request.parameters
        let slow = (p["title"] as? String)?.hasPrefix("slow") == true
        let run = { [self] in
            guard stillAuthorized() else { completion(["error": "scope_changed"]); return }
            if request.command.isWrite {
                if isCancelled() { completion(["error": "cancelled"]); return }
                switch journal.begin(request, clientID: clientID) {
                case .execute: break
                case .repeatResult(let result):
                    completion(result.merging(["repeated": true]) { _, new in new }); return
                case .reject(let error): completion(["error": error]); return
                }
                let result = write(request)
                completion(journal.finish(request, result: result)
                           ? result : ["error": "write_committed_journal_pending_review"])
            } else {
                completion(read(request))
            }
        }
        let wait = slow ? 2.0 : delay
        if wait > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { MainActor.assumeIsolated(run) }
        } else {
            run()
        }
    }

    private func read(_ request: BridgeRequest) -> [String: Any] {
        let p = request.parameters
        switch request.command {
        case .readEvents:
            guard p["calendarID"] as? String == "CAL-WORK" else { return ["error": "target_unavailable"] }
            return ["truncated": false, "items": [[
                "id": "EV1", "version": "1791200000.123456", "title": "Design review",
                "titleTruncated": false, "start": 1_791_295_200.0, "end": 1_791_298_800.0,
                "recurring": false, "allDay": false, "timeZone": "GMT", "hasAttendees": false,
            ], [
                "id": "EV2", "version": "1791200001.000000", "title": "Offsite",
                "titleTruncated": false, "start": 1_791_259_200.0, "end": 1_791_345_600.0,
                "recurring": false, "allDay": true, "timeZone": "America/New_York",
                "hasAttendees": false,
            ]]]
        case .readReminders:
            guard p["listID"] as? String == "LIST-GROC" else { return ["error": "target_unavailable"] }
            return ["truncated": false, "items": [reminder(id: "R1", title: "Buy oat milk")]]
        default:
            return ["error": "invalid_request"]
        }
    }

    private func write(_ request: BridgeRequest) -> [String: Any] {
        let p = request.parameters
        counter += 1
        let version = String(format: "%.6f", 1_791_216_000.0 + Double(counter))
        switch request.command {
        case .createEvent, .updateEvent:
            var item: [String: Any] = ["id": p["itemID"] as? String ?? "EV-\(counter)", "version": version]
            if p["allDay"] != nil {
                item["allDayVerified"] = true
                item["notesVerified"] = true
                item["start"] = p["start"]
                item["end"] = (p["end"] as! NSNumber).doubleValue - 1
                item["endExclusive"] = p["end"]
            }
            return ["item": item]
        case .deleteEvent, .deleteReminder:
            return ["deleted": true]
        case .createReminder, .updateReminder, .completeReminder:
            let title = p["title"] as? String ?? "Buy oat milk"
            var item = reminder(id: p["itemID"] as? String ?? "R-\(counter)", title: title)
            item["version"] = version
            if request.command == .completeReminder { item["completed"] = true }
            if let due = p["due"] as? [String: Any], due["kind"] as? String == "timed",
               let at = due["at"] as? NSNumber {
                let zone = TimeZone(identifier: due["timeZone"] as? String ?? "GMT")!
                item["due"] = ["kind": "timed", "at": at.doubleValue,
                               "local": local(at.doubleValue, zone), "timeZone": zone.identifier]
                item["alarms"] = [["kind": "absolute", "at": at.doubleValue]]
                item["alarmCount"] = 1
            }
            return ["item": item]
        default:
            return ["error": "invalid_request"]
        }
    }

    private func reminder(id: String, title: String) -> [String: Any] {
        ["id": id, "title": title, "titleTruncated": false, "completed": false, "recurring": false,
         "version": "1791200002.000000",
         "due": ["kind": "all_day", "date": "2026-10-06", "timeZone": "America/New_York"],
         "recurrence": ["kind": "none", "supported": true],
         "alarms": [[String: Any]](), "alarmCount": 0, "alarmsTruncated": false]
    }

    private func local(_ seconds: Double, _ zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                        from: Date(timeIntervalSince1970: seconds))
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d",
                      c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }
}

/// The harness never fetches client metadata documents; DCR covers OAuth here.
@MainActor
final class OfflineFetcher: CIMDFetching {
    func fetch(_ url: URL, completion: @escaping (Result<ClientMetadata, CIMDError>) -> Void) {
        DispatchQueue.main.async { completion(.failure(.network("offline harness"))) }
    }
}

/// Stands in for the approval panel.
@MainActor
final class FakeApprovals: ApprovalGate {
    var mode: String
    private var waiting = [(id: UUID, clientID: String, completion: (ApprovalDecision) -> Void)]()

    init(mode: String) { self.mode = mode }

    var pendingCount: Int { waiting.count }

    func request(_ approval: ApprovalRequest,
                 completion: @escaping (ApprovalDecision) -> Void) -> () -> Void {
        switch mode {
        case "allow": completion(.allowed); return {}
        case "deny": completion(.denied); return {}
        case "timeout":
            let id = UUID()
            waiting.append((id, approval.clientID, completion))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MainActor.assumeIsolated { self.resolve(id, .timedOut) }
            }
            return { [weak self] in self?.resolve(id, .withdrawn) }
        default:
            let id = UUID()
            waiting.append((id, approval.clientID, completion))
            return { [weak self] in self?.resolve(id, .withdrawn) }
        }
    }

    /// Answers the oldest waiting request.
    func answer(_ decision: ApprovalDecision) -> Bool {
        guard let first = waiting.first else { return false }
        resolve(first.id, decision)
        return true
    }

    private func resolve(_ id: UUID, _ decision: ApprovalDecision) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        let entry = waiting.remove(at: index)
        entry.completion(decision)
    }
}

@MainActor
final class Harness {
    let directory: URL
    let registry: ClientRegistry
    let files: ClientCredentialFiles
    let collections = FakeCollections()
    let executor: FakeExecutor
    let approvals: FakeApprovals
    let limiter = RateLimiter()
    let counters = MCPTrafficCounters()
    var bridgeOn = true
    var service: MCPService!
    var remote: RemoteMCPService!
    var oauth: OAuthServer!
    var remoteConfiguration: RemoteConfiguration!
    var remoteToken = ""
    var clients = [String: String]()
    var connections = [String: MCPServer.Connection]()
    var lastPort = 0

    init(directory: URL, approvalMode: String) {
        self.directory = directory
        registry = ClientRegistry(directory: directory)
        files = ClientCredentialFiles(parent: directory)
        executor = FakeExecutor(directory: directory)
        approvals = FakeApprovals(mode: approvalMode)
        let pipeline = RequestPipeline(
            registry: registry, commands: executor, collections: collections,
            approvals: approvals, limiter: limiter,
            bridgeActive: { [unowned self] in self.bridgeOn }, didRecord: {})
        let server = MCPServer(registry: registry, pipeline: pipeline, limiter: limiter,
                               counters: counters,
                               zone: { TimeZone(identifier: "America/New_York")! },
                               didConnect: { [unowned self] id, connection in
                                   self.connections[id] = connection })
        service = MCPService(server: server, limiter: limiter, counters: counters,
                             endpointFile: MCPEndpointFile(directory: directory))
        oauth = OAuthServer(directory: directory, fetcher: OfflineFetcher(),
                            clientAllowed: { [unowned self] in self.registry.cloudAccessAllowed(clientID: $0) },
                            clientName: { [unowned self] id in self.registry.clients()?.first { $0.id == id }?.name })
        oauth.connectionsChanged = { [unowned self] id in _ = self.registry.bumpRevision(clientID: id) }
        let remoteServer = MCPServer(registry: registry, pipeline: pipeline, limiter: limiter, counters: counters,
                                     zone: { TimeZone(identifier: "America/New_York")! },
                                     didConnect: { [unowned self] id, connection in
                                         self.connections["remote|" + id] = connection })
        remote = RemoteMCPService(server: remoteServer, registry: registry, limiter: limiter,
                                  counters: counters, oauth: oauth)
    }

    func makeClients() -> [String: Any] {
        let work = "CAL-WORK", groceries = "LIST-GROC"
        let specs: [(String, [ClientGrant], ApprovalMode)] = [
            ("agent", [ClientGrant(resource: .calendar, targetID: work, mask: 3),
                       ClientGrant(resource: .reminderList, targetID: groceries, mask: 19)], .allow),
            ("full", [ClientGrant(resource: .calendar, targetID: work, mask: 15),
                      ClientGrant(resource: .reminderList, targetID: groceries, mask: 31)], .allow),
            ("ask", [ClientGrant(resource: .calendar, targetID: work, mask: 15),
                     ClientGrant(resource: .reminderList, targetID: groceries, mask: 31)], .ask),
            ("reader", [ClientGrant(resource: .calendar, targetID: work, mask: 1)], .allow),
            ("none", [], .allow),
            ("ghost", [ClientGrant(resource: .calendar, targetID: "CAL-GONE", mask: 1)], .allow),
            ("cloud", [ClientGrant(resource: .calendar, targetID: work, mask: 3),
                       ClientGrant(resource: .reminderList, targetID: groceries, mask: 3)], .allow),
        ]
        var result = [String: Any]()
        for (name, grants, approval) in specs {
            guard case .success(let issued) = registry.createClient(
                    name: name, credentials: [.mcpToken], approval: approval),
                  case .success = registry.replaceGrants(clientID: issued.id, grants: grants),
                  case .success = files.saveNew(clientID: issued.id, token: issued.mcpToken!)
            else { fatalError("couldn't create \(name)") }
            clients[name] = issued.id
            result[name] = ["id": issued.id, "token": issued.mcpToken!]
        }
        // Remote Access for "cloud" only.
        guard case .success = registry.setCloudAccess(clientID: clients["cloud"]!, true),
              case .success(let token) = registry.issueRemoteToken(clientID: clients["cloud"]!)
        else { fatalError("couldn't set up cloud access") }
        remoteToken = token
        return result
    }

    func control(_ command: [String: Any]) -> [String: Any] {
        let client = (command["client"] as? String).flatMap { clients[$0] }
        switch command["cmd"] as? String {
        case "bridge":
            bridgeOn = command["on"] as? Bool ?? true
            if !bridgeOn { _ = approvals.answer(.withdrawn) }
            return ["ok": true]
        case "approval":
            approvals.mode = command["mode"] as? String ?? "allow"
            return ["ok": true]
        case "answer":
            let decision: ApprovalDecision = command["decision"] as? String == "deny" ? .denied : .allowed
            return ["ok": approvals.answer(decision)]
        case "pending":
            return ["pending": approvals.pendingCount]
        case "activity":
            let rows = (registry.activity() ?? []).map { row -> [String: Any] in
                var value: [String: Any] = ["command": row.command, "outcome": row.outcome,
                                            "clientID": row.clientID as Any? ?? NSNull()]
                if let via = row.via { value["via"] = via }
                if let agent = row.agent { value["agent"] = agent }
                if let target = row.targetID { value["targetID"] = target }
                if let approval = row.approval { value["approval"] = approval }
                return value
            }
            return ["activity": rows]
        case "grants":
            guard let client else { return ["ok": false] }
            let grants = (command["grants"] as? [[String: Any]] ?? []).compactMap { raw -> ClientGrant? in
                guard let resource = (raw["resource"] as? String).flatMap(ClientResource.init(rawValue:)),
                      let target = raw["targetID"] as? String, let mask = raw["mask"] as? Int
                else { return nil }
                return ClientGrant(resource: resource, targetID: target, mask: mask)
            }
            if case .success = registry.replaceGrants(clientID: client, grants: grants) { return ["ok": true] }
            return ["ok": false]
        case "revoke":
            guard let client else { return ["ok": false] }
            _ = registry.revoke(clientID: client)
            _ = files.remove(clientID: client, kind: .mcpToken)
            return ["ok": true]
        case "reset_token":
            guard let client, case .success(let token) = registry.issueMCPToken(clientID: client),
                  case .success = files.replace(clientID: client, token: token) else { return ["ok": false] }
            return ["ok": true, "token": token]
        case "connection":
            guard let client, let connection = connections[client] else { return ["connection": NSNull()] }
            return ["connection": ["agent": connection.agent as Any? ?? NSNull()]]
        case "stop":
            service.stop()
            return ["ok": true]
        case "start":
            service.start(port: command["port"] as? Int ?? lastPort)
            return ["ok": true]
        case "remote_start":
            remoteConfiguration = RemoteConfiguration(secret: "q7Zk2vN4bXwP9sL1mT6hYa",
                                                      publicOrigin: "https://remote.test", port: 0)
            remote.start(remoteConfiguration)
            return ["ok": true]
        case "remote_port":
            if case .listening(let port) = remote.status { return ["port": port] }
            return ["port": NSNull()]
        case "set_cloud":
            guard let client else { return ["ok": false] }
            if case .success = registry.setCloudAccess(clientID: client, command["on"] as? Bool ?? false) {
                if command["on"] as? Bool != true { oauth.revokeAll(clientID: client) }
                return ["ok": true]
            }
            return ["ok": false]
        case "issue_remote_token":
            guard let client, case .success(let token) = registry.issueRemoteToken(clientID: client)
            else { return ["ok": false] }
            return ["ok": true, "token": token]
        case "nonce":
            return ["nonce": remote.nonces.issue()]
        case "open_pairing":
            guard let client else { return ["ok": false] }
            oauth.openPairing(clientID: client)
            return ["ok": true]
        case "pairings":
            return ["pending": oauth.pendingPairings.map { ["code": $0.code, "app": $0.appName] }]
        case "answer_pairing":
            guard let request = oauth.pendingPairings.last else { return ["ok": false] }
            oauth.answerPairing(request.id, allow: command["allow"] as? Bool ?? false)
            return ["ok": true]
        case "oauth_connections":
            guard let client else { return ["count": 0] }
            return ["count": oauth.connections(clientID: client).count]
        case "counters":
            let snapshot = counters.snapshot
            return ["requests": snapshot.requests, "authFailures": snapshot.authFailures,
                    "byStatus": Dictionary(uniqueKeysWithValues: snapshot.byStatus.map { (String($0), $1) })]
        case "journal_entries":
            // The main file plus every client's shard.
            var files = [directory.appendingPathComponent("write-journal.json")]
            let shards = directory.appendingPathComponent("write-journal")
            files += ((try? FileManager.default.contentsOfDirectory(atPath: shards.path)) ?? [])
                .map { shards.appendingPathComponent($0) }
            let count = files.reduce(0) { total, url in
                let data = (try? Data(contentsOf: url)) ?? Data()
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                return total + ((object?["entries"] as? [String: Any])?.count ?? 0)
            }
            return ["count": count]
        default:
            return ["error": "unknown command"]
        }
    }
}

enum Output {
    static func line(_ object: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}

@main
struct MCPServerHarness {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        guard let path = ProcessInfo.processInfo.environment["EVENTKIT_MCP_TEST_DIR"] else {
            FileHandle.standardError.write(Data("EVENTKIT_MCP_TEST_DIR is required\n".utf8))
            exit(2)
        }
        let mode = ProcessInfo.processInfo.environment["EVENTKIT_MCP_TEST_APPROVAL"] ?? "allow"
        MainActor.assumeIsolated {
            let harness = Harness(directory: URL(fileURLWithPath: path, isDirectory: true),
                                  approvalMode: mode)
            let clients = harness.makeClients()
            var announced = false
            harness.service.statusChanged = { status in
                switch status {
                case .listening(let port):
                    harness.lastPort = port
                    if !announced {
                        announced = true
                        Output.line(["port": port, "clients": clients, "remoteToken": harness.remoteToken])
                        startControl(harness)
                    }
                case .failed(let failure):
                    if !announced {
                        FileHandle.standardError.write(Data("listener failed: \(failure)\n".utf8))
                        exit(1)
                    }
                default: break
                }
            }
            let port = Int(ProcessInfo.processInfo.environment["EVENTKIT_MCP_TEST_PORT"] ?? "0") ?? 0
            harness.service.start(port: port)
        }
        dispatchMain()
    }

    @MainActor
    static func startControl(_ harness: Harness) {
        Thread.detachNewThread {
            while let line = readLine() {
                let command = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated { Output.line(harness.control(command)) }
                }
            }
            DispatchQueue.main.sync {
                MainActor.assumeIsolated { harness.service.stop() }
            }
            exit(0)
        }
    }
}
