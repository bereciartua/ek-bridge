import AppKit
import EventKit
import ServiceManagement

enum BridgeErrorText {
    static func describe(_ error: Error) -> String {
        switch error as? BridgeIOError {
        case .alreadyActive?:
            String(localized: "Another copy of \(AppIdentity.displayName) is already running.")
        case .unsafePath?:
            String(localized: "\(AppIdentity.displayName)'s folder in /tmp has unsafe permissions. Quit other copies and try again.")
        case .directoryFailed?, .writeFailed?:
            String(localized: "\(AppIdentity.displayName) couldn't create its working folder.")
        case nil:
            String(localized: "Something unexpected stopped it.")
        }
    }

    static let policyUnavailable = String(localized: "Connection settings can't be read.")
}

@MainActor
final class BridgeAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var localBridge: LocalBridge?
    private let bridgeEnablement = BridgeEnablement()
    private lazy var store = EKEventStore()
    private lazy var commands = EventKitCommands(store: store)
    private lazy var testCollections = TestCollections(store: store)
    #if EVENTKIT_UI_REVIEW
    private let review = UIReview()
    #else
    private lazy var activityStore = ActivityStore(dataFolder: Self.dataFolder, autoCompact: true)
    private lazy var clientRegistry = ClientRegistry(activity: activityStore)
    private let rateLimiter = RateLimiter()
    private let mcpCounters = MCPTrafficCounters()
    private lazy var approvals = ApprovalCenter(summarize: { [weak self] request in
        ApprovalSummaries.build(request, store: self?.store, collections: self?.model.collections ?? [])
    })
    private lazy var approvalPanel = ApprovalPanelController(center: approvals)
    private lazy var pipeline = RequestPipeline(
        registry: clientRegistry, commands: commands,
        collections: EventKitCollectionSource(store: store),
        approvals: approvals, limiter: rateLimiter,
        bridgeActive: { [weak self] in self?.localBridge?.active == true },
        didRecord: { [weak self] in self?.model.scheduleRefresh() })
    private lazy var mcpService: MCPService = {
        let server = MCPServer(registry: clientRegistry, pipeline: pipeline, limiter: rateLimiter,
                               counters: mcpCounters,
                               didConnect: { [weak self] id, connection in
                                   self?.model.mcpDidConnect(id, connection) })
        let origins = Set(UserDefaults.standard.stringArray(forKey: "MCPServerAllowedOrigins") ?? [])
        let service = MCPService(server: server, limiter: rateLimiter, counters: mcpCounters,
                                 endpointFile: MCPEndpointFile(directory: Self.dataFolder),
                                 allowedOrigins: origins)
        service.statusChanged = { [weak self] status in self?.model.mcpStatusDidChange(status) }
        return service
    }()
    private lazy var cimdFetcher = CIMDFetcher()
    private lazy var oauth = OAuthServer(
        directory: Self.dataFolder, fetcher: cimdFetcher,
        clientAllowed: { [weak self] id in self?.clientRegistry.cloudAccessAllowed(clientID: id) ?? false },
        clientName: { [weak self] id in self?.clientRegistry.clients()?.first { $0.id == id }?.name })
    private let keepAwake = KeepAwake()
    private lazy var updater = SparkleUpdater(gate: UpdateRelaunchGate(
        pendingApprovals: { [weak self] in self?.approvals.pending.count ?? 0 },
        maximumWait: ApprovalCenter.timeout + 5))
    private lazy var remoteService: RemoteMCPService = {
        // A second protocol layer over the same pipeline: only credentials,
        // limits and the gate differ.
        let server = MCPServer(registry: clientRegistry, pipeline: pipeline, limiter: rateLimiter,
                               counters: mcpCounters,
                               didConnect: { [weak self] id, connection in
                                   self?.model.mcpDidConnect(id, connection) })
        let service = RemoteMCPService(server: server, registry: clientRegistry, limiter: rateLimiter,
                                       counters: mcpCounters, oauth: oauth)
        service.statusChanged = { [weak self] status in self?.model.remoteStatusDidChange(status) }
        service.didServe = { [weak self] note in self?.model.remoteDidServe(note) }
        return service
    }()
    #endif
    private var model: BridgeAppModel!
    private var windowController: MainWindowController!
    private var statusMenu: StatusMenuController!
    #if EVENTKIT_LIVE_TEST
    private var automation: LiveTestAutomation?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if EVENTKIT_UI_REVIEW
        model = BridgeAppModel(services: review.services())
        #else
        #if !EVENTKIT_LIVE_TEST
        // The live-test copy has no feed and never updates itself.
        updater.start()
        #endif
        model = BridgeAppModel(services: liveServices())
        // Retention (ActivityRetention) runs at launch, then as rows are added.
        activityStore.scheduleCompaction()
        updater.foundUpdateChanged = { [weak self] in self?.model.updateFound($0) }
        #endif
        #if !EVENTKIT_UI_REVIEW
        // Before start(), so a working setup isn't announced as just completed.
        if bridgeEnablement.isEnabled { model.bridgeDidChange(startBridge()) }
        #endif
        windowController = MainWindowController(model: model)
        statusMenu = StatusMenuController(model: model)
        #if !EVENTKIT_UI_REVIEW
        approvals.queueChanged = { [weak self] in self?.approvalPanel.update() }
        approvals.selectionChanged = { [weak self] in self?.approvalPanel.update() }
        model.showApprovals = { [weak self] in self?.approvalPanel.bringForward() }
        // If the listener didn't survive sleep, start it again.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.mcpShouldRun, !self.model.mcpIsListening else { return }
                self.model.retryMCPServer()
            }
        }
        #endif
        NSApp.mainMenu = MainMenu.build(target: self)
        #if EVENTKIT_UI_REVIEW
        review.run(model: model, window: windowController, statusMenu: statusMenu)
        #endif
        model.start()
        #if EVENTKIT_LIVE_TEST
        automation = LiveTestAutomation(context: .init(
            model: model, approvals: approvals, store: store,
            presentWindow: { [weak self] in self?.windowController.present() },
            mainWindow: { [weak self] in self?.windowController.window },
            panelWindow: { [weak self] in self?.approvalPanel.window },
            moveToApplications: { [weak self] in
                if case .failed(let problem) = AppMover.move(prepareToQuit: { self?.quitAfterApprovals() }) {
                    return problem
                }
                return nil
            }), dataFolder: Self.dataFolder)
        automation?.start()
        #endif
        #if !EVENTKIT_UI_REVIEW
        // A first run opens the window so the setup checklist is the first thing
        // seen; so does the first run after the rename.
        if model.showsSetupChecklist || model.renameNoticePending { windowController.present() }
        if let movedFrom = AppMover.movedFrom() {
            windowController.present()
            model.didMove(from: movedFrom)
            if InstallLocation.volume(of: movedFrom) == nil {
                AppMover.cleanUpOldCopy(movedFrom) { [weak self] trashed in
                    self?.model.didMove(from: movedFrom, trashed: trashed)
                }
            }
        } else if !AppIdentity.isLiveTest || CommandLine.arguments.contains("--move-prompt") {
            // The live-test copy is moved by its automation instead.
            model.offerMoveToApplications()
        }
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowController.present()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model?.hasUnsavedChanges == true else { return .terminateNow }
        // The prompt can finish synchronously (an app-modal alert), so reply
        // only after this method has returned .terminateLater.
        model.confirmUnsaved({ DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) } },
                             cancelled: { DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: false) } })
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        Pasteboard.clearSecret()
        #if !EVENTKIT_UI_REVIEW
        // Waiting changes are refused, and the endpoint file goes away.
        approvals.shutDown()
        mcpService.stop()
        remoteService.stop()
        keepAwake.set(false)
        #endif
        localBridge?.stop()
        localBridge = nil
        #if EVENTKIT_UI_REVIEW
        review.cleanup()
        #endif
    }

    // MARK: Live services

    #if !EVENTKIT_UI_REVIEW
    private static var dataFolder: URL {
        AppIdentity.dataFolder(
            inSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
    }

    private func liveServices() -> BridgeServices {
        BridgeServices(
            registry: clientRegistry,
            credentialFiles: ClientCredentialFiles(),
            defaults: .standard,
            dataFolder: Self.dataFolder,
            store: store,
            authorizationStatus: { EKEventStore.authorizationStatus(for: $0) },
            requestFullAccess: { [weak self] type, completion in
                guard let store = self?.store else { return }
                let finish: @Sendable (Bool, Error?) -> Void = { granted, error in
                    DispatchQueue.main.async {
                        // A store created before access was granted can keep an empty source list.
                        if granted { self?.store.reset() }
                        completion(granted, error)
                    }
                }
                if type == .event {
                    store.requestFullAccessToEvents(completion: finish)
                } else {
                    store.requestFullAccessToReminders(completion: finish)
                }
            },
            collections: { [weak self] in self?.liveCollections() ?? [] },
            setBridge: { [weak self] on in self?.setBridge(on) ?? .off },
            loginItemStatus: { AppIdentity.isLiveTest ? .notRegistered : SMAppService.mainApp.status },
            setLoginItem: { on in
                // The live-test copy never registers itself as a login item.
                guard !AppIdentity.isLiveTest else { throw LiveTestUnavailable() }
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            },
            isInstalledInApplications: { Self.installedLocation },
            installLocation: { AppMover.location },
            moveToApplications: { [weak self] in
                AppMover.move(prepareToQuit: { self?.quitAfterApprovals() })
            },
            commandLineTool: CommandLineTool(appURL: Bundle.main.bundleURL,
                                             home: FileManager.default.homeDirectoryForCurrentUser),
            testCollections: testCollections,
            mcp: MCPControls(
                start: { [weak self] port in self?.mcpService.start(port: port) },
                stop: { [weak self] in self?.mcpService.stop() },
                counters: { [weak self] in self?.mcpCounters.snapshot ?? .init() },
                launcherURL: Bundle.main.bundleURL
                    .appendingPathComponent("Contents/MacOS/\(AppIdentity.launcherName)"),
                portIsFree: { PortProbe.isFree($0) }),
            approvals: approvals,
            remote: RemoteControls(
                start: { [weak self] in self?.remoteService.start($0) },
                update: { [weak self] in self?.remoteService.update($0) },
                stop: { [weak self] in self?.remoteService.stop() },
                test: { [weak self] configuration, completion in
                    guard let self else { return }
                    RemoteProbe.test(configuration, nonces: self.remoteService.nonces, completion: completion)
                },
                portIsFree: { PortProbe.isFree($0) },
                setKeepAwake: { [weak self] in self?.keepAwake.set($0) },
                onACPower: { KeepAwake.onACPower },
                oauth: oauth),
            updater: updater.controls,
            installedAgents: { [weak self] in self?.installedAgents.current() ?? [] },
            agentSetup: Self.agentSetup,
            itemLookup: { [weak self] ref in self.map { ItemLookup.snapshot(ref, store: $0.store) } },
            showItem: { ItemLookup.show($0) })
    }

    private lazy var installedAgents: InstalledAgentsCache = {
        let cache = InstalledAgentsCache()
        cache.changed = { [weak self] in self?.model.scheduleRefresh(collections: true) }
        return cache
    }()

    private func liveCollections() -> [CollectionInfo] {
        var result = [CollectionInfo]()
        for (type, resource) in [(EKEntityType.event, ClientResource.calendar), (.reminder, .reminderList)]
        where EKEventStore.authorizationStatus(for: type) == .fullAccess {
            result += store.calendars(for: type).map { calendar in
                let color = calendar.color.usingColorSpace(.sRGB).map {
                    CollectionColor(red: Double($0.redComponent), green: Double($0.greenComponent),
                                    blue: Double($0.blueComponent))
                }
                return CollectionInfo(resource: resource, id: calendar.calendarIdentifier,
                                      name: calendar.title, account: calendar.source.title,
                                      writable: calendar.allowsContentModifications, color: color)
            }
        }
        return result.sortedForDisplay()
    }

    private static var installedLocation: Bool { AppMover.location == .applications }

    /// One-click setup. The live-test copy writes only into a scratch home
    /// (EKB_AGENT_HOME) and runs Claude Code only with its own config folder
    /// (CLAUDE_CONFIG_DIR), so a live test can never change the owner's agents.
    private static var agentSetup: AgentSetupControls {
        #if EVENTKIT_LIVE_TEST
        let environment = ProcessInfo.processInfo.environment
        guard let home = environment["EKB_AGENT_HOME"], home.hasPrefix("/"), home != NSHomeDirectory() else {
            return .refusing(String(localized: "The test copy sets agents up only in a scratch home (EKB_AGENT_HOME)."))
        }
        let live = OneClickAgents.live(home: home)
        return AgentSetupControls(
            preview: { agent, context, done in
                guard agent != .claudeCode || environment["CLAUDE_CONFIG_DIR"]?.hasPrefix("/") == true else {
                    return done(.failure(OneClickFailure(message: "The test copy runs Claude Code only with CLAUDE_CONFIG_DIR set.")))
                }
                live.preview(agent, context, done)
            },
            apply: live.apply, restart: { _, done in done(false) })
        #else
        return OneClickAgents.live()
        #endif
    }

    private var quitGate: UpdateRelaunchGate?

    /// After Move to Applications: quits once changes waiting in the
    /// approval panel are answered or time out (as for updates).
    private func quitAfterApprovals() {
        let gate = UpdateRelaunchGate(pendingApprovals: { [weak self] in self?.approvals.pending.count ?? 0 },
                                      maximumWait: ApprovalCenter.timeout + 5)
        quitGate = gate
        if !gate.postpone({ NSApp.terminate(nil) }) { NSApp.terminate(nil) }
    }

    // MARK: Bridge

    private func setBridge(_ on: Bool) -> BridgeRunState {
        if on {
            let state = startBridge()
            if state == .on { bridgeEnablement.setEnabled(true) }
            return state
        }
        bridgeEnablement.setEnabled(false)
        localBridge?.stop()
        approvals.withdrawAll()
        return .off
    }

    private func startBridge() -> BridgeRunState {
        if localBridge != nil { return .on }
        guard clientRegistry.clients() != nil else { return .failed(BridgeErrorText.policyUnavailable) }
        do {
            localBridge = try LocalBridge(handle: { [weak self] envelope, completion in
                guard let self else { completion(["error": "app_unavailable"]); return }
                self.handleClient(envelope, completion: completion)
            }, onStop: { [weak self] in
                self?.localBridge = nil
                self?.approvals.withdrawAll()
                self?.model.bridgeDidChange(.off)
            })
            return .on
        } catch {
            return .failed(BridgeErrorText.describe(error))
        }
    }

    private func handleClient(_ envelope: ClientBridgeEnvelope,
                              completion: @escaping ([String: Any]) -> Void) {
        switch clientRegistry.authenticateSignature(
            clientID: envelope.clientID, signature: envelope.signature,
            signedPayload: envelope.signedPayload, command: envelope.request.command) {
        case .success(let id):
            pipeline.handle(envelope.request, clientID: id, origin: .cli, completion: completion)
        case .failure(let error):
            model.scheduleRefresh()
            completion(["error": error.rawValue])
        }
    }
    #endif

    // MARK: Main menu actions

    @objc func newClient(_ sender: Any?) { model.beginNewClient() }
    @objc func openMainWindow(_ sender: Any?) { windowController.present() }
    @objc func showSettingsPane(_ sender: Any?) { model.show(.settings) }
    @objc func showOverviewPane(_ sender: Any?) { model.show(.overview) }
    @objc func showActivityPane(_ sender: Any?) { model.show(.activity) }
    @objc func findInActivity(_ sender: Any?) { model.focusActivitySearch() }
    @objc func previousTab(_ sender: Any?) { model.stepClientTab(-1) }
    @objc func nextTab(_ sender: Any?) { model.stepClientTab(1) }
    @objc func saveAccess(_ sender: Any?) { model.saveDraft() }
    @objc func revertAccess(_ sender: Any?) { model.revertDraft() }
    @objc func showSetupChecklist(_ sender: Any?) { model.showSetupAgain() }
    @objc func checkForUpdates(_ sender: Any?) { model.checkForUpdates() }
    @objc func openLink(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { NSWorkspace.shared.open(url) }
    }
    @objc func showAbout(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: AppIdentity.displayName,
            .credits: NSAttributedString(string: String(localized: "Scoped Calendar and Reminders access for tools on your Mac.\nLicensed under the Apache License 2.0. Not affiliated with Apple.\nUpdates by Sparkle (MIT License).")),
        ])
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(newClient(_:)): model.canCreateClient
        case #selector(saveAccess(_:)), #selector(revertAccess(_:)): model.hasUnsavedChanges
        case #selector(showSetupChecklist(_:)): model.canShowSetupAgain
        case #selector(checkForUpdates(_:)): model.updaterAvailable
        case #selector(findInActivity(_:)): model.windowIsVisible()
        case #selector(previousTab(_:)), #selector(nextTab(_:)): model.canStepClientTab
        default: true
        }
    }
}

/// Finds installed agents (B04) off the main thread, at most once a minute;
/// the model reads the last answer on each full refresh.
@MainActor
final class InstalledAgentsCache {
    private var value = Set<AgentKind>()
    private var checkedAt: Date?
    private var running = false
    var changed: () -> Void = {}

    func current() -> Set<AgentKind> {
        if !running, checkedAt.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
            running = true
            DispatchQueue.global(qos: .utility).async {
                let probe = AgentProbe(
                    appURL: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
                    fileExists: { FileManager.default.fileExists(atPath: $0) },
                    home: NSHomeDirectory())
                let found = AgentDetection.installed(probe)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.running = false
                        self.checkedAt = Date()
                        guard found != self.value else { return }
                        self.value = found
                        self.changed()
                    }
                }
            }
        }
        return value
    }
}

/// Start at login in the live-test copy.
struct LiveTestUnavailable: LocalizedError {
    var errorDescription: String? { String(localized: "Not available in the test copy.") }
}

enum MainMenu {
    @MainActor
    static func build(target: BridgeAppDelegate) -> NSMenu {
        let main = NSMenu()
        let name = AppIdentity.displayName

        let app = submenu(name, in: main)
        app.addItem(item(String(localized: "About \(name)"), #selector(BridgeAppDelegate.showAbout(_:)), target: target))
        app.addItem(item(String(localized: "Check for Updates…"), #selector(BridgeAppDelegate.checkForUpdates(_:)), target: target))
        app.addItem(.separator())
        app.addItem(item(String(localized: "Settings…"), #selector(BridgeAppDelegate.showSettingsPane(_:)), ",", target: target))
        app.addItem(.separator())
        app.addItem(item(String(localized: "Hide \(name)"), #selector(NSApplication.hide(_:)), "h"))
        let others = item(String(localized: "Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(others)
        app.addItem(item(String(localized: "Show All"), #selector(NSApplication.unhideAllApplications(_:))))
        app.addItem(.separator())
        app.addItem(item(String(localized: "Quit \(name)"), #selector(NSApplication.terminate(_:)), "q"))

        let file = submenu(String(localized: "File"), in: main)
        file.addItem(item(String(localized: "Add a Connection…"), #selector(BridgeAppDelegate.newClient(_:)), "n", target: target))
        file.addItem(.separator())
        file.addItem(item(String(localized: "Save Access"), #selector(BridgeAppDelegate.saveAccess(_:)), "s", target: target))
        file.addItem(item(String(localized: "Revert Access"), #selector(BridgeAppDelegate.revertAccess(_:)), target: target))
        file.addItem(.separator())
        file.addItem(item(String(localized: "Close Window"), #selector(NSWindow.performClose(_:)), "w"))

        let edit = submenu(String(localized: "Edit"), in: main)
        edit.addItem(item(String(localized: "Undo"), Selector(("undo:")), "z"))
        let redo = item(String(localized: "Redo"), Selector(("redo:")), "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(item(String(localized: "Cut"), #selector(NSText.cut(_:)), "x"))
        edit.addItem(item(String(localized: "Copy"), #selector(NSText.copy(_:)), "c"))
        edit.addItem(item(String(localized: "Paste"), #selector(NSText.paste(_:)), "v"))
        edit.addItem(item(String(localized: "Select All"), #selector(NSText.selectAll(_:)), "a"))
        edit.addItem(.separator())
        edit.addItem(item(String(localized: "Find…"), #selector(BridgeAppDelegate.findInActivity(_:)), "f", target: target))

        let view = submenu(String(localized: "View"), in: main)
        view.addItem(item(String(localized: "Overview"), #selector(BridgeAppDelegate.showOverviewPane(_:)), "1", target: target))
        view.addItem(item(String(localized: "Activity"), #selector(BridgeAppDelegate.showActivityPane(_:)), "2", target: target))
        view.addItem(item(String(localized: "Settings"), #selector(BridgeAppDelegate.showSettingsPane(_:)), "3", target: target))
        view.addItem(.separator())
        for (title, selector, arrow) in [
            (String(localized: "Previous Tab"), #selector(BridgeAppDelegate.previousTab(_:)), NSLeftArrowFunctionKey),
            (String(localized: "Next Tab"), #selector(BridgeAppDelegate.nextTab(_:)), NSRightArrowFunctionKey),
        ] {
            let tab = item(title, selector, String(Character(UnicodeScalar(arrow)!)), target: target)
            tab.keyEquivalentModifierMask = [.command, .option]
            view.addItem(tab)
        }

        let window = submenu(String(localized: "Window"), in: main)
        window.addItem(item(String(localized: "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item(String(localized: "Zoom"), #selector(NSWindow.performZoom(_:))))
        window.addItem(.separator())
        window.addItem(item(String(localized: "Open \(name)"), #selector(BridgeAppDelegate.openMainWindow(_:)), "o", target: target))
        window.addItem(item(String(localized: "Bring All to Front"), #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = window

        let help = submenu(String(localized: "Help"), in: main)
        for group in [AppLinks.documentation, AppLinks.community] {
            for link in group {
                let entry = item(link.title, #selector(BridgeAppDelegate.openLink(_:)), target: target)
                entry.representedObject = link.url
                help.addItem(entry)
            }
            help.addItem(.separator())
        }
        help.addItem(item(String(localized: "Show Setup Checklist"), #selector(BridgeAppDelegate.showSetupChecklist(_:)), target: target))
        NSApp.helpMenu = help
        return main
    }

    private static func submenu(_ title: String, in main: NSMenu) -> NSMenu {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        holder.submenu = menu
        main.addItem(holder)
        return menu
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "",
                             target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }
}

@main
struct EKBridgeApp {
    static func main() {
        #if EVENTKIT_SYNTHETIC_TEST
        if CommandLine.arguments.count > 1 {
            _ = NSApplication.shared
            SyntheticTestMode.run(CommandLine.arguments[1])
            return
        }
        #endif
        let app = NSApplication.shared
        #if !EVENTKIT_UI_REVIEW
        // Relaunched by Move to Applications: let the old copy quit first.
        AppMover.waitForPreviousCopy()
        #endif
        #if EVENTKIT_LIVE_TEST
        // The live-test copy refuses to run with any of the installed app's
        // identities, so it can never share its data, transport or ports.
        let collisions = LiveTestIsolation.collisions(.current, runningBundleID: Bundle.main.bundleIdentifier)
        if !collisions.isEmpty {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = String(localized: "\(AppIdentity.displayName) can't start.")
            alert.informativeText = String(localized: "Its \(collisions.joined(separator: ", ")) would be the same as EK Bridge's. Rebuild it with scripts/live_test.sh build.")
            alert.runModal()
            exit(1)
        }
        #endif
        #if !EVENTKIT_UI_REVIEW && !EVENTKIT_UPDATE_TEST && !EVENTKIT_LIVE_TEST
        // Before anything reads settings or the data folder. (The test copies
        // have their own bundle ID and data folder, and nothing to migrate.)
        RenameMigrationLaunch.run()
        #endif
        let delegate = BridgeAppDelegate()
        app.delegate = delegate
        #if EVENTKIT_UI_REVIEW
        app.setActivationPolicy(.accessory)
        #else
        // "Always" must be in place before the first window shows, to avoid a Dock bounce.
        let mode = DockIconMode(rawValue: UserDefaults.standard.string(forKey: "DockIconMode") ?? "")
        app.setActivationPolicy(mode == .always ? .regular : .accessory)
        #endif
        app.run()
    }
}

#if !EVENTKIT_UI_REVIEW
/// Runs `RenameMigration` on the first launch under the new name. The old app
/// uses the same data folder (through the link), so it must never run at the
/// same time: it has to quit before the migration and before every later
/// launch, and if it starts while this app runs (its own Start at login), the
/// user chooses which one keeps running.
@MainActor
enum RenameMigrationLaunch {
    private static var launchObserver: NSObjectProtocol?

    static func run() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let migration = RenameMigration(defaults: .standard,
                                        legacyDefaults: UserDefaults(suiteName: LegacyIdentity.bundleID),
                                        support: support)
        guard quitOldApp(beforeMigration: migration.isPending) else { exit(0) }
        if case .failed(let problem) = migration.run() {
            _ = alert(String(localized: "\(AppIdentity.displayName) couldn't move its data folder."), problem,
                      buttons: [String(localized: "Quit")])
            exit(1)
        }
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
            let launched = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard launched?.bundleIdentifier == LegacyIdentity.bundleID else { return }
            MainActor.assumeIsolated {
                if !quitOldApp(beforeMigration: false) { NSApp.terminate(nil) }
            }
        }
    }

    /// Returns once no copy of the old app is running, or false when the user
    /// chose to quit this app instead. Asks once, then offers Force Quit if the
    /// old app doesn't quit within 10 seconds (it may be showing a question).
    private static func quitOldApp(beforeMigration: Bool) -> Bool {
        var asked = false
        while let old = NSRunningApplication.runningApplications(
            withBundleIdentifier: LegacyIdentity.bundleID).first(where: { !$0.isTerminated }) {
            if !asked {
                let message = beforeMigration
                    ? String(localized: "\(AppIdentity.displayName) is the new name of \(LegacyIdentity.displayName). Its settings, connections and Activity move over once the old app has quit.")
                    : String(localized: "\(AppIdentity.displayName) is the new name of \(LegacyIdentity.displayName), and the two share their data, so only one can run. Delete the old app so it doesn't start again.")
                guard alert(String(localized: "Quit \(LegacyIdentity.displayName) to continue"), message,
                            buttons: [String(localized: "Quit \(LegacyIdentity.displayName)"),
                                      String(localized: "Quit \(AppIdentity.displayName)")]) else { return false }
                asked = true
                old.terminate()
            } else {
                guard alert(String(localized: "\(LegacyIdentity.displayName) didn't quit."),
                            String(localized: "It may be waiting for an answer in its own window. Force it to quit (unsaved changes in it are lost), or quit \(AppIdentity.displayName) and try again later."),
                            buttons: [String(localized: "Force Quit \(LegacyIdentity.displayName)"),
                                      String(localized: "Quit \(AppIdentity.displayName)")]) else { return false }
                old.forceTerminate()
            }
            let deadline = Date().addingTimeInterval(10)
            while !old.isTerminated && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
        }
        return true
    }

    /// True for the first button.
    private static func alert(_ title: String, _ message: String, buttons: [String]) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        for button in buttons { alert.addButton(withTitle: button) }
        return alert.runModal() == .alertFirstButtonReturn
    }
}
#endif
