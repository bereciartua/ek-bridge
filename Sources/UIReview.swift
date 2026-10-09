#if EVENTKIT_UI_REVIEW
import AppKit
import CryptoKit
import EventKit
import ServiceManagement
import SwiftUI

// UI-review build only (EVENTKIT_UI_REVIEW=1). Uses a temporary registry, key
// folder and defaults suite with fake clients, calendars and activity. It
// never touches EventKit or starts the bridge.
//
// Arguments:
//   --ui-window-lifecycle-test   cycle the window and its sheets, print JSON
//   --ui-snapshots <dir>         write PNGs of every screen, light and dark
//   --ui-visual-review           show the window and print its window number
//     --ui-route overview|activity|client|settings, --ui-hold <seconds>,
//     --ui-size <width>x<height>, --ui-select-problem, --ui-open-menu, --ui-appearance light|dark
//   --ui-fresh                   start with no clients (setup checklist)
//   --ui-calendar / --ui-reminders notDetermined|denied|writeOnly|restricted|fullAccess
//   --ui-many-collections        60 calendars and lists
//   --ui-long-names              a 60-character client and a 50-character calendar
//   --ui-max-clients             32 active clients (New Client is disabled)
//   --ui-max-activity            500 activity rows
//   --ui-bridge-off              start with the bridge off
//   --ui-mcp listening|off|port-in-use   the fake MCP server's state (default listening)
//   --ui-remote                  start with Remote Access on, a tunnel address and a cloud client
//   --ui-renamed                 the first launch after the rename (access re-check; use with --ui-calendar notDetermined)
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
    /// Move to Applications calls (the fake never moves anything).
    var moveCalls = 0
    /// The fake updater: never contacts GitHub.
    var updaterAvailable = !CommandLine.arguments.contains("--ui-no-updater")
    var automaticUpdateChecks = true
    var lastUpdateCheck = Date().addingTimeInterval(-2 * 3_600)
    private(set) var updateChecks = 0
    let many: Bool
    /// "listening", "off" or "port-in-use".
    var mcpMode: String
    /// What the fake Remote Access test answers.
    var remoteReachable = true
    /// What the fake tunnel checks on this Mac answer, per tunnel (plan 08).
    /// Other tunnel can't be checked.
    var tunnelHealth: [TunnelProvider: TunnelHealth] = UIReview.defaultTunnelHealth
    static let quickTunnelOrigin = "https://quiet-river-1234.trycloudflare.com"
    static let defaultTunnelHealth: [TunnelProvider: TunnelHealth] = [
        .tailscaleFunnel: .running(address: remoteOrigin, port: 47616),
        .cloudflareQuick: .running(address: quickTunnelOrigin, port: 47616),
        .cloudflareTunnel: .notRunning(reason: .noTunnel),
        .ngrok: .notInstalled,
    ]
    /// Checks the fake ran, for the behavior test.
    var tunnelChecks = 0
    /// Calls to the fake MCP server, for the behavior test.
    var mcpStarts = 0
    var mcpStops = 0
    weak var model: BridgeAppModel?
    private(set) lazy var approvals = ApprovalCenter(summarize: { request in
        ApprovalSummaries.build(request, lookup: Self.fixtureLookup(request),
                                collections: Self.collections(many: false))
    }, summarizeAccess: { access in
        AccessAsk.build(access, summary: ApprovalSummaries.build(access.approvalRequest,
                                                                 lookup: Self.fixtureLookup(access.approvalRequest),
                                                                 collections: Self.collections(many: false)),
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
        // The local server follows EK Bridge; "--ui-mcp off" is the Advanced switch turned off.
        if mcpMode == "off" { defaults.set(false, forKey: "LocalMCPServerAllowed") }
        if CommandLine.arguments.contains("--ui-remote") && fresh != true { seedRemote() }
        if renamed ?? CommandLine.arguments.contains("--ui-renamed") {
            defaults.set(true, forKey: RenameMigration.accessRecheckKey)
        }
        if !(fresh ?? CommandLine.arguments.contains("--ui-fresh")) {
            seed()
            ConnectionAgentKinds.save([Self.claudeID: .claudeCode, Self.cursorID: .cursor], defaults)
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
            installLocation: { [unowned self] in
                self.installedInApplications ? .applications
                    : .elsewhere(path: NSHomeDirectory() + "/Downloads/EKBridge.app")
            },
            moveToApplications: { [unowned self] in
                self.moveCalls += 1
                return .moving
            },
            // No Homebrew folders (this Mac's own links must not count), and the
            // installed location in copied commands instead of the build folder.
            commandLineTool: CommandLineTool(appURL: Bundle.main.bundleURL, home: directory, packageBins: [],
                                             displayAppURL: URL(fileURLWithPath: "/Applications/EKBridge.app")),
            testCollections: nil,
            mcp: MCPControls(
                start: { [unowned self] _ in
                    self.mcpStarts += 1
                    if self.mcpMode == "off" { self.mcpMode = "listening" }
                    DispatchQueue.main.async { self.reportMCP() }
                },
                stop: { [unowned self] in
                    self.mcpStops += 1
                    self.mcpMode = "off"
                },
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
                test: { [unowned self] _, completion in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        completion(self.remoteReachable ? .success((rtt: 0.18, tunnel: "Tailscale Funnel"))
                            : .failure(RemoteTestFailure(reason: "The tunnel answered with HTTP 502. Check that it's running and points at port 47616.")))
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
                lastCheck: { [unowned self] in self.lastUpdateCheck }),
            installedAgents: { [.claudeCode, .claudeDesktop, .cursor] },
            agentSetup: fakeAgentSetup(),
            itemLookup: { Self.fixtureItem($0) },
            showItem: { [unowned self] _ in
                self.itemShows += 1
                return true
            },
            notifications: NotificationControls(
                post: { [unowned self] in self.posted.append($0) },
                permission: { [unowned self] done in MainActor.assumeIsolated { done(self.notificationPermission) } },
                requestPermission: { [unowned self] done in
                    MainActor.assumeIsolated {
                        if self.notificationPermission == .notDetermined { self.notificationPermission = .allowed }
                        done(self.notificationPermission == .allowed)
                    }
                },
                openSettings: {}),
            tunnels: TunnelChecks { [unowned self] provider, _, done in
                self.tunnelChecks += 1
                DispatchQueue.main.async { done(self.tunnelHealth[provider] ?? .unknown) }
            })
    }

    /// The fake notification center (C05): what was posted, and what macOS allows.
    var posted = [AppNotification]()
    var notificationPermission = NotificationPermission.notDetermined

    /// The panel's summary for the seeded "Design review" change: moved an hour later.
    static var designSummary: ApprovalSummary {
        let day = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!
        func at(_ hour: Int) -> Date { day.addingTimeInterval(Double(hour) * 3_600) }
        return ApprovalSummary(title: "Claude Code wants to change an event", subtitle: "Work · iCloud",
                               rows: [.init(label: String(localized: "When"), value: ApprovalSummaries.span(at(11), at(12)),
                                            before: ApprovalSummaries.span(at(10), at(11)))],
                               isDelete: false)
    }

    /// Show in Calendar / Reminders calls (the fake opens nothing).
    var itemShows = 0

    /// What EventKit would say about the seeded Activity items (C02):
    /// "ev-gone" was deleted.
    static func fixtureItem(_ ref: ItemRef) -> ItemSnapshot? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func at(_ days: Int, _ hour: Int) -> Date {
            calendar.date(byAdding: DateComponents(day: days, hour: hour), to: today)!
        }
        func event(_ title: String, _ days: Int, _ hour: Int, _ calendarID: String) -> ItemSnapshot {
            ItemSnapshot(title: title, when: ApprovalSummaries.span(at(days, hour), at(days, hour + 1)),
                         collectionID: calendarID)
        }
        func due(_ days: Int, _ hour: Int) -> String {
            String(localized: "Due \(at(days, hour).formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))")
        }
        switch ref.id {
        case "ev-design": return event("Design review", 1, 11, "cal-work")
        case "ev-weekly": return event("Weekly sync", 2, 9, "cal-work")
        case "ev-sam": return event("1:1 with Sam", 0, 16, "cal-work")
        case "ev-gone": return .deleted
        case "rem-cleaning":
            return ItemSnapshot(title: "Pick up dry cleaning", when: String(localized: "Completed"),
                                collectionID: "list-errands")
        case "rem-library":
            return ItemSnapshot(title: "Return library books", when: due(1, 18), collectionID: "list-errands")
        case "rem-oat":
            return ItemSnapshot(title: "Buy oat milk", when: due(3, 9), collectionID: "list-errands")
        default: return nil
        }
    }

    /// Add to <Agent>… without touching any real file: Claude Desktop's file
    /// already has another server; applying "writes" nothing.
    var oneClickApplies = 0
    var restarts = 0
    func fakeAgentSetup() -> AgentSetupControls {
        AgentSetupControls(
            preview: { agent, context, done in
                guard let setup = agent.oneClickSetup(context) else { return }
                switch setup {
                case .jsonMerge(let file, let root, let key, let entry):
                    let before = Data("""
                        {
                          "mcpServers": {
                            "filesystem": {
                              "command": "npx",
                              "args": ["-y", "@modelcontextprotocol/server-filesystem", "~/Desktop"]
                            }
                          }
                        }

                        """.utf8)
                    let merged = try! AgentConfigWriter.merge(current: before, root: root, key: key, entry: entry)
                    let change = ConfigChange(
                        fileURL: OneClickAgents.expand(file, home: NSHomeDirectory()), before: before,
                        after: merged.after, outcome: merged.outcome,
                        summary: String(localized: "Adds “\(key)” to \(root)"),
                        diffLines: AgentConfigWriter.diff(before, merged.after))
                    DispatchQueue.main.async { done(.success(.file(agent: agent, change: change))) }
                case .claudeCode(let key, let arguments):
                    DispatchQueue.main.async {
                        done(.success(.command(agent: agent, executable: NSHomeDirectory() + "/.local/bin/claude",
                                               arguments: arguments, key: key, replacing: false)))
                    }
                case .codex(let key, _, let file, let table):
                    // As without the codex command: its config.toml, with a model and another server.
                    let before = Data("""
                        model = "gpt-5-codex"

                        [mcp_servers.filesystem]
                        command = "npx"
                        args = ["-y", "@modelcontextprotocol/server-filesystem", "~/Desktop"]

                        """.utf8)
                    let appended = try! AgentConfigWriter.appendTOML(current: before, key: key, table: table)
                    let change = ConfigChange(
                        fileURL: OneClickAgents.expand(file, home: NSHomeDirectory()), before: before,
                        after: appended.after, outcome: appended.outcome,
                        summary: String(localized: "Adds the “\(key)” server at the end"),
                        diffLines: AgentConfigWriter.diff(before, appended.after))
                    DispatchQueue.main.async { done(.success(.file(agent: agent, change: change))) }
                }
            },
            apply: { [unowned self] preview, done in
                self.oneClickApplies += 1
                let result: OneClickResult = switch preview {
                case .file(let agent, let change):
                    OneClickResult(agent: agent, backup: URL(fileURLWithPath: change.fileURL.path
                        + ".ekbridge-backup-20261008-154210"))
                case .command(let agent, _, _, let key, _):
                    OneClickResult(agent: agent, output: "Added stdio MCP server \(key) to user config\nFile modified: ~/.claude.json")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { done(.success(result)) }
            },
            restart: { [unowned self] _, done in
                self.restarts += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done(true) }
            })
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

    /// Queues an access request (C04) as the pipeline would; Always Allow
    /// saves the action like the pipeline does.
    @discardableResult
    func queueAccess(_ command: BridgeCommand, _ parameters: [String: Any], client: String = UIReview.claudeID,
                     name: String = "Claude Code", resource: ClientResource, target: String, mask: Int, bit: Int,
                     source: String? = nil, agent: String? = "claude-code 2.4.1",
                     answered: @escaping (AccessDecision) -> Void = { _ in }) -> Bool {
        approvals.resetAccessThrottle()
        let request = BridgeRequest(id: UUID().uuidString.lowercased(), command: command, parameters: parameters)
        let missing = MissingAccess(clientID: client, clientName: name, revision: 1, resource: resource,
                                    targetID: target, currentMask: mask, missingBit: bit, sourceID: source)
        let shown = approvals.requestAccess(AccessRequest(missing: missing, request: request, agent: agent,
                                                          requestID: "\(client)|\(request.id)")) { [weak self] decision in
            if decision == .allowAlways {
                _ = self?.registry.addAccess(clientID: client, resource: resource, targetID: target, bit: bit)
                self?.model?.refresh()
            }
            answered(decision)
        } != nil
        approvalPanel.update()
        return shown
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
        // A last-known name for Claude Code's signed-out calendar.
        let october5 = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 9))!
        let labels: [String: Any] = ["version": 1, "labels": ["calendar:cal-signed-out": [
            "name": "Project calendar", "account": "Exchange", "colorHex": "#8E8E93",
            "lastSeen": october5.timeIntervalSince1970 - 3_600, "missingSince": october5.timeIntervalSince1970]]]
        try? JSONSerialization.data(withJSONObject: labels)
            .write(to: directory.appendingPathComponent(CollectionLabelStore.fileName))
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
        // Oldest first, as stored. A request that was accepted has a start and
        // a result row; one refused before that has a single row. Changes name
        // their item by ID; `fixtureItem` plays EventKit for the names (C02).
        // Claude Code and Cursor come in over MCP, the scripts over the command line.
        struct Row {
            let offset: TimeInterval
            let client: String?
            let command: String
            let outcome: String
            let target: String?
            var item: String? = nil
            var destination: String? = nil
            var approval: String? = nil
            var missing: Int? = nil
        }
        let script: [Row] = [
            Row(offset: -86_400 * 2 - 600, client: Self.revokedID, command: "read_events", outcome: "success", target: "cal-work"),
            Row(offset: -86_400 - 7_200, client: Self.obsidianID, command: "read_events", outcome: "success", target: "cal-work"),
            Row(offset: -86_400 - 7_000, client: Self.obsidianID, command: "update_event", outcome: "error:conflict",
                target: "cal-work", item: "ev-sam"),
            Row(offset: -86_400 - 6_900, client: Self.obsidianID, command: "read_events", outcome: "success", target: "cal-work"),
            Row(offset: -86_400 - 6_800, client: Self.obsidianID, command: "update_event", outcome: "success",
                target: "cal-work", item: "ev-sam"),
            Row(offset: -86_400 - 5_000, client: Self.claudeID, command: "delete_event", outcome: "success",
                target: "cal-work", item: "ev-gone", approval: "user"),
            Row(offset: -86_400 - 3_500, client: Self.cursorID, command: "create_event", outcome: "forbidden",
                target: "cal-home", missing: ClientGrant.create),
            Row(offset: -86_400 - 3_000, client: nil, command: "read_events", outcome: "unauthorized", target: nil),
            Row(offset: -86_400 - 1_000, client: Self.briefingID, command: "read_reminders", outcome: "success", target: "list-reminders"),
            Row(offset: -9_000, client: Self.briefingID, command: "authorization_status", outcome: "success", target: nil),
            Row(offset: -8_800, client: Self.briefingID, command: "read_events", outcome: "success", target: "cal-family"),
            Row(offset: -8_700, client: Self.briefingID, command: "read_events", outcome: "success", target: "cal-work"),
            Row(offset: -8_600, client: Self.briefingID, command: "read_events", outcome: "success", target: "cal-home"),
            Row(offset: -8_500, client: Self.briefingID, command: "read_reminders", outcome: "success", target: "list-reminders"),
            Row(offset: -5_000, client: Self.claudeID, command: "scope_status", outcome: "success", target: nil),
            Row(offset: -4_900, client: Self.claudeID, command: "read_events", outcome: "success", target: "cal-work"),
            Row(offset: -4_800, client: Self.claudeID, command: "create_event", outcome: "error:idempotency_pending_review",
                target: "cal-work"),
            Row(offset: -4_700, client: Self.claudeID, command: "read_events", outcome: "success", target: "cal-work"),
            Row(offset: -4_000, client: Self.claudeID, command: "read_reminders", outcome: "success", target: "list-errands"),
            Row(offset: -3_900, client: Self.claudeID, command: "create_reminder", outcome: "forbidden",
                target: "list-groceries", missing: ClientGrant.create),
            Row(offset: -3_800, client: Self.claudeID, command: "update_event", outcome: "forbidden",
                target: "cal-work", item: "ev-design", destination: "cal-home", missing: ClientGrant.create),
            Row(offset: -3_700, client: Self.briefingID, command: "read_events", outcome: "success", target: "cal-work"),
            Row(offset: -2_400, client: Self.claudeID, command: "read_reminders", outcome: "success", target: "list-errands"),
            Row(offset: -2_300, client: Self.claudeID, command: "complete_reminder", outcome: "success",
                target: "list-errands", item: "rem-cleaning"),
            Row(offset: -1_800, client: Self.claudeID, command: "read_events", outcome: "error:too_many_events_narrow_range",
                target: "cal-home"),
            Row(offset: -1_700, client: Self.claudeID, command: "read_events", outcome: "success", target: "cal-home"),
            Row(offset: -900, client: Self.obsidianID, command: "read_events", outcome: "success", target: "cal-work"),
            Row(offset: -600, client: Self.claudeID, command: "create_event", outcome: "success",
                target: "cal-work", item: "ev-weekly", approval: "user"),
            Row(offset: -420, client: Self.claudeID, command: "read_events", outcome: "success", target: "cal-work"),
            Row(offset: -300, client: Self.claudeID, command: "update_event", outcome: "success",
                target: "cal-work", item: "ev-design", approval: "user"),
            Row(offset: -1_500, client: nil, command: "mcp", outcome: "unauthorized", target: nil),
            Row(offset: -1_400, client: Self.cursorID, command: "read_events", outcome: "error:bridge_off", target: "cal-home"),
            Row(offset: -1_300, client: Self.claudeID, command: "delete_reminder", outcome: "error:approval_denied",
                target: "list-errands", item: "rem-library", approval: "denied"),
            Row(offset: -1_250, client: Self.claudeID, command: "read_events", outcome: "error:rate_limited", target: "cal-work"),
            Row(offset: -1_100, client: Self.claudeID, command: "list_collections", outcome: "success", target: nil),
            Row(offset: -200, client: Self.briefingID, command: "read_reminders", outcome: "success", target: "list-reminders"),
            Row(offset: -150, client: Self.claudeID, command: "create_reminder", outcome: "success",
                target: "list-errands", item: "rem-oat", approval: "user"),
            Row(offset: -120, client: Self.claudeID, command: "read_events", outcome: "success", target: "cal-work"),
            Row(offset: -90, client: Self.obsidianID, command: "read_events", outcome: "error:client_paused", target: "cal-work"),
        ]
        let store = ActivityStore(dataFolder: directory)
        for (index, row) in script.enumerated().sorted(by: { $0.element.offset < $1.element.offset }) {
            let at = now.addingTimeInterval(row.offset)
            let mcp = row.client == nil ? row.command == "mcp" : (row.client == Self.claudeID || row.client == Self.cursorID)
            let request = "\(row.client ?? "-")|seed-\(index)"
            let refusedEarly = ["forbidden", "unauthorized", "error:bridge_off", "error:rate_limited",
                                "error:client_paused"].contains(row.outcome)
            var record = ActivityRecord(id: "\(request)|\(refusedEarly ? ActivityRecord.event : ActivityRecord.result)",
                                        requestID: request,
                                        phase: refusedEarly ? ActivityRecord.event : ActivityRecord.result,
                                        at: at, clientID: row.client, command: row.command, outcome: row.outcome)
            record.targetID = row.target
            record.destinationID = row.destination
            if row.client != Self.revokedID && !(row.client == nil && row.command == "read_events") {
                record.via = mcp ? "mcp" : "cli"
            }
            if row.client == Self.claudeID { record.agent = "claude-code 2.4.1" }
            record.approval = row.approval
            record.missing = row.missing
            record.item = row.item.map {
                ItemRef(kind: CommandPresentation.targetsList(row.command) ? "reminder" : "event", id: $0)
            }
            if !refusedEarly {
                var start = ActivityRecord(id: "\(request)|\(ActivityRecord.start)", requestID: request,
                                           phase: ActivityRecord.start, at: at.addingTimeInterval(-0.2),
                                           clientID: row.client, command: row.command, outcome: "accepted")
                start.targetID = record.targetID
                start.destinationID = record.destinationID
                start.via = record.via
                start.agent = record.agent
                _ = store.append(start)
            }
            _ = store.append(record)
        }
        var activity = [[String: Any]]()
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
        model.bridgeDidChange(bridgeOn ? .on : .off)
        if let version = Self.value(arguments, "--ui-update-found") {
            model.updateFound(FoundUpdate(version: version, critical: arguments.contains("--ui-update-critical")))
        }
        if arguments.contains("--ui-move-prompt") {
            DispatchQueue.main.async { model.offerMoveToApplications() }
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
            case "remote": model.navigate(to: .remoteAccess)
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
            switch value("--ui-appearance") {
            case "dark":
                NSApp.appearance = NSAppearance(named: .darkAqua)
                statusMenu.menuAppearance = NSAppearance(named: .darkAqua)
            case "light":
                NSApp.appearance = NSAppearance(named: .aqua)
                statusMenu.menuAppearance = NSAppearance(named: .aqua)
            default: break
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

    /// A second, empty environment for the setup checklist snapshots.
    func makeFreshWindow(calendar: EKAuthorizationStatus, reminders: EKAuthorizationStatus)
        -> (BridgeAppModel, MainWindowController) {
        let (_, model, controller) = makeFreshEnvironment(calendar: calendar, reminders: reminders)
        return (model, controller)
    }

    /// The same, with its fake services, so a test can record requests.
    func makeFreshEnvironment(calendar: EKAuthorizationStatus, reminders: EKAuthorizationStatus)
        -> (UIReview, BridgeAppModel, MainWindowController) {
        let fresh = UIReview(fresh: true, calendar: calendar, reminders: reminders)
        extraReviews.append(fresh)
        let model = BridgeAppModel(services: fresh.services())
        fresh.model = model
        let controller = MainWindowController(model: model)
        extraWindows.append(controller)
        return (fresh, model, controller)
    }

    /// Records a successful request from a connection, as the pipeline would.
    func recordSuccess(_ clientID: String) {
        let request = BridgeRequest(id: UUID().uuidString.lowercased(), command: .scopeStatus, parameters: [:])
        if case .success(let call) = registry.authorize(clientID: clientID, request: request,
                                                        origin: .mcp(agent: "claude-desktop 1.0")) {
            _ = registry.recordResult(call, outcome: "success")
        }
        model?.refresh()
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
                               .client(UIReview.revokedID), .remoteAccess]
        model.navigate(to: routes[number % routes.count])
        model.sheet = number.isMultiple(of: 2) ? .newClient : .rename(UIReview.claudeID)
        // Generous: the window server is slower with the display asleep, and the
        // first launch after a rebuild draws its first sheet slowly.
        whenSheet(waited: 0) {
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

    /// Runs `work` once the sheet is attached, or after 3 s.
    private func whenSheet(waited: Double, _ work: @escaping @MainActor () -> Void) {
        if controller.window?.attachedSheet != nil && waited >= 0.6 || waited >= 3 { return work() }
        after(0.1) { self.whenSheet(waited: waited + 0.1, work) }
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
        step("⌘3 opens Settings") {
            self.key("3") && self.model.route == .settings
        }
        step("⌘F opens Activity") {
            self.key("f") && self.model.route == .activity
        }
        step("wait for Activity to appear") { true }
        step("⌘F focuses the search field") {
            let editor = self.window.firstResponder as? NSTextView
            return editor?.isFieldEditor == true && editor?.delegate is NSSearchField
        }
        step("⌘N opens New Client") {
            self.key("n") && self.model.sheet == .newClient
        }
        step("close the sheet") {
            self.model.sheet = nil
            self.model.navigate(to: .client(claude))
            return self.model.route == .client(claude)
        }
        step("column Turn On for All sets Read on the rows shown and stages them") {
            guard let draft = self.model.draft, !draft.hasChanges else { return false }
            let calendars = self.model.collections(.calendar)
            let unread = calendars.filter { draft.mask($0.key) & ClientGrant.read == 0 }.count
            self.model.applyColumn(bit: ClientGrant.read, on: true, rows: calendars)
            guard let after = self.model.draft, after.changedCells == unread,
                  calendars.allSatisfy({ after.mask($0.key) & ClientGrant.read != 0 }) else { return false }
            self.window.undoManager?.undo()
            return self.model.draft?.hasChanges == false
        }
        step("column Delete for all skips read-only calendars, write implies Read") {
            let calendars = self.model.collections(.calendar)
            self.model.applyColumn(bit: ClientGrant.delete, on: true, rows: calendars)
            guard let draft = self.model.draft else { return false }
            let ok = calendars.allSatisfy { row in
                row.writable ? draft.mask(row.key) & (ClientGrant.delete | ClientGrant.read) == (ClientGrant.delete | ClientGrant.read)
                    : draft.mask(row.key) & ClientGrant.delete == 0
            }
            self.model.revertDraft()
            return ok
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
        step("Claude Code tile: an MCP connection that reads everything") {
            let name = self.model.suggestedName(AddConnectionTile.agent(.claudeCode).suggestedName)
            // The fixture's Claude Code was renamed above, so the name is free.
            guard name == "Claude Code",
                  self.model.createClient(name: name, kind: .agent, askBeforeChanges: true,
                                          startingAccess: .readAll, agent: .claudeCode) == nil,
                  let created = self.model.activeClients.first(where: { $0.name == name }) else { return false }
            let listed = self.model.collections.count
            return created.hasMCPToken && !created.hasSigningKey && created.grants.count == listed &&
                created.grants.allSatisfy { $0.mask == ClientGrant.read } && created.approval == .ask &&
                self.model.agent(for: created.id) == .claudeCode && self.model.route == .client(created.id)
        }
        step("a new connection opens on Connect") {
            guard case .client(let id) = self.model.route, let client = self.model.client(id) else { return false }
            return self.model.tab(client) == .connect &&
                self.model.connectionStatusLine(client).text.hasPrefix("Waiting for Claude Code")
        }
        step("the next one is numbered") {
            self.model.suggestedName("Claude Code") == "Claude Code 2"
        }
        step("read all plus one: full access on the chosen list only") {
            let groceries = GrantKey(resource: .reminderList, targetID: "list-groceries")
            guard self.model.createClient(name: "Cursor 2", kind: .agent, startingAccess: .readAllPlusOne(groceries),
                                          agent: .cursor) == nil,
                  let created = self.model.activeClients.first(where: { $0.name == "Cursor 2" }) else { return false }
            return created.grants.first { $0.targetID == "list-groceries" }?.mask == 31 &&
                created.grants.filter { $0.targetID != "list-groceries" }.allSatisfy { $0.mask == ClientGrant.read }
        }
        step("Script tile: a command-line connection with no access") {
            let name = self.model.suggestedName(AddConnectionTile.script.suggestedName)
            guard self.model.createClient(name: name, kind: AddConnectionTile.script.kind) == nil,
                  let created = self.model.activeClients.first(where: { $0.name == name }) else { return false }
            return created.hasSigningKey && !created.hasMCPToken && created.grants.isEmpty &&
                self.model.banner?.message == "Choose what it can use, then Save."
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
                  ClientMenu.items(model: self.model, client: paused).contains(where: { $0.title == "Resume Connection" })
            else { return false }
            self.model.setPaused(created.id, false)
            guard let resumed = self.model.client(created.id) else { return false }
            return !resumed.paused && resumed.pausedAt == nil && resumed.approval == created.approval &&
                self.model.tokenFileStatus(created.id) == .present &&
                ClientMenu.items(model: self.model, client: resumed).contains(where: { $0.title == "Pause Connection" })
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
        step("a connection's agent is remembered") {
            let stored = self.model.agent(for: UIReview.cursorID) == .cursor
            self.model.setAgent(.claudeDesktop, for: UIReview.cursorID)
            let saved = ConnectionAgentKinds.load(self.review.defaults)[UIReview.cursorID] == .claudeDesktop
            self.model.setAgent(.cursor, for: UIReview.cursorID)
            return stored && saved && self.model.installedAgents.contains(.claudeDesktop)
        }
        step("Add to Claude Desktop shows the preview") {
            self.model.navigate(to: .client(claude))
            self.model.beginOneClick(claude, agent: .claudeDesktop)
            return self.model.sheet == .configPreview
        }
        step("the preview holds the change, no token") {
            guard case .preview(.file(_, let change))? = self.model.oneClick?.phase else { return false }
            let text = String(decoding: change.after, as: UTF8.self)
            return change.outcome == .added && text.contains("\"filesystem\"") && text.contains("--client") &&
                !text.contains("ekb_mcp_v1_") && self.review.oneClickApplies == 0
        }
        step("Add applies through the fake") {
            self.model.confirmOneClick()
            return self.review.oneClickApplies == 1
        }
        step("added: the sheet closes with the backup's name") {
            self.model.sheet == nil && self.model.oneClickResult(claude, .claudeDesktop) != nil &&
                self.model.banner?.message?.contains(".ekbridge-backup-") == true &&
                self.model.agent(for: claude) == .claudeDesktop
        }
        step("Restart Claude Desktop") {
            self.model.restartAgent(.claudeDesktop)
            return self.review.restarts == 1 && self.model.restarting == .claudeDesktop
        }
        step("restarted") {
            self.model.setAgent(.claudeCode, for: claude)
            return self.model.restarting == nil
        }
        step("a connection with a successful request opens on Access") {
            self.model.navigate(to: .client(claude))
            guard let client = self.model.client(claude) else { return false }
            return self.model.tab(client) == .access
        }
        step("edits survive switching tabs; the save bar shows on Connect") {
            self.model.setAction(self.family, bit: ClientGrant.delete, on: true)
            self.model.clientTab[claude] = .connect
            return self.model.hasUnsavedChanges && ((self.model.draft?.mask(self.family) ?? 0) & ClientGrant.delete) != 0
        }
        step("⌘⌥→ switches tab") {
            let arrow = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                               modifierFlags: [.command, .option, .function, .numericPad],
                                               timestamp: 0, windowNumber: self.window.windowNumber, context: nil,
                                               characters: arrow, charactersIgnoringModifiers: arrow,
                                               isARepeat: false, keyCode: 124) else { return false }
            self.window.makeKey()
            return NSApp.mainMenu?.performKeyEquivalent(with: event) == true &&
                self.model.clientTab[claude] == .activity
        }
        step("the Activity tab shows only this connection's rows") {
            let rows = ActivityScope.client(claude).entries(self.model)
            self.model.revertDraft()
            self.model.clientTab[claude] = nil
            return !rows.isEmpty && rows.allSatisfy { $0.clientID == claude } &&
                rows.count < self.model.activity.count
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
                self.model.setAgent(agent, for: claude)
                for method in agent.methods {
                    self.model.methodChoice["\(claude)|\(agent.rawValue)"] = method
                    let snippet = agent.snippet(method, context)
                    let texts = [snippet.text] + snippet.steps + snippet.extraSnippets.map(\.text)
                    if texts.contains(where: { $0.contains(token) || $0.contains("ekb_mcp_v1_") }) { return false }
                }
            }
            self.model.setAgent(.claudeCode, for: claude)
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
        step("pausing EK Bridge stops MCP") {
            let stops = self.review.mcpStops
            self.model.setBridgeEnabled(false)
            return !self.model.bridge.isOn && self.review.mcpStops == stops + 1 && !self.model.mcpStarted &&
                self.model.mcpStatus == .off && self.model.mcpStatusLine == nil
        }
        step("turning on with an MCP connection starts MCP") {
            let starts = self.review.mcpStarts
            self.model.setBridgeEnabled(true)
            return self.model.bridge.isOn && self.review.mcpStarts == starts + 1 && self.model.mcpStarted
        }
        step("MCP is listening again") { self.model.mcpIsListening }
        step("turning the local MCP server off with recent agents asks first") {
            self.model.mcpDidConnect(claude, MCPServer.Connection(at: Date(), agent: "claude-code 2.4.1"))
            self.model.refresh()
            self.model.setLocalMCPAllowed(false)
            return self.window.attachedSheet != nil
        }
        step("cancel keeps it on") {
            self.answer(.alertSecondButtonReturn) && self.model.localMCPAllowed && self.model.mcpIsListening
        }
        step("pause for an hour sets resumeAt and turns off") {
            self.model.pause(for: .oneHour)
            guard let resume = self.model.resumeAt else { return false }
            return !self.model.bridge.isOn && abs(resume.timeIntervalSinceNow - 3_600) < 5 &&
                self.model.bridgeTitle.hasPrefix("\(AppIdentity.displayName) is paused until")
        }
        step("tick after resumeAt turns on") {
            self.model.pause(until: Date().addingTimeInterval(-1))
            self.model.tick()
            return self.model.bridge.isOn && self.model.resumeAt == nil && self.model.banner?.kind == .info
        }
        step("manual turn on clears resumeAt") {
            self.model.pause(for: .untilTomorrow)
            guard self.model.resumeAt != nil, !self.model.bridge.isOn else { return false }
            self.model.setBridgeEnabled(true)
            return self.model.bridge.isOn && self.model.resumeAt == nil
        }
        step("Advanced switch off keeps MCP off") {
            self.model.setLocalMCPAllowed(false, confirm: false)
            self.model.setBridgeEnabled(false)
            self.model.setBridgeEnabled(true)
            let off = !self.model.mcpStarted && self.model.mcpStatus == .off
            self.model.setLocalMCPAllowed(true)
            return off && self.model.mcpStarted
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
        step("Remote Access page reachable from the menu's problem line") {
            self.model.fix(.remoteAccessFailed("x"))
            return self.model.route == .remoteAccess
        }
        step("guide: starting over shows the tunnels; a set-up address skips to done") {
            self.model.chooseTunnelAgain()
            let choosing = self.model.remoteGuideStep == .chooseTunnel
            self.model.tunnelChoice = .tailscaleFunnel
            return choosing && self.model.remoteGuideStep == .done
        }
        step("guide: picking the default tunnel and Back redraw the page") {
            // The page only redraws for observed changes: the default tunnel
            // and Back used to change only UserDefaults.
            final class Count: @unchecked Sendable { var value = 0 }
            let changes = Count()
            let observe = {
                withObservationTracking { _ = self.model.remoteGuideStep } onChange: { changes.value += 1 }
            }
            observe()
            self.model.chooseTunnelAgain()
            observe()
            self.model.tunnelChoice = .tailscaleFunnel
            return changes.value == 2
        }
        step("guide advances on address save") {
            self.model.remoteEditingAddress = true
            guard self.model.remoteGuideStep == .pasteAddress,
                  self.model.setRemoteAddress("https://other-mac.tail1234.ts.net") == nil,
                  self.model.remoteGuideStep == .test else { return false }
            self.model.testRemoteAccess()
            return true
        }
        step("the test makes it done") {
            self.model.remoteGuideStep == .done
        }
        step("turning off from the page") {
            self.model.setRemoteAccessEnabled(false)
            return !self.model.remoteEnabled && self.model.remoteStatus == .off
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
        step("Move to Applications… asks first") {
            self.review.installedInApplications = false
            self.model.refresh()
            self.model.beginMoveToApplications()
            return self.window.attachedSheet != nil && self.review.moveCalls == 0
        }
        step("moving calls the mover") {
            self.answer(.alertFirstButtonReturn) && self.review.moveCalls == 1
        }
        step("Not Now doesn't move") {
            self.model.beginMoveToApplications()
            return self.answer(.alertSecondButtonReturn) && self.review.moveCalls == 1
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
                && widths[0].change >= ActivityColumns.widestChangeLabel
        }
        // C02: the Changes filter, the item card and a deleted item.
        step("Changes filter hides reads") {
            self.model.openActivity()
            self.model.activityKind = .changes
            let shown = ActivityScope.all.entries(self.model).filter { $0.matches(self.model.activityKind) }
            let ok = !shown.isEmpty && shown.allSatisfy(\.isWrite) &&
                shown.contains { $0.code != "success" } && !shown.contains { $0.command == "read_events" }
            self.model.activityKind = .all
            return ok
        }
        step("selecting a write shows the item card") {
            guard let write = self.model.activity.first(where: { $0.item?.id == "ev-design" && $0.code == "success" })
            else { return false }
            self.model.openActivity(selecting: write.id)
            guard case .found(let item) = self.model.itemDisplay(write) else { return false }
            let before = self.review.itemShows
            self.model.showItem(write)
            return item.title == "Design review" && item.exists && write.changeLabel == "Changed event" &&
                write.resultLabel == "Approved" && self.review.itemShows == before + 1
        }
        // C04: the access panel, Always Allow and the access table.
        step("access request panel appears and Always Allow updates the access table") {
            self.review.approvals.withdrawAll()
            self.model.navigate(to: .client(UIReview.cursorID))
            let home = GrantKey(resource: .calendar, targetID: "cal-home")
            guard self.model.client(UIReview.cursorID)?.grants.first(where: { $0.targetID == "cal-home" })?.mask == 1,
                  self.review.queueAccess(.createEvent, ["calendarID": "cal-home", "title": "Dentist"],
                                          client: UIReview.cursorID, name: "Cursor", resource: .calendar,
                                          target: "cal-home", mask: ClientGrant.read, bit: ClientGrant.create),
                  let item = self.review.approvals.pendingAccess.first,
                  self.model.pendingAccessRequests == ["Cursor can't add events to Home"],
                  self.model.needsYouItems.contains(.accessRequest(title: "Cursor can't add events to Home"))
            else { return false }
            // Unsaved access edits hold Always Allow back.
            self.model.setAction(GrantKey(resource: .calendar, targetID: "cal-family"), bit: ClientGrant.read, on: true)
            self.review.approvals.allowAlways(item.id)
            guard self.review.approvals.pendingAccess.count == 1 else { return false }
            self.model.revertDraft()
            self.review.approvals.allowAlways(item.id)
            return self.review.approvals.pendingAccess.isEmpty &&
                self.model.client(UIReview.cursorID)?.grants.first(where: { $0.targetID == "cal-home" })?.mask == 3 &&
                self.model.draft?.mask(home) == 3
        }
        step("restore Cursor's access") {
            _ = self.review.registry.replaceGrants(clientID: UIReview.cursorID, grants: [
                ClientGrant(resource: .calendar, targetID: "cal-home", mask: 1)])
            self.model.refresh()
            return self.model.client(UIReview.cursorID)?.grants.first?.mask == 1
        }
        step("an answered change keeps its summary for the session") {
            let request = BridgeRequest(id: "c03", command: .updateEvent, parameters: ["calendarID": "cal-work"])
            var asked = ApprovalRequest(clientID: UIReview.claudeID, clientName: "Claude Code", agent: nil,
                                        request: request, targetID: "cal-work")
            asked.requestID = "\(UIReview.claudeID)|c03"
            _ = self.review.approvals.request(asked) { _ in }
            guard let item = self.review.approvals.pending.last else { return false }
            self.review.approvals.allow(item.id)
            return self.model.recentSummaries["\(UIReview.claudeID)|c03"] == item.summary
        }
        // C05: notifications.
        step("a change nobody answered posts one notification") {
            self.review.posted.removeAll()
            self.model.navigate(to: .overview)
            let request = BridgeRequest(id: "c05", command: .updateEvent,
                                        parameters: ["calendarID": "cal-work", "itemID": "fixture-update"])
            var asked = ApprovalRequest(clientID: UIReview.claudeID, clientName: "Claude Code", agent: nil,
                                        request: request, targetID: "cal-work")
            asked.requestID = "\(UIReview.claudeID)|c05"
            _ = self.review.approvals.request(asked) { _ in }
            guard let item = self.review.approvals.pending.last else { return false }
            self.review.approvals.expired(item)
            self.review.approvals.withdrawAll()
            let note = self.review.posted.last
            return self.review.posted.count == 1 && note?.kind == .declined &&
                note?.title == "A change wasn't made" &&
                note?.body == "Claude Code wanted to change an event (“Design review”). Nobody answered in 45 s." &&
                self.review.notificationPermission == .allowed
        }
        step("refused is off by default, then posts once per connection") {
            self.review.posted.removeAll()
            guard !self.model.notificationKinds.contains(.refused),
                  self.model.notificationKinds == [.declined, .update] else { return false }
            let refuse = {
                let request = BridgeRequest(id: UUID().uuidString, command: .createEvent,
                                            parameters: ["calendarID": "cal-family", "title": "x"])
                _ = self.review.registry.authorize(clientID: UIReview.cursorID, request: request, origin: .cli)
                self.model.refresh()
            }
            refuse()
            guard self.review.posted.isEmpty else { return false }
            self.model.setNotification(.refused, true)
            refuse()
            refuse()
            let ok = self.review.posted.count == 1 && self.review.posted[0].body == "Cursor can't add events to Family."
            self.model.setNotification(.refused, false)
            return ok
        }
        step("an update posts once per version") {
            // Not from Overview, which shows the update itself.
            self.model.navigate(to: .activity)
            self.review.posted.removeAll()
            self.model.updateFound(FoundUpdate(version: "9.9.9", critical: false))
            self.model.updateFound(nil)
            self.model.updateFound(FoundUpdate(version: "9.9.9", critical: false))
            self.model.updateFound(nil)
            return self.review.posted.map(\.body) == ["EK Bridge 9.9.9 is available."]
        }
        step("clicking a declined notification opens its Activity row") {
            self.model.handleNotification(AppNotification.openActivity, kind: .declined,
                                          info: [AppNotification.requestIDKey: "nothing"])
            return self.model.route == .activity
        }
        step("Overview's Today and the menu name the item") {
            guard let design = self.model.activity.first(where: { $0.item?.id == "ev-design" && $0.code == "success" }),
                  let deleted = self.model.activity.first(where: { $0.item?.id == "ev-gone" }) else { return false }
            return design.headline(item: self.model.itemTitle(design), collection: "Work") == "Changed “Design review”" &&
                deleted.headline(item: self.model.itemTitle(deleted), collection: "Work") == "Deleted event · Work"
        }
        step("deleted item shows Deleted") {
            guard let gone = self.model.activity.first(where: { $0.item?.id == "ev-gone" }),
                  case .found(let item) = self.model.itemDisplay(gone) else { return false }
            self.model.activitySelection = nil
            return !item.exists && gone.changeLabel == "Deleted event"
        }
        step("a refused move names its destination") {
            guard let move = self.model.activity.first(where: { $0.isMove && $0.code == "forbidden" }) else { return false }
            return ActivityInspector.refusedOnDestination(move) && move.changeLabel == "Move event" &&
                ActivityInspector.missingAction(move) == "Create"
        }
        // A fresh run, end to end (B09): allow both, add Claude Desktop, one-click, first request.
        let (fresh, freshModel, _) = review.makeFreshEnvironment(calendar: .notDetermined, reminders: .notDetermined)
        step("fresh run: three steps, the first current") {
            freshModel.start()
            let states = SetupChecklist.states(freshModel.checklistInput)
            freshModel.requestAccess(.calendar)
            freshModel.requestAccess(.reminderList)
            return states == [.macOSAccess: .current, .addConnection: .pending, .connect: .pending]
        }
        step("wait for the macOS prompts") { true }
        step("allowing both finishes macOS access") {
            SetupChecklist.states(freshModel.checklistInput)[.macOSAccess] == .done
        }
        step("adding Claude Desktop with Read all finishes Add your agent") {
            guard freshModel.createClient(name: "Claude Desktop", startingAccess: .readAll, agent: .claudeDesktop) == nil
            else { return false }
            return SetupChecklist.states(freshModel.checklistInput)[.addConnection] == .done &&
                SetupChecklist.states(freshModel.checklistInput)[.connect] == .current
        }
        step("Connect turns EK Bridge on and opens Add to Claude Desktop") {
            guard let focus = SetupChecklist.focusClient(freshModel.checklistInput) else { return false }
            freshModel.connectFromSetup(focus)
            return freshModel.bridge.isOn && freshModel.sheet == .configPreview && freshModel.waitingForTestRequest
        }
        step("Add applies through the fake") {
            freshModel.confirmOneClick()
            return true
        }
        step("the first request completes setup") {
            guard let id = freshModel.activeClients.first?.id,
                  freshModel.oneClickResult(id, .claudeDesktop) != nil else { return false }
            fresh.recordSuccess(id)
            return SetupChecklist.isComplete(freshModel.checklistInput) &&
                freshModel.setupJustCompletedName == "Claude Desktop"
        }
        step("Needs you lists a waiting change and the unavailable calendar") {
            self.queue(.createReminder, ["listID": "list-errands", "title": "x"])
            let items = self.model.needsYouItems
            self.review.approvals.withdrawAll()
            return items.first == .approvals(1) && items.contains {
                if case .unavailable(_, _, let key, _, _) = $0 { key.targetID == "cal-signed-out" } else { false }
            }
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

/// The snapshot `menu-glyphs`: each state on a strip like the menu bar.
struct MenuGlyphPreview: View {
    var body: some View {
        HStack(spacing: 28) {
            ForEach([(MenuBarGlyphState.on, "On"), (.paused, "Paused"), (.attention, "Needs attention")],
                    id: \.1) { state, label in
                VStack(spacing: 10) {
                    Image(nsImage: MenuBarGlyph.image(state))
                        .renderingMode(.template)
                        .frame(width: 30, height: 24)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                    Image(nsImage: MenuBarGlyph.image(state))
                        .renderingMode(.template)
                        .resizable()
                        .frame(width: 36, height: 36)
                    Text(label).font(.callout).foregroundStyle(.secondary)
                }
                .frame(width: 100)
            }
        }
        .foregroundStyle(.primary)
        .frame(width: 420, height: 190)
        .background(.bar)
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
    /// Claude Code's grants while `overview-quiet` hides its unavailable one.
    private var quietGrants: [ClientGrant]?

    init(review: UIReview, model: BridgeAppModel, controller: MainWindowController, folder: URL) {
        self.review = review
        self.model = model
        self.controller = controller
        self.folder = folder
    }

    func start() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        controller.present()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            let main = controller.window
            func step(_ name: String, _ setup: @escaping @MainActor () -> NSWindow?) {
                steps.append(("\(name)-\(suffix)", setup))
            }
            step("menu-glyphs") {
                let window = self.glyphWindow
                window.appearance = NSAppearance(named: appearance)
                window.center()
                window.orderFrontRegardless()
                return window
            }
            step("overview") {
                // Needs you (mockup 07): an agent asking for access and an
                // unavailable calendar. Today names the items (C06).
                self.glyphWindow.orderOut(nil)
                main?.appearance = NSAppearance(named: appearance)
                self.model.sheet = nil
                self.model.navigate(to: .overview)
                self.review.approvals.withdrawAll()
                self.review.queueAccess(.createEvent, ["calendarID": "cal-home", "title": "Dentist"],
                                        client: UIReview.cursorID, name: "Cursor", resource: .calendar,
                                        target: "cal-home", mask: ClientGrant.read, bit: ClientGrant.create,
                                        agent: "cursor 1.7")
                return main
            }
            step("overview-quiet") {
                // Nothing needs you: no approvals, Activity seen, every granted calendar listed.
                self.review.approvals.withdrawAll()
                self.model.markActivityViewed()
                self.quietGrants = self.review.registry.clients()?.first { $0.id == UIReview.claudeID }?.grants
                _ = self.review.registry.replaceGrants(
                    clientID: UIReview.claudeID,
                    grants: (self.quietGrants ?? []).filter { $0.targetID != "cal-signed-out" })
                self.model.refresh()
                return main
            }
            step("overview-paused") {
                self.model.setBridgeEnabled(false)
                return main
            }
            step("restore-overview") {
                self.model.setBridgeEnabled(true)
                if let grants = self.quietGrants {
                    _ = self.review.registry.replaceGrants(clientID: UIReview.claudeID, grants: grants)
                }
                self.model.refresh()
                return nil
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
                let design = self.model.activity.first { $0.item?.id == "ev-design" && $0.code == "success" }
                // Approved in the panel this session (C03): its before → after.
                if let request = design?.requestID { self.model.rememberApprovalSummary(request, UIReview.designSummary) }
                self.model.activitySelection = design?.id
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
            step("activity-problems") {
                // Rebuilt at the default size (see activity-minimum).
                main?.setContentSize(MainWindowController.defaultSize)
                self.model.navigate(to: .overview)
                DispatchQueue.main.async {
                    self.model.navigate(to: .activity)
                    self.model.activityKind = .problems
                    self.model.activitySelection = self.model.activity.first { $0.isMove && $0.code == "forbidden" }?.id
                }
                return main
            }
            step("activity-deleted-item") {
                self.model.activityKind = .all
                self.model.activitySelection = self.model.activity.first { $0.item?.id == "ev-gone" }?.id
                return main
            }
            step("activity-no-calendar-access") {
                self.review.calendarStatus = .denied
                self.model.refresh()
                self.model.activitySelection = self.model.activity.first {
                    $0.item?.id == "ev-design" && $0.code == "success"
                }?.id
                return main
            }
            step("settings-notifications") {
                self.review.calendarStatus = .fullAccess
                self.model.refresh()
                self.model.activitySelection = nil
                main?.setContentSize(MainWindowController.defaultSize)
                self.model.settingsTab = .general
                self.model.navigate(to: .settings)
                self.model.settingsScrollTarget = "notifications"
                return main
            }
            step("settings-notifications-off") {
                self.review.notificationPermission = .denied
                self.model.refreshNotificationPermission()
                self.model.settingsScrollTarget = "notifications"
                return main
            }
            step("settings") {
                self.review.notificationPermission = .notDetermined
                self.model.refreshNotificationPermission()
                self.review.calendarStatus = .fullAccess
                self.model.refresh()
                self.model.activitySelection = nil
                main?.setContentSize(MainWindowController.defaultSize)
                self.model.setShowDeveloperTools(true)
                self.model.settingsTab = .general
                self.model.navigate(to: .settings)
                return main
            }
            step("settings-advanced") {
                self.model.settingsTab = .advanced
                return main
            }
            step("overview-mcp") {
                self.model.setShowDeveloperTools(false)
                self.model.navigate(to: .overview)
                return main
            }
            step("overview-paused-until") {
                self.model.pause(for: .oneHour)
                return main
            }
            step("restore-paused") {
                self.model.setBridgeEnabled(true)
                return nil
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
                self.model.settingsTab = .general
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
                self.model.clientTab[UIReview.claudeID] = .connect
                self.model.connectTab[UIReview.claudeID] = .agent
                self.model.agentChoice[UIReview.claudeID] = .claudeCode
                return main
            }
            step("client-connect-agent-claude-desktop") {
                self.model.agentChoice[UIReview.claudeID] = .claudeDesktop
                return main
            }
            step("sheet-config-preview") {
                self.model.beginOneClick(UIReview.claudeID, agent: .claudeDesktop)
                return main
            }
            step("client-connect-one-click-done") {
                self.model.confirmOneClick()
                return main
            }
            step("sheet-config-preview-claude-code") {
                self.model.dismissBanner()
                self.model.beginOneClick(UIReview.claudeID, agent: .claudeCode)
                return main
            }
            step("client-connect-copy") {
                self.model.closeOneClick()
                self.model.copySetup.insert(UIReview.claudeID)
                return main
            }
            // C07: Codex and Gemini CLI offer Add to … next to the copyable setup.
            step("client-connect-codex") {
                self.model.copySetup.remove(UIReview.claudeID)
                self.model.agentChoice[UIReview.claudeID] = .codex
                return main
            }
            step("sheet-config-preview-codex") {
                self.model.beginOneClick(UIReview.claudeID, agent: .codex)
                return main
            }
            step("sheet-config-preview-gemini") {
                self.model.closeOneClick()
                self.model.agentChoice[UIReview.claudeID] = .geminiCLI
                self.model.beginOneClick(UIReview.claudeID, agent: .geminiCLI)
                return main
            }
            step("client-connect-direct-other") {
                self.model.closeOneClick()
                self.model.copySetup.remove(UIReview.claudeID)
                self.model.agentChoice[UIReview.claudeID] = .other
                return main
            }
            step("client-connect-cli") {
                self.model.agentChoice[UIReview.claudeID] = .claudeCode
                self.model.navigate(to: .client(UIReview.briefingID))
                self.model.clientTab[UIReview.briefingID] = .connect
                return main
            }
            step("client-connect-server-off") {
                // EK Bridge paused: the Connect tab offers to turn it on.
                self.model.navigate(to: .client(UIReview.cursorID))
                self.model.clientTab[UIReview.cursorID] = .connect
                self.model.setBridgeEnabled(false)
                return main
            }
            step("settings-mcp-listening") {
                self.model.setBridgeEnabled(true)
                self.model.settingsScrollTarget = "mcp"
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
            // Ask for access when refused (C04, mockup 06).
            step("access-request-panel") {
                self.review.approvals.withdrawAll()
                self.review.queueAccess(.createReminder, [
                    "listID": "list-groceries", "title": "Buy oat milk",
                    "due": ["kind": "timed", "at": 1_793_887_200, "timeZone": "America/New_York"]],
                    resource: .reminderList, target: "list-groceries", mask: ClientGrant.read, bit: ClientGrant.create)
                self.review.approvalPanel.window?.appearance = NSAppearance(named: appearance)
                return self.review.approvalPanel.window
            }
            step("access-request-panel-move") {
                self.review.approvals.withdrawAll()
                self.review.queueAccess(.updateEvent, [
                    "calendarID": "cal-work", "itemID": "fixture-update", "expectedVersion": "1",
                    "targetCalendarID": "cal-home"],
                    client: UIReview.cursorID, name: "Cursor", resource: .calendar, target: "cal-home",
                    mask: ClientGrant.read, bit: ClientGrant.create, source: "cal-work", agent: "cursor 1.7")
                self.review.approvalPanel.window?.appearance = NSAppearance(named: appearance)
                return self.review.approvalPanel.window
            }
            // Remote Access (B10): the page before setup, the guide, then set up.
            step("remote-not-set-up") {
                self.review.approvals.withdrawAll()
                self.model.navigate(to: .remoteAccess)
                return main
            }
            step("remote-guide-1") {
                self.model.remoteGuideActive = true
                return main
            }
            step("remote-guide-2") {
                self.model.tunnelChoice = .tailscaleFunnel
                self.model.applyRemoteEnabled(true)
                return main
            }
            step("remote-guide-3") {
                self.model.remoteTunnelStarted = true
                return main
            }
            step("remote-guide-4-failed") {
                self.review.remoteReachable = false
                _ = self.model.setRemoteAddress(UIReview.remoteOrigin)
                self.model.testRemoteAccess()
                return main
            }
            step("remote-set-up") {
                self.review.remoteReachable = true
                self.model.testRemoteAccess()
                return main
            }
            // Plan 08: the Tunnel row's states, from the checks on this Mac.
            step("remote-tunnel-down") {
                self.review.tunnelHealth[.tailscaleFunnel] = .notRunning(reason: .noTunnel)
                self.review.remoteReachable = false
                self.model.testRemoteAccess()
                return main
            }
            step("remote-tunnel-wrong-port") {
                self.review.tunnelHealth[.tailscaleFunnel] = .wrongPort(port: 47615, address: UIReview.remoteOrigin)
                self.model.testRemoteAccess()
                return main
            }
            step("remote-tunnel-not-public") {
                self.review.tunnelHealth[.tailscaleFunnel] = .notPublic(address: UIReview.remoteOrigin)
                self.model.testRemoteAccess()
                return main
            }
            step("remote-tunnel-cant-check") {
                self.review.tunnelHealth[.tailscaleFunnel] = .unknown
                self.review.remoteReachable = true
                self.model.testRemoteAccess()
                return main
            }
            step("client-cloud") {
                // Back to a running tunnel for the steps that follow.
                self.review.tunnelHealth = UIReview.defaultTunnelHealth
                self.model.testRemoteAccess()
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
            step("sheet-new-client-cloud") {
                // Remote Access is on here, so the sheet offers a Cloud agent tile.
                self.model.oauthClientDetails = nil
                self.model.sheet = nil
                self.review.approvals.withdrawAll()
                self.model.navigate(to: .overview)
                // On the next turn, so SwiftUI builds a fresh sheet.
                DispatchQueue.main.async { self.model.sheet = .newClient }
                return main
            }
            step("sheet-new-client") {
                self.model.sheet = nil
                self.model.applyRemoteEnabled(false)
                self.model.setShowDeveloperTools(false)
                self.model.navigate(to: .overview)
                // On the next turn, so SwiftUI builds a fresh sheet.
                DispatchQueue.main.async { self.model.sheet = .newClient }
                return main
            }
            step("sheet-new-client-write") {
                self.model.sheet = nil
                self.model.newConnectionAccessPreset = .readAllPlusOne
                // On the next turn, so SwiftUI builds a fresh sheet.
                DispatchQueue.main.async { self.model.sheet = .newClient }
                return main
            }
            step("sheet-new-client-script") {
                self.model.sheet = nil
                self.model.newConnectionPreset = .script
                // On the next turn, so SwiftUI builds a fresh sheet.
                DispatchQueue.main.async { self.model.sheet = .newClient }
                return main
            }
            step("sheet-new-client-no-access") {
                self.model.sheet = nil
                self.review.calendarStatus = .notDetermined
                self.review.remindersStatus = .notDetermined
                self.model.refresh()
                // On the next turn, so SwiftUI builds a fresh sheet.
                DispatchQueue.main.async { self.model.sheet = .newClient }
                return main
            }
            step("restore-access") {
                self.model.sheet = nil
                self.review.calendarStatus = .fullAccess
                self.review.remindersStatus = .fullAccess
                self.model.refresh()
                return nil
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
            step("sheet-move-to-applications") {
                // The launch prompt (--ui-move-prompt), from Downloads.
                self.model.sheet = nil
                self.review.defaults.removeObject(forKey: BridgeAppModel.moveDeclinedKey)
                DispatchQueue.main.async { self.model.offerMoveToApplications() }
                return main
            }
            step("restore-move-prompt") {
                if let sheet = main?.attachedSheet { main?.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
                return nil
            }
            step("overview-moved") {
                // The relaunched copy after Move to Applications from a disk image.
                self.model.navigate(to: .overview)
                self.model.didMove(from: "/Volumes/EK Bridge")
                return main
            }
            step("restore-moved") {
                self.model.dismissBanner()
                return nil
            }
            step("client-tab-activity") {
                self.model.sheet = nil
                self.model.navigate(to: .client(UIReview.claudeID))
                self.model.clientTab[UIReview.claudeID] = .activity
                return main
            }
            step("client-connect-cloud-off") {
                // Cloud access on, Remote Access off: one line under Connect (A08).
                self.model.clientTab[UIReview.claudeID] = .connect
                return main
            }
            step("client-access") {
                // The README's Access picture: Claude Code's calendars, scrolled to the table.
                self.model.sheet = nil
                self.model.navigate(to: .client(UIReview.claudeID))
                self.model.accessTab[UIReview.claudeID] = .calendar
                self.model.clientScrollTarget = "access"
                return main
            }
            // Setup in three steps (B09), in fresh environments of its own.
            let (freshReview, freshModel, freshController) = self.review.makeFreshEnvironment(
                calendar: .fullAccess, reminders: .notDetermined)
            let (_, scriptModel, scriptController) = self.review.makeFreshEnvironment(
                calendar: .fullAccess, reminders: .fullAccess)
            step("setup") {
                self.model.sheet = nil
                main?.orderOut(nil)
                freshModel.start()
                freshController.window?.appearance = NSAppearance(named: appearance)
                freshController.present()
                return freshController.window
            }
            step("restore-allow-reminders") {
                freshModel.requestAccess(.reminderList)
                return nil
            }
            step("setup-progress") {
                if freshModel.activeClients.isEmpty {
                    _ = freshModel.createClient(name: "Claude Code", startingAccess: .readAll, agent: .claudeCode)
                }
                freshModel.navigate(to: .overview)
                freshModel.dismissBanner()
                return freshController.window
            }
            step("setup-activity-empty") {
                freshModel.navigate(to: .activity)
                return freshController.window
            }
            step("setup-complete") {
                freshModel.navigate(to: .overview)
                if let id = freshModel.activeClients.first?.id { freshReview.recordSuccess(id) }
                return freshController.window
            }
            step("setup-cli") {
                freshController.window?.orderOut(nil)
                if scriptModel.activeClients.isEmpty {
                    _ = scriptModel.createClient(name: "Nightly script", kind: .cli, startingAccess: .readAll)
                }
                scriptModel.navigate(to: .overview)
                scriptModel.dismissBanner()
                scriptController.window?.appearance = NSAppearance(named: appearance)
                scriptController.present()
                return scriptController.window
            }
            step("restore") {
                freshController.window?.orderOut(nil)
                scriptController.window?.orderOut(nil)
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
                self.whenSettled(window) {
                    if self.external {
                        self.waitForExternalCapture(window, name: name)
                    } else {
                        self.capture(window, name: name)
                        self.next()
                    }
                }
            }
        }
    }

    /// Runs `ready` once the window is visible and its frame has stayed the
    /// same for three checks 0.1 s apart (a window or sheet still opening is
    /// animating), or after 5 s.
    private func whenSettled(_ window: NSWindow, stable: Int = 0, last: NSRect? = nil, waited: Double = 0,
                             _ ready: @escaping @MainActor () -> Void) {
        let frame = window.frame
        let steady = window.isVisible && frame == last ? stable + 1 : 0
        if steady >= 3 || waited >= 5 { return ready() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            MainActor.assumeIsolated {
                self.whenSettled(window, stable: steady, last: frame, waited: waited + 0.1, ready)
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

    /// The menu bar icons in each state at 18 and 36 pt, on a bar-like strip
    /// (the status item itself isn't captured).
    private lazy var glyphWindow: NSWindow = {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 190),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MenuGlyphPreview())
        return window
    }()

    private func target(for name: String) -> NSWindow? {
        if name.hasPrefix("restore") { return nil }
        if name.hasPrefix("menu-glyphs") { return glyphWindow }
        if name.hasPrefix("approval-panel") || name.hasPrefix("access-request-panel") {
            return review.approvalPanel.window
        }
        if name.hasPrefix("setup") {
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
