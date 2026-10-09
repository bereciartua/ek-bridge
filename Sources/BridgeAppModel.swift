import AppKit
import EventKit
import Observation
import ServiceManagement

enum Route: Hashable {
    case overview
    case activity
    case client(String)
    case settings
    /// Remote Access's own page (B10).
    case remoteAccess
}

enum DockIconMode: String, CaseIterable, Identifiable {
    case whileWindowOpen, always, never

    var id: String { rawValue }
    var title: String {
        switch self {
        case .whileWindowOpen: String(localized: "While the window is open")
        case .always: String(localized: "Always")
        case .never: String(localized: "Never")
        }
    }
}

enum ActivityClientFilter: Hashable {
    case all
    case client(String)
    case unknown
}

enum ActivityViaFilter: Hashable, CaseIterable {
    case all, mcp, remote, cli
}

struct Banner: Identifiable {
    enum Kind { case info, success, warning, error }

    let id = UUID()
    let kind: Kind
    let title: String
    var message: String? = nil
    var code: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var persists: Bool { kind == .warning || kind == .error }
}

enum ModelSheet: Identifiable, Equatable {
    case newClient
    case rename(String)
    case unavailableGrants(String)
    case collectionIDs
    case mcpPort
    case remotePort
    case remoteAddress
    case pairing(UUID)
    case oauthClient
    /// Add to <Agent>…: the preview, then the result (B07).
    case configPreview

    var id: String {
        switch self {
        case .newClient: "new"
        case .rename(let id): "rename-\(id)"
        case .unavailableGrants(let id): "unavailable-\(id)"
        case .collectionIDs: "collection-ids"
        case .mcpPort: "mcp-port"
        case .remotePort: "remote-port"
        case .remoteAddress: "remote-address"
        case .pairing(let id): "pairing-\(id)"
        case .oauthClient: "oauth-client"
        case .configPreview: "config-preview"
        }
    }
}

/// How a new client connects (New Client ▸ Connects from).
enum ClientKind: String, CaseIterable, Identifiable {
    case agent, cli, both

    var id: String { rawValue }
    var credentials: Set<CredentialKind> {
        switch self {
        case .agent: [.mcpToken]
        case .cli: [.signingKey]
        case .both: [.mcpToken, .signingKey]
        }
    }
}

/// The client page's Connect tabs.
enum ConnectTab: Hashable { case agent, cli }

/// Settings' tabs (B11).
enum SettingsTab: Hashable, CaseIterable { case general, advanced, about }

/// A connection page's tabs (B08).
enum ClientTab: Hashable, CaseIterable { case access, connect, activity }

/// The dot before a connection's status line.
enum StatusDot: Equatable { case ok, waiting, warning, neutral }

/// The MCP server, as the model drives it. The UI-review build passes fakes.
@MainActor
struct MCPControls {
    var start: (Int) -> Void
    var stop: () -> Void
    var counters: () -> MCPTrafficCounters.Snapshot
    /// `Contents/MacOS/bridge-mcp` inside the running app.
    var launcherURL: URL
    /// Whether 127.0.0.1:port can be bound right now.
    var portIsFree: (Int) -> Bool
}

/// Remote Access, as the model drives it. The UI-review build passes fakes.
@MainActor
struct RemoteControls {
    var start: (RemoteConfiguration) -> Void
    var update: (RemoteConfiguration) -> Void
    var stop: () -> Void
    /// Fetches `<public URL>/r/<secret>/health?nonce=…` through the tunnel:
    /// the round trip and the tunnel the app saw, or why it failed.
    var test: (RemoteConfiguration, @escaping (Result<(rtt: TimeInterval, tunnel: String?), RemoteTestFailure>) -> Void) -> Void
    var portIsFree: (Int) -> Bool
    var setKeepAwake: (Bool) -> Void
    var onACPower: () -> Bool
    var oauth: OAuthServer?
}

struct RemoteTestFailure: Error, Equatable {
    let reason: String
}

enum RemoteTestState: Equatable {
    case notTested
    case testing
    case reachable(rtt: TimeInterval, tunnel: String?, at: Date)
    case notReachable(reason: String, at: Date)
}

/// What the client page says about an agent's connection.
enum MCPConnectionState: Equatable {
    case waiting
    case connected(agent: String?, at: Date)
    case refused(code: String, entryID: String)
}

enum TestCollectionsState {
    case notCreated, created, partlyCreated

    var label: String {
        switch self {
        case .notCreated: String(localized: "Not created")
        case .created: String(localized: "Created")
        case .partlyCreated: String(localized: "Partly created")
        }
    }
}

/// Everything the model needs from the outside world. The UI-review build
/// passes fakes, so it never touches EventKit or starts the bridge.
@MainActor
struct BridgeServices {
    var registry: ClientRegistry
    var credentialFiles: ClientCredentialFiles
    var defaults: UserDefaults
    var dataFolder: URL
    var store: EKEventStore?
    var authorizationStatus: (EKEntityType) -> EKAuthorizationStatus
    var requestFullAccess: (EKEntityType, @escaping @Sendable (Bool, Error?) -> Void) -> Void
    var collections: () -> [CollectionInfo]
    /// Starts or stops the bridge and returns the resulting state.
    var setBridge: (Bool) -> BridgeRunState
    var loginItemStatus: () -> SMAppService.Status
    var setLoginItem: (Bool) throws -> Void
    var isInstalledInApplications: () -> Bool
    /// Move to Applications: where the app is, and the move itself (A11).
    var installLocation: () -> InstallLocation = { .applications }
    var moveToApplications: () -> MoveResult = { .failed("") }
    var commandLineTool: CommandLineTool
    var testCollections: TestCollections?
    var mcp: MCPControls
    var approvals: ApprovalCenter?
    var remote: RemoteControls
    var updater: UpdaterControls
    /// Agents found on this Mac (B04). The live version answers from a cache
    /// refreshed in the background; the UI-review build returns fixed ones.
    var installedAgents: () -> Set<AgentKind> = { [] }
    /// Add to <Agent>…: preview, apply, restart (B07).
    var agentSetup: AgentSetupControls = .unavailable
    /// An Activity row's item as EventKit has it now (C02). Nil when it
    /// can't be looked up; `ItemSnapshot.deleted` when it's gone.
    var itemLookup: (ItemRef) -> ItemSnapshot? = { _ in nil }
    /// Show in Calendar / Reminders. False when nothing opened.
    var showItem: (ItemRef) -> Bool = { _ in false }
}

/// What Activity can say about a row's item.
enum ItemDisplay: Equatable {
    /// A read, or a row from before 0.10: no item.
    case none
    /// Calendar or Reminders access isn't Full Access, so it can't be named.
    case noAccess(ClientResource)
    case found(ItemSnapshot)
}

/// One Add to <Agent>… from click to result.
struct OneClickSession: Equatable {
    enum Phase: Equatable {
        case loading
        case preview(OneClickPreview)
        case running(OneClickPreview)
        case done(OneClickResult)
        case failed(OneClickFailure)
    }

    let clientID: String
    let agent: AgentKind
    var phase: Phase
}

/// The single source of truth for every surface: menu bar, main window and
/// setup checklist. Refreshes on app activation, EventKit changes, registry
/// mutations, bridge start/stop and new activity.
@MainActor @Observable
final class BridgeAppModel {
    // MARK: State

    private(set) var bridge: BridgeRunState = .off
    private(set) var calendarAccess: EKAuthorizationStatus = .notDetermined
    private(set) var remindersAccess: EKAuthorizationStatus = .notDetermined
    private(set) var clients: [ClientView] = []
    private(set) var activity: [ActivityEntry] = []
    private(set) var collections: [CollectionInfo] = []
    /// Last-known names of granted collections (`CollectionLabelStore`).
    private(set) var collectionLabels = [String: CollectionLabel]()
    private(set) var policyStoreAvailable = true
    private(set) var loginItem: SMAppService.Status = .notRegistered
    private(set) var loginItemError: String?
    private(set) var isInstalledInApplications = false
    private(set) var commandLineTool: CommandLineTool.State = .unavailable
    /// How copied commands start (`bridge-client`, the app's own copy, or the source launcher).
    private(set) var cliCommand: CommandLineTool.Program = .source
    /// Homebrew linked `bridge-client` to this copy (Settings reports only its own link).
    private(set) var cliLinkedByHomebrew = false
    private(set) var now = Date()
    private(set) var accessRequestInFlight = Set<ClientResource>()
    private(set) var accessRequestDeclined = Set<ClientResource>()

    var route: Route = .overview
    var sheet: ModelSheet? {
        didSet {
            // A pairing request that arrived while another sheet was open is shown once it closes.
            if oldValue == .configPreview, sheet != .configPreview { oneClick = nil }
            if sheet == nil, oldValue != nil {
                DispatchQueue.main.async { [weak self] in self?.presentNextPairing() }
            }
        }
    }
    private(set) var banner: Banner?
    private(set) var draft: GrantDraft?
    private(set) var savedToastAt: Date?
    /// A calendar or list to highlight in the access table (deep link from Activity).
    var accessFocus: GrantKey?
    /// The scroll target inside the client pane ("access" after creating a client).
    var clientScrollTarget: String?
    /// The scroll target inside Settings: "mcp" and "developer" (Advanced), "about".
    var settingsScrollTarget: String?
    var settingsTab = SettingsTab.general
    var accessTab = [String: ClientResource]()
    /// The tab each connection page shows, this session (B08).
    var clientTab = [String: ClientTab]()
    /// Connections whose Connect tab shows Advanced options (method, token file).
    var advancedSetup = Set<String>()

    var activityClientFilter: ActivityClientFilter = .all
    var activityVia: ActivityViaFilter = .all
    /// All · Changes · Problems.
    var activityKind = ActivityKind.all
    var activitySearch = ""
    var activitySelection: ActivityEntry.ID?
    /// Incremented by ⌘F; Activity's search field takes focus on each change.
    private(set) var activitySearchFocusRequest = 0
    private(set) var activityLastViewed: Date?
    /// Looked-up Activity items (C02), in memory only.
    @ObservationIgnored private var itemCache = [ItemRef: ItemSnapshot]()
    /// Bumped when the cache is cleared, so rows look their items up again.
    private(set) var itemLookupGeneration = 0
    /// Approval panel summaries of changes answered this session, by request
    /// ID (C03): Activity shows their before → after. Memory only, at most 200.
    private(set) var recentSummaries = [String: ApprovalSummary]()
    @ObservationIgnored private var recentSummaryOrder = [String]()
    static let maxRecentSummaries = 200

    private(set) var dockMode: DockIconMode = .whileWindowOpen
    private(set) var showDeveloperTools = false
    private(set) var setupHidden = false
    private(set) var setupCompleted = false
    private(set) var setupSkipped = Set<SetupChecklist.Step>()
    /// Set once by `RenameMigration`; Overview explains the new name until dismissed.
    private(set) var renameNoticePending = false
    /// Set by `RenameMigration` until the checklist completes or is hidden.
    private var renameAccessRecheck = false
    // Updates (Settings ▸ General, the menu and Overview).
    private(set) var updaterAvailable = false
    private(set) var automaticUpdateChecks = false
    private(set) var lastUpdateCheck: Date?
    /// Found by a scheduled check and not opened yet.
    private(set) var foundUpdate: FoundUpdate?
    /// The version whose Overview card was closed; the menu item stays.
    private(set) var dismissedUpdateVersion: String?
    /// Set briefly when the checklist finishes, to show the success message.
    private(set) var setupJustCompletedName: String?
    private(set) var developerOutput: String?
    private(set) var testCollectionsState: TestCollectionsState = .notCreated
    private(set) var waitingForTestRequest = false

    // The local MCP server (Settings ▸ Advanced) and agent connections. It
    // runs while EK Bridge is on, the user allows it, and a connection has
    // an MCP token (`mcpShouldRun`).
    private(set) var localMCPAllowed = true
    /// Whether the model has started `services.mcp` (and not stopped it).
    private(set) var mcpStarted = false
    private(set) var mcpPort = MCPDefaults.port
    private(set) var mcpStatus: MCPService.Status = .off
    private(set) var mcpConnections = [String: MCPServer.Connection]()
    private(set) var newAgentApproval = ApprovalMode.ask
    private(set) var newCLIApproval = ApprovalMode.allow
    // Remote Access (the Remote Access page, client Cloud sections).
    private(set) var remoteEnabled = false
    private(set) var remotePort = RemoteDefaults.port
    private(set) var remoteSecret = ""
    private(set) var remoteOrigin: String?
    private(set) var remoteStatus: RemoteMCPService.Status = .off
    private(set) var remoteTest = RemoteTestState.notTested
    private(set) var remoteAutoOff: TimeInterval = 0
    private(set) var remoteOffAt: Date?
    /// Pause EK Bridge ▸ For 1 Hour / Until Tomorrow: when it turns back on.
    private(set) var resumeAt: Date?
    private(set) var keepAwake = false
    private(set) var remoteNotes = [RemoteRequestNote]()
    private(set) var remoteConnections = [String: MCPServer.Connection]()
    /// Bumped when OAuth connections or pairing change, so views re-read them.
    private(set) var oauthChanges = 0
    /// The guide's tunnel, saved once chosen (UserDefaults RemoteTunnelChoice).
    var tunnelChoice = TunnelProvider.tailscaleFunnel {
        didSet { services.defaults.set(tunnelChoice.rawValue, forKey: Keys.tunnelChoice) }
    }
    var tunnelChosen: Bool { services.defaults.string(forKey: Keys.tunnelChoice) != nil }
    /// The Remote Access guide is in progress (shown even once Remote Access is on).
    var remoteGuideActive = false
    /// Guide step 2's "I've Started It", this session.
    var remoteTunnelStarted = false
    /// Guide step 3 shown again from step 4's Back.
    var remoteEditingAddress = false
    var cloudAgentChoice = [String: CloudAgentKind]()
    var connectTab = [String: ConnectTab]()
    /// The agent picked on a Connect tab this session; falls back to the
    /// stored kind (`connectionAgents`), then Claude Code.
    var agentChoice = [String: AgentKind]()
    /// Each connection's agent, saved in UserDefaults `ConnectionAgentKinds` (B04).
    private(set) var connectionAgents = [String: AgentKind]()
    /// Agents found on this Mac, for the Add a Connection sheet and setup.
    private(set) var installedAgents = Set<AgentKind>()
    /// The Add to <Agent>… in progress, shown in the config preview sheet.
    private(set) var oneClick: OneClickSession?
    /// Finished one-click setups this session, keyed "clientID|agent".
    private(set) var oneClickDone = [String: OneClickResult]()
    /// Connections whose Connect tab shows the setup to copy instead of the one-click card.
    var copySetup = Set<String>()
    /// Restart <Agent> running for this agent.
    private(set) var restarting: AgentKind?
    /// Keyed by "clientID|agent".
    var methodChoice = [String: SetupMethod]()

    // MARK: Wiring

    @ObservationIgnored let services: BridgeServices
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored var showWindow: () -> Void = {}
    @ObservationIgnored var dockModeChanged: () -> Void = {}
    @ObservationIgnored var windowIsVisible: () -> Bool = { false }
    /// Brings the approval panel forward (menu bar item).
    @ObservationIgnored var showApprovals: () -> Void = {}
    @ObservationIgnored private var refreshScheduled = false
    @ObservationIgnored private var refreshCollectionsPending = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers = [NSObjectProtocol]()
    @ObservationIgnored private var bannerTimer: Timer?
    @ObservationIgnored private lazy var labelStore = CollectionLabelStore(folder: services.dataFolder)

    private enum Keys {
        static let setupHidden = "SetupChecklistHidden"
        static let setupCompleted = "SetupChecklistCompleted"
        static let setupSkipped = "SetupChecklistSkipped"
        static let activityLastViewed = "ActivityLastViewed"
        static let dockMode = "DockIconMode"
        static let showDeveloperTools = "ShowDeveloperTools"
        static let lastRoute = "LastPane"
        /// 0.8.2's switch; still written, so a rollback finds a sensible value.
        static let mcpEnabled = "MCPServerEnabled"
        static let localMCPAllowed = "LocalMCPServerAllowed"
        static let mcpPort = "MCPServerPort"
        static let approvalAgent = "ApprovalDefaultAgent"
        static let approvalCLI = "ApprovalDefaultCommandLine"
        static let remoteEnabled = "RemoteAccessEnabled"
        static let remotePort = "MCPRemotePort"
        static let remoteSecret = "RemoteAccessSecretPath"
        static let remoteOrigin = "RemoteAccessPublicAddress"
        static let remoteAutoOff = "RemoteAccessAutoOff"
        static let remoteOffAt = "RemoteAccessOffAt"
        static let keepAwake = "RemoteAccessKeepAwake"
        static let resumeAt = "BridgeResumeAt"
        static let tunnelChoice = "RemoteTunnelChoice"
    }

    init(services: BridgeServices) {
        self.services = services
        let defaults = services.defaults
        setupHidden = defaults.bool(forKey: Keys.setupHidden)
        setupCompleted = defaults.bool(forKey: Keys.setupCompleted)
        setupSkipped = Set((defaults.array(forKey: Keys.setupSkipped) as? [Int] ?? [])
            .compactMap(SetupChecklist.Step.init(rawValue:)))
        renameNoticePending = defaults.bool(forKey: RenameMigration.noticeKey)
        renameAccessRecheck = defaults.bool(forKey: RenameMigration.accessRecheckKey)
        let viewed = defaults.double(forKey: Keys.activityLastViewed)
        activityLastViewed = viewed > 0 ? Date(timeIntervalSinceReferenceDate: viewed) : nil
        dockMode = DockIconMode(rawValue: defaults.string(forKey: Keys.dockMode) ?? "") ?? .whileWindowOpen
        showDeveloperTools = defaults.bool(forKey: Keys.showDeveloperTools)
        localMCPAllowed = defaults.object(forKey: Keys.localMCPAllowed) as? Bool ?? true
        let port = defaults.integer(forKey: Keys.mcpPort)
        mcpPort = MCPDefaults.validPorts.contains(port) ? port : MCPDefaults.port
        newAgentApproval = ApprovalMode(rawValue: defaults.string(forKey: Keys.approvalAgent) ?? "") ?? .ask
        newCLIApproval = ApprovalMode(rawValue: defaults.string(forKey: Keys.approvalCLI) ?? "") ?? .allow
        remoteEnabled = defaults.bool(forKey: Keys.remoteEnabled)
        let remote = defaults.integer(forKey: Keys.remotePort)
        remotePort = MCPDefaults.validPorts.contains(remote) ? remote : RemoteDefaults.port
        remoteSecret = defaults.string(forKey: Keys.remoteSecret).flatMap {
            RemoteConfiguration.validSecret($0) ? $0 : nil
        } ?? ""
        remoteOrigin = defaults.string(forKey: Keys.remoteOrigin).flatMap(RemoteConfiguration.normalizedOrigin)
        remoteAutoOff = max(0, defaults.double(forKey: Keys.remoteAutoOff))
        let offAt = defaults.double(forKey: Keys.remoteOffAt)
        remoteOffAt = offAt > 0 ? Date(timeIntervalSinceReferenceDate: offAt) : nil
        keepAwake = defaults.bool(forKey: Keys.keepAwake)
        if let tunnel = defaults.string(forKey: Keys.tunnelChoice).flatMap(TunnelProvider.init(rawValue:)) {
            tunnelChoice = tunnel
        }
        connectionAgents = ConnectionAgentKinds.load(defaults)
        let resume = defaults.double(forKey: Keys.resumeAt)
        resumeAt = resume > 0 ? Date(timeIntervalSinceReferenceDate: resume) : nil
        switch defaults.string(forKey: Keys.lastRoute) {
        case "activity": route = .activity
        case "settings": route = .settings
        case "remote": route = .remoteAccess
        default: route = .overview
        }
        refresh()
        // First launch of 0.9: the local server follows EK Bridge unless the
        // user turned it off and no connection uses MCP.
        if defaults.object(forKey: Keys.localMCPAllowed) == nil {
            localMCPAllowed = MCPRunPolicy.migratedAllowed(
                old: defaults.object(forKey: Keys.mcpEnabled) as? Bool,
                hasMCPConnections: activeClients.contains(where: \.hasMCPToken))
            defaults.set(localMCPAllowed, forKey: Keys.localMCPAllowed)
            defaults.set(localMCPAllowed, forKey: Keys.mcpEnabled)
        }
        // On the first launch with this setting, history counts as seen, so
        // only problems from now on raise the badge.
        if activityLastViewed == nil, let latest = activity.first?.at {
            activityLastViewed = latest
            defaults.set(latest.timeIntervalSinceReferenceDate, forKey: Keys.activityLastViewed)
        }
        // Installs that already served a request never see the checklist,
        // even if the bridge is off right now. Right after the rename they do:
        // macOS asks for access again under the new bundle ID.
        if !setupCompleted, !renameAccessRecheck, SetupChecklist.isDone(.connect, checklistInput) {
            setupCompleted = true
            defaults.set(true, forKey: Keys.setupCompleted)
        }
    }

    func start() {
        started = true
        services.approvals?.answered = { [weak self] requestID, summary, _ in
            self?.rememberApprovalSummary(requestID, summary)
        }
        syncMCPServer()
        if remoteEnabled {
            if let offAt = remoteOffAt, offAt <= Date() {
                applyRemoteEnabled(false)
            } else {
                services.remote.start(remoteConfiguration)
            }
        }
        services.remote.oauth?.pairingRequested = { [weak self] request in self?.pairingRequested(request) }
        services.remote.oauth?.pairingChanged = { [weak self] in self?.oauthChanges += 1 }
        services.remote.oauth?.connectionsChanged = { [weak self] clientID in
            guard let self else { return }
            // A connection added or revoked invalidates work in flight.
            _ = self.services.registry.bumpRevision(clientID: clientID)
            self.services.approvals?.withdraw(clientID: clientID)
            self.oauthChanges += 1
            self.scheduleRefresh()
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        if let store = services.store {
            observers.append(center.addObserver(forName: .EKEventStoreChanged, object: store,
                                                queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh(collections: true) }
            })
        }
        // macOS doesn't notify about privacy changes, so poll the cheap
        // statuses; this also keeps relative times current.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 0.5
    }

    // MARK: Refresh

    /// Coalesces bursts (for example many requests) to at most about 4 Hz.
    /// Request-driven refreshes skip EventKit and Login Items, which they
    /// can't change; `collections` is set for EventKit change notifications.
    func scheduleRefresh(collections: Bool = false) {
        refreshCollectionsPending = refreshCollectionsPending || collections
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            let full = self.refreshCollectionsPending
            self.refreshCollectionsPending = false
            self.refresh(full: full)
        }
    }

    func refresh() { refresh(full: true) }

    private func refresh(full: Bool) {
        now = Date()
        // Activity's item names are looked up again after Calendar or
        // Reminders may have changed.
        if full && !itemCache.isEmpty {
            itemCache.removeAll()
            itemLookupGeneration += 1
        }
        updateAccess()
        if let current = services.registry.clients() {
            policyStoreAvailable = true
            if clients != current { clients = current }
            let entries = ActivityEntry.entries(from: services.registry.activity() ?? [])
            if entries != activity { activity = entries }
            pruneConnectionAgents()
        } else {
            policyStoreAvailable = false
            clients = []
            activity = []
        }
        if full {
            let listed = services.collections()
            if listed != collections { collections = listed }
            updateCollectionLabels()
            loginItem = services.loginItemStatus()
            isInstalledInApplications = services.isInstalledInApplications()
            refreshCommandLineTool()
            refreshUpdater()
            let agents = services.installedAgents()
            if agents != installedAgents { installedAgents = agents }
        }
        reconcileDraft()
        reconcileRoute()
        updateTestCollectionsState()
        if route == .activity && windowIsVisible() { markActivityViewed() }
        syncMCPServer()
        checkSetupCompletion()
    }

    /// Every 2 s (internal for the behavior test).
    func tick() {
        let before = (calendarAccess, remindersAccess)
        updateAccess()
        if before.0 != calendarAccess || before.1 != remindersAccess {
            refresh()
        } else if Date().timeIntervalSince(now) >= 30 {
            now = Date()
        }
        if let saved = savedToastAt, Date().timeIntervalSince(saved) > 2.5 { savedToastAt = nil }
        if let resume = resumeAt, resume <= Date() { resumeAsScheduled() }
        if remoteEnabled, let offAt = remoteOffAt, offAt <= Date() {
            applyRemoteEnabled(false)
            showBanner(Banner(kind: .info, title: String(localized: "Remote Access turned off, as scheduled.")))
        }
        updateKeepAwake()
    }

    private func updateAccess() {
        let calendar = services.authorizationStatus(.event)
        let reminders = services.authorizationStatus(.reminder)
        if calendar != calendarAccess { calendarAccess = calendar }
        if reminders != remindersAccess { remindersAccess = reminders }
        if calendar != .denied { accessRequestDeclined.remove(.calendar) }
        if reminders != .denied { accessRequestDeclined.remove(.reminderList) }
    }

    /// Called by the app delegate when the bridge starts, stops or fails.
    func bridgeDidChange(_ state: BridgeRunState) {
        if bridge != state { bridge = state }
        refresh()
    }

    // MARK: Agents (B04)

    /// The agent a connection's Connect tab sets up.
    func agent(for clientID: String) -> AgentKind {
        agentChoice[clientID] ?? connectionAgents[clientID] ?? .claudeCode
    }

    /// Remembers a connection's agent: when it's added, and when the user
    /// picks another agent in Connect.
    func setAgent(_ kind: AgentKind, for clientID: String) {
        agentChoice[clientID] = kind
        guard connectionAgents[clientID] != kind else { return }
        connectionAgents[clientID] = kind
        ConnectionAgentKinds.save(connectionAgents, services.defaults)
    }

    /// Removed connections forget their agent.
    private func pruneConnectionAgents() {
        let kept = ConnectionAgentKinds.pruned(connectionAgents, activeIDs: Set(activeClients.map(\.id)))
        guard kept != connectionAgents else { return }
        connectionAgents = kept
        ConnectionAgentKinds.save(kept, services.defaults)
    }

    // MARK: One-click setup (B07)

    /// What a connection's agent setup points at: this app's launcher and token file.
    func setupContext(_ clientID: String) -> SetupContext {
        SetupContext(url: mcpURL, launcherPath: launcherPath, clientID: clientID,
                     tokenPath: tokenFileURL(clientID)?.path ?? "")
    }

    func oneClickResult(_ clientID: String, _ agent: AgentKind) -> OneClickResult? {
        oneClickDone["\(clientID)|\(agent.rawValue)"]
    }

    /// Add to <Agent>…: builds the change and opens the preview sheet. Nothing
    /// is written until the user clicks Add there.
    func beginOneClick(_ clientID: String, agent: AgentKind? = nil) {
        let agent = agent ?? self.agent(for: clientID)
        guard agent.oneClick, client(clientID)?.hasMCPToken == true else { return }
        oneClick = OneClickSession(clientID: clientID, agent: agent, phase: .loading)
        sheet = .configPreview
        services.agentSetup.preview(agent, setupContext(clientID)) { [weak self] result in
            guard let self, self.oneClick?.clientID == clientID, self.oneClick?.phase == .loading else { return }
            switch result {
            case .success(let preview): self.oneClick?.phase = .preview(preview)
            case .failure(let failure): self.oneClick?.phase = .failed(failure)
            }
        }
    }

    /// Add (or Replace) in the preview sheet.
    func confirmOneClick() {
        guard let session = oneClick, case .preview(let preview) = session.phase else { return }
        oneClick?.phase = .running(preview)
        services.agentSetup.apply(preview) { [weak self] result in
            guard let self, self.oneClick?.clientID == session.clientID else { return }
            switch result {
            case .success(let done):
                self.oneClickDone["\(session.clientID)|\(session.agent.rawValue)"] = done
                self.setAgent(session.agent, for: session.clientID)
                if case .file = preview {
                    // A file agent is done: close the sheet and say where the backup is.
                    self.oneClick = nil
                    self.sheet = nil
                    self.showBanner(Banner(
                        kind: .success,
                        title: done.alreadySetUp ? String(localized: "\(session.agent.displayName) was already set up.")
                                                 : String(localized: "Added to \(session.agent.displayName)."),
                        message: done.backup.map { String(localized: "Backup: \($0.lastPathComponent)") },
                        actionTitle: done.backup == nil ? nil : String(localized: "Show in Finder"),
                        action: done.backup.map { url in { NSWorkspace.shared.activateFileViewerSelecting([url]) } }))
                } else {
                    self.oneClick?.phase = .done(done)
                }
            case .failure(let failure):
                self.oneClick?.phase = .failed(failure)
            }
        }
    }

    func closeOneClick() {
        oneClick = nil
        if sheet == .configPreview { sheet = nil }
    }

    /// Restart Claude Desktop: quits it, waits up to 5 s, opens it again.
    func restartAgent(_ agent: AgentKind) {
        guard restarting == nil else { return }
        restarting = agent
        services.agentSetup.restart(agent) { [weak self] restarted in
            guard let self else { return }
            self.restarting = nil
            if !restarted {
                self.showBanner(Banner(kind: .warning,
                                       title: String(localized: "\(agent.displayName) didn't quit."),
                                       message: String(localized: "Quit \(agent.displayName) and open it again.")))
            }
        }
    }

    /// The Remote Access page (B10).
    func showRemoteAccess() { show(.remoteAccess) }

    var remoteGuideStep: RemoteGuide.Step {
        let reachable: Bool = if case .reachable = remoteTest { true } else { false }
        return RemoteGuide.step(tunnelChosen: tunnelChosen, remoteOn: remoteEnabled,
                                // Editing the address means the tunnel was started.
                                started: remoteTunnelStarted || remoteEditingAddress,
                                origin: remoteEditingAddress ? nil : remoteOrigin,
                                reachable: reachable)
    }

    /// Guide step 1: forget the choice, so the tunnel chips show again.
    func chooseTunnelAgain() {
        services.defaults.removeObject(forKey: Keys.tunnelChoice)
        remoteTunnelStarted = false
        remoteGuideActive = true
    }

    // MARK: Derived state

    /// Keeps the names of granted collections, so one that disappears can
    /// still be named. Runs on every full refresh, which includes saves.
    private func updateCollectionLabels() {
        guard policyStoreAvailable else { return }
        let listedResources = Set([ClientResource.calendar, .reminderList].filter { status($0) == .fullAccess })
        let granted = Set(activeClients.flatMap { client in
            client.grants.map { GrantKey(resource: $0.resource, targetID: $0.targetID) }
        })
        labelStore.update(listed: collections, listedResources: listedResources, granted: granted)
        if labelStore.labels != collectionLabels { collectionLabels = labelStore.labels }
    }

    func collectionLabel(_ key: GrantKey) -> CollectionLabel? {
        collectionLabels[CollectionLabelStore.key(key)]
    }

    /// "Project calendar" for an unavailable collection with a label.
    func unavailableName(_ key: GrantKey) -> String? { collectionLabel(key)?.name }

    var activeClients: [ClientView] { clients.filter { !$0.revoked } }
    var revokedClients: [ClientView] { clients.filter(\.revoked) }
    /// Active clients that are paused: they keep their access but are refused.
    var pausedCount: Int { activeClients.filter(\.paused).count }

    func client(_ id: String?) -> ClientView? {
        guard let id else { return nil }
        return clients.first { $0.id == id }
    }

    /// Names are resolved at display time, so renames show everywhere at once.
    func clientName(_ id: String?) -> String {
        guard let id else { return String(localized: "Unknown connection") }
        guard let client = client(id) else { return String(localized: "Removed connection") }
        return client.revoked ? String(localized: "\(client.name) (removed)") : client.name
    }

    var problems: [AttentionProblem] {
        var result = AttentionLogic.problems(bridge: bridge, calendar: calendarAccess, reminders: remindersAccess,
                                             clients: clients, policyStoreAvailable: policyStoreAvailable,
                                             mcpFailure: mcpFailureText)
        if let failure = remoteFailureText { result.append(.remoteAccessFailed(failure)) }
        return result
    }

    var needsAttention: Bool { !problems.isEmpty }

    /// Overview's Needs you (B12). Problems Overview already shows as a
    /// banner or in its header (settings unreadable, MCP or EK Bridge
    /// failing to start) aren't repeated.
    var needsYouItems: [NeedsYouItem] {
        let shown = problems.filter {
            switch $0 {
            case .policyStoreUnavailable, .mcpServerFailed, .bridgeFailed: false
            default: true
            }
        }
        let unavailable = activeClients.flatMap { client in
            unavailableGrants(client, staged: false).map { key in
                NeedsYou.Unavailable(connectionID: client.id, connectionName: client.name, key: key,
                                     name: unavailableName(key),
                                     mask: client.grants.first { $0.resource == key.resource && $0.targetID == key.targetID }?.mask ?? 0)
            }
        }
        return NeedsYou.items(pendingApprovals: pendingApprovalCount, problems: shown, unavailable: unavailable,
                              unseenProblems: unseenProblemCount, lastViewed: activityLastViewed,
                              update: foundUpdate.map { ($0.version, $0.critical) }, updateCardShown: showsUpdateCard)
    }

    /// Needs you ▸ refused requests: Activity with Problems only.
    func openProblems() {
        openActivity()
        activityKind = .problems
    }

    /// The fix for a problem, shared by the menu bar and Overview's Needs you.
    func fix(_ problem: AttentionProblem) {
        switch problem {
        case .calendarAccess: openPrivacySettings(.calendar)
        case .remindersAccess: openPrivacySettings(.reminderList)
        case .policyStoreUnavailable, .bridgeFailed: show(.overview)
        case .mcpServerFailed:
            settingsScrollTarget = "mcp"
            show(.settings)
        case .remoteAccessFailed:
            show(.remoteAccess)
        }
    }

    func lastRequest(for clientID: String) -> Date? {
        ActivityStats.lastRequest(for: clientID, in: activity)
    }

    var unseenProblemCount: Int {
        ActivityStats.unseenProblems(activity, since: activityLastViewed)
    }

    func status(_ resource: ClientResource) -> EKAuthorizationStatus {
        resource == .calendar ? calendarAccess : remindersAccess
    }

    func collections(_ resource: ClientResource) -> [CollectionInfo] {
        collections.filter { $0.resource == resource }
    }

    func collection(_ key: GrantKey) -> CollectionInfo? { collections.named(key) }

    /// Types EventKit can't list right now, because Full Access is missing.
    var hiddenResources: Set<ClientResource> {
        Set([ClientResource.calendar, .reminderList].filter { status($0) != .fullAccess })
    }

    /// Saved grants that EventKit doesn't list right now, for types with Full Access.
    func unavailableGrants(_ client: ClientView, staged: Bool = true) -> [GrantKey] {
        var keys = client.grants.map { GrantKey(resource: $0.resource, targetID: $0.targetID) }
        // Leave out removals the user has already staged.
        if staged, let draft, draft.clientID == client.id {
            keys = keys.filter { draft.mask($0) != 0 }
        }
        return keys.filter { status($0.resource) == .fullAccess && collection($0) == nil }
    }

    /// The header subtitle for the menu and the status item tooltip.
    var statusSubtitle: String {
        if !policyStoreAvailable { return String(localized: "Connection settings can't be read") }
        switch bridge {
        case .failed: return String(localized: "Paused · \(AppIdentity.displayName) couldn't start")
        case .off:
            guard let resumeAt else { return String(localized: "Paused · agents and scripts are refused") }
            return String(localized: "Paused \(PauseSchedule.untilText(resumeAt, now: now)) · agents and scripts are refused")
        case .on:
            let failing = problems.compactMap { problem -> String? in
                switch problem {
                case .calendarAccess: String(localized: "requests to Calendar will fail")
                case .remindersAccess: String(localized: "requests to Reminders will fail")
                default: nil
                }
            }
            if let first = failing.first { return first.capitalizingFirstLetter }
            // The header already says "EK Bridge is on".
            let count = activeClients.count - pausedCount
            var parts = [count == 1 ? String(localized: "1 connection") : String(localized: "\(count) connections")]
            if pausedCount > 0 { parts.append(String(localized: "\(pausedCount) paused")) }
            if let last = activity.first?.at {
                parts.append(String(localized: "last request \(RelativeTime.ago(last, now: now).lowercased())"))
            }
            if unseenProblemCount > 0 {
                parts.append(unseenProblemCount == 1 ? String(localized: "1 new problem")
                                                     : String(localized: "\(unseenProblemCount) new problems"))
            }
            return parts.joined(separator: " · ")
        }
    }

    // MARK: Navigation and the unsaved-changes guard

    func navigate(to target: Route) {
        guard target != route else {
            if !windowIsVisible() { showWindow() }
            return
        }
        confirmUnsaved { [weak self] in self?.go(target) }
    }

    func show(_ target: Route) {
        navigate(to: target)
        showWindow()
    }

    private func go(_ target: Route) {
        route = target
        if let banner, !banner.persists { self.banner = nil }
        switch target {
        case .overview: services.defaults.set("overview", forKey: Keys.lastRoute)
        case .activity: services.defaults.set("activity", forKey: Keys.lastRoute)
        case .settings: services.defaults.set("settings", forKey: Keys.lastRoute)
        case .remoteAccess: services.defaults.set("remote", forKey: Keys.lastRoute)
        case .client: break
        }
        reconcileDraft()
        if target == .activity { markActivityViewed() }
    }

    func windowDidShow() {
        if route == .activity { markActivityViewed() }
        refresh()
    }

    private func reconcileRoute() {
        if case .client(let id) = route, client(id) == nil { route = .overview }
    }

    private func reconcileDraft() {
        guard case .client(let id) = route, let client = client(id), !client.revoked else {
            if draft != nil { clearDraft() }
            return
        }
        if draft?.clientID != id {
            clearDraft()
            draft = GrantDraft(client: client)
        } else if let draft, !draft.hasChanges, GrantDraft(client: client).saved != draft.saved {
            // Saved grants changed underneath an unedited draft.
            self.draft = GrantDraft(client: client)
        }
    }

    private func clearDraft() {
        window?.undoManager?.removeAllActions(withTarget: self)
        draft = nil
    }

    var hasUnsavedChanges: Bool { draft?.hasChanges == true }

    /// Runs `action` now, or after the user saves or discards staged access edits.
    /// The completion receives false when the user cancels.
    func confirmUnsaved(_ action: @escaping () -> Void, cancelled: @escaping () -> Void = {}) {
        guard let draft, draft.hasChanges, let client = client(draft.clientID) else {
            action()
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Save changes to \(client.name)’s access?")
        alert.informativeText = String(localized: "If you don’t save, your changes to its calendars and lists are lost.")
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let dontSave = alert.addButton(withTitle: String(localized: "Don’t Save"))
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = [.command]
        present(alert) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                if self.saveDraft() { action() } else { cancelled() }
            case .alertThirdButtonReturn:
                self.revertDraft()
                action()
            default:
                cancelled()
            }
        }
    }

    /// Presents an alert as a sheet on the main window when it's visible,
    /// otherwise as an app-modal alert.
    func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window, window.isVisible, window.attachedSheet == nil {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            completion(alert.runModal())
        }
    }

    // MARK: Banners

    func showBanner(_ banner: Banner) {
        self.banner = banner
        bannerTimer?.invalidate()
        let text = [banner.title, banner.message].compactMap { $0 }.joined(separator: " ")
        announce(text)
        guard !banner.persists else { return }
        let id = banner.id
        bannerTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.banner?.id == id { self?.banner = nil }
            }
        }
    }

    func dismissBanner() { banner = nil }

    func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: Bridge

    /// The switch and Turn On EK Bridge. Any manual change ends a scheduled pause.
    func setBridgeEnabled(_ on: Bool) {
        confirmUnsaved { [weak self] in
            guard let self else { return }
            self.setResumeAt(nil)
            let state = self.services.setBridge(on)
            // Changes waiting for approval are refused when the bridge goes off.
            if !state.isOn { self.services.approvals?.withdrawAll() }
            self.bridgeDidChange(state)
        }
    }

    /// Pause EK Bridge ▸ For 1 Hour, Until Tomorrow (8:00) or Until I Turn
    /// It On (`date` nil).
    func pause(until date: Date?) {
        confirmUnsaved { [weak self] in
            guard let self else { return }
            let state = self.services.setBridge(false)
            if !state.isOn { self.services.approvals?.withdrawAll() }
            self.setResumeAt(date)
            self.bridgeDidChange(state)
        }
    }

    func pause(for choice: PauseChoice) {
        pause(until: PauseSchedule.resumeDate(choice, now: Date()))
    }

    private func setResumeAt(_ date: Date?) {
        resumeAt = date
        services.defaults.set(date?.timeIntervalSinceReferenceDate ?? 0, forKey: Keys.resumeAt)
    }

    /// The scheduled end of a pause. Turning on needs no unsaved-edits guard.
    private func resumeAsScheduled() {
        setResumeAt(nil)
        guard !bridge.isOn else { return }
        let state = services.setBridge(true)
        bridgeDidChange(state)
        if state.isOn {
            showBanner(Banner(kind: .info, title: String(localized: "\(AppIdentity.displayName) turned back on, as scheduled.")))
        }
    }

    /// "EK Bridge is on", "EK Bridge is paused" or "EK Bridge is paused until 3:40 PM".
    var bridgeTitle: String {
        if bridge.isOn { return String(localized: "\(AppIdentity.displayName) is on") }
        guard let resumeAt else { return String(localized: "\(AppIdentity.displayName) is paused") }
        return String(localized: "\(AppIdentity.displayName) is paused \(PauseSchedule.untilText(resumeAt, now: now))")
    }

    // MARK: macOS access

    func requestAccess(_ resource: ClientResource) {
        guard status(resource) == .notDetermined, !accessRequestInFlight.contains(resource) else { return }
        accessRequestInFlight.insert(resource)
        services.requestFullAccess(resource == .calendar ? .event : .reminder) { [weak self] granted, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.accessRequestInFlight.remove(resource)
                self.refresh()
                if !granted && self.status(resource) != .fullAccess {
                    self.accessRequestDeclined.insert(resource)
                }
            }
        }
    }

    func openPrivacySettings(_ resource: ClientResource?) {
        let anchor = resource == .reminderList ? "Privacy_Reminders" : "Privacy_Calendars"
        let urls = [
            resource == nil ? nil : "x-apple.systempreferences:com.apple.preference.security?\(anchor)",
            "x-apple.systempreferences:com.apple.preference.security",
        ].compactMap { $0.flatMap(URL.init(string:)) }
        for url in urls where NSWorkspace.shared.open(url) { return }
    }

    // MARK: Clients

    /// The tile Add a Connection opens with (setup's "Add a command-line connection…").
    var newConnectionPreset: AddConnectionTile?
    /// The starting access the sheet opens with (UI review snapshots).
    var newConnectionAccessPreset: StartingAccessChoice?

    func beginNewClient(preset: AddConnectionTile? = nil) {
        guard policyStoreAvailable, activeClients.count < ClientRegistry.maxActiveClients else { return }
        confirmUnsaved { [weak self] in
            self?.showWindow()
            self?.newConnectionPreset = preset
            self?.sheet = .newClient
        }
    }

    /// "Claude Code", or "Claude Code 2", "Claude Code 3"… when taken.
    func suggestedName(_ base: String) -> String {
        if nameIssue(base) == nil { return base }
        for number in 2...99 {
            let candidate = "\(base) \(number)"
            if nameIssue(candidate) == nil { return candidate }
        }
        return base
    }

    var canCreateClient: Bool {
        policyStoreAvailable && activeClients.count < ClientRegistry.maxActiveClients
    }

    func nameIssue(_ name: String, excluding clientID: String? = nil) -> ClientNameIssue? {
        services.registry.nameIssue(name, excluding: clientID)
    }

    /// The Ask before changes preset for a new client of this kind (Settings).
    func defaultApproval(for kind: ClientKind) -> ApprovalMode {
        kind == .cli ? newCLIApproval : newAgentApproval
    }

    /// Creates a connection, its credential files and its starting access
    /// (B05). Returns an issue only for name problems the sheet shows inline;
    /// every other outcome closes it. `cloud` opens Connect at From the cloud.
    func createClient(name: String, kind: ClientKind = .agent, askBeforeChanges: Bool? = nil,
                      startingAccess: StartingAccess = .nothing, agent: AgentKind? = nil,
                      cloud: Bool = false) -> ClientNameIssue? {
        if let issue = nameIssue(name) { return issue }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let approval = askBeforeChanges.map { $0 ? ApprovalMode.ask : .allow } ?? defaultApproval(for: kind)
        switch services.registry.createClient(name: trimmed, credentials: kind.credentials,
                                              approval: approval) {
        case .success(let issued):
            sheet = nil
            var failure: CredentialFileError?
            if let key = issued.signingKey,
               case .failure(let error) = services.credentialFiles.saveNew(clientID: issued.id, key: key) {
                failure = error
            }
            if failure == nil, let token = issued.mcpToken,
               case .failure(let error) = services.credentialFiles.saveNew(clientID: issued.id, token: token) {
                failure = error
            }
            if let failure {
                let revoked = services.registry.revoke(clientID: issued.id)
                let removed = removeCredentialFiles(issued.id)
                refresh()
                showCleanupBanner(title: issued.mcpToken != nil && issued.signingKey == nil
                                    ? String(localized: "Couldn't save the token file.")
                                    : String(localized: "Couldn't save the key file."),
                                  code: failure.rawValue, revoked: revoked, removed: removed,
                                  clientID: issued.id)
                return nil
            }
            refresh()
            if let agent { setAgent(agent, for: issued.id) }
            let listed = collections.sortedForDisplay().map { (key: $0.key, writable: $0.writable) }
            let starting = StartingAccess.grants(startingAccess, listed: listed)
            var saveFailure: ClientRegistryError?
            if !starting.grants.isEmpty,
               case .failure(let error) = services.registry.replaceGrants(clientID: issued.id, grants: starting.grants) {
                saveFailure = error
            }
            refresh()
            go(.client(issued.id))
            connectTab[issued.id] = kind == .cli ? .cli : .agent
            if let saveFailure {
                clientScrollTarget = "access"
                showBanner(Banner(kind: .error, title: String(localized: "\(trimmed) was added, but its starting access couldn't be saved."),
                                  message: String(localized: "Choose what it can use, then Save."),
                                  code: saveFailure.rawValue))
            } else if startingAccess == .nothing || starting.grants.isEmpty {
                clientScrollTarget = "access"
                showBanner(Banner(kind: .info, title: String(localized: "\(trimmed) was added."),
                                  message: String(localized: "Choose what it can use, then Save.")))
            } else if starting.capped {
                showBanner(Banner(kind: .info, title: String(localized: "\(trimmed) was added."),
                                  message: String(localized: "Read access was given to \(starting.grants.count) of \(listed.count) calendars and lists; choose the rest in Access.")))
            } else if cloud {
                clientScrollTarget = "cloud"
            }
        case .failure(.duplicateName):
            return .duplicate(trimmed)
        case .failure(.invalidName):
            return ClientRegistry.nameShapeIssue(name) ?? .empty
        case .failure(let error):
            sheet = nil
            showBanner(Banner(kind: .error, title: String(localized: "Couldn't add the connection."),
                              message: error == .limitReached
                                ? String(localized: "You have 32 connections, the maximum. Remove one to add another.")
                                : String(localized: "Nothing was changed."),
                              code: error.rawValue))
        }
        return nil
    }

    /// Removes both credential files; the first failure wins.
    private func removeCredentialFiles(_ clientID: String) -> Result<Void, CredentialFileError> {
        let key = services.credentialFiles.remove(clientID: clientID, kind: .signingKey)
        let token = services.credentialFiles.remove(clientID: clientID, kind: .mcpToken)
        let remote = services.credentialFiles.remove(clientID: clientID, kind: .remoteToken)
        if case .failure = key { return key }
        if case .failure = token { return token }
        return remote
    }

    func rename(_ clientID: String, to name: String) -> ClientNameIssue? {
        if let issue = nameIssue(name, excluding: clientID) { return issue }
        switch services.registry.rename(clientID: clientID, name: name) {
        case .success:
            sheet = nil
            refresh()
            let renamed = clientName(clientID)
            showBanner(Banner(kind: .success, title: String(localized: "Renamed to “\(renamed)”.")))
            return nil
        case .failure(.duplicateName):
            return .duplicate(name.trimmingCharacters(in: .whitespacesAndNewlines))
        case .failure(.invalidName):
            return ClientRegistry.nameShapeIssue(name) ?? .empty
        case .failure(let error):
            sheet = nil
            showBanner(Banner(kind: .error, title: String(localized: "Couldn't rename the connection."),
                              message: String(localized: "Nothing was changed."), code: error.rawValue))
            return nil
        }
    }

    func keyFileURL(_ clientID: String) -> URL? { services.credentialFiles.url(for: clientID) }

    func keyFileStatus(_ clientID: String) -> CredentialFileStatus {
        services.credentialFiles.status(clientID: clientID)
    }

    func showKeyFile(_ clientID: String) {
        guard let url = keyFileURL(clientID) else { return }
        if keyFileStatus(clientID) == .present {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            // Never open the file itself; show its folder when the file is gone.
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }

    func rotateKey(_ clientID: String) {
        guard let client = client(clientID), !client.revoked else { return }
        confirmUnsaved { [weak self] in self?.confirmRotate(client) }
    }

    private func confirmRotate(_ client: ClientView) {
        var fileStatus = keyFileStatus(client.id)
        // Check before changing the registry: a failed file write after
        // rotating would revoke the client.
        if fileStatus == .present, case .failure = services.credentialFiles.canReplace(clientID: client.id) {
            fileStatus = .unsafe
        }
        if fileStatus == .unsafe {
            showBanner(Banner(kind: .warning, title: String(localized: "The key file isn't safe to replace."),
                              message: String(localized: "Check its permissions in Finder, or remove this connection and add a new one."),
                              actionTitle: String(localized: "Show in Finder"),
                              action: { [weak self] in self?.showKeyFile(client.id) }))
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Rotate the key for “\(client.name)”?")
        alert.informativeText = String(localized: "The current key stops working now. The new key is saved to the same file, so tools that read it from there keep working. Copies of the old file stop working.")
        alert.addButton(withTitle: String(localized: "Rotate Key"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        present(alert) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            switch self.services.registry.rotateKey(clientID: client.id) {
            case .success(let key):
                self.services.approvals?.withdraw(clientID: client.id)
                let written = fileStatus == .missing
                    ? self.services.credentialFiles.saveNew(clientID: client.id, key: key)
                    : self.services.credentialFiles.replace(clientID: client.id, key: key)
                switch written {
                case .success:
                    self.refresh()
                    self.showBanner(Banner(kind: .success, title: String(localized: "Key rotated."),
                                           message: String(localized: "The old key no longer works.")))
                case .failure(let error):
                    let revoked = self.services.registry.revoke(clientID: client.id)
                    let removed = self.removeCredentialFiles(client.id)
                    self.refresh()
                    self.showCleanupBanner(title: String(localized: "Couldn't save the new key file."),
                                           code: error.rawValue, revoked: revoked, removed: removed,
                                           clientID: client.id)
                }
            case .failure(let error):
                self.showBanner(Banner(kind: .error, title: String(localized: "Couldn't rotate the key."),
                                       message: String(localized: "Nothing was changed."), code: error.rawValue))
            }
        }
    }

    /// Saved at once, outside the staged grant draft. Pausing is undone by
    /// Resume, so it doesn't ask first. Changes waiting for approval are
    /// withdrawn and an Allow for 15 minutes window ends.
    func setPaused(_ clientID: String, _ paused: Bool) {
        guard let client = client(clientID), !client.revoked, client.paused != paused else { return }
        switch services.registry.setPaused(clientID: clientID, paused) {
        case .success:
            services.approvals?.withdraw(clientID: clientID)
            refresh()
            showBanner(paused
                ? Banner(kind: .success, title: String(localized: "“\(client.name)” is paused."),
                         message: String(localized: "Its requests are refused until you resume it. Its keys, tokens and access are kept."))
                : Banner(kind: .success, title: String(localized: "“\(client.name)” is resumed."),
                         message: String(localized: "Its next request is handled as before.")))
        case .failure(let error):
            showBanner(Banner(kind: .error,
                              title: paused ? String(localized: "Couldn't pause the connection.")
                                            : String(localized: "Couldn't resume the connection."),
                              message: String(localized: "Nothing was changed."), code: error.rawValue))
        }
    }

    func revokeClient(_ clientID: String) {
        guard let client = client(clientID), !client.revoked else { return }
        confirmUnsaved { [weak self] in self?.confirmRevoke(client) }
    }

    private func confirmRevoke(_ client: ClientView) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Remove “\(client.name)”?")
        alert.informativeText = String(localized: "The agent or script using it stops working: its key and MCP token are deleted and all of its access is removed. You can’t undo this. To reconnect it later, add a new connection.")
        let revoke = alert.addButton(withTitle: String(localized: "Remove"))
        revoke.hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        present(alert) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            switch self.services.registry.revoke(clientID: client.id) {
            case .success:
                self.services.approvals?.withdraw(clientID: client.id)
                self.services.remote.oauth?.revokeAll(clientID: client.id)
                let removed = self.removeCredentialFiles(client.id)
                self.clearDraft()
                self.refresh()
                self.go(.overview)
                switch removed {
                case .success:
                    self.showBanner(Banner(kind: .success, title: String(localized: "“\(client.name)” was removed."),
                                           message: String(localized: "Its credential files were removed.")))
                case .failure(let error):
                    self.showBanner(Banner(
                        kind: .warning, title: String(localized: "“\(client.name)” was removed, but a credential file couldn’t be deleted."),
                        message: String(localized: "Its key no longer works. Check the file before continuing."),
                        code: error.rawValue, actionTitle: String(localized: "Show in Finder"),
                        action: { [weak self] in self?.showKeyFile(client.id) }))
                }
            case .failure(let error):
                self.showBanner(Banner(kind: .error, title: String(localized: "Couldn't remove the connection."),
                                       message: String(localized: "Nothing was changed."), code: error.rawValue))
            }
        }
    }

    private func showCleanupBanner(title: String, code: String,
                                   revoked: Result<Void, ClientRegistryError>,
                                   removed: Result<Void, CredentialFileError>, clientID: String) {
        var cleanedUp = true
        if case .failure = revoked { cleanedUp = false }
        if case .failure = removed { cleanedUp = false }
        if cleanedUp {
            showBanner(Banner(kind: .warning, title: title,
                              message: String(localized: "The connection was removed so no unused key is left behind. Check that Application Support isn’t full or locked, then try again."),
                              code: code))
        } else {
            showBanner(Banner(kind: .warning, title: title,
                              message: String(localized: "Cleanup didn’t finish. Pause \(AppIdentity.displayName) and check this connection’s key file before continuing."),
                              code: code, actionTitle: String(localized: "Show in Finder"),
                              action: { [weak self] in self?.showKeyFile(clientID) }))
        }
    }

    // MARK: Access editing

    func setAction(_ key: GrantKey, bit: Int, on: Bool) {
        guard let draft else { return }
        let next = ClientGrantEditing.toggling(draft.mask(key), bit: bit, on: on)
        setMask(key, next, actionName: String(localized: "Change Access"))
    }

    enum RowPreset { case readOnly, fullAccess, noAccess }

    func apply(_ preset: RowPreset, to collection: CollectionInfo) {
        let mask: Int
        switch preset {
        case .readOnly: mask = ClientGrant.read
        case .fullAccess:
            mask = ClientGrantEditing.allowedMask(resource: collection.resource, writable: collection.writable)
        case .noAccess: mask = 0
        }
        setMask(collection.key, mask, actionName: String(localized: "Change Access"))
    }

    /// Turn On for All / Turn Off for All in an access table header (B06):
    /// `bit` on every visible row that allows it. On implies Read; turning
    /// Read off clears the write actions too, after a confirmation when that
    /// clears more than 5 write cells. One undo step.
    func applyColumn(bit: Int, on: Bool, rows: [CollectionInfo]) {
        guard let draft else { return }
        var changes = [GrantKey: Int]()
        for row in rows {
            let allowed = ClientGrantEditing.allowedMask(resource: row.resource, writable: row.writable)
            guard allowed & bit != 0 else { continue }
            let old = draft.mask(row.key)
            let next = on ? ClientGrantEditing.toggling(old, bit: bit, on: true)
                : bit == ClientGrant.read ? 0 : old & ~bit
            if next != old { changes[row.key] = next }
        }
        guard !changes.isEmpty else { return }
        let clearedWrites = changes.filter { key, mask in
            draft.mask(key) & ~ClientGrant.read != 0 && mask & ~ClientGrant.read == 0
        }
        let writeCells = clearedWrites.reduce(0) { $0 + (draft.mask($1.key) & ~ClientGrant.read).nonzeroBitCount }
        guard !on, bit == ClientGrant.read, writeCells > 5 else {
            setMasks(changes, actionName: String(localized: "Change Access"))
            return
        }
        let resource = rows.first?.resource ?? .calendar
        let alert = NSAlert()
        alert.messageText = String(localized: "Turn off Read for all?")
        alert.informativeText = resource == .calendar
            ? String(localized: "This also turns off Create, Edit and Delete on \(clearedWrites.count) calendars.")
            : String(localized: "This also turns off Create, Edit, Delete and Complete on \(clearedWrites.count) lists.")
        alert.addButton(withTitle: String(localized: "Turn Off"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        present(alert) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.setMasks(changes, actionName: String(localized: "Change Access"))
        }
    }

    /// Several rows at once, undone together.
    private func setMasks(_ changes: [GrantKey: Int], actionName: String) {
        guard var current = draft else { return }
        var old = [GrantKey: Int]()
        for (key, mask) in changes {
            old[key] = current.mask(key)
            current.set(key, mask: mask)
        }
        draft = current
        savedToastAt = nil
        if let undo = window?.undoManager {
            undo.registerUndo(withTarget: self) { model in
                MainActor.assumeIsolated { model.setMasks(old, actionName: actionName) }
            }
            undo.setActionName(actionName)
        }
    }

    func removeUnavailable(_ key: GrantKey) {
        setMask(key, 0, actionName: String(localized: "Remove Access"))
    }

    /// Puts back the saved mask exactly, without implying Read.
    func restoreSaved(_ key: GrantKey) {
        guard let draft else { return }
        setMask(key, draft.savedMask(key), actionName: String(localized: "Remove Access"))
    }

    private func setMask(_ key: GrantKey, _ mask: Int, actionName: String) {
        guard var current = draft else { return }
        let old = current.mask(key)
        guard old != mask else { return }
        current.set(key, mask: mask)
        draft = current
        savedToastAt = nil
        if let undo = window?.undoManager {
            undo.registerUndo(withTarget: self) { model in
                MainActor.assumeIsolated { model.setMask(key, old, actionName: actionName) }
            }
            undo.setActionName(actionName)
        }
    }

    @discardableResult
    func saveDraft() -> Bool {
        guard let draft, let client = client(draft.clientID), !client.revoked else { return false }
        guard draft.hasChanges else { return true }
        let listed = collections.map { (key: $0.key, writable: $0.writable) }
        let grants = draft.grantsToSave(base: client.grants, listed: listed)
        switch services.registry.replaceGrants(clientID: client.id, grants: grants) {
        case .success:
            services.approvals?.withdraw(clientID: client.id)
            clearDraft()
            refresh()
            if let updated = self.client(client.id) { self.draft = GrantDraft(client: updated) }
            savedToastAt = Date()
            if let banner, banner.kind == .error { self.banner = nil }
            announce(String(localized: "Saved. Changes apply to the next request."))
            return true
        case .failure(.unavailable):
            // The registry stops all access after a write failure until the app restarts.
            showBanner(Banner(kind: .error, title: String(localized: "Couldn't save."),
                              message: String(localized: "Connection settings can't be written, so nothing was changed and agents and scripts can't connect. Quit and reopen the app, then make the changes again."),
                              code: ClientRegistryError.unavailable.rawValue))
            return false
        case .failure(let error):
            showBanner(Banner(kind: .error, title: String(localized: "Couldn't save."),
                              message: String(localized: "Nothing was changed."), code: error.rawValue))
            return false
        }
    }

    func revertDraft() {
        guard let draft, let client = client(draft.clientID) else { return }
        clearDraft()
        self.draft = GrantDraft(client: client)
    }

    var showSavedToast: Bool { savedToastAt != nil }

    // MARK: Activity

    func openActivity(selecting id: ActivityEntry.ID? = nil, client: String? = nil,
                      keepingVia: Bool = false) {
        activityKind = .all
        activitySearch = ""
        if !keepingVia { activityVia = .all }
        activityClientFilter = client.map { .client($0) } ?? .all
        activitySelection = id
        show(.activity)
    }

    /// ⌘F: shows Activity and puts the cursor in its search field.
    func focusActivitySearch() {
        show(.activity)
        // After the pane exists, so its field sees the change.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.route == .activity else { return }
            self.activitySearchFocusRequest += 1
        }
    }

    /// The item an Activity row names, looked up live and cached until
    /// Calendar or Reminders changes (C02).
    func itemDisplay(_ entry: ActivityEntry) -> ItemDisplay {
        guard let ref = entry.item else { return .none }
        let resource: ClientResource = ref.kind == "event" ? .calendar : .reminderList
        guard (resource == .calendar ? calendarAccess : remindersAccess) == .fullAccess else {
            return .noAccess(resource)
        }
        _ = itemLookupGeneration
        if let cached = itemCache[ref] { return .found(cached) }
        guard let snapshot = services.itemLookup(ref) else { return .none }
        itemCache[ref] = snapshot
        return .found(snapshot)
    }

    /// Keeps an answered change's panel summary for this session (C03).
    func rememberApprovalSummary(_ requestID: String, _ summary: ApprovalSummary) {
        if recentSummaries[requestID] == nil { recentSummaryOrder.append(requestID) }
        recentSummaries[requestID] = summary
        while recentSummaryOrder.count > Self.maxRecentSummaries {
            recentSummaries[recentSummaryOrder.removeFirst()] = nil
        }
    }

    /// The panel's summary for an Activity row answered this session.
    func recentSummary(_ entry: ActivityEntry) -> ApprovalSummary? {
        entry.requestID.flatMap { recentSummaries[$0] }
    }

    /// A looked-up title already in the cache, for Activity's search. Never
    /// looks anything up itself.
    func cachedItemTitle(_ entry: ActivityEntry) -> String? {
        entry.item.flatMap { itemCache[$0] }.flatMap { $0.exists ? $0.title : nil }
    }

    /// Show in Calendar / Show in Reminders.
    func showItem(_ entry: ActivityEntry) {
        guard let ref = entry.item, services.showItem(ref) else {
            showBanner(Banner(kind: .warning, title: String(localized: "Couldn't open the item."),
                              message: String(localized: "It may have been deleted, or Calendar and Reminders may not be available.")))
            return
        }
    }

    func markActivityViewed() {
        let latest = activity.first?.at ?? Date()
        guard activityLastViewed.map({ $0 < latest }) ?? true else { return }
        activityLastViewed = latest
        services.defaults.set(latest.timeIntervalSinceReferenceDate, forKey: Keys.activityLastViewed)
    }

    /// Opens a client at the calendar or list an activity row targeted.
    func openClientAccess(_ clientID: String, focus key: GrantKey?) {
        confirmUnsaved { [weak self] in
            guard let self else { return }
            self.go(.client(clientID))
            self.clientTab[clientID] = .access
            self.clientScrollTarget = "access"
            if let key {
                self.accessTab[clientID] = key.resource
                self.accessFocus = key
            }
        }
    }

    // MARK: Setup checklist

    var checklistInput: SetupChecklist.Input {
        SetupChecklist.Input(
            calendar: calendarAccess, reminders: remindersAccess, clients: clients,
            bridgeOn: bridge.isOn,
            successfulClientIDs: Set(activity.filter { $0.code == "success" }.compactMap(\.clientID)),
            skipped: setupSkipped, mcpListening: mcpIsListening)
    }

    var showsSetupChecklist: Bool {
        policyStoreAvailable && (setupJustCompletedName != nil ||
            (!setupHidden && !setupCompleted && !SetupChecklist.isComplete(checklistInput)))
    }

    /// Settings and Help can bring the checklist back while steps are left.
    var canShowSetupAgain: Bool {
        !showsSetupChecklist && policyStoreAvailable && !SetupChecklist.isComplete(checklistInput)
    }

    // MARK: Updates

    func refreshUpdater() {
        updaterAvailable = services.updater.isAvailable()
        automaticUpdateChecks = updaterAvailable && services.updater.automaticChecks()
        lastUpdateCheck = services.updater.lastCheck()
    }

    /// Opens Sparkle's window: checks now, or shows the update it found.
    func checkForUpdates() {
        services.updater.checkForUpdates()
    }

    func setAutomaticUpdateChecks(_ on: Bool) {
        services.updater.setAutomaticChecks(on)
        refreshUpdater()
    }

    /// From a scheduled check, or nil once the user opened it.
    func updateFound(_ update: FoundUpdate?) {
        foundUpdate = update
        refreshUpdater()
    }

    /// Hides the Overview card for this version; the menu item stays. A
    /// security update's card can't be hidden.
    func dismissFoundUpdate() {
        guard let foundUpdate, !foundUpdate.critical else { return }
        dismissedUpdateVersion = foundUpdate.version
    }

    var showsUpdateCard: Bool {
        guard let foundUpdate else { return false }
        return foundUpdate.critical || foundUpdate.version != dismissedUpdateVersion
    }

    func dismissRenameNotice() {
        renameNoticePending = false
        services.defaults.set(false, forKey: RenameMigration.noticeKey)
    }

    func hideSetup() {
        setupHidden = true
        services.defaults.set(true, forKey: Keys.setupHidden)
        endRenameAccessRecheck()
    }

    private func endRenameAccessRecheck() {
        guard renameAccessRecheck else { return }
        renameAccessRecheck = false
        services.defaults.removeObject(forKey: RenameMigration.accessRecheckKey)
    }

    func showSetupAgain() {
        setupHidden = false
        setupCompleted = false
        services.defaults.set(false, forKey: Keys.setupHidden)
        services.defaults.set(false, forKey: Keys.setupCompleted)
        show(.overview)
    }

    func skipSetupStep(_ step: SetupChecklist.Step) {
        setupSkipped.insert(step)
        services.defaults.set(setupSkipped.map(\.rawValue), forKey: Keys.setupSkipped)
    }

    /// The program copied commands start with: `bridge-client` when a link on
    /// the PATH (Settings' or Homebrew's) runs this copy, else this copy's own
    /// `bridge-client` by its full path, so the command works as pasted.
    var cliProgram: String { cliCommand.text }

    private func refreshCommandLineTool() {
        let tool = services.commandLineTool
        commandLineTool = tool.state
        cliCommand = tool.program
        cliLinkedByHomebrew = tool.linkedByPackageManager
    }

    func installCommandLineTool() {
        let tool = services.commandLineTool
        switch tool.install() {
        case .success:
            showBanner(Banner(kind: .success,
                              title: String(localized: "Installed \(CommandLineTool.name) in \(tool.displayPath)."),
                              message: isInstalledInApplications
                                ? String(localized: "If your shell can't find it, add ~/.local/bin to your PATH.")
                                : String(localized: "If your shell can't find it, add ~/.local/bin to your PATH. Moving the app breaks the link; install it again from the new place.")))
        case .failure(.notALink):
            showBanner(Banner(kind: .error,
                              title: String(localized: "\(tool.displayPath) already exists and isn't a link."),
                              message: String(localized: "Remove it, then try again.")))
        case .failure(.unavailable):
            showBanner(Banner(kind: .error,
                              title: String(localized: "This copy of the app has no \(CommandLineTool.name)."),
                              message: String(localized: "Build it with sh build.sh, or download the app again.")))
        case .failure(.failed(let reason)):
            showBanner(Banner(kind: .error,
                              title: String(localized: "Couldn't install \(CommandLineTool.name)."),
                              message: reason))
        }
        refreshCommandLineTool()
    }

    func copyTestCommand() {
        guard let client = SetupChecklist.focusClient(checklistInput) else { return }
        if !bridge.isOn { setBridgeEnabled(true) }
        Pasteboard.copy(ConnectCommand.scopeStatus(for: client, among: clients, program: cliProgram))
        waitingForTestRequest = true
    }

    /// Setup's Connect step (B09): turns EK Bridge on, then Add to <Agent>…
    /// for one-click agents, or the connection's Connect tab.
    func connectFromSetup(_ client: ClientView) {
        if !bridge.isOn { setBridgeEnabled(true) }
        waitingForTestRequest = true
        if agent(for: client.id).oneClick {
            beginOneClick(client.id)
        } else {
            clientTab[client.id] = .connect
            connectTab[client.id] = .agent
            navigate(to: .client(client.id))
        }
    }

    /// Setup's "Copy the setup instead": the connection's Connect tab with the snippet.
    func copySetupFromSetup(_ client: ClientView) {
        copySetup.insert(client.id)
        clientTab[client.id] = .connect
        navigate(to: .client(client.id))
    }

    private func checkSetupCompletion() {
        guard !setupCompleted, !setupHidden, policyStoreAvailable,
              SetupChecklist.isComplete(checklistInput) else { return }
        setupCompleted = true
        waitingForTestRequest = false
        services.defaults.set(true, forKey: Keys.setupCompleted)
        endRenameAccessRecheck()
        // Existing installs that already work never see the checklist or the message.
        guard started else { return }
        let connected = activity.first { $0.code == "success" && client($0.clientID)?.revoked == false }
        setupJustCompletedName = clientName(connected?.clientID)
        announce(String(localized: "\(setupJustCompletedName ?? "") connected. You're all set."))
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.setupJustCompletedName = nil
        }
    }

    // MARK: Settings

    func setDockMode(_ mode: DockIconMode) {
        dockMode = mode
        services.defaults.set(mode.rawValue, forKey: Keys.dockMode)
        dockModeChanged()
    }

    func setShowDeveloperTools(_ on: Bool) {
        showDeveloperTools = on
        services.defaults.set(on, forKey: Keys.showDeveloperTools)
        if !on { developerOutput = nil }
    }

    /// Only the install location gates Start at login. A copy that has never
    /// been registered (every first install, and the first launch under a new
    /// bundle ID) reports `.notFound`, not `.notRegistered`, and `register()`
    /// works from there; a real failure shows as the row's error.
    var canChangeStartAtLogin: Bool { isInstalledInApplications && !AppIdentity.isLiveTest }

    func setStartAtLogin(_ on: Bool) {
        loginItemError = nil
        do {
            try services.setLoginItem(on)
        } catch {
            let value = error as NSError
            loginItemError = String(localized: "Couldn't change this setting. (\(value.domain) \(value.code))")
        }
        loginItem = services.loginItemStatus()
    }

    func revealRunningApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    // MARK: Move to Applications

    static let moveDeclinedKey = "MoveToApplicationsDeclined"

    /// The question, worded for where the app runs from.
    private func moveAlert() -> NSAlert {
        let place = services.installLocation().placeName(home: NSHomeDirectory())
        let alert = NSAlert()
        alert.messageText = String(localized: "Move \(AppIdentity.displayName) to Applications?")
        alert.informativeText = String(localized: "It's running from \(place). Agents start \(AppIdentity.displayName)'s launcher from this location, so setups break if it moves later.")
        alert.addButton(withTitle: String(localized: "Move to Applications"))
        alert.addButton(withTitle: String(localized: "Not Now"))
        return alert
    }

    /// Move to Applications… (the notices): asks, then moves.
    func beginMoveToApplications() {
        confirmUnsaved { [weak self] in
            guard let self else { return }
            self.present(self.moveAlert()) { [weak self] response in
                if response == .alertFirstButtonReturn { self?.performMove() }
            }
        }
    }

    /// At launch, outside Applications, unless the user chose Don't Ask Again.
    func offerMoveToApplications() {
        guard services.installLocation() != .applications,
              !services.defaults.bool(forKey: Self.moveDeclinedKey) else { return }
        let alert = moveAlert()
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Don't ask again")
        present(alert) { [weak self] response in
            guard let self else { return }
            if alert.suppressionButton?.state == .on {
                self.services.defaults.set(true, forKey: Self.moveDeclinedKey)
            }
            if response == .alertFirstButtonReturn { self.performMove() }
        }
    }

    private func performMove() {
        clearDraft()
        if case .failed(let problem) = services.moveToApplications() {
            showBanner(Banner(kind: .error, title: String(localized: "Couldn't move \(AppIdentity.displayName) to Applications."),
                              message: problem.isEmpty ? nil : problem))
        }
    }

    /// In the relaunched copy: says it moved, then that the old copy is in
    /// the Trash (`trashed`, once known), or offers to eject the disk image
    /// it came from.
    func didMove(from path: String, trashed: Bool? = nil) {
        let volume = InstallLocation.volume(of: path)
        let message: String? = switch (volume, trashed) {
        case (.some, _): nil
        case (nil, true?): String(localized: "The old copy is in the Trash.")
        case (nil, false?): String(localized: "The old copy couldn't be moved to the Trash: \(path)")
        case (nil, nil): nil
        }
        showBanner(Banner(kind: .success, title: String(localized: "\(AppIdentity.displayName) moved to Applications."),
                          message: message,
                          actionTitle: volume == nil ? nil : String(localized: "Eject Disk Image"),
                          action: volume.map { volume in {
                              [weak self] in
                              do {
                                  try NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: volume))
                                  self?.dismissBanner()
                              } catch {
                                  self?.showBanner(Banner(kind: .warning,
                                                          title: String(localized: "The disk image couldn't be ejected."),
                                                          message: String(localized: "Eject it in Finder.")))
                              }
                          } }))
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func revealDataFolder() {
        let folder = services.dataFolder
        if FileManager.default.fileExists(atPath: folder.path) {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([folder.deletingLastPathComponent()])
        }
    }

    var dataFolderPath: String { services.dataFolder.path }

    // MARK: MCP server

    var mcpIsListening: Bool {
        if case .listening = mcpStatus { return true }
        return false
    }

    var mcpURL: String { MCPEndpointFile.endpointURL(port: mcpListeningPort ?? mcpPort) }

    var mcpListeningPort: Int? {
        if case .listening(let port) = mcpStatus { return port }
        return nil
    }

    /// Whether the local MCP server should be listening (D1): EK Bridge is
    /// on, the user allows it, and a connection uses MCP.
    var mcpShouldRun: Bool {
        MCPRunPolicy.shouldRun(bridgeOn: bridge.isOn, allowed: localMCPAllowed,
                               hasMCPConnections: activeClients.contains(where: \.hasMCPToken))
    }

    /// Starts or stops the listener when `mcpShouldRun` changes. Called on
    /// every refresh (connections, tokens and the bridge state change there).
    private func syncMCPServer() {
        guard started else { return }
        let should = mcpShouldRun
        guard should != mcpStarted else { return }
        mcpStarted = should
        if should {
            mcpStatus = .starting
            services.mcp.start(mcpPort)
        } else {
            services.mcp.stop()
            mcpStatus = .off
        }
    }

    /// Text for a running server that failed; nil otherwise.
    var mcpFailureText: String? {
        guard mcpStarted, case .failed(let failure) = mcpStatus else { return nil }
        switch failure {
        case .portInUse(let port):
            return String(localized: "Port \(String(port)) is in use by another app.")
        case .other(let reason):
            return reason
        }
    }

    var mcpPortInUse: Bool {
        if case .failed(.portInUse) = mcpStatus { return mcpStarted }
        return false
    }

    /// The short line for Overview and the menu bar; nil while EK Bridge is
    /// paused (the header says so) or when no connection uses MCP.
    var mcpStatusLine: String? {
        guard bridge.isOn else { return nil }
        if !localMCPAllowed { return String(localized: "Local MCP server is off (Settings ▸ Advanced)") }
        guard mcpStarted else { return nil }
        switch mcpStatus {
        case .listening(let port): return String(localized: "MCP on port \(String(port))")
        case .failed(.portInUse(let port)): return String(localized: "MCP couldn't start · port \(String(port)) is in use")
        case .failed: return String(localized: "MCP couldn't start")
        case .starting, .off: return String(localized: "MCP starting…")
        }
    }

    /// Called by the app delegate when the listener changes state.
    func mcpStatusDidChange(_ status: MCPService.Status) {
        if mcpStatus != status { mcpStatus = status }
        checkSetupCompletion()
    }

    /// Called for every authenticated MCP request, local or remote.
    func mcpDidConnect(_ clientID: String, _ connection: MCPServer.Connection) {
        if connection.remote {
            remoteConnections[clientID] = connection
        } else {
            mcpConnections[clientID] = connection
        }
    }

    /// Settings ▸ Advanced ▸ Local MCP server. `confirm: false` skips the
    /// "agents used it recently" question (UI review, live-test automation).
    func setLocalMCPAllowed(_ on: Bool, confirm: Bool = true) {
        guard on != localMCPAllowed else { return }
        if on || !confirm {
            applyLocalMCPAllowed(on)
            return
        }
        let recent = Set(mcpConnections.filter { now.timeIntervalSince($0.value.at) < 600 }.map(\.key))
        guard !recent.isEmpty else { applyLocalMCPAllowed(false); return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Turn off the local MCP server?")
        alert.informativeText = recent.count == 1
            ? String(localized: "1 agent used it in the last 10 minutes; it'll lose access until you turn it back on.")
            : String(localized: "\(recent.count) agents used it in the last 10 minutes; they'll lose access until you turn it back on.")
        alert.addButton(withTitle: String(localized: "Turn Off"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        present(alert) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.applyLocalMCPAllowed(false)
        }
    }

    private func applyLocalMCPAllowed(_ on: Bool) {
        localMCPAllowed = on
        services.defaults.set(on, forKey: Keys.localMCPAllowed)
        services.defaults.set(on, forKey: Keys.mcpEnabled)
        syncMCPServer()
        announce(on ? String(localized: "Local MCP server on") : String(localized: "Local MCP server off"))
    }

    func retryMCPServer() {
        guard mcpStarted else { return }
        services.mcp.start(mcpPort)
    }

    /// Nil when `port` can be used; otherwise the reason, for the port sheet.
    func portIssue(_ text: String) -> String? {
        guard let port = Int(text.trimmingCharacters(in: .whitespaces)),
              MCPDefaults.validPorts.contains(port) else {
            return String(localized: "Use a number from 1024 to 65535.")
        }
        if port == remotePort {
            return String(localized: "That's the Remote Access port. Use a different one.")
        }
        if port == mcpListeningPort { return nil }
        return services.mcp.portIsFree(port) ? nil
            : String(localized: "Port \(String(port)) is in use by another app.")
    }

    func changeMCPPort(_ text: String) -> String? {
        if let issue = portIssue(text) { return issue }
        let port = Int(text.trimmingCharacters(in: .whitespaces))!
        sheet = nil
        guard port != mcpPort || !mcpIsListening else { return nil }
        mcpPort = port
        services.defaults.set(port, forKey: Keys.mcpPort)
        if mcpStarted { services.mcp.start(port) }
        showBanner(Banner(kind: .success, title: String(localized: "The MCP server now uses port \(String(port))."),
                          message: String(localized: "Agents set up with a direct URL need the new address. Launcher setups keep working.")))
        return nil
    }

    var launcherPath: String { services.mcp.launcherURL.path }

    func revealLauncher() {
        NSWorkspace.shared.activateFileViewerSelecting([services.mcp.launcherURL])
    }

    var mcpCounters: MCPTrafficCounters.Snapshot { services.mcp.counters() }

    /// "2 agents made 37 requests today", from Activity rows that came via MCP.
    var mcpTodayText: String {
        let calendar = Calendar.current
        let today = activity.filter { $0.isMCP && calendar.isDate($0.at, inSameDayAs: now) }
        let agents = Set(today.compactMap(\.clientID)).count
        if today.isEmpty { return String(localized: "No agent requests today") }
        let requests = today.count == 1 ? String(localized: "1 request") : String(localized: "\(today.count) requests")
        return agents == 1 ? String(localized: "1 agent made \(requests) today")
                           : String(localized: "\(agents) agents made \(requests) today")
    }

    // MARK: Ask before changes

    func setNewClientApproval(_ mode: ApprovalMode, for kind: ClientKind) {
        if kind == .cli {
            newCLIApproval = mode
            services.defaults.set(mode.rawValue, forKey: Keys.approvalCLI)
        } else {
            newAgentApproval = mode
            services.defaults.set(mode.rawValue, forKey: Keys.approvalAgent)
        }
    }

    /// Saved at once, outside the staged grant draft: a different kind of
    /// setting with a different undo story. Bumps the client's revision.
    func setApproval(_ clientID: String, _ mode: ApprovalMode) {
        guard let client = client(clientID), !client.revoked, client.approval != mode else { return }
        switch services.registry.setApproval(clientID: clientID, mode) {
        case .success:
            services.approvals?.withdraw(clientID: clientID)
            refresh()
            showBanner(Banner(kind: .success, title: String(localized: "Saved. Applies to the next change.")))
        case .failure(let error):
            showBanner(Banner(kind: .error, title: String(localized: "Couldn't change Ask before changes."),
                              message: String(localized: "Nothing was changed."), code: error.rawValue))
        }
    }

    func applyApprovalToAll(_ mode: ApprovalMode) {
        let changing = activeClients.filter { $0.approval != mode }
        guard !changing.isEmpty else {
            showBanner(Banner(kind: .info, title: String(localized: "Every connection already uses this setting.")))
            return
        }
        let alert = NSAlert()
        alert.messageText = mode == .ask
            ? String(localized: "Ask before every change from all connections?")
            : String(localized: "Allow changes from all connections without asking?")
        alert.informativeText = changing.count == 1
            ? String(localized: "1 connection changes. Each one can still be changed on its page.")
            : String(localized: "\(changing.count) connections change. Each one can still be changed on its page.")
        alert.addButton(withTitle: String(localized: "Apply to All Connections"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        present(alert) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            var failed: ClientRegistryError?
            for client in changing {
                if case .failure(let error) = self.services.registry.setApproval(clientID: client.id, mode) {
                    failed = error
                    break
                }
                self.services.approvals?.withdraw(clientID: client.id)
            }
            self.refresh()
            if let failed {
                self.showBanner(Banner(kind: .error, title: String(localized: "Couldn't change every connection."),
                                       code: failed.rawValue))
            } else {
                self.showBanner(Banner(kind: .success, title: String(localized: "Saved. Applies to the next change.")))
            }
        }
    }

    var pendingApprovalCount: Int { services.approvals?.pending.count ?? 0 }

    // MARK: MCP access per client

    func tokenFileURL(_ clientID: String) -> URL? { services.credentialFiles.url(for: clientID, kind: .mcpToken) }

    func tokenFileStatus(_ clientID: String) -> CredentialFileStatus {
        services.credentialFiles.status(clientID: clientID, kind: .mcpToken)
    }

    func showTokenFile(_ clientID: String) {
        guard let url = tokenFileURL(clientID) else { return }
        // Never open the file itself.
        NSWorkspace.shared.activateFileViewerSelecting(
            [tokenFileStatus(clientID) == .present ? url : url.deletingLastPathComponent()])
    }

    /// The client page's connection line (§13.3).
    func mcpConnection(for client: ClientView) -> MCPConnectionState {
        let issued = client.mcpIssuedAt ?? .distantPast
        if let last = activity.first(where: { $0.clientID == client.id && $0.isMCP && $0.at >= issued }),
           last.isProblem, (mcpConnections[client.id]?.at ?? .distantPast) <= last.at.addingTimeInterval(1) {
            return .refused(code: last.code, entryID: last.id)
        }
        let memory = mcpConnections[client.id].flatMap { $0.at >= issued ? $0 : nil }
        let logged = activity.first { $0.clientID == client.id && $0.isMCP && $0.at >= issued }
        switch (memory, logged) {
        case (let memory?, let logged?) where logged.at > memory.at:
            return .connected(agent: logged.agent ?? memory.agent, at: logged.at)
        case (let memory?, _): return .connected(agent: memory.agent, at: memory.at)
        case (nil, let logged?): return .connected(agent: logged.agent, at: logged.at)
        case (nil, nil): return .waiting
        }
    }

    /// Connect until the connection's first successful request, then Access.
    func defaultTab(_ client: ClientView) -> ClientTab {
        activity.contains { $0.clientID == client.id && $0.code == "success" } ? .access : .connect
    }

    func tab(_ client: ClientView) -> ClientTab { clientTab[client.id] ?? defaultTab(client) }

    /// View ▸ Previous Tab / Next Tab on a connection's page.
    func stepClientTab(_ offset: Int) {
        guard case .client(let id) = route, let client = client(id), !client.revoked else { return }
        let all = ClientTab.allCases
        guard let index = all.firstIndex(of: tab(client)) else { return }
        clientTab[id] = all[(index + offset + all.count) % all.count]
    }

    var canStepClientTab: Bool {
        if case .client(let id) = route, client(id)?.revoked == false { return true }
        return false
    }

    /// The header's one status line (B08): connected, waiting, paused or refused.
    func connectionStatusLine(_ client: ClientView) -> (dot: StatusDot, text: String) {
        if client.paused {
            guard let at = client.pausedAt else { return (.neutral, String(localized: "Paused")) }
            return (.neutral, String(localized: "Paused since \(at.formatted(.dateTime.month(.abbreviated).day().hour().minute()))"))
        }
        let last = activity.first { $0.clientID == client.id }
        if let last, last.isProblem {
            return (.warning, String(localized: "Last request was refused: \(last.outcome.label)"))
        }
        let lastText = last.map { String(localized: "last request \(RelativeTime.ago($0.at, now: now).lowercased())") }
        if client.hasMCPToken, case .connected(let agent, _) = mcpConnection(for: client) {
            return (.ok, ([String(localized: "Connected")] + [agent, lastText].compactMap { $0 }).joined(separator: " · "))
        }
        if let lastText { return (.ok, ([String(localized: "Connected")] + [lastText]).joined(separator: " · ")) }
        let waiting = client.hasMCPToken
            ? String(localized: "Waiting for \(agent(for: client.id).displayName)")
            : String(localized: "Waiting for its first request")
        return (.waiting, ([waiting] + [startingSummary(client)]).joined(separator: " · "))
    }

    /// "reads all calendars and lists · asks before changes".
    func startingSummary(_ client: ClientView) -> String {
        let readable = Set(client.grants.filter { $0.mask & ClientGrant.read != 0 }
            .map { GrantKey(resource: $0.resource, targetID: $0.targetID) })
        let reads: String
        if client.grants.isEmpty {
            reads = String(localized: "no access yet")
        } else if !collections.isEmpty, collections.allSatisfy({ readable.contains($0.key) }) {
            reads = String(localized: "reads all calendars and lists")
        } else {
            reads = AccessSummary.counts(client.grants).lowercasedFirst
        }
        let writes = client.grants.contains { $0.mask & ~ClientGrant.read != 0 }
        guard writes || client.approval == .ask else { return reads }
        return reads + " · " + (client.approval == .ask ? String(localized: "asks before changes")
                                                        : String(localized: "changes without asking"))
    }

    func turnOnMCPAccess(_ clientID: String) {
        guard let client = client(clientID), !client.revoked, !client.hasMCPToken else { return }
        issueToken(client, replacing: false)
    }

    func resetMCPToken(_ clientID: String) {
        guard let client = client(clientID), !client.revoked, client.hasMCPToken else { return }
        if tokenFileStatus(clientID) == .unsafe {
            showBanner(Banner(kind: .warning, title: String(localized: "The token file isn't safe to replace."),
                              message: String(localized: "Check its permissions in Finder, or remove MCP access and turn it on again."),
                              actionTitle: String(localized: "Show in Finder"),
                              action: { [weak self] in self?.showTokenFile(clientID) }))
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Reset the MCP token for “\(client.name)”?")
        alert.informativeText = String(localized: "Agents set up with the launcher or the token file keep working. Agents you gave the token to directly stop working until you copy the new one.")
        alert.addButton(withTitle: String(localized: "Reset Token"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        present(alert) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.issueToken(client, replacing: true)
        }
    }

    private func issueToken(_ client: ClientView, replacing: Bool) {
        let fileStatus = tokenFileStatus(client.id)
        switch services.registry.issueMCPToken(clientID: client.id) {
        case .success(let token):
            services.approvals?.withdraw(clientID: client.id)
            let written = fileStatus == .present
                ? services.credentialFiles.replace(clientID: client.id, token: token)
                : services.credentialFiles.saveNew(clientID: client.id, token: token)
            if case .failure(let error) = written {
                // Never leave a token in the registry that no file holds.
                _ = services.registry.removeMCPToken(clientID: client.id)
                _ = services.credentialFiles.remove(clientID: client.id, kind: .mcpToken)
                refresh()
                showBanner(Banner(kind: .warning, title: String(localized: "Couldn't save the token file."),
                                  message: String(localized: "MCP access is off for this connection. Check that Application Support isn’t full or locked, then try again."),
                                  code: error.rawValue))
                return
            }
            refresh()
            connectTab[client.id] = .agent
            showBanner(Banner(kind: .success,
                              title: replacing ? String(localized: "Token reset.")
                                               : String(localized: "MCP access is on for \(client.name)."),
                              message: replacing
                                ? String(localized: "The old token no longer works.")
                                : String(localized: "Copy the setup below into your agent.")))
        case .failure(let error):
            showBanner(Banner(kind: .error, title: String(localized: "Couldn't change MCP access."),
                              message: String(localized: "Nothing was changed."), code: error.rawValue))
        }
    }

    func removeMCPAccess(_ clientID: String) {
        guard let client = client(clientID), !client.revoked, client.hasMCPToken else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Remove MCP access for “\(client.name)”?")
        alert.informativeText = String(localized: "Agents using it stop working now. Its access settings are kept, so you can turn MCP access on again later.")
        let remove = alert.addButton(withTitle: String(localized: "Remove"))
        remove.hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        present(alert) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            switch self.services.registry.removeMCPToken(clientID: client.id) {
            case .success:
                self.services.approvals?.withdraw(clientID: client.id)
                let removed = self.services.credentialFiles.remove(clientID: client.id, kind: .mcpToken)
                self.refresh()
                if case .failure(let error) = removed {
                    self.showBanner(Banner(kind: .warning, title: String(localized: "MCP access was removed, but the token file couldn’t be removed."),
                                           message: String(localized: "The token no longer works. Check the file before continuing."),
                                           code: error.rawValue, actionTitle: String(localized: "Show in Finder"),
                                           action: { [weak self] in self?.showTokenFile(client.id) }))
                } else {
                    self.showBanner(Banner(kind: .success, title: String(localized: "MCP access removed for \(client.name).")))
                }
            case .failure(let error):
                self.showBanner(Banner(kind: .error, title: String(localized: "Couldn't remove MCP access."),
                                       message: String(localized: "Nothing was changed."), code: error.rawValue))
            }
        }
    }

    func addSigningKey(_ clientID: String) {
        guard let client = client(clientID), !client.revoked, !client.hasSigningKey else { return }
        switch services.registry.addSigningKey(clientID: client.id) {
        case .success(let key):
            services.approvals?.withdraw(clientID: client.id)
            let existing = keyFileStatus(client.id)
            let written = existing == .present
                ? services.credentialFiles.replace(clientID: client.id, key: key)
                : services.credentialFiles.saveNew(clientID: client.id, key: key)
            if case .failure(let error) = written {
                _ = services.registry.removeSigningKey(clientID: client.id)
                refresh()
                showBanner(Banner(kind: .warning, title: String(localized: "Couldn't save the key file."),
                                  message: String(localized: "The command-line key wasn't added. Check that Application Support isn’t full or locked, then try again."),
                                  code: error.rawValue))
                return
            }
            refresh()
            connectTab[client.id] = .cli
            showBanner(Banner(kind: .success, title: String(localized: "Command-line key added for \(client.name).")))
        case .failure(let error):
            showBanner(Banner(kind: .error, title: String(localized: "Couldn't add a command-line key."),
                              message: String(localized: "Nothing was changed."), code: error.rawValue))
        }
    }

    func removeSigningKey(_ clientID: String) {
        guard let client = client(clientID), !client.revoked, client.hasSigningKey else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Remove the command-line key for “\(client.name)”?")
        alert.informativeText = String(localized: "Scripts using it stop working now. MCP access isn't affected.")
        let remove = alert.addButton(withTitle: String(localized: "Remove"))
        remove.hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        present(alert) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            switch self.services.registry.removeSigningKey(clientID: client.id) {
            case .success:
                self.services.approvals?.withdraw(clientID: client.id)
                _ = self.services.credentialFiles.remove(clientID: client.id, kind: .signingKey)
                self.refresh()
                self.showBanner(Banner(kind: .success, title: String(localized: "Command-line key removed for \(client.name).")))
            case .failure(let error):
                self.showBanner(Banner(kind: .error, title: String(localized: "Couldn't remove the key."),
                                       message: String(localized: "Nothing was changed."), code: error.rawValue))
            }
        }
    }

    /// Copies the token only after the user confirms. The token is never
    /// displayed; the pasteboard copy is concealed, transient and cleared
    /// after 90 s if it's still there.
    func copyToken(_ clientID: String) {
        guard let client = client(clientID), client.hasMCPToken, let url = tokenFileURL(clientID) else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Copy the MCP token for “\(client.name)”?")
        alert.informativeText = String(localized: "Anyone with this token can use \(client.name)'s access while \(AppIdentity.displayName) is on. Paste it only into the agent's settings, and don't share it. The clipboard is cleared in 90 seconds.")
        alert.addButton(withTitle: String(localized: "Copy Token"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        present(alert) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            // Same checks as bridge-mcp: owned, private, small, token-shaped.
            guard let data = try? SafePath.readFile(url.path, maxBytes: CredentialKind.mcpToken.maxBytes),
                  let token = String(data: data, encoding: .utf8), ClientRegistry.validMCPToken(token) else {
                self.showBanner(Banner(kind: .warning, title: String(localized: "Couldn't read the token file."),
                                       message: String(localized: "Reset the token to create a new one."),
                                       actionTitle: String(localized: "Show in Finder"),
                                       action: { [weak self] in self?.showTokenFile(clientID) }))
                return
            }
            Pasteboard.copySecret(token, clearAfter: 90)
            self.announce(String(localized: "Token copied. The clipboard is cleared in 90 seconds."))
        }
    }

    // MARK: Remote Access

    var remoteConfiguration: RemoteConfiguration {
        RemoteConfiguration(secret: remoteSecret, publicOrigin: remoteOrigin, port: remotePort)
    }

    var remoteIsListening: Bool {
        if case .listening = remoteStatus { return true }
        return false
    }

    /// The URL cloud agents use, or nil until the tunnel's address is known.
    var remoteMCPURL: String? { remoteConfiguration.mcpURL }

    var remoteFailureText: String? {
        guard remoteEnabled, case .failed(let failure) = remoteStatus else { return nil }
        switch failure {
        case .portInUse(let port): return String(localized: "Port \(String(port)) is in use by another app.")
        case .other(let reason): return reason
        }
    }

    var cloudClients: [ClientView] { activeClients.filter(\.cloudAccess) }

    /// "Remote Access on · 2 cloud clients", for the menu bar.
    var remoteMenuLine: String {
        let count = cloudClients.count
        return count == 1 ? String(localized: "Remote Access on · 1 cloud connection")
                          : String(localized: "Remote Access on · \(count) cloud connections")
    }

    /// Overview's line: "Remote Access · Reachable · my-mac.tail1234.ts.net".
    var remoteStatusLine: String? {
        guard remoteEnabled else { return nil }
        let host = remoteOrigin.flatMap(URL.init(string:))?.host
        let state: String
        if remoteFailureText != nil {
            state = String(localized: "Couldn't start")
        } else if remoteOrigin == nil {
            state = String(localized: "Waiting for tunnel")
        } else {
            switch remoteTest {
            case .reachable: state = String(localized: "Reachable")
            case .notReachable: state = String(localized: "Not reachable")
            case .testing: state = String(localized: "Testing…")
            case .notTested: state = String(localized: "Not tested")
            }
        }
        return ([String(localized: "Remote Access"), state] + (host.map { [$0] } ?? [])).joined(separator: " · ")
    }

    func remoteStatusDidChange(_ status: RemoteMCPService.Status) {
        if remoteStatus != status { remoteStatus = status }
    }

    func remoteDidServe(_ note: RemoteRequestNote) {
        remoteNotes.append(note)
        if remoteNotes.count > 50 { remoteNotes.removeFirst(remoteNotes.count - 50) }
    }

    /// The tunnel and forwarded address of a remote Activity row, if this
    /// app saw it since launch (kept in memory only).
    func remoteNote(for entry: ActivityEntry) -> RemoteRequestNote? {
        guard entry.via == "remote", let clientID = entry.clientID else { return nil }
        return remoteNotes.last { $0.clientID == clientID && abs($0.at.timeIntervalSince(entry.at)) < 5 }
    }

    func setRemoteAccessEnabled(_ on: Bool) {
        guard on != remoteEnabled else { return }
        guard on else { applyRemoteEnabled(false); return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Turn on Remote Access?")
        alert.informativeText = String(localized: "Cloud agents you allow will be able to reach this Mac through a tunnel you set up. Nothing is reachable until you set up a tunnel and allow a connection.")
        alert.addButton(withTitle: String(localized: "Turn On"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        present(alert) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.applyRemoteEnabled(true)
        }
    }

    func applyRemoteEnabled(_ on: Bool) {
        remoteEnabled = on
        services.defaults.set(on, forKey: Keys.remoteEnabled)
        if on {
            if remoteSecret.isEmpty {
                remoteSecret = RemoteConfiguration.newSecret()
                services.defaults.set(remoteSecret, forKey: Keys.remoteSecret)
            }
            scheduleRemoteOff()
            services.remote.start(remoteConfiguration)
        } else {
            services.remote.stop()
            services.remote.oauth?.closePairing()
            remoteStatus = .off
            remoteTest = .notTested
            setRemoteOffAt(nil)
        }
        updateKeepAwake()
        announce(on ? String(localized: "Remote Access on") : String(localized: "Remote Access off"))
    }

    func setRemoteAutoOff(_ interval: TimeInterval) {
        remoteAutoOff = interval
        services.defaults.set(interval, forKey: Keys.remoteAutoOff)
        if remoteEnabled { scheduleRemoteOff() }
    }

    private func scheduleRemoteOff() {
        setRemoteOffAt(remoteAutoOff > 0 ? Date().addingTimeInterval(remoteAutoOff) : nil)
    }

    private func setRemoteOffAt(_ date: Date?) {
        remoteOffAt = date
        services.defaults.set(date?.timeIntervalSinceReferenceDate ?? 0, forKey: Keys.remoteOffAt)
    }

    func setKeepAwake(_ on: Bool) {
        keepAwake = on
        services.defaults.set(on, forKey: Keys.keepAwake)
        updateKeepAwake()
    }

    /// Only while Remote Access is on and the Mac is on power.
    private func updateKeepAwake() {
        services.remote.setKeepAwake(remoteEnabled && keepAwake && services.remote.onACPower())
    }

    /// Nil when the address can be used; otherwise why not.
    func remoteAddressIssue(_ text: String) -> String? {
        RemoteConfiguration.normalizedOrigin(text) == nil
            ? String(localized: "Enter the tunnel's https address, like https://my-mac.tail1234.ts.net, without a path.")
            : nil
    }

    func setRemoteAddress(_ text: String) -> String? {
        if let issue = remoteAddressIssue(text) { return issue }
        sheet = nil
        remoteEditingAddress = false
        let previous = remoteOrigin
        remoteOrigin = RemoteConfiguration.normalizedOrigin(text)
        services.defaults.set(remoteOrigin, forKey: Keys.remoteOrigin)
        remoteTest = .notTested
        services.remote.update(remoteConfiguration)
        if previous != nil, previous != remoteOrigin {
            let dropped = dropStaleConnections()
            showBanner(Banner(kind: .info, title: String(localized: "The Remote Access address changed."),
                              message: dropped > 0
                                ? String(localized: "Update the URL in each cloud agent. Connected cloud apps were disconnected; connect them again.")
                                : String(localized: "Update the URL in each cloud agent.")))
        }
        return nil
    }

    /// OAuth connections are bound to the MCP URL, so a new address or secret path ends them.
    private func dropStaleConnections() -> Int {
        guard let oauth = services.remote.oauth else { return 0 }
        let resource = remoteConfiguration.oauthContext?.resource ?? ""
        let dropped = oauth.revokeConnections(notFor: resource)
        oauth.closePairing()
        oauthChanges += 1
        return dropped
    }

    func remotePortIssue(_ text: String) -> String? {
        guard let port = Int(text.trimmingCharacters(in: .whitespaces)),
              MCPDefaults.validPorts.contains(port) else {
            return String(localized: "Use a number from 1024 to 65535.")
        }
        if port == mcpPort { return String(localized: "That's the local MCP server's port. Use a different one.") }
        if port == remotePort && remoteIsListening { return nil }
        return services.remote.portIsFree(port) ? nil
            : String(localized: "Port \(String(port)) is in use by another app.")
    }

    func changeRemotePort(_ text: String) -> String? {
        if let issue = remotePortIssue(text) { return issue }
        sheet = nil
        remotePort = Int(text.trimmingCharacters(in: .whitespaces))!
        services.defaults.set(remotePort, forKey: Keys.remotePort)
        remoteTest = .notTested
        if remoteEnabled { services.remote.start(remoteConfiguration) }
        showBanner(Banner(kind: .success, title: String(localized: "Remote Access now uses port \(String(remotePort))."),
                          message: String(localized: "Point your tunnel at the new port.")))
        return nil
    }

    func resetRemoteSecret() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Reset the secret path?")
        alert.informativeText = String(localized: "Every cloud agent setup uses the current URL and stops working until you give it the new one. Connected cloud apps are disconnected and have to connect again.")
        alert.addButton(withTitle: String(localized: "Reset Path"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        present(alert) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.remoteSecret = RemoteConfiguration.newSecret()
            self.services.defaults.set(self.remoteSecret, forKey: Keys.remoteSecret)
            self.remoteTest = .notTested
            self.services.remote.update(self.remoteConfiguration)
            _ = self.dropStaleConnections()
            self.showBanner(Banner(kind: .success, title: String(localized: "New secret path."),
                                   message: String(localized: "Update the URL in each cloud agent.")))
        }
    }

    /// One outbound HTTPS request to this app's own health URL through the
    /// tunnel, with a nonce only this app issued.
    func testRemoteAccess() {
        guard remoteEnabled, remoteOrigin != nil, remoteTest != .testing else { return }
        remoteTest = .testing
        services.remote.test(remoteConfiguration) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                self.remoteTest = .reachable(rtt: value.rtt, tunnel: value.tunnel, at: Date())
            case .failure(let failure):
                self.remoteTest = .notReachable(reason: failure.reason, at: Date())
            }
        }
    }

    // MARK: Cloud access per client

    func remoteTokenStatus(_ clientID: String) -> CredentialFileStatus {
        services.credentialFiles.status(clientID: clientID, kind: .remoteToken)
    }

    /// "This client can read Work and add to Groceries from the internet."
    func cloudSummary(_ client: ClientView) -> String {
        let text = AccessSummary.text(grants: client.grants, collections: collections, hidden: hiddenResources,
                                      unavailableName: unavailableName)
        return client.grants.isEmpty
            ? String(localized: "This connection has no access yet, so cloud agents can't use anything.")
            : String(localized: "Cloud agents can use this from the internet: \(text).")
    }

    func setCloudAccess(_ clientID: String, _ on: Bool) {
        guard let client = client(clientID), !client.revoked, client.cloudAccess != on else { return }
        if on {
            applyCloudAccess(client, true)
            return
        }
        let connections = services.remote.oauth?.connections(clientID: clientID).count ?? 0
        guard client.hasRemoteToken || connections > 0 else { applyCloudAccess(client, false); return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Turn off cloud access for “\(client.name)”?")
        alert.informativeText = String(localized: "Its remote token and every connected cloud app stop working now. Its access on this Mac isn't affected.")
        let off = alert.addButton(withTitle: String(localized: "Turn Off"))
        off.hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        present(alert) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.applyCloudAccess(client, false)
        }
    }

    private func applyCloudAccess(_ client: ClientView, _ on: Bool) {
        switch services.registry.setCloudAccess(clientID: client.id, on) {
        case .success:
            if !on {
                services.remote.oauth?.revokeAll(clientID: client.id)
                _ = services.credentialFiles.remove(clientID: client.id, kind: .remoteToken)
            }
            services.approvals?.withdraw(clientID: client.id)
            refresh()
        case .failure(let error):
            showBanner(Banner(kind: .error, title: String(localized: "Couldn't change cloud access."),
                              message: String(localized: "Nothing was changed."), code: error.rawValue))
        }
    }

    /// Creates the remote token if needed, then copies it after confirming.
    /// Unlike local tokens there's no launcher to read it, so copying is the
    /// normal way to set a bearer-token cloud agent up.
    func copyRemoteToken(_ clientID: String) {
        guard let client = client(clientID), client.cloudAccess else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Copy the remote token for “\(client.name)”?")
        alert.informativeText = String(localized: "Anyone with this token and the URL can use \(client.name)'s access from the internet while Remote Access and \(AppIdentity.displayName) are on. Paste it only into the cloud agent's settings. The clipboard is cleared in 90 seconds.")
        alert.addButton(withTitle: String(localized: "Copy Remote Token"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        present(alert) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            if !client.hasRemoteToken || self.remoteTokenStatus(clientID) != .present {
                guard self.issueRemoteToken(client) else { return }
            }
            guard let url = self.services.credentialFiles.url(for: clientID, kind: .remoteToken),
                  let data = try? SafePath.readFile(url.path, maxBytes: CredentialKind.remoteToken.maxBytes),
                  let token = String(data: data, encoding: .utf8), ClientRegistry.validRemoteToken(token) else {
                self.showBanner(Banner(kind: .warning, title: String(localized: "Couldn't read the remote token."),
                                       message: String(localized: "Reset the remote token to create a new one.")))
                return
            }
            Pasteboard.copySecret(token, clearAfter: 90)
            self.announce(String(localized: "Remote token copied. The clipboard is cleared in 90 seconds."))
        }
    }

    func resetRemoteToken(_ clientID: String) {
        guard let client = client(clientID), client.cloudAccess, client.hasRemoteToken else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Reset the remote token for “\(client.name)”?")
        alert.informativeText = String(localized: "Cloud agents using the current token stop working until you copy the new one into their settings. Connected cloud apps aren't affected.")
        alert.addButton(withTitle: String(localized: "Reset Token"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        present(alert) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            if self.issueRemoteToken(client) {
                self.showBanner(Banner(kind: .success, title: String(localized: "Remote token reset."),
                                       message: String(localized: "The old token no longer works.")))
            }
        }
    }

    @discardableResult
    private func issueRemoteToken(_ client: ClientView) -> Bool {
        switch services.registry.issueRemoteToken(clientID: client.id) {
        case .success(let token):
            services.approvals?.withdraw(clientID: client.id)
            if case .failure(let error) = services.credentialFiles.save(clientID: client.id, remoteToken: token) {
                _ = services.registry.removeRemoteToken(clientID: client.id)
                refresh()
                showBanner(Banner(kind: .warning, title: String(localized: "Couldn't save the remote token file."),
                                  message: String(localized: "No remote token was created."), code: error.rawValue))
                return false
            }
            refresh()
            return true
        case .failure(let error):
            showBanner(Banner(kind: .error, title: String(localized: "Couldn't create a remote token."),
                              message: String(localized: "Nothing was changed."), code: error.rawValue))
            return false
        }
    }

    func oauthConnections(_ clientID: String) -> [OAuthConnectionView] {
        _ = oauthChanges
        return services.remote.oauth?.connections(clientID: clientID) ?? []
    }

    func revokeConnection(_ connection: OAuthConnectionView) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Revoke “\(connection.appName)”?")
        alert.informativeText = String(localized: "It stops working now. To use it again, connect it again.")
        let revoke = alert.addButton(withTitle: String(localized: "Revoke"))
        revoke.hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        present(alert) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.services.remote.oauth?.revoke(connectionID: connection.id)
        }
    }

    /// Opens a 10-minute pairing window for this client (§22.6).
    /// The OAuth client set up for an app that takes a client ID and secret (Gemini Enterprise).
    /// In memory only, while its sheet is open; the store keeps only the secret's digest.
    struct OAuthClientDetails: Equatable {
        let bridgeClientID: String
        let clientID: String
        let secret: String
        let authorizationURL: String
        let tokenURL: String
        let redirectURI: String
    }

    var oauthClientDetails: OAuthClientDetails? {
        didSet { if oauthClientDetails == nil, sheet == .oauthClient { sheet = nil } }
    }

    /// Gemini Enterprise ▸ Connect a Cloud App…: makes a confidential client for this bridge client,
    /// opens pairing, and shows the values to enter. Each use replaces the client's unused ones.
    func setUpOAuthClient(_ clientID: String, appName: String, redirectURI: String) {
        guard let oauth = services.remote.oauth, let client = client(clientID), client.cloudAccess,
              let context = remoteConfiguration.oauthContext else { return }
        guard let issued = oauth.registerConfidentialClient(for: clientID, name: appName,
                                                            redirectURI: redirectURI) else {
            showBanner(Banner(kind: .error, title: String(localized: "Couldn't set up the app."),
                              message: String(localized: "The list of connected apps can't be saved right now.")))
            return
        }
        oauth.openPairing(clientID: clientID)
        oauthChanges += 1
        oauthClientDetails = OAuthClientDetails(
            bridgeClientID: clientID, clientID: issued.clientID, secret: issued.secret,
            authorizationURL: context.issuer + "/oauth/authorize", tokenURL: context.issuer + "/oauth/token",
            redirectURI: redirectURI)
        sheet = .oauthClient
    }

    func copyOAuthClientSecret() {
        guard let secret = oauthClientDetails?.secret else { return }
        Pasteboard.copySecret(secret, clearAfter: 90)
        announce(String(localized: "Client secret copied. The clipboard is cleared in 90 seconds."))
    }

    func connectCloudApp(_ clientID: String) {
        guard let oauth = services.remote.oauth, client(clientID)?.cloudAccess == true else { return }
        oauth.openPairing(clientID: clientID)
        oauthChanges += 1
        showBanner(Banner(kind: .info, title: String(localized: "Pairing is open for 10 minutes."),
                          message: String(localized: "Add the connector in the cloud app now. When it asks to connect, check the code and allow it here.")))
    }

    var pairingClientID: String? {
        _ = oauthChanges
        guard let oauth = services.remote.oauth, let expires = oauth.pairingExpiresAt, expires > now else { return nil }
        return oauth.pairingClientID
    }

    func pairingRequest(_ id: UUID) -> PairingRequest? {
        _ = oauthChanges
        return services.remote.oauth?.pendingPairings.first { $0.id == id }
    }

    private func pairingRequested(_ request: PairingRequest) {
        oauthChanges += 1
        showWindow()
        presentNextPairing()
        announce(String(localized: "\(request.appName) wants to connect. Code \(request.code)."))
    }

    /// Shows the oldest waiting request, but never replaces a sheet the user is looking at: a request
    /// that arrived just before a click would otherwise put its Allow button under the pointer.
    private func presentNextPairing() {
        guard sheet == nil, let next = services.remote.oauth?.pendingPairings.first else { return }
        sheet = .pairing(next.id)
    }

    func answerPairing(_ id: UUID, allow: Bool) {
        services.remote.oauth?.answerPairing(id, allow: allow)
        oauthChanges += 1
        sheet = nil
    }

    // MARK: Developer tools

    private func updateTestCollectionsState() {
        guard let tests = services.testCollections else { return }
        let next: TestCollectionsState
        switch (tests.calendarID != nil, tests.reminderListID != nil) {
        case (true, true): next = .created
        case (false, false): next = .notCreated
        default: next = .partlyCreated
        }
        if next != testCollectionsState { testCollectionsState = next }
    }

    func checkTestSources() {
        developerOutput = services.testCollections?.sourcePreview()
            ?? String(localized: "Test collections aren't available in this build.")
    }

    func createTestCollections() {
        developerOutput = services.testCollections?.create()
            ?? String(localized: "Test collections aren't available in this build.")
        refresh()
    }

    func removeTestCollections() {
        guard let tests = services.testCollections else {
            developerOutput = String(localized: "Test collections aren't available in this build.")
            return
        }
        tests.removeEmpty { [weak self] message in
            self?.developerOutput = message
            self?.refresh()
        }
    }
}

/// Copies only the given text. The CLI key is never put on the pasteboard;
/// the MCP token only through `copySecret`, after a confirmation.
enum Pasteboard {
    @MainActor static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Marks the copy concealed and transient so clipboard managers skip it,
    /// and clears it after `seconds` unless something else was copied since.
    /// The pasteboard change a secret copy made, until it's cleared.
    @MainActor private static var secretChange: Int?

    /// Clears a copied secret that's still on the pasteboard (90 s passed, or
    /// the app is quitting).
    @MainActor static func clearSecret() {
        guard let change = secretChange else { return }
        secretChange = nil
        if NSPasteboard.general.changeCount == change { NSPasteboard.general.clearContents() }
    }

    @MainActor static func copySecret(_ text: String, clearAfter seconds: TimeInterval) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.writeObjects([item])
        let count = pasteboard.changeCount
        secretChange = count
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if secretChange == count { clearSecret() }
        }
    }
}
