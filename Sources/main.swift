import AppKit
import EventKit
import ServiceManagement

enum BridgeErrorText {
    static func describe(_ error: Error) -> String {
        switch error as? BridgeIOError {
        case .alreadyActive?:
            String(localized: "Another copy of \(AppIdentity.displayName) is already running.")
        case .unsafePath?:
            String(localized: "The bridge's folder in /tmp has unsafe permissions. Quit other copies and try again.")
        case .directoryFailed?, .writeFailed?:
            String(localized: "The bridge couldn't create its working folder.")
        case nil:
            String(localized: "Something unexpected stopped it.")
        }
    }

    static let policyUnavailable = String(localized: "Client settings can't be read.")
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
    private lazy var clientRegistry = ClientRegistry()
    #endif
    private var model: BridgeAppModel!
    private var windowController: MainWindowController!
    private var statusMenu: StatusMenuController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if EVENTKIT_UI_REVIEW
        model = BridgeAppModel(services: review.services())
        #else
        model = BridgeAppModel(services: liveServices())
        #endif
        #if !EVENTKIT_UI_REVIEW
        // Before start(), so a working setup isn't announced as just completed.
        if bridgeEnablement.isEnabled { model.bridgeDidChange(startBridge()) }
        #endif
        windowController = MainWindowController(model: model)
        statusMenu = StatusMenuController(model: model)
        NSApp.mainMenu = MainMenu.build(target: self)
        #if EVENTKIT_UI_REVIEW
        review.run(model: model, window: windowController, statusMenu: statusMenu)
        #endif
        model.start()
        #if !EVENTKIT_UI_REVIEW
        // A first run opens the window so the setup checklist is the first thing seen.
        if model.showsSetupChecklist { windowController.present() }
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
        model.confirmUnsaved({ sender.reply(toApplicationShouldTerminate: true) },
                             cancelled: { sender.reply(toApplicationShouldTerminate: false) })
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        localBridge?.stop()
        localBridge = nil
        #if EVENTKIT_UI_REVIEW
        review.cleanup()
        #endif
    }

    // MARK: Live services

    #if !EVENTKIT_UI_REVIEW
    private func liveServices() -> BridgeServices {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return BridgeServices(
            registry: clientRegistry,
            credentialFiles: ClientCredentialFiles(),
            defaults: .standard,
            dataFolder: support.appendingPathComponent(AppIdentity.dataFolderName, isDirectory: true),
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
            loginItemStatus: { SMAppService.mainApp.status },
            setLoginItem: { on in
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            },
            isInstalledInApplications: { Self.installedLocation },
            testCollections: testCollections)
    }

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

    private static var installedLocation: Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        let userApps = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true).path
        return path.hasPrefix("/Applications/") || path.hasPrefix(userApps + "/")
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
                self?.model.bridgeDidChange(.off)
            })
            return .on
        } catch {
            return .failed(BridgeErrorText.describe(error))
        }
    }

    private func handleClient(_ envelope: ClientBridgeEnvelope,
                              completion: @escaping ([String: Any]) -> Void) {
        let request = envelope.request
        let checked = clientRegistry.authorize(
            clientID: envelope.clientID, signature: envelope.signature,
            signedPayload: envelope.signedPayload, request: request)
        guard case .success(let call) = checked else {
            let error: String
            if case .failure(let reason) = checked { error = reason.rawValue }
            else { error = "unauthorized" }
            model.scheduleRefresh()
            completion(["error": error])
            return
        }
        let selected = BridgeScope(
            calendarID: call.grant?.resource == .calendar ? call.targetID : nil,
            reminderListID: call.grant?.resource == .reminderList ? call.targetID : nil,
            generation: call.revision)
        if let error = CommandPolicy.validate(request, scope: selected) {
            finishClient(call, ["error": error], completion)
            return
        }
        guard clientRegistry.stillAuthorized(call), localBridge?.active == true else {
            finishClient(call, ["error": "scope_changed"], completion)
            return
        }
        switch request.command {
        case .scopeStatus, .calendarCount, .reminderListCount:
            guard let client = clientRegistry.clients()?.first(where: { $0.id == call.clientID }) else {
                finishClient(call, ["error": "client_unavailable"], completion)
                return
            }
            let grants = client.grants
            if request.command == .scopeStatus {
                let rows = grants.map { grant -> [String: Any] in
                    ["resource": grant.resource.rawValue,
                     "targetID": grant.targetID, "mask": grant.mask]
                }
                finishClient(call, ["grants": rows], completion)
            } else {
                let type: EKEntityType = request.command == .calendarCount ? .event : .reminder
                guard EKEventStore.authorizationStatus(for: type) == .fullAccess else {
                    finishClient(call, ["error": "full_access_required"], completion)
                    return
                }
                let resource: ClientResource = type == .event ? .calendar : .reminderList
                let allowed = Set(grants.filter { $0.resource == resource }.map(\.targetID))
                let count = store.calendars(for: type).filter {
                    allowed.contains($0.calendarIdentifier)
                }.count
                finishClient(call, ["count": count], completion)
            }
        default:
            commands.runAuthorized(request, selected: selected,
                                   stillAuthorized: { [weak self] in
                guard let self else { return false }
                return self.clientRegistry.stillAuthorized(call) && self.localBridge?.active == true
            }) { [weak self] value in
                self?.finishClient(call, value, completion)
            }
        }
    }

    private func finishClient(_ call: AuthorizedClientCall, _ value: [String: Any],
                              _ completion: ([String: Any]) -> Void) {
        let outcome = (value["error"] as? String).map { "error:\($0)" } ?? "success"
        guard clientRegistry.recordResult(call, outcome: outcome) else {
            completion(["error": "activity_unavailable"])
            return
        }
        model.scheduleRefresh()
        completion(value)
    }
    #endif

    // MARK: Main menu actions

    @objc func newClient(_ sender: Any?) { model.beginNewClient() }
    @objc func openMainWindow(_ sender: Any?) { windowController.present() }
    @objc func showSettingsPane(_ sender: Any?) { model.show(.settings) }
    @objc func showOverviewPane(_ sender: Any?) { model.show(.overview) }
    @objc func showActivityPane(_ sender: Any?) { model.show(.activity) }
    @objc func saveAccess(_ sender: Any?) { model.saveDraft() }
    @objc func revertAccess(_ sender: Any?) { model.revertDraft() }
    @objc func showSetupChecklist(_ sender: Any?) { model.showSetupAgain() }
    @objc func showAbout(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: AppIdentity.displayName,
            .credits: NSAttributedString(string: String(localized: "Scoped Calendar and Reminders access for tools on your Mac.")),
        ])
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(newClient(_:)): model.canCreateClient
        case #selector(saveAccess(_:)), #selector(revertAccess(_:)): model.hasUnsavedChanges
        case #selector(showSetupChecklist(_:)): !model.showsSetupChecklist
        default: true
        }
    }
}

enum MainMenu {
    @MainActor
    static func build(target: BridgeAppDelegate) -> NSMenu {
        let main = NSMenu()
        let name = AppIdentity.displayName

        let app = submenu(name, in: main)
        app.addItem(item(String(localized: "About \(name)"), #selector(BridgeAppDelegate.showAbout(_:)), target: target))
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
        file.addItem(item(String(localized: "New Client…"), #selector(BridgeAppDelegate.newClient(_:)), "n", target: target))
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

        let view = submenu(String(localized: "View"), in: main)
        view.addItem(item(String(localized: "Overview"), #selector(BridgeAppDelegate.showOverviewPane(_:)), "1", target: target))
        view.addItem(item(String(localized: "Activity"), #selector(BridgeAppDelegate.showActivityPane(_:)), "2", target: target))

        let window = submenu(String(localized: "Window"), in: main)
        window.addItem(item(String(localized: "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item(String(localized: "Zoom"), #selector(NSWindow.performZoom(_:))))
        window.addItem(.separator())
        window.addItem(item(String(localized: "Open \(name)"), #selector(BridgeAppDelegate.openMainWindow(_:)), "o", target: target))
        window.addItem(item(String(localized: "Bring All to Front"), #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = window

        let help = submenu(String(localized: "Help"), in: main)
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
struct EventKitBridgeApp {
    static func main() {
        #if EVENTKIT_SYNTHETIC_TEST
        if CommandLine.arguments.count > 1 {
            _ = NSApplication.shared
            SyntheticTestMode.run(CommandLine.arguments[1])
            return
        }
        #endif
        let app = NSApplication.shared
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
