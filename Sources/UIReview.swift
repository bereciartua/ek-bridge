#if EVENTKIT_UI_REVIEW
import AppKit
import CryptoKit
import EventKit
import ServiceManagement

// UI-review build only (EVENTKIT_UI_REVIEW=1). Uses a temporary registry, key
// folder and defaults suite with fake clients, calendars and activity. It
// never touches EventKit or starts the bridge.
//
// Arguments:
//   --ui-window-lifecycle-test   cycle the window and its sheets, print JSON
//   --ui-snapshots <dir>         write PNGs of every screen, light and dark
//   --ui-visual-review           show the window and print its window number
//     --ui-route overview|activity|client|settings, --ui-hold <seconds>,
//     --ui-size <width>x<height>, --ui-select-problem, --ui-open-menu
//   --ui-fresh                   start with no clients (setup checklist)
//   --ui-calendar / --ui-reminders notDetermined|denied|writeOnly|restricted|fullAccess
//   --ui-many-collections        60 calendars and lists
//   --ui-long-names              a 60-character client and a 50-character calendar
//   --ui-max-clients             32 active clients (New Client is disabled)
//   --ui-max-activity            500 activity rows
//   --ui-bridge-off              start with the bridge off
//   --ui-mcp listening|off|port-in-use   the fake MCP server's state (default listening)
//   --ui-remote                  start with Remote Access on, a tunnel address and a cloud client
//   --ui-renamed                 the first launch after the rename (notice; use with --ui-calendar notDetermined)
//   --ui-update-found <version>  a scheduled check found that version (menu item, Overview card)
//   --ui-update-critical         …and it's a security update
//   --ui-no-updater              a build that can't update itself (built from source)
@MainActor
final class UIReview {
    static let claudeID = "3f2a9c1e-7b4d-4e8a-9c21-5d6f0a1b2c3d"
    static let briefingID = "8c1d4e2f-5a6b-4c7d-8e9f-0a1b2c3d4e5f"
    static let obsidianID = "b7e3f1a2-9c4d-4e5f-a6b7-c8d9e0f1a2b3"
    static let cursorID = "5e6f7a8b-9c0d-4e1f-a2b3-c4d5e6f7a8b9"
    static let revokedID = "d2c4e6f8-1a3b-4c5d-8e7f-9a0b1c2d3e4f"
    static let port = 47615

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ek-bridge-ui-review-\(UUID().uuidString)", isDirectory: true)
    private let suiteName = "ek-bridge-ui-review-\(UUID().uuidString)"
    private(set) lazy var defaults = UserDefaults(suiteName: suiteName)!
    private(set) lazy var registry = ClientRegistry(directory: directory)
    private(set) lazy var credentialFiles = ClientCredentialFiles(parent: directory)
    private let arguments = CommandLine.arguments
    var calendarStatus: EKAuthorizationStatus
    var remindersStatus: EKAuthorizationStatus
    var bridgeOn: Bool
    /// What macOS reports for Start at login, and whether the app counts as
    /// installed in Applications (the behavior test changes both).
    var loginItemStatus = SMAppService.Status.notRegistered
    var installedInApplications = false
    /// The fake updater: never contacts GitHub.
    var updaterAvailable = !CommandLine.arguments.contains("--ui-no-updater")
    var automaticUpdateChecks = true
    var lastUpdateCheck = Date().addingTimeInterval(-2 * 3_600)
    private(set) var updateChecks = 0
    let many: Bool
    /// "listening", "off" or "port-in-use".
    var mcpMode: String
    weak var model: BridgeAppModel?
    private(set) lazy var approvals = ApprovalCenter(summarize: { request in
        ApprovalSummaries.build(request, lookup: Self.fixtureLookup(request),
                                collections: Self.collections(many: false))
    })
    private(set) lazy var approvalPanel = ApprovalPanelController(center: approvals)
    private(set) lazy var oauth = OAuthServer(
        directory: directory, fetcher: ReviewFetcher(),
        clientAllowed: { [unowned self] id in self.registry.cloudAccessAllowed(clientID: id) },
        clientName: { [unowned self] id in self.registry.clients()?.first { $0.id == id }?.name })
    static let remoteSecret = "q7Zk2vN4bXwP9sL1mT6hYa"
    static let remoteOrigin = "https://my-mac.tail1234.ts.net"
    static var longNames: Bool { CommandLine.arguments.contains("--ui-long-names") }
    private var extraWindows = [MainWindowController]()
    private var extraReviews = [UIReview]()

    init(fresh: Bool? = nil, calendar: EKAuthorizationStatus? = nil,
         reminders: EKAuthorizationStatus? = nil, renamed: Bool? = nil) {
        calendarStatus = calendar ?? Self.status(CommandLine.arguments, "--ui-calendar")
        remindersStatus = reminders ?? Self.status(CommandLine.arguments, "--ui-reminders")
        bridgeOn = fresh == true ? false : !CommandLine.arguments.contains("--ui-bridge-off")
        many = CommandLine.arguments.contains("--ui-many-collections")
        mcpMode = Self.value(CommandLine.arguments, "--ui-mcp") ?? "listening"
        if mcpMode != "off" && fresh != true { defaults.set(true, forKey: "MCPServerEnabled") }
        if CommandLine.arguments.contains("--ui-remote") && fresh != true { seedRemote() }
        if renamed ?? CommandLine.arguments.contains("--ui-renamed") {
            defaults.set(true, forKey: RenameMigration.noticeKey)
            defaults.set(true, forKey: RenameMigration.accessRecheckKey)
        }
        if !(fresh ?? CommandLine.arguments.contains("--ui-fresh")) {
            seed()
            // Requests from the last day and a half count as unseen.
            defaults.set(Date().addingTimeInterval(-129_600).timeIntervalSinceReferenceDate,
                         forKey: "ActivityLastViewed")
        }
    }

    private static func value(_ arguments: [String], _ flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// Reports the fake listener's state, as MCPService would.
    func reportMCP() {
        let status: MCPService.Status = switch mcpMode {
        case "port-in-use": .failed(.portInUse(Self.port))
        case "off": .off
        default: .listening(port: Self.port)
        }
        model?.mcpStatusDidChange(status)
    }

    private static func status(_ arguments: [String], _ flag: String) -> EKAuthorizationStatus {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return .fullAccess }
        switch arguments[index + 1] {
        case "notDetermined": return .notDetermined
        case "denied": return .denied
        case "writeOnly": return .writeOnly
        case "restricted": return .restricted
        default: return .fullAccess
        }
    }

    func services() -> BridgeServices {
        BridgeServices(
            registry: registry, credentialFiles: credentialFiles, defaults: defaults,
            dataFolder: directory, store: nil,
            authorizationStatus: { [unowned self] type in
                type == .event ? self.calendarStatus : self.remindersStatus
            },
            requestFullAccess: { [unowned self] type, completion in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    if type == .event { self.calendarStatus = .fullAccess } else { self.remindersStatus = .fullAccess }
                    completion(true, nil)
                }
            },
            collections: { [unowned self] in
                Self.collections(many: self.many).filter {
                    ($0.resource == .calendar ? self.calendarStatus : self.remindersStatus) == .fullAccess
                }
            },
            setBridge: { [unowned self] on in
                self.bridgeOn = on
                return on ? .on : .off
            },
            loginItemStatus: { [unowned self] in self.loginItemStatus },
            setLoginItem: { [unowned self] on in self.loginItemStatus = on ? .enabled : .notRegistered },
            isInstalledInApplications: { [unowned self] in self.installedInApplications },
            // No Homebrew folders (this Mac's own links must not count), and the
            // installed location in copied commands instead of the build folder.
            commandLineTool: CommandLineTool(appURL: Bundle.main.bundleURL, home: directory, packageBins: [],
                                             displayAppURL: URL(fileURLWithPath: "/Applications/EKBridge.app")),
            testCollections: nil,
            mcp: MCPControls(
                start: { [unowned self] _ in
                    if self.mcpMode == "off" { self.mcpMode = "listening" }
                    DispatchQueue.main.async { self.reportMCP() }
                },
                stop: { [unowned self] in self.mcpMode = "off" },
                counters: { MCPTrafficCounters.Snapshot(requests: 41, byStatus: [401: 2, 421: 1],
                                                         authFailures: 2) },
                launcherURL: URL(fileURLWithPath: "/Applications/EKBridge.app/Contents/MacOS/bridge-mcp"),
                portIsFree: { $0 != 47616 }),
            approvals: approvals,
            remote: RemoteControls(
                start: { [unowned self] configuration in
                    DispatchQueue.main.async { self.model?.remoteStatusDidChange(.listening(port: configuration.port)) }
                },
                update: { _ in },
                stop: {},
                test: { _, completion in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        completion(.success((rtt: 0.18, tunnel: "Tailscale Funnel")))
                    }
                },
                portIsFree: { $0 != 47615 },
                setKeepAwake: { _ in },
                onACPower: { true },
                oauth: oauth),
            updater: UpdaterControls(
                isAvailable: { [unowned self] in self.updaterAvailable },
                checkForUpdates: { [unowned self] in
                    // Sparkle's window would open here; opening it clears the reminder.
                    self.updateChecks += 1
                    self.lastUpdateCheck = Date()
                    self.model?.updateFound(nil)
                },
                automaticChecks: { [unowned self] in self.automaticUpdateChecks },
                setAutomaticChecks: { [unowned self] in self.automaticUpdateChecks = $0 },
                lastCheck: { [unowned self] in self.lastUpdateCheck }))
    }

    /// Starts a pairing request the way claude.ai would: register (DCR),
    /// then open the authorize page. The app then shows the pairing sheet.
    func startPairing(for clientID: String, reopen: Bool = true) {
        if reopen { oauth.openPairing(clientID: clientID) }
        let context = OAuthContext(publicOrigin: Self.remoteOrigin, secretPrefix: "/r/" + Self.remoteSecret)
        let callback = "https://claude.ai/api/mcp/auth_callback"
        let registration = try! JSONSerialization.data(withJSONObject: [
            "redirect_uris": [callback], "client_name": "claude.ai"])
        let register = Self.request("POST", context.secretPrefix + "/oauth/register", body: registration,
                                    contentType: "application/json")
        _ = oauth.handle(register, context: context) { [weak self] response in
            guard let self,
                  let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                  let clientID = object["client_id"] as? String else { return }
            var query = URLComponents()
            query.queryItems = [
                .init(name: "response_type", value: "code"), .init(name: "client_id", value: clientID),
                .init(name: "redirect_uri", value: callback), .init(name: "state", value: "review"),
                .init(name: "code_challenge", value: "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"),
                .init(name: "code_challenge_method", value: "S256")]
            let authorize = Self.request("GET", context.secretPrefix + "/oauth/authorize?" + (query.query ?? ""))
            _ = self.oauth.handle(authorize, context: context) { _ in }
        }
    }

    static func request(_ method: String, _ target: String, body: Data = Data(),
                        contentType: String? = nil) -> HTTPRequest {
        var head = "\(method) \(target) HTTP/1.1\r\nHost: my-mac.tail1234.ts.net\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        head += "Content-Length: \(body.count)\r\n\r\n"
        var parser = HTTPParser()
        guard case .request(let request) = parser.feed(Data(head.utf8) + body) else {
            preconditionFailure("review request didn't parse")
        }
        return request
    }

    /// Remote Access on, with a tunnel address and Claude Code allowed from
    /// the cloud.
    func seedRemote() {
        defaults.set(true, forKey: "RemoteAccessEnabled")
        defaults.set(Self.remoteSecret, forKey: "RemoteAccessSecretPath")
        defaults.set(Self.remoteOrigin, forKey: "RemoteAccessPublicAddress")
    }

    // The current item for update and delete snapshots, which have no EventKit
    // to read: the real summary builder compares against these.
    static func fixtureLookup(_ request: ApprovalRequest) -> ApprovalLookup {
        let reviewZone = TimeZone.current.identifier
        switch request.request.parameters["itemID"] as? String {
        case "fixture-update":
            return ApprovalLookup(event: EventFields(
                calendarID: "cal-work", title: "Design review", start: 1_791_295_200, end: 1_791_298_800,
                allDay: false, timeZone: reviewZone, notes: "Agenda: roadmap", location: "Room 4", place: nil,
                url: nil, alarms: [.relative(-600)], availability: .busy, recurrence: .none))
        case "fixture-series":
            return ApprovalLookup(event: EventFields(
                calendarID: "cal-work", title: "Weekly sync", start: 1_792_504_800, end: 1_792_508_400,
                allDay: false, timeZone: reviewZone, notes: nil, location: nil, place: nil, url: nil, alarms: [],
                availability: .busy, recurrence: .rule(RecurrenceSpec(frequency: .weekly))),
                recurring: true, occurrenceStart: Date(timeIntervalSince1970: 1_792_504_800), occurrences: 37)
        case "fixture-reminder":
            var due = DateComponents(year: 2026, month: 11, day: 1, hour: 9, minute: 0, second: 0)
            due.timeZone = TimeZone.current
            return ApprovalLookup(reminder: ReminderFields(
                listID: "list-errands", title: "Return library books", due: due, start: due, notes: nil,
                url: nil, location: nil, priority: 0, alarms: [], recurrence: .none, completed: true))
        default:
            return ApprovalLookup()
        }
    }

    /// Queues fixture approvals the way the pipeline would.
    func queueApproval(_ command: BridgeCommand, _ parameters: [String: Any], agent: String,
                       client: String? = nil, name: String = "Claude Code") {
        let client = client ?? Self.claudeID
        let request = BridgeRequest(id: UUID().uuidString.lowercased(), command: command,
                                    parameters: parameters)
        _ = approvals.request(ApprovalRequest(clientID: client, clientName: name, agent: agent,
                                              request: request,
                                              targetID: (parameters["calendarID"] ?? parameters["listID"]) as? String)) { _ in }
        approvalPanel.update()
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults().removePersistentDomain(forName: suiteName)
        extraReviews.forEach { $0.cleanup() }
    }

    // MARK: Fixture

    static func collections(many: Bool) -> [CollectionInfo] {
        func color(_ hex: Int) -> CollectionColor {
            CollectionColor(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
                            blue: Double(hex & 0xff) / 255)
        }
        var rows = [
            CollectionInfo(resource: .calendar, id: "cal-home", name: "Home", account: "iCloud", writable: true, color: color(0x1E88E5)),
            CollectionInfo(resource: .calendar, id: "cal-family", name: "Family", account: "iCloud", writable: true, color: color(0x34C759)),
            CollectionInfo(resource: .calendar, id: "cal-work", name: "Work", account: "iCloud", writable: true, color: color(0xFF9500)),
            CollectionInfo(resource: .calendar, id: "cal-team",
                           name: longNames ? "Team calendar for the quarterly planning offsite" : "Team calendar",
                           account: "Google", writable: true, color: color(0xAF52DE)),
            CollectionInfo(resource: .calendar, id: "cal-holidays", name: "US Holidays", account: "Other", writable: false, color: color(0x8E8E93)),
            CollectionInfo(resource: .calendar, id: "cal-birthdays", name: "Birthdays", account: "Other", writable: false, color: color(0x8E8E93)),
            CollectionInfo(resource: .reminderList, id: "list-reminders", name: "Reminders", account: "iCloud", writable: true, color: color(0x1E88E5)),
            CollectionInfo(resource: .reminderList, id: "list-errands", name: "Errands", account: "iCloud", writable: true, color: color(0xFF9500)),
            CollectionInfo(resource: .reminderList, id: "list-groceries", name: "Groceries", account: "iCloud", writable: true, color: color(0x34C759)),
        ]
        if many {
            let palette = [0x1E88E5, 0x34C759, 0xFF9500, 0xAF52DE, 0xFF3B30, 0x5AC8FA]
            for index in 0..<51 {
                let calendar = index < 36
                rows.append(CollectionInfo(
                    resource: calendar ? .calendar : .reminderList, id: "extra-\(index)",
                    name: calendar ? "Project calendar \(index + 1) with a longer descriptive name"
                                   : "Shared list \(index - 35)",
                    account: ["iCloud", "Google", "Exchange (work)"][index % 3],
                    writable: index % 7 != 0, color: color(palette[index % palette.count])))
            }
        }
        return rows.sortedForDisplay()
    }

    private func seed() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        func verifier() -> (String, String) {
            let key = Curve25519.Signing.PrivateKey()
            return (key.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined(),
                    "ekb_v1_" + key.rawRepresentation.map { String(format: "%02x", $0) }.joined())
        }
        func grant(_ resource: String, _ id: String, _ mask: Int) -> [String: Any] {
            ["resource": resource, "targetID": id, "mask": mask]
        }
        func token() -> (String, String) {
            let value = "ekb_mcp_v1_" + (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
            return (ClientRegistry.tokenDigest(value), value)
        }
        let now = Date()
        var clients = [[String: Any]]()
        // (id, name, grants, CLI key, MCP token, Ask before changes)
        let definitions: [(String, String, [[String: Any]], Bool, Bool, String?)] = [
            (Self.claudeID, Self.longNames ? "Claude Code on the work laptop, with a long descriptive name" : "Claude Code", [
                grant("calendar", "cal-home", 1), grant("calendar", "cal-work", 7),
                grant("reminderList", "list-errands", 23), grant("calendar", "cal-signed-out", 1)],
             false, true, "ask"),
            (Self.briefingID, "Morning briefing", [
                grant("calendar", "cal-work", 1), grant("calendar", "cal-family", 1),
                grant("calendar", "cal-home", 1), grant("reminderList", "list-reminders", 1),
                grant("calendar", "cal-holidays", 3)], true, false, nil),
            (Self.obsidianID, "Obsidian sync", [grant("calendar", "cal-work", 5)], true, false, nil),
            (Self.cursorID, "Cursor", [grant("calendar", "cal-home", 1)], true, true, "ask"),
        ]
        for (id, name, grants, cli, mcp, approval) in definitions {
            var record: [String: Any] = ["id": id, "name": name, "verifier": "", "revoked": false,
                                         "revision": 4, "grants": grants]
            if cli {
                let (public_, key) = verifier()
                record["verifier"] = public_
                _ = credentialFiles.saveNew(clientID: id, key: key)
            }
            if mcp {
                let (digest, value) = token()
                record["mcpVerifier"] = digest
                record["mcpIssuedAt"] = now.addingTimeInterval(id == Self.cursorID ? -300 : -86_400 * 3)
                    .timeIntervalSinceReferenceDate
                _ = credentialFiles.saveNew(clientID: id, token: value)
            }
            if let approval { record["approval"] = approval }
            if id == Self.obsidianID {
                record["paused"] = true
                record["pausedAt"] = now.addingTimeInterval(-600).timeIntervalSinceReferenceDate
            }
            clients.append(record)
        }
        if CommandLine.arguments.contains("--ui-max-clients") {
            for index in 1...28 {
                clients.append(["id": UUID().uuidString.lowercased(), "name": "Script \(index)",
                                "verifier": verifier().0, "revoked": false, "revision": 1, "grants": []])
            }
        }
        clients.append(["id": Self.revokedID, "name": "Old shell script", "verifier": "", "revoked": true,
                        "revision": 6, "grants": [],
                        "revokedAt": now.addingTimeInterval(-86_400 * 6).timeIntervalSinceReferenceDate])
        // Oldest first, as stored. Each request has an "accepted" row and a result.
        // Claude Code and Cursor come in over MCP, the scripts over the command line.
        let script: [(TimeInterval, String?, String, String, String?)] = [
            (-86_400 * 2 - 600, Self.revokedID, "read_events", "success", "cal-work"),
            (-86_400 - 7_200, Self.obsidianID, "read_events", "success", "cal-work"),
            (-86_400 - 7_000, Self.obsidianID, "update_event", "error:conflict", "cal-work"),
            (-86_400 - 6_900, Self.obsidianID, "read_events", "success", "cal-work"),
            (-86_400 - 6_800, Self.obsidianID, "update_event", "success", "cal-work"),
            (-86_400 - 3_000, nil, "read_events", "unauthorized", nil),
            (-86_400 - 1_000, Self.briefingID, "read_reminders", "success", "list-reminders"),
            (-9_000, Self.briefingID, "authorization_status", "success", nil),
            (-8_800, Self.briefingID, "read_events", "success", "cal-family"),
            (-8_700, Self.briefingID, "read_events", "success", "cal-work"),
            (-8_600, Self.briefingID, "read_events", "success", "cal-home"),
            (-8_500, Self.briefingID, "read_reminders", "success", "list-reminders"),
            (-5_000, Self.claudeID, "scope_status", "success", nil),
            (-4_900, Self.claudeID, "read_events", "success", "cal-work"),
            (-4_800, Self.claudeID, "create_event", "error:idempotency_pending_review", "cal-work"),
            (-4_700, Self.claudeID, "read_events", "success", "cal-work"),
            (-4_000, Self.claudeID, "read_reminders", "success", "list-errands"),
            (-3_900, Self.claudeID, "create_reminder", "forbidden", "list-groceries"),
            (-3_700, Self.briefingID, "read_events", "success", "cal-work"),
            (-2_400, Self.claudeID, "read_reminders", "success", "list-errands"),
            (-2_300, Self.claudeID, "complete_reminder", "success", "list-errands"),
            (-1_800, Self.claudeID, "read_events", "error:too_many_events_narrow_range", "cal-home"),
            (-1_700, Self.claudeID, "read_events", "success", "cal-home"),
            (-900, Self.obsidianID, "read_events", "success", "cal-work"),
            (-600, Self.claudeID, "create_event", "success", "cal-work"),
            (-420, Self.claudeID, "read_events", "success", "cal-work"),
            (-300, Self.claudeID, "update_event", "success", "cal-work"),
            (-1_500, nil, "mcp", "unauthorized", nil),
            (-1_400, Self.cursorID, "read_events", "error:bridge_off", "cal-home"),
            (-1_300, Self.claudeID, "delete_reminder", "error:approval_denied", "list-errands"),
            (-1_250, Self.claudeID, "read_events", "error:rate_limited", "cal-work"),
            (-1_100, Self.claudeID, "list_collections", "success", nil),
            (-200, Self.briefingID, "read_reminders", "success", "list-reminders"),
            (-150, Self.claudeID, "create_reminder", "success", "list-errands"),
            (-120, Self.claudeID, "read_events", "success", "cal-work"),
            (-90, Self.obsidianID, "read_events", "error:client_paused", "cal-work"),
        ]
        var activity = [[String: Any]]()
        for (offset, client, command, outcome, target) in script {
            let at = now.addingTimeInterval(offset).timeIntervalSinceReferenceDate
            var row: [String: Any] = ["at": at, "command": command, "outcome": outcome]
            if let client { row["clientID"] = client }
            if let target { row["targetID"] = target }
            let mcp = client == nil ? command == "mcp" : (client == Self.claudeID || client == Self.cursorID)
            if client != Self.revokedID && !(client == nil && command == "read_events") {
                row["via"] = mcp ? "mcp" : "cli"
            }
            if client == Self.claudeID { row["agent"] = "claude-code 2.4.1" }
            if client == Self.claudeID && command == "create_reminder" && outcome == "success" {
                row["approval"] = "user"
            }
            if outcome == "error:approval_denied" { row["approval"] = "denied" }
            if (outcome == "success" || outcome.hasPrefix("error:")) &&
                outcome != "error:bridge_off" && outcome != "error:rate_limited" &&
                outcome != "error:client_paused" {
                var accepted = row
                accepted["approval"] = nil
                accepted["at"] = at - 0.2
                accepted["outcome"] = "accepted"
                activity.append(accepted)
            }
            activity.append(row)
        }
        if CommandLine.arguments.contains("--ui-max-activity") {
            let commands = ["read_events", "read_reminders", "create_event", "update_reminder", "scope_status"]
            let outcomes = ["success", "success", "success", "forbidden", "error:conflict", "error:scope_changed"]
            activity = (0..<500).map { index in
                var row: [String: Any] = [
                    "at": now.addingTimeInterval(Double(index - 500) * 400).timeIntervalSinceReferenceDate,
                    "clientID": [Self.claudeID, Self.briefingID, Self.obsidianID][index % 3],
                    "command": commands[index % commands.count], "outcome": outcomes[index % outcomes.count]]
                if index % 5 != 4 { row["targetID"] = index % 5 == 1 ? "list-errands" : "cal-work" }
                return row
            }
        }
        let state: [String: Any] = ["version": 4, "clients": clients, "activity": activity]
        let file = directory.appendingPathComponent("client-registry.json")
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
            FileManager.default.createFile(atPath: file.path, contents: data,
                                           attributes: [.posixPermissions: 0o600])
        }
    }

    // MARK: Modes

    func run(model: BridgeAppModel, window: MainWindowController, statusMenu: StatusMenuController) {
        self.model = model
        approvals.queueChanged = { [weak self] in self?.approvalPanel.update() }
        approvals.selectionChanged = { [weak self] in self?.approvalPanel.update() }
        model.showApprovals = { [weak self] in self?.approvalPanel.bringForward() }
        model.mcpDidConnect(Self.claudeID, MCPServer.Connection(at: Date().addingTimeInterval(-120),
                                                               agent: "claude-code 2.4.1"))
        reportMCP()
        model.bridgeDidChange(bridgeOn ? .on : .off)
        if let version = Self.value(arguments, "--ui-update-found") {
            model.updateFound(FoundUpdate(version: version, critical: arguments.contains("--ui-update-critical")))
        }
        // This build shares the app's bundle ID, so macOS's icon cache can hand
        // back an older icon; show the one this bundle carries in panels and
        // snapshots.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        DispatchQueue.main.async { self.runMode(model: model, window: window, statusMenu: statusMenu) }
    }

    private func runMode(model: BridgeAppModel, window: MainWindowController, statusMenu: StatusMenuController) {
        if arguments.contains("--ui-window-lifecycle-test") {
            WindowLifecycleReview(model: model, controller: window).start()
        } else if arguments.contains("--ui-behavior-test") {
            BehaviorReview(model: model, controller: window, review: self).start()
        } else if let index = arguments.firstIndex(of: "--ui-snapshots"), index + 1 < arguments.count {
            let folder = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            SnapshotReview(review: self, model: model, controller: window, folder: folder).start()
        } else {
            switch value("--ui-route") {
            case "activity": model.navigate(to: .activity)
            case "settings": model.navigate(to: .settings)
            case "client": model.navigate(to: .client(Self.claudeID))
            default: model.navigate(to: .overview)
            }
            window.present()
            if let size = value("--ui-size")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
                window.window?.setContentSize(NSSize(width: size[0], height: size[1]))
            }
            if arguments.contains("--ui-select-problem") {
                model.activitySelection = model.activity.first { $0.code == "forbidden" }?.id
            }
            if arguments.contains("--ui-open-menu") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { statusMenu.button?.performClick(nil) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let frame = statusMenu.button?.window?.frame ?? .zero
                let screen = NSScreen.screens.first?.frame ?? .zero
                let result: [String: Any] = ["windowNumber": window.window?.windowNumber ?? 0,
                                             "statusItemX": frame.minX,
                                             "statusItemTop": screen.maxY - frame.maxY,
                                             "screenWidth": screen.width]
                if let data = try? JSONSerialization.data(withJSONObject: result) {
                    FileHandle.standardOutput.write(data + Data([10]))
                }
            }
            let hold = Double(value("--ui-hold") ?? "") ?? 20
            DispatchQueue.main.asyncAfter(deadline: .now() + hold) { NSApp.terminate(nil) }
        }
    }

    private func value(_ flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// The first launch after the rename: existing clients and Activity, access
    /// not yet granted to the new bundle ID, and the notice.
    func makeRenamedWindow() -> (BridgeAppModel, MainWindowController) {
        let renamed = UIReview(fresh: false, calendar: .notDetermined, reminders: .notDetermined, renamed: true)
        extraReviews.append(renamed)
        let model = BridgeAppModel(services: renamed.services())
        renamed.model = model
        let controller = MainWindowController(model: model)
        extraWindows.append(controller)
        return (model, controller)
    }

    /// A second, empty environment for the setup checklist snapshots.
    func makeFreshWindow(calendar: EKAuthorizationStatus, reminders: EKAuthorizationStatus)
        -> (BridgeAppModel, MainWindowController) {
        let fresh = UIReview(fresh: true, calendar: calendar, reminders: reminders)
        extraReviews.append(fresh)
        let model = BridgeAppModel(services: fresh.services())
        let controller = MainWindowController(model: model)
        extraWindows.append(controller)
        return (model, controller)
    }
}

/// Opens and closes the window and its sheets eight times, checking that the
/// controller keeps the same window and that nothing is released on close.
/// The review build makes no network requests.
@MainActor
final class ReviewFetcher: CIMDFetching {
    func fetch(_ url: URL, completion: @escaping (Result<ClientMetadata, CIMDError>) -> Void) {
        completion(.failure(.network("offline review build")))
    }
}

@MainActor
final class WindowLifecycleReview {
    let model: BridgeAppModel
    let controller: MainWindowController
    private var windowID: ObjectIdentifier?

    init(model: BridgeAppModel, controller: MainWindowController) {
        self.model = model
        self.controller = controller
    }

    func start() {
        controller.present()
        windowID = controller.window.map(ObjectIdentifier.init)
        cycle(1)
    }

    private func cycle(_ number: Int) {
        let routes: [Route] = [.overview, .activity, .client(UIReview.claudeID), .settings,
                               .client(UIReview.revokedID)]
        model.navigate(to: routes[number % routes.count])
        model.sheet = number.isMultiple(of: 2) ? .newClient : .rename(UIReview.claudeID)
        // Generous: the window server is slower with the display asleep.
        after(0.6) {
            guard let window = self.controller.window, window.isVisible, window.attachedSheet != nil,
                  !window.isReleasedWhenClosed else { return self.report("sheet_missing", number) }
            self.model.sheet = nil
            self.after(0.25) {
                guard window.attachedSheet == nil else { return self.report("sheet_stuck", number) }
                window.performClose(nil)
                self.after(0.15) {
                    guard !window.isVisible else { return self.report("close_failed", number) }
                    self.controller.present()
                    self.after(0.15) {
                        guard let reopened = self.controller.window,
                              ObjectIdentifier(reopened) == self.windowID, reopened.isVisible,
                              reopened.frame.width >= MainWindowController.minimumSize.width else {
                            return self.report("reopen_failed", number)
                        }
                        if number == 8 { self.report("passed", number) } else { self.cycle(number + 1) }
                    }
                }
            }
        }
    }

    private func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated(work) }
    }

    private func report(_ outcome: String, _ cycle: Int) {
        let result: [String: Any] = ["outcome": outcome, "cycles": cycle]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data + Data([10]))
        }
        NSApp.terminate(nil)
    }
}

/// Drives the model and window the way a user would and checks the results:
/// undo, write implies Read, the unsaved-changes guard on close, navigation,
/// bridge toggle and quit, rename, create, revoke and Activity deep links.
@MainActor
final class BehaviorReview {
    let model: BridgeAppModel
    let controller: MainWindowController
    let review: UIReview
    private var steps = [(String, @MainActor () -> Bool)]()
    private var passed = [String]()
    private var tokenBefore: String?
    private var callBefore: AuthorizedClientCall?
    private var decision: ApprovalDecision?

    init(model: BridgeAppModel, controller: MainWindowController, review: UIReview) {
        self.model = model
        self.controller = controller
        self.review = review
    }

    private var registry: ClientRegistry { review.registry }

    private func authorizedCall(_ clientID: String) -> AuthorizedClientCall? {
        let request = BridgeRequest(id: UUID().uuidString.lowercased(), command: .scopeStatus, parameters: [:])
        guard case .success(let call) = registry.authorize(clientID: clientID, request: request, origin: .cli)
        else { return nil }
        return call
    }

    private func queue(_ command: BridgeCommand, _ parameters: [String: Any]) {
        let request = BridgeRequest(id: UUID().uuidString.lowercased(), command: command, parameters: parameters)
        _ = review.approvals.request(ApprovalRequest(clientID: UIReview.claudeID, clientName: "Claude Code",
                                                     agent: "claude-code 2.4.1", request: request,
                                                     targetID: parameters["listID"] as? String)) {
            [weak self] in self?.decision = $0
        }
    }

    private var window: NSWindow { controller.window! }
    private let family = GrantKey(resource: .calendar, targetID: "cal-family")
    private let work = GrantKey(resource: .calendar, targetID: "cal-work")

    /// Sends ⌘<key> through the main menu, as a keyboard shortcut would.
    private func key(_ character: String) -> Bool {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: character,
            charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0) else { return false }
        window.makeKey()
        return NSApp.mainMenu?.performKeyEquivalent(with: event) == true
    }

    private func answer(_ code: NSApplication.ModalResponse) -> Bool {
        guard let sheet = window.attachedSheet else { return false }
        window.endSheet(sheet, returnCode: code)
        return true
    }

    func start() {
        controller.present()
        let claude = UIReview.claudeID
        step("open client") {
            self.model.navigate(to: .client(claude))
            return self.model.draft?.clientID == claude && !self.model.hasUnsavedChanges
        }
        step("write implies read") {
            self.model.setAction(self.family, bit: ClientGrant.edit, on: true)
            return self.model.draft?.mask(self.family) == 5 && self.model.draft?.changedCells == 2
        }
        step("undo both together") {
            self.window.undoManager?.undo()
            return self.model.draft?.mask(self.family) == 0 && !self.model.hasUnsavedChanges
        }
        step("redo") {
            self.window.undoManager?.redo()
            return self.model.draft?.mask(self.family) == 5
        }
        step("unchecking read keeps writes") {
            self.model.setAction(self.family, bit: ClientGrant.read, on: false)
            return self.model.draft.map { ClientGrantEditing.writeWithoutRead($0.mask(self.family)) } == true
        }
        step("close prompts") {
            self.window.performClose(nil)
            return self.window.isVisible && self.window.attachedSheet != nil
        }
        step("cancel keeps edits") {
            self.answer(.alertSecondButtonReturn) && self.window.isVisible && self.model.hasUnsavedChanges
        }
        step("close again, don't save") {
            self.window.performClose(nil)
            return self.answer(.alertThirdButtonReturn)
        }
        step("window closed and edits dropped") {
            !self.window.isVisible && !self.model.hasUnsavedChanges
        }
        step("reopen at the same client") {
            self.controller.present()
            return self.window.isVisible && self.model.route == .client(claude)
        }
        step("switching pane prompts") {
            self.model.setAction(self.family, bit: ClientGrant.read, on: true)
            self.model.navigate(to: .overview)
            return self.model.route == .client(claude) && self.window.attachedSheet != nil
        }
        step("save from the prompt") {
            self.answer(.alertFirstButtonReturn)
        }
        step("saved and navigated") {
            self.model.route == .overview &&
                self.model.client(claude)?.grants.contains(ClientGrant(resource: .calendar, targetID: "cal-family", mask: 1)) == true
        }
        step("bridge toggle prompts") {
            self.model.navigate(to: .client(claude))
            self.model.setAction(self.work, bit: ClientGrant.delete, on: true)
            self.model.setBridgeEnabled(false)
            return self.model.bridge == .on && self.window.attachedSheet != nil
        }
        step("don't save, then the bridge turns off") {
            self.answer(.alertThirdButtonReturn)
        }
        step("bridge off, edits dropped") {
            self.model.bridge == .off && !self.model.hasUnsavedChanges &&
                self.model.client(claude)?.grants.first { $0.targetID == "cal-work" }?.mask == 7
        }
        step("quit prompts and cancel keeps running") {
            self.model.setBridgeEnabled(true)
            self.model.setAction(self.work, bit: ClientGrant.delete, on: true)
            let reply = NSApp.delegate?.applicationShouldTerminate?(NSApp)
            return reply == .terminateLater && self.answer(.alertSecondButtonReturn)
        }
        step("revert") {
            self.model.revertDraft()
            return !self.model.hasUnsavedChanges
        }
        step("⌘Z through the Edit menu") {
            self.model.setAction(self.family, bit: ClientGrant.create, on: true)
            // Undo goes to the key window; without one (a locked screen), send it there directly.
            let sent = NSApp.keyWindow === self.window
                ? self.key("z") : NSApp.sendAction(Selector(("undo:")), to: self.window, from: nil)
            return sent && self.model.draft?.mask(self.family) == 1
        }
        step("⌘S saves") {
            self.model.setAction(self.family, bit: ClientGrant.create, on: true)
            return self.key("s") && !self.model.hasUnsavedChanges &&
                self.model.client(claude)?.grants.contains(ClientGrant(resource: .calendar, targetID: "cal-family", mask: 3)) == true
        }
        step("⌘2 and ⌘1 switch panes") {
            self.key("2") && self.model.route == .activity && self.key("1") && self.model.route == .overview
        }
        step("⌘N opens New Client") {
            self.key("n") && self.model.sheet == .newClient
        }
        step("close the sheet") {
            self.model.sheet = nil
            self.model.navigate(to: .client(claude))
            return self.model.route == .client(claude)
        }
        step("unavailable grant removal is staged") {
            let gone = GrantKey(resource: .calendar, targetID: "cal-signed-out")
            guard let client = self.model.client(claude),
                  self.model.unavailableGrants(client) == [gone] else { return false }
            self.model.removeUnavailable(gone)
            let staged = self.model.draft?.mask(gone) == 0 && self.model.hasUnsavedChanges &&
                self.model.unavailableGrants(client).isEmpty
            self.model.restoreSaved(gone)
            return staged && !self.model.hasUnsavedChanges
        }
        step("rename updates everywhere") {
            guard self.model.rename(claude, to: "  claude code (laptop) ") == nil else { return false }
            return self.model.clientName(claude) == "claude code (laptop)" &&
                self.model.activity.contains { $0.clientID == claude } &&
                self.model.rename(UIReview.obsidianID, to: "CLAUDE CODE (LAPTOP)") == .duplicate("claude code (laptop)")
        }
        step("create client") {
            guard self.model.createClient(name: "Shortcuts") == nil,
                  let created = self.model.activeClients.first(where: { $0.name == "Shortcuts" }) else { return false }
            // AI agent is the default kind, with Ask before changes preset on.
            return self.model.route == .client(created.id) && self.model.banner?.kind == .info &&
                created.grants.isEmpty && self.model.tokenFileStatus(created.id) == .present &&
                self.model.keyFileStatus(created.id) == .missing && created.approval == .ask &&
                self.model.createClient(name: "shortcuts") == .duplicate("Shortcuts")
        }
        step("pause and resume keep everything") {
            guard let created = self.model.activeClients.first(where: { $0.name == "Shortcuts" }) else { return false }
            self.model.setPaused(created.id, true)
            guard let paused = self.model.client(created.id), paused.paused, paused.pausedAt != nil,
                  self.window.attachedSheet == nil, self.model.banner?.kind == .success,
                  self.model.activeClients.contains(where: { $0.id == created.id }),
                  self.model.tokenFileStatus(created.id) == .present,
                  ClientMenu.items(model: self.model, client: paused).contains(where: { $0.title == "Resume Client" })
            else { return false }
            self.model.setPaused(created.id, false)
            guard let resumed = self.model.client(created.id) else { return false }
            return !resumed.paused && resumed.pausedAt == nil && resumed.approval == created.approval &&
                self.model.tokenFileStatus(created.id) == .present &&
                ClientMenu.items(model: self.model, client: resumed).contains(where: { $0.title == "Pause Client" })
        }
        step("revoke asks first") {
            guard let created = self.model.activeClients.first(where: { $0.name == "Shortcuts" }) else { return false }
            self.model.revokeClient(created.id)
            return self.window.attachedSheet != nil
        }
        step("revoke") { self.answer(.alertFirstButtonReturn) }
        step("revoked, key file removed") {
            guard let revoked = self.model.revokedClients.first(where: { $0.name == "Shortcuts" }) else { return false }
            return self.model.route == .overview && self.model.banner?.kind == .success &&
                self.model.tokenFileStatus(revoked.id) == .missing
        }
        step("create a command-line client") {
            guard self.model.createClient(name: "Nightly sync", kind: .cli) == nil,
                  let created = self.model.activeClients.first(where: { $0.name == "Nightly sync" }) else { return false }
            return self.model.keyFileStatus(created.id) == .present &&
                self.model.tokenFileStatus(created.id) == .missing && created.approval == .allow &&
                self.model.connectTab[created.id] == .cli
        }
        step("switch Connect tabs") {
            self.model.navigate(to: .client(claude))
            self.model.connectTab[claude] = .cli
            let cli = self.model.connectTab[claude] == .cli
            self.model.connectTab[claude] = .agent
            return cli && self.model.client(claude)?.hasSigningKey == false
        }
        step("no snippet contains the token") {
            guard let url = self.model.tokenFileURL(claude),
                  let token = try? String(contentsOf: url, encoding: .utf8) else { return false }
            let context = SetupContext(url: self.model.mcpURL, launcherPath: self.model.launcherPath,
                                       clientID: claude, tokenPath: url.path)
            for agent in AgentKind.allCases {
                self.model.agentChoice[claude] = agent
                for method in agent.methods {
                    self.model.methodChoice["\(claude)|\(agent.rawValue)"] = method
                    let snippet = agent.snippet(method, context)
                    let texts = [snippet.text] + snippet.steps + snippet.extraSnippets.map(\.text)
                    if texts.contains(where: { $0.contains(token) || $0.contains("ekb_mcp_v1_") }) { return false }
                }
            }
            self.model.agentChoice[claude] = .claudeCode
            return true
        }
        step("Install Command-Line Tool links bridge-client") {
            self.model.refresh()
            guard self.model.commandLineTool == .notInstalled,
                  self.model.cliProgram == "/Applications/EKBridge.app/Contents/MacOS/bridge-client" else { return false }
            self.model.installCommandLineTool()
            return self.model.commandLineTool == .installed && self.model.banner?.kind == .success
        }
        step("copied commands use bridge-client") {
            guard let client = self.model.clients.first(where: { $0.id == claude }) else { return false }
            return ConnectCommand.scopeStatus(for: client, among: self.model.clients, program: self.model.cliProgram)
                .hasPrefix("bridge-client scope_status --client ")
        }
        step("Copy Token asks first") {
            NSPasteboard.general.clearContents()
            self.model.copyToken(claude)
            return self.window.attachedSheet != nil
        }
        step("cancel copies nothing") {
            self.answer(.alertSecondButtonReturn) &&
                NSPasteboard.general.string(forType: .string) == nil
        }
        step("Reset token asks first") {
            self.tokenBefore = self.model.tokenFileURL(claude).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            self.callBefore = self.authorizedCall(claude)
            self.model.resetMCPToken(claude)
            return self.window.attachedSheet != nil
        }
        step("reset replaces the token and bumps the revision") {
            guard self.answer(.alertFirstButtonReturn) else { return false }
            let after = self.model.tokenFileURL(claude).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            return after != nil && after != self.tokenBefore &&
                self.callBefore.map { !self.registry.stillAuthorized($0) } == true
        }
        step("approval mode change bumps the revision") {
            guard let call = self.authorizedCall(claude) else { return false }
            self.model.setApproval(claude, .allow)
            let changed = self.model.client(claude)?.approval == .allow && !self.registry.stillAuthorized(call)
            self.model.setApproval(claude, .ask)
            return changed && self.model.client(claude)?.approval == .ask
        }
        step("approval panel shows, Allow resolves") {
            self.decision = nil
            self.queue(.createReminder, ["listID": "list-errands", "title": "Buy oat milk"])
            guard self.review.approvalPanel.window?.isVisible == true else { return false }
            self.review.approvals.allow(self.review.approvals.pending[0].id)
            return self.decision == .allowed && self.review.approvalPanel.window?.isVisible == false
        }
        step("Deny resolves") {
            self.decision = nil
            self.queue(.deleteReminder, ["listID": "list-errands", "itemID": "x"])
            guard self.review.approvals.pending.first?.summary.isDelete == true else { return false }
            self.review.approvals.deny(self.review.approvals.pending[0].id)
            return self.decision == .denied && self.review.approvals.pending.isEmpty
        }
        step("a blind delete shows the warning") {
            self.decision = nil
            self.queue(.deleteReminder, ["listID": "list-errands", "itemID": "x"])
            return self.review.approvals.current?.summary.isBlindDelete == true
        }
        step("wait for the panel to arm") { true }
        step("wait for the panel to arm, again") { true }
        step("Return denies a blind delete") {
            guard let panel = self.review.approvalPanel.window,
                  let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                               windowNumber: panel.windowNumber, context: nil, characters: "\r",
                                               charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
            else { return false }
            panel.makeKey()
            _ = panel.performKeyEquivalent(with: event)
            return self.decision == .denied && self.review.approvals.pending.isEmpty
        }
        step("timeout, queue limit and the 15-minute allowance (fake clock)") {
            var clock = Date()
            var timers = [@MainActor () -> Void]()
            let center = ApprovalCenter(summarize: { _ in ApprovalSummary(title: "", rows: [], isDelete: false) },
                                        now: { clock }, schedule: { _, action in timers.append(action) })
            var decisions = [ApprovalDecision]()
            let request = ApprovalRequest(clientID: "c", clientName: "C", agent: nil,
                                          request: BridgeRequest(id: "r", command: .createEvent, parameters: [:]),
                                          targetID: nil, revision: 3)
            for _ in 0..<4 { _ = center.request(request) { decisions.append($0) } }
            guard decisions == [.tooMany], center.pending.count == 3 else { return false }
            timers[0]()
            guard decisions == [.tooMany, .timedOut] else { return false }
            center.allow(center.pending[0].id, forWindow: true)
            _ = center.request(request) { decisions.append($0) }
            guard decisions.last == .allowedByWindow else { return false }
            clock = clock.addingTimeInterval(ApprovalCenter.allowWindow + 1)
            _ = center.request(request) { decisions.append($0) }
            let expired = decisions.last == .allowedByWindow && center.pending.count == 2
            var next = request
            next.revision = 4
            center.allow(center.pending[0].id, forWindow: true)
            _ = center.request(next) { decisions.append($0) }
            // A revision change ends the allowance.
            return expired && center.pending.count == 2
        }
        step("port change validation") {
            self.model.portIssue("80") != nil && self.model.portIssue("abc") != nil &&
                self.model.portIssue("70000") != nil && self.model.portIssue("47616") != nil &&
                self.model.portIssue("47620") == nil
        }
        step("turning the MCP server off with recent agents asks first") {
            self.model.mcpDidConnect(claude, MCPServer.Connection(at: Date(), agent: "claude-code 2.4.1"))
            self.model.refresh()
            self.model.setMCPServerEnabled(false)
            return self.window.attachedSheet != nil
        }
        step("cancel keeps it on") {
            self.answer(.alertSecondButtonReturn) && self.model.mcpEnabled && self.model.mcpIsListening
        }
        step("turning on Remote Access asks first") {
            self.model.setRemoteAccessEnabled(true)
            return self.window.attachedSheet != nil && !self.model.remoteEnabled
        }
        step("Remote Access on, with a secret path") {
            self.answer(.alertFirstButtonReturn) && self.model.remoteEnabled &&
                RemoteConfiguration.validSecret(self.model.remoteSecret)
        }
        step("address validation") {
            self.model.remoteIsListening &&
                self.model.remoteAddressIssue("http://my-mac.example") != nil &&
                self.model.remoteAddressIssue("https://my-mac.example/path") != nil &&
                self.model.setRemoteAddress("https://My-Mac.tail1234.ts.net/") == nil &&
                self.model.remoteMCPURL == "https://my-mac.tail1234.ts.net/r/\(self.model.remoteSecret)/mcp"
        }
        step("remote port can't be the MCP port") {
            self.model.remotePortIssue("47615") != nil && self.model.remotePortIssue("47620") == nil
        }
        step("Test reports reachable") {
            self.model.testRemoteAccess()
            return self.model.remoteTest == .testing
        }
        step("reachable") {
            if case .reachable = self.model.remoteTest { return true }
            return false
        }
        step("cloud access and Copy Remote Token asks first") {
            self.model.setCloudAccess(claude, true)
            guard self.model.client(claude)?.cloudAccess == true else { return false }
            self.model.copyRemoteToken(claude)
            return self.window.attachedSheet != nil
        }
        step("copying creates the remote token") {
            NSPasteboard.general.clearContents()
            guard self.answer(.alertFirstButtonReturn) else { return false }
            let copied = NSPasteboard.general.string(forType: .string) ?? ""
            Pasteboard.clearSecret()
            return ClientRegistry.validRemoteToken(copied) && self.model.client(claude)?.hasRemoteToken == true &&
                NSPasteboard.general.string(forType: .string) == nil
        }
        step("a cloud app asks to pair") {
            self.review.startPairing(for: claude)
            return self.model.pairingClientID == claude
        }
        step("pairing shows the code") {
            guard case .pairing(let id) = self.model.sheet, let request = self.model.pairingRequest(id) else {
                return false
            }
            return request.code.count == 7 && request.appName == "claude.ai" && self.window.attachedSheet != nil
        }
        var firstPairing: UUID?
        step("a second request waits instead of replacing the sheet") {
            guard case .pairing(let id) = self.model.sheet else { return false }
            firstPairing = id
            self.review.startPairing(for: claude, reopen: false)
            return self.model.sheet == .pairing(id) && self.review.oauth.pendingPairings.count == 2
        }
        step("answering shows the waiting request") {
            guard let first = firstPairing else { return false }
            self.model.answerPairing(first, allow: false)
            return self.model.sheet == nil
        }
        step("deny closes the pairing") {
            guard case .pairing(let id) = self.model.sheet, id != firstPairing else { return false }
            self.model.answerPairing(id, allow: false)
            return self.model.sheet == nil && self.model.oauthConnections(claude).isEmpty
        }
        step("turning cloud access off asks, then removes the token") {
            self.model.setCloudAccess(claude, false)
            guard self.window.attachedSheet != nil, self.answer(.alertFirstButtonReturn) else { return false }
            return self.model.client(claude)?.cloudAccess == false &&
                self.model.client(claude)?.hasRemoteToken == false &&
                self.model.remoteTokenStatus(claude) == .missing
        }
        step("Remote Access off from the menu") {
            self.model.applyRemoteEnabled(false)
            return !self.model.remoteEnabled && self.model.remoteStatus == .off
        }
        step("activity deep link") {
            guard let forbidden = self.model.activity.first(where: { $0.code == "forbidden" }) else { return false }
            self.model.openActivity(selecting: forbidden.id)
            return self.model.route == .activity && self.model.activitySelection == forbidden.id &&
                self.model.unseenProblemCount == 0
        }
        step("Show All Activity clears a client filter") {
            self.model.openActivity(client: UIReview.obsidianID)
            let scoped = self.model.activityClientFilter == .client(UIReview.obsidianID)
            self.model.openActivity()
            return scoped && self.model.activityClientFilter == .all && self.model.activitySelection == nil
        }
        step("open client at the target row") {
            self.model.openClientAccess(claude, focus: GrantKey(resource: .reminderList, targetID: "list-groceries"))
            return self.model.route == .client(claude) && self.model.accessTab[claude] == .reminderList &&
                self.model.accessFocus?.targetID == "list-groceries"
        }
        // A first install has never been registered as a login item, and
        // macOS reports that as .notFound; the switch must still work.
        step("Start at login on a first install") {
            self.review.installedInApplications = true
            self.review.loginItemStatus = .notFound
            self.model.refresh()
            guard self.model.canChangeStartAtLogin else { return false }
            self.model.setStartAtLogin(true)
            let enabled = self.model.loginItem == .enabled && self.model.loginItemError == nil
            self.review.installedInApplications = false
            self.review.loginItemStatus = .notRegistered
            self.model.refresh()
            return enabled && !self.model.canChangeStartAtLogin
        }
        // Updates, with the fake updater (Sparkle isn't started in this build).
        step("a found update shows a card") {
            self.model.updateFound(FoundUpdate(version: "9.9.0", critical: false))
            return self.model.showsUpdateCard && self.model.foundUpdate?.version == "9.9.0"
        }
        step("closing the card keeps the menu item") {
            self.model.dismissFoundUpdate()
            return !self.model.showsUpdateCard && self.model.foundUpdate != nil
        }
        step("a security update's card can't be closed") {
            self.model.updateFound(FoundUpdate(version: "9.9.1", critical: true))
            self.model.dismissFoundUpdate()
            return self.model.showsUpdateCard
        }
        step("Check for Updates opens Sparkle and clears the reminder") {
            guard let item = self.checkForUpdatesItem, let action = item.action,
                  (NSApp.delegate as? NSMenuItemValidation)?.validateMenuItem(item) == true else { return false }
            let before = self.review.updateChecks
            NSApp.sendAction(action, to: item.target, from: item)
            return self.review.updateChecks == before + 1 && self.model.foundUpdate == nil &&
                !self.model.showsUpdateCard
        }
        step("automatic checks follow the switch") {
            self.model.setAutomaticUpdateChecks(false)
            let off = !self.model.automaticUpdateChecks && !self.review.automaticUpdateChecks
            self.model.setAutomaticUpdateChecks(true)
            return off && self.model.automaticUpdateChecks && self.review.automaticUpdateChecks
        }
        step("the Help menu has the links, then the checklist") {
            let titles = NSApp.helpMenu?.items.map { $0.isSeparatorItem ? "-" : $0.title } ?? []
            return titles == [AppLinks.help.title, "Set Up an AI Agent", "Release Notes", "-",
                              "Ask a Question…", "Report an Issue…", "-", "Show Setup Checklist"]
                && NSApp.helpMenu?.items.first?.representedObject as? URL == AppLinks.help.url
        }
        step("activity result column fits every label") {
            let widths = [900, 760].map {
                ActivityColumns.widths(for: ActivityColumns.tableWidth(windowWidth: CGFloat($0)))
            }
            return widths.allSatisfy { $0.result >= ActivityColumns.widestResultLabel }
                && widths[0].request >= ActivityColumns.widestRequestLabel
        }
        step("a copy built from source can't check") {
            self.review.updaterAvailable = false
            self.model.refresh()
            let disabled = !self.model.updaterAvailable && !self.model.automaticUpdateChecks &&
                self.checkForUpdatesItem.map { (NSApp.delegate as? NSMenuItemValidation)?.validateMenuItem($0) } == false
            self.review.updaterAvailable = true
            self.model.refresh()
            return disabled && self.model.updaterAvailable
        }
        next()
    }

    private var checkForUpdatesItem: NSMenuItem? {
        NSApp.mainMenu?.items.first?.submenu?.items.first {
            $0.action == #selector(BridgeAppDelegate.checkForUpdates(_:))
        }
    }

    private func step(_ name: String, _ check: @escaping @MainActor () -> Bool) {
        steps.append((name, check))
    }

    private func next() {
        guard !steps.isEmpty else { return report("passed", failed: nil) }
        let (name, check) = steps.removeFirst()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated {
                if check() {
                    self.passed.append(name)
                    self.next()
                } else {
                    self.report("failed", failed: name)
                }
            }
        }
    }

    private func report(_ outcome: String, failed: String?) {
        var result: [String: Any] = ["outcome": outcome, "steps": passed.count]
        if let failed { result["failed"] = failed }
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data + Data([10]))
        }
        // Leave nothing staged, so quitting doesn't prompt.
        model.revertDraft()
        NSApp.terminate(nil)
    }
}

/// Renders each screen with fixture data, in both appearances, to PNG with
/// cacheDisplay (no screen-recording permission needed).
@MainActor
final class SnapshotReview {
    let review: UIReview
    let model: BridgeAppModel
    let controller: MainWindowController
    let folder: URL
    private var steps = [(String, @MainActor () -> NSWindow?)]()
    private var written = [String]()

    init(review: UIReview, model: BridgeAppModel, controller: MainWindowController, folder: URL) {
        self.review = review
        self.model = model
        self.controller = controller
        self.folder = folder
    }

    func start() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        controller.present()
        let (freshModel, freshController) = review.makeFreshWindow(calendar: .fullAccess, reminders: .notDetermined)
        let (renamedModel, renamedController) = review.makeRenamedWindow()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            let main = controller.window
            func step(_ name: String, _ setup: @escaping @MainActor () -> NSWindow?) {
                steps.append(("\(name)-\(suffix)", setup))
            }
            step("overview") {
                main?.appearance = NSAppearance(named: appearance)
                self.model.sheet = nil
                self.model.navigate(to: .overview)
                return main
            }
            step("client") {
                self.model.navigate(to: .client(UIReview.claudeID))
                return main
            }
            step("client-edited") {
                self.model.setAction(GrantKey(resource: .calendar, targetID: "cal-family"), bit: ClientGrant.edit, on: true)
                self.model.setAction(GrantKey(resource: .calendar, targetID: "cal-work"), bit: ClientGrant.delete, on: true)
                return main
            }
            step("client-reminders") {
                self.model.revertDraft()
                self.model.accessTab[UIReview.claudeID] = .reminderList
                return main
            }
            step("client-readonly-warning") {
                self.model.accessTab[UIReview.claudeID] = .calendar
                self.model.navigate(to: .client(UIReview.briefingID))
                return main
            }
            step("client-paused") {
                self.model.navigate(to: .client(UIReview.obsidianID))
                return main
            }
            step("activity") {
                self.model.navigate(to: .activity)
                self.model.activitySelection = self.model.activity.first { $0.code == "forbidden" }?.id
                return main
            }
            step("activity-minimum") {
                // Rebuilt at the new size, as a window opened at it would be.
                let selection = self.model.activitySelection
                self.model.navigate(to: .overview)
                main?.setContentSize(MainWindowController.minimumSize)
                DispatchQueue.main.async {
                    self.model.navigate(to: .activity)
                    self.model.activitySelection = selection
                }
                return main
            }
            step("settings") {
                main?.setContentSize(MainWindowController.defaultSize)
                self.model.setShowDeveloperTools(true)
                self.model.navigate(to: .settings)
                return main
            }
            step("overview-mcp") {
                self.model.setShowDeveloperTools(false)
                self.model.navigate(to: .overview)
                return main
            }
            step("overview-update") {
                self.model.updateFound(FoundUpdate(version: "0.8.1", critical: false))
                return main
            }
            step("overview-update-security") {
                self.model.updateFound(FoundUpdate(version: "0.8.2", critical: true))
                return main
            }
            step("settings-updates") {
                self.model.updateFound(nil)
                self.model.navigate(to: .settings)
                return main
            }
            step("settings-updates-source-build") {
                self.review.updaterAvailable = false
                self.model.refresh()
                return main
            }
            step("settings-about") {
                self.review.updaterAvailable = true
                self.model.refresh()
                self.model.navigate(to: .settings)
                self.model.settingsScrollTarget = "about"
                return main
            }
            step("overview-after-updates") {
                self.review.updaterAvailable = true
                self.model.refresh()
                self.model.navigate(to: .overview)
                return main
            }
            step("client-connect-agent-claude-code") {
                self.model.navigate(to: .client(UIReview.claudeID))
                self.model.connectTab[UIReview.claudeID] = .agent
                self.model.agentChoice[UIReview.claudeID] = .claudeCode
                return main
            }
            step("client-connect-agent-claude-desktop") {
                self.model.agentChoice[UIReview.claudeID] = .claudeDesktop
                return main
            }
            step("client-connect-direct-other") {
                self.model.agentChoice[UIReview.claudeID] = .other
                return main
            }
            step("client-connect-no-token") {
                self.model.agentChoice[UIReview.claudeID] = .claudeCode
                self.model.navigate(to: .client(UIReview.briefingID))
                self.model.connectTab[UIReview.briefingID] = .agent
                return main
            }
            step("client-connect-cli") {
                self.model.connectTab[UIReview.briefingID] = .cli
                return main
            }
            step("client-connect-server-off") {
                self.model.navigate(to: .client(UIReview.cursorID))
                self.review.mcpMode = "off"
                self.model.setMCPServerEnabled(false, confirm: false)
                return main
            }
            step("settings-mcp-listening") {
                self.model.setMCPServerEnabled(true)
                self.model.navigate(to: .settings)
                return main
            }
            step("settings-mcp-port-in-use") {
                self.review.mcpMode = "port-in-use"
                self.review.reportMCP()
                return main
            }
            step("activity-mcp-inspector") {
                self.review.mcpMode = "listening"
                self.review.reportMCP()
                self.model.navigate(to: .activity)
                self.model.activitySelection = self.model.activity.first { $0.code == "approval_denied" }?.id
                return main
            }
            step("approval-panel-create") {
                self.model.activitySelection = nil
                self.review.queueApproval(.createReminder, [
                    "listID": "list-groceries", "title": "Buy oat milk",
                    "due": ["kind": "timed", "at": 1_793_887_200, "timeZone": "America/New_York"],
                    "recurrence": ["kind": "rule", "frequency": "weekly", "interval": 1, "weekdays": ["TH"]]],
                    agent: "codex 0.98.0", client: UIReview.cursorID, name: "Codex")
                self.review.approvalPanel.window?.appearance = NSAppearance(named: appearance)
                return self.review.approvalPanel.window
            }
            step("approval-panel-update") {
                self.review.approvals.withdrawAll()
                self.review.queueApproval(.updateEvent, ["calendarID": "cal-work", "itemID": "fixture-update",
                                                         "expectedVersion": "1", "idempotencyKey": "k",
                                                         "start": 1_791_298_800, "end": 1_791_302_400],
                                          agent: "codex 0.98.0", client: UIReview.cursorID, name: "Codex")
                return self.review.approvalPanel.window
            }
            step("approval-panel-event-fields") {
                self.review.approvals.withdrawAll()
                // Tuesday, October 13, 2026, 10:00 in Madrid.
                self.review.queueApproval(.createEvent, [
                    "calendarID": "cal-work", "title": "Weekly sync", "start": 1_791_878_400, "end": 1_791_882_000,
                    "timeZone": "Europe/Madrid", "idempotencyKey": "k",
                    "recurrence": ["kind": "rule", "frequency": "weekly", "weekdays": ["TU"],
                                   "end": ["kind": "count", "count": 10]],
                    "notes": "Agenda:\n1. Roadmap\n2. Hiring\n3. Offsite dates\n4. Anything else",
                    "location": "Sala 2", "structuredLocation": ["title": "Sala 2", "latitude": 40.4168,
                                                                 "longitude": -3.7038],
                    "url": "https://meet.example.com/abc-defg-hij", "availability": "busy",
                    "alarms": [["kind": "relative", "offset": -900], ["kind": "relative", "offset": -86_400]],
                ], agent: "claude-code 2.4.1")
                return self.review.approvalPanel.window
            }
            step("approval-panel-recurring-delete") {
                self.review.approvals.withdrawAll()
                self.review.queueApproval(.deleteEvent, ["calendarID": "cal-work", "itemID": "fixture-series",
                                                         "expectedVersion": "1", "idempotencyKey": "k",
                                                         "occurrenceStart": 1_792_504_800, "span": "future"],
                                          agent: "claude-code 2.4.1")
                return self.review.approvalPanel.window
            }
            step("approval-panel-reminder-fields") {
                self.review.approvals.withdrawAll()
                self.review.queueApproval(.updateReminder, ["listID": "list-errands", "itemID": "fixture-reminder",
                                                            "expectedVersion": "1", "idempotencyKey": "k",
                                                            "completed": false, "priority": "high",
                                                            "notes": "Two are overdue.",
                                                            "url": "tel:+15555550100"],
                                          agent: "codex 0.98.0", client: UIReview.cursorID, name: "Codex")
                return self.review.approvalPanel.window
            }
            step("approval-panel-delete-queued") {
                self.review.approvals.withdrawAll()
                for title in ["a", "b"] {
                    self.review.queueApproval(.createReminder, ["listID": "list-errands", "title": title],
                                              agent: "claude-code 2.4.1")
                }
                self.review.queueApproval(.deleteReminder, ["listID": "list-errands",
                                                            "itemID": "x-apple-reminderkit://REMCDReminder/6C1E2B9D-55A0-4F3B-9D8E-0C7A33A14F2A"],
                                          agent: "claude-code 2.4.1")
                self.review.approvals.selection = 2
                return self.review.approvalPanel.window
            }
            step("settings-remote") {
                self.review.approvals.withdrawAll()
                self.model.applyRemoteEnabled(true)
                _ = self.model.setRemoteAddress(UIReview.remoteOrigin)
                self.model.testRemoteAccess()
                self.model.settingsScrollTarget = "remote"
                self.model.navigate(to: .settings)
                return main
            }
            step("settings-remote-more") {
                self.model.settingsScrollTarget = "developer"
                return main
            }
            step("client-cloud") {
                if self.model.client(UIReview.claudeID)?.cloudAccess != true {
                    self.model.setCloudAccess(UIReview.claudeID, true)
                }
                self.model.cloudAgentChoice[UIReview.claudeID] = .claudeAI
                self.model.navigate(to: .client(UIReview.claudeID))
                self.model.clientScrollTarget = "cloud"
                return main
            }
            step("client-cloud-bearer") {
                self.model.cloudAgentChoice[UIReview.claudeID] = .anthropicAPI
                return main
            }
            step("sheet-pairing") {
                self.review.startPairing(for: UIReview.claudeID)
                return main?.attachedSheet ?? main
            }
            step("sheet-oauth-client") {
                self.model.sheet = nil
                self.model.cloudAgentChoice[UIReview.claudeID] = .geminiEnterprise
                self.model.setUpOAuthClient(UIReview.claudeID, appName: CloudAgentKind.geminiEnterprise.displayName,
                                            redirectURI: CloudAgentKind.geminiEnterprise.preRegisteredRedirectURI!)
                return main?.attachedSheet ?? main
            }
            step("new-client-sheet-mcp") {
                self.model.oauthClientDetails = nil
                self.model.sheet = nil
                self.model.applyRemoteEnabled(false)
                self.review.approvals.withdrawAll()
                self.model.navigate(to: .overview)
                self.model.sheet = .newClient
                return main?.attachedSheet ?? main
            }
            step("sheet-new-client") {
                self.model.setShowDeveloperTools(false)
                self.model.navigate(to: .overview)
                self.model.sheet = .newClient
                return main?.attachedSheet ?? main
            }
            step("sheet-rename") {
                self.model.sheet = nil
                self.model.navigate(to: .client(UIReview.claudeID))
                self.model.sheet = .rename(UIReview.claudeID)
                return main?.attachedSheet ?? main
            }
            step("sheet-unavailable") {
                self.model.sheet = .unavailableGrants(UIReview.claudeID)
                return main?.attachedSheet ?? main
            }
            step("client-access") {
                // The README's Access picture: Claude Code's calendars, scrolled to the table.
                self.model.sheet = nil
                self.model.navigate(to: .client(UIReview.claudeID))
                self.model.accessTab[UIReview.claudeID] = .calendar
                self.model.clientScrollTarget = "access"
                return main
            }
            step("setup") {
                self.model.sheet = nil
                main?.orderOut(nil)
                freshController.window?.appearance = NSAppearance(named: appearance)
                freshController.present()
                return freshController.window
            }
            step("setup-progress") {
                if freshModel.activeClients.isEmpty { _ = freshModel.createClient(name: "Claude Code") }
                freshModel.navigate(to: .overview)
                freshModel.dismissBanner()
                return freshController.window
            }
            step("overview-renamed") {
                freshController.window?.orderOut(nil)
                renamedModel.navigate(to: .overview)
                renamedModel.bridgeDidChange(.on)
                renamedModel.mcpStatusDidChange(.listening(port: UIReview.port))
                renamedController.window?.appearance = NSAppearance(named: appearance)
                renamedController.present()
                return renamedController.window
            }
            step("restore") {
                renamedController.window?.orderOut(nil)
                freshController.window?.orderOut(nil)
                self.controller.present()
                return nil
            }
        }
        next()
    }

    private func next() {
        guard !steps.isEmpty else {
            let result: [String: Any] = ["outcome": "passed", "files": written]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
                FileHandle.standardOutput.write(data + Data([10]))
            }
            NSApp.terminate(nil)
            return
        }
        let (name, setup) = steps.removeFirst()
        _ = setup()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            MainActor.assumeIsolated {
                // Look the window up after layout so sheets are attached.
                guard let window = self.target(for: name) else { return self.next() }
                if self.external {
                    self.waitForExternalCapture(window, name: name)
                } else {
                    self.capture(window, name: name)
                    self.next()
                }
            }
        }
    }

    /// External mode prints each ready window and waits for a line on stdin,
    /// so a script can capture the real window (lists and tables included).
    private var external: Bool { CommandLine.arguments.contains("--ui-snapshots-external") }

    private func waitForExternalCapture(_ window: NSWindow, name: String) {
        let ready: [String: Any] = ["ready": name, "windowNumber": window.windowNumber]
        if let data = try? JSONSerialization.data(withJSONObject: ready, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data + Data([10]))
        }
        DispatchQueue.global().async {
            _ = readLine()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.written.append("\(name).png")
                    self.next()
                }
            }
        }
    }

    private func target(for name: String) -> NSWindow? {
        if name.hasPrefix("restore") { return nil }
        if name.hasPrefix("approval-panel") { return review.approvalPanel.window }
        if name.hasPrefix("setup") || name.hasPrefix("overview-renamed") {
            return NSApp.windows.first { $0.isVisible && $0 !== controller.window && $0.contentViewController != nil }
        }
        guard let main = controller.window else { return nil }
        return name.hasPrefix("sheet") || name.hasPrefix("new-client-sheet") ? (main.attachedSheet ?? main) : main
    }

    private func capture(_ window: NSWindow, name: String) {
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let url = folder.appendingPathComponent("\(name).png")
        if (try? data.write(to: url)) != nil { written.append(url.lastPathComponent) }
    }
}
#endif
