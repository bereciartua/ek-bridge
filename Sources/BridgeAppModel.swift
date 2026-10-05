import AppKit
import EventKit
import Observation
import ServiceManagement

enum Route: Hashable {
    case overview
    case activity
    case client(String)
    case settings
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

    var id: String {
        switch self {
        case .newClient: "new"
        case .rename(let id): "rename-\(id)"
        case .unavailableGrants(let id): "unavailable-\(id)"
        case .collectionIDs: "collection-ids"
        }
    }
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
    var testCollections: TestCollections?
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
    private(set) var policyStoreAvailable = true
    private(set) var loginItem: SMAppService.Status = .notRegistered
    private(set) var loginItemError: String?
    private(set) var isInstalledInApplications = false
    private(set) var now = Date()
    private(set) var accessRequestInFlight = Set<ClientResource>()
    private(set) var accessRequestDeclined = Set<ClientResource>()

    var route: Route = .overview
    var sheet: ModelSheet?
    private(set) var banner: Banner?
    private(set) var draft: GrantDraft?
    private(set) var savedToastAt: Date?
    /// A calendar or list to highlight in the access table (deep link from Activity).
    var accessFocus: GrantKey?
    /// The scroll target inside the client pane ("access" after creating a client).
    var clientScrollTarget: String?
    var accessTab = [String: ClientResource]()

    var activityClientFilter: ActivityClientFilter = .all
    var activityProblemsOnly = false
    var activitySearch = ""
    var activitySelection: ActivityEntry.ID?
    private(set) var activityLastViewed: Date?

    private(set) var dockMode: DockIconMode = .whileWindowOpen
    private(set) var showDeveloperTools = false
    private(set) var setupHidden = false
    private(set) var setupCompleted = false
    private(set) var setupSkipped = Set<SetupChecklist.Step>()
    /// Set briefly when the checklist finishes, to show the success message.
    private(set) var setupJustCompletedName: String?
    private(set) var developerOutput: String?
    private(set) var testCollectionsState: TestCollectionsState = .notCreated
    private(set) var waitingForTestRequest = false

    // MARK: Wiring

    @ObservationIgnored let services: BridgeServices
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored var showWindow: () -> Void = {}
    @ObservationIgnored var dockModeChanged: () -> Void = {}
    @ObservationIgnored var windowIsVisible: () -> Bool = { false }
    @ObservationIgnored private var refreshScheduled = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers = [NSObjectProtocol]()
    @ObservationIgnored private var bannerTimer: Timer?

    private enum Keys {
        static let setupHidden = "SetupChecklistHidden"
        static let setupCompleted = "SetupChecklistCompleted"
        static let setupSkipped = "SetupChecklistSkipped"
        static let activityLastViewed = "ActivityLastViewed"
        static let dockMode = "DockIconMode"
        static let showDeveloperTools = "ShowDeveloperTools"
        static let lastRoute = "LastPane"
    }

    init(services: BridgeServices) {
        self.services = services
        let defaults = services.defaults
        setupHidden = defaults.bool(forKey: Keys.setupHidden)
        setupCompleted = defaults.bool(forKey: Keys.setupCompleted)
        setupSkipped = Set((defaults.array(forKey: Keys.setupSkipped) as? [Int] ?? [])
            .compactMap(SetupChecklist.Step.init(rawValue:)))
        let viewed = defaults.double(forKey: Keys.activityLastViewed)
        activityLastViewed = viewed > 0 ? Date(timeIntervalSinceReferenceDate: viewed) : nil
        dockMode = DockIconMode(rawValue: defaults.string(forKey: Keys.dockMode) ?? "") ?? .whileWindowOpen
        showDeveloperTools = defaults.bool(forKey: Keys.showDeveloperTools)
        switch defaults.string(forKey: Keys.lastRoute) {
        case "activity": route = .activity
        case "settings": route = .settings
        default: route = .overview
        }
        refresh()
        // Installs that already served a request never see the checklist,
        // even if the bridge is off right now.
        if !setupCompleted, SetupChecklist.isDone(.testRequest, checklistInput) {
            setupCompleted = true
            defaults.set(true, forKey: Keys.setupCompleted)
        }
    }

    func start() {
        started = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        if let store = services.store {
            observers.append(center.addObserver(forName: .EKEventStoreChanged, object: store,
                                                queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
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
    func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    func refresh() {
        now = Date()
        updateAccess()
        if let current = services.registry.clients() {
            policyStoreAvailable = true
            if clients != current { clients = current }
            let entries = ActivityEntry.entries(from: services.registry.activity() ?? [])
            if entries != activity { activity = entries }
        } else {
            policyStoreAvailable = false
            clients = []
            activity = []
        }
        let listed = services.collections()
        if listed != collections { collections = listed }
        loginItem = services.loginItemStatus()
        isInstalledInApplications = services.isInstalledInApplications()
        reconcileDraft()
        reconcileRoute()
        updateTestCollectionsState()
        if route == .activity && windowIsVisible() { markActivityViewed() }
        checkSetupCompletion()
    }

    private func tick() {
        let before = (calendarAccess, remindersAccess)
        updateAccess()
        if before.0 != calendarAccess || before.1 != remindersAccess {
            refresh()
        } else if Date().timeIntervalSince(now) >= 30 {
            now = Date()
        }
        if let saved = savedToastAt, Date().timeIntervalSince(saved) > 2.5 { savedToastAt = nil }
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

    // MARK: Derived state

    var activeClients: [ClientView] { clients.filter { !$0.revoked } }
    var revokedClients: [ClientView] { clients.filter(\.revoked) }

    func client(_ id: String?) -> ClientView? {
        guard let id else { return nil }
        return clients.first { $0.id == id }
    }

    /// Names are resolved at display time, so renames show everywhere at once.
    func clientName(_ id: String?) -> String {
        guard let id else { return String(localized: "Unknown client") }
        guard let client = client(id) else { return String(localized: "Removed client") }
        return client.revoked ? String(localized: "\(client.name) (revoked)") : client.name
    }

    var problems: [AttentionProblem] {
        AttentionLogic.problems(bridge: bridge, calendar: calendarAccess, reminders: remindersAccess,
                                clients: clients, policyStoreAvailable: policyStoreAvailable)
    }

    var needsAttention: Bool { !problems.isEmpty }

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

    /// Saved grants that EventKit doesn't list right now, for types with Full Access.
    func unavailableGrants(_ client: ClientView, staged: Bool = true) -> [GrantKey] {
        var keys = client.grants.map { GrantKey(resource: $0.resource, targetID: $0.targetID) }
        if staged, let draft, draft.clientID == client.id {
            keys = keys.filter { draft.mask($0) != 0 || draft.savedMask($0) != 0 }
        }
        return keys.filter { status($0.resource) == .fullAccess && collection($0) == nil }
    }

    /// The header subtitle for the menu and the status item tooltip.
    var statusSubtitle: String {
        if !policyStoreAvailable { return String(localized: "Client settings can't be read") }
        switch bridge {
        case .failed: return String(localized: "Off · the bridge couldn't start")
        case .off: return String(localized: "Off · clients can't connect")
        case .on:
            let failing = problems.compactMap { problem -> String? in
                switch problem {
                case .calendarAccess: String(localized: "requests to Calendar will fail")
                case .remindersAccess: String(localized: "requests to Reminders will fail")
                default: nil
                }
            }
            if let first = failing.first { return String(localized: "On · \(first)") }
            let count = activeClients.count
            var parts = [String(localized: "On"),
                         count == 1 ? String(localized: "1 client") : String(localized: "\(count) clients")]
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

    func setBridgeEnabled(_ on: Bool) {
        confirmUnsaved { [weak self] in
            guard let self else { return }
            let state = self.services.setBridge(on)
            self.bridgeDidChange(state)
        }
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

    func beginNewClient() {
        guard policyStoreAvailable, activeClients.count < ClientRegistry.maxActiveClients else { return }
        confirmUnsaved { [weak self] in
            self?.showWindow()
            self?.sheet = .newClient
        }
    }

    var canCreateClient: Bool {
        policyStoreAvailable && activeClients.count < ClientRegistry.maxActiveClients
    }

    func nameIssue(_ name: String, excluding clientID: String? = nil) -> ClientNameIssue? {
        services.registry.nameIssue(name, excluding: clientID)
    }

    /// Creates a client and its key file. Returns false only for name problems
    /// the sheet shows inline; every other outcome closes the sheet.
    func createClient(name: String) -> ClientNameIssue? {
        if let issue = nameIssue(name) { return issue }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        sheet = nil
        switch services.registry.createClient(name: trimmed) {
        case .success(let issued):
            switch services.credentialFiles.saveNew(clientID: issued.id, key: issued.key) {
            case .success:
                refresh()
                go(.client(issued.id))
                clientScrollTarget = "access"
                showBanner(Banner(kind: .info, title: String(localized: "\(trimmed) was created."),
                                  message: String(localized: "It has no access yet. Choose calendars and lists below, then Save.")))
            case .failure(let error):
                let revoked = services.registry.revoke(clientID: issued.id)
                let removed = services.credentialFiles.remove(clientID: issued.id)
                refresh()
                showCleanupBanner(title: String(localized: "Couldn't save the key file."),
                                  code: error.rawValue, revoked: revoked, removed: removed,
                                  clientID: issued.id)
            }
        case .failure(.duplicateName):
            return .duplicate(trimmed)
        case .failure(.invalidName):
            return ClientRegistry.nameShapeIssue(name) ?? .empty
        case .failure(let error):
            showBanner(Banner(kind: .error, title: String(localized: "Couldn't create the client."),
                              message: error == .limitReached
                                ? String(localized: "You have 32 active clients, the maximum. Revoke one to add another.")
                                : String(localized: "Nothing was changed."),
                              code: error.rawValue))
        }
        return nil
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
            showBanner(Banner(kind: .error, title: String(localized: "Couldn't rename the client."),
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
        let fileStatus = keyFileStatus(client.id)
        if fileStatus == .unsafe {
            showBanner(Banner(kind: .warning, title: String(localized: "The key file isn't safe to replace."),
                              message: String(localized: "Check its permissions in Finder, or revoke this client and create a new one."),
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
                    let removed = self.services.credentialFiles.remove(clientID: client.id)
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

    func revokeClient(_ clientID: String) {
        guard let client = client(clientID), !client.revoked else { return }
        confirmUnsaved { [weak self] in self?.confirmRevoke(client) }
    }

    private func confirmRevoke(_ client: ClientView) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Revoke “\(client.name)”?")
        alert.informativeText = String(localized: "Its key stops working and all of its access is removed. You can’t undo this. To reconnect this tool later, create a new client.")
        let revoke = alert.addButton(withTitle: String(localized: "Revoke"))
        revoke.hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        present(alert) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            switch self.services.registry.revoke(clientID: client.id) {
            case .success:
                let removed = self.services.credentialFiles.remove(clientID: client.id)
                self.clearDraft()
                self.refresh()
                self.go(.overview)
                switch removed {
                case .success:
                    self.showBanner(Banner(kind: .success, title: String(localized: "“\(client.name)” was revoked."),
                                           message: String(localized: "Its key file was removed.")))
                case .failure(let error):
                    self.showBanner(Banner(
                        kind: .warning, title: String(localized: "“\(client.name)” was revoked, but its key file couldn’t be removed."),
                        message: String(localized: "Its key no longer works. Check the file before continuing."),
                        code: error.rawValue, actionTitle: String(localized: "Show in Finder"),
                        action: { [weak self] in self?.showKeyFile(client.id) }))
                }
            case .failure(let error):
                self.showBanner(Banner(kind: .error, title: String(localized: "Couldn't revoke the client."),
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
                              message: String(localized: "The client was removed so no unused key is left behind. Check that Application Support isn’t full or locked, then try again."),
                              code: code))
        } else {
            showBanner(Banner(kind: .warning, title: title,
                              message: String(localized: "Cleanup didn’t finish. Turn off the bridge and check this client’s key file before continuing."),
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
            clearDraft()
            refresh()
            if let updated = self.client(client.id) { self.draft = GrantDraft(client: updated) }
            savedToastAt = Date()
            if let banner, banner.kind == .error { self.banner = nil }
            announce(String(localized: "Saved. Changes apply to the next request."))
            return true
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

    func openActivity(selecting id: ActivityEntry.ID? = nil, client: String? = nil) {
        activityProblemsOnly = false
        activitySearch = ""
        if let client { activityClientFilter = .client(client) } else if id != nil { activityClientFilter = .all }
        activitySelection = id
        show(.activity)
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
            skipped: setupSkipped)
    }

    var showsSetupChecklist: Bool {
        policyStoreAvailable && (setupJustCompletedName != nil ||
            (!setupHidden && !setupCompleted && !SetupChecklist.isComplete(checklistInput)))
    }

    func hideSetup() {
        setupHidden = true
        services.defaults.set(true, forKey: Keys.setupHidden)
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

    func copyTestCommand() {
        guard let client = SetupChecklist.focusClient(checklistInput) else { return }
        Pasteboard.copy(ConnectCommand.scopeStatus(clientName: client.name))
        waitingForTestRequest = true
    }

    private func checkSetupCompletion() {
        guard !setupCompleted, !setupHidden, policyStoreAvailable,
              SetupChecklist.isComplete(checklistInput) else { return }
        setupCompleted = true
        waitingForTestRequest = false
        services.defaults.set(true, forKey: Keys.setupCompleted)
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

/// Copies only the given text. The key itself is never put on the pasteboard.
enum Pasteboard {
    @MainActor static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
