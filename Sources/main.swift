import AppKit
import EventKit
import ServiceManagement

@MainActor
final class BridgeAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private let eventStatus = NSTextField(labelWithString: "")
    private let reminderStatus = NSTextField(labelWithString: "")
    private let output = NSTextView()
    private var eventRequestButton: NSButton!
    private var reminderRequestButton: NSButton!
    private var eventListButton: NSButton!
    private var reminderListButton: NSButton!
    private var bridgeEnableButton: NSButton!
    private var bridgeDisableButton: NSButton!
    private let bridgeStatus = NSTextField(labelWithString: "Local bridge: off")
    private var localBridge: LocalBridge?
    private let bridgeEnablement = BridgeEnablement()
    private var requestInFlight = false
    private lazy var store = EKEventStore()
    private lazy var commands = EventKitCommands(store: store)
    private lazy var testCollections = TestCollections(store: store)
    private lazy var clientRegistry = ClientRegistry()
    private lazy var clientManager = ClientManagerUI(registry: clientRegistry, store: store)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "◷"
        refreshMenu()
        let content = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        let page = NSScrollView()
        page.hasVerticalScroller = true
        page.drawsBackground = false
        page.translatesAutoresizingMaskIntoConstraints = false
        let document = NSView()
        document.addSubview(stack)
        page.documentView = document
        content.addSubview(page)

        let title = NSTextField(labelWithString: "EventKit Bridge")
        title.font = .boldSystemFont(ofSize: 23)
        stack.addArrangedSubview(title)

        let explanation = NSTextField(wrappingLabelWithString:
            "Control which local clients can access your calendars and reminders. Permissions are saved per collection and can be changed or revoked at any time.")
        explanation.maximumNumberOfLines = 2
        explanation.textColor = .secondaryLabelColor
        stack.addArrangedSubview(explanation)

        let bridgeTitle = NSTextField(labelWithString: "Local bridge")
        bridgeTitle.font = .boldSystemFont(ofSize: 15)
        bridgeStatus.font = .systemFont(ofSize: 14, weight: .medium)
        eventRequestButton = button("Request Calendar Access", #selector(requestEvents))
        eventListButton = button("List Calendars", #selector(listEvents))
        reminderRequestButton = button("Request Reminders Access", #selector(requestReminders))
        reminderListButton = button("List Reminder Lists", #selector(listReminders))
        bridgeEnableButton = button("Enable Local Bridge", #selector(enableBridge))
        bridgeDisableButton = button("Disable", #selector(disableBridge))

        let bridgeActions = NSStackView(views: [bridgeEnableButton, bridgeDisableButton])
        bridgeActions.spacing = 10
        let bridgeHint = NSTextField(wrappingLabelWithString:
            "While active, enrolled clients can use only their saved permissions. The on/off choice is retained across app launches.")
        bridgeHint.textColor = .secondaryLabelColor
        bridgeHint.maximumNumberOfLines = 2
        stack.addArrangedSubview(card([bridgeTitle, bridgeStatus, bridgeActions, bridgeHint], width: 800))

        let clientsTitle = NSTextField(labelWithString: "Clients and permissions")
        clientsTitle.font = .boldSystemFont(ofSize: 15)
        let clientsHint = NSTextField(wrappingLabelWithString:
            "Review each client's calendars, reminder lists and allowed actions. Create a client, rotate its key or revoke it here.")
        clientsHint.textColor = .secondaryLabelColor
        clientsHint.maximumNumberOfLines = 2
        let manageButton = button("Open Clients & Permissions…", #selector(manageClients))
        stack.addArrangedSubview(card([clientsTitle, clientsHint, manageButton], width: 800))

        let accessTitle = NSTextField(labelWithString: "macOS access")
        accessTitle.font = .boldSystemFont(ofSize: 15)
        let eventActions = NSStackView(views: [eventRequestButton, eventListButton])
        eventActions.spacing = 10
        let reminderActions = NSStackView(views: [reminderRequestButton, reminderListButton])
        reminderActions.spacing = 10
        stack.addArrangedSubview(card([accessTitle, eventStatus, eventActions,
                                       reminderStatus, reminderActions], width: 800))

        let diagnosticsTitle = NSTextField(labelWithString: "Test collections")
        diagnosticsTitle.font = .boldSystemFont(ofSize: 15)
        let diagnosticsHint = NSTextField(wrappingLabelWithString:
            "These tools work only with the app's own temporary test calendar and reminder list.")
        diagnosticsHint.textColor = .secondaryLabelColor
        let diagnosticsActions = NSStackView(views: [
            button("Check Test Sources", #selector(checkTestSources)),
            button("Create Test Collections", #selector(createTestCollections)),
            button("Remove Empty Test Collections", #selector(removeTestCollections)),
        ])
        diagnosticsActions.spacing = 8
        stack.addArrangedSubview(card([diagnosticsTitle, diagnosticsHint, diagnosticsActions], width: 800))

        output.isEditable = false
        output.isSelectable = true
        output.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        output.string = "Collection details and test results appear here."
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = output
        stack.addArrangedSubview(scroll)

        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            page.topAnchor.constraint(equalTo: content.topAnchor),
            page.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            document.widthAnchor.constraint(equalTo: page.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 105),
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 850, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "EventKit Bridge"
        window.contentView = content
        window.center()
        self.window = window
        refreshStatus()
        refreshBridgeStatus()
        if bridgeEnablement.isEnabled { startBridge() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        localBridge?.stop()
        localBridge = nil
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func card(_ views: [NSView], width: CGFloat) -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.borderColor = .separatorColor
        box.borderWidth = 1
        box.cornerRadius = 9
        box.contentViewMargins = NSSize(width: 16, height: 13)
        let contents = NSStackView(views: views)
        contents.orientation = .vertical
        contents.alignment = .leading
        contents.spacing = 9
        box.contentView = contents
        box.widthAnchor.constraint(equalToConstant: width).isActive = true
        return box
    }

    private func refreshStatus() {
        let events = EKEventStore.authorizationStatus(for: .event)
        let reminders = EKEventStore.authorizationStatus(for: .reminder)
        eventStatus.stringValue = "Calendar access: \(name(events))"
        reminderStatus.stringValue = "Reminders access: \(name(reminders))"
        eventRequestButton.isEnabled = !requestInFlight && events == .notDetermined
        reminderRequestButton.isEnabled = !requestInFlight && reminders == .notDetermined
        eventListButton.isEnabled = !requestInFlight && events == .fullAccess
        reminderListButton.isEnabled = !requestInFlight && reminders == .fullAccess
        refreshMenu()
    }

    private func name(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "Not determined"
        case .restricted: "Restricted"
        case .denied: "Denied"
        case .fullAccess: "Full access"
        case .writeOnly: "Write only"
        @unknown default: "Unknown"
        }
    }

    @objc private func requestEvents(_ sender: Any?) {
        guard EKEventStore.authorizationStatus(for: .event) == .notDetermined else { return }
        requestInFlight = true
        refreshStatus()
        store.requestFullAccessToEvents { [weak self] granted, error in
            let errorCode = error.map { "\(($0 as NSError).domain) \(($0 as NSError).code)" }
            DispatchQueue.main.async { [weak self] in
                self?.finishRequest("Calendar", granted: granted, errorCode: errorCode)
            }
        }
    }

    @objc private func requestReminders(_ sender: Any?) {
        guard EKEventStore.authorizationStatus(for: .reminder) == .notDetermined else { return }
        requestInFlight = true
        refreshStatus()
        store.requestFullAccessToReminders { [weak self] granted, error in
            let errorCode = error.map { "\(($0 as NSError).domain) \(($0 as NSError).code)" }
            DispatchQueue.main.async { [weak self] in
                self?.finishRequest("Reminders", granted: granted, errorCode: errorCode)
            }
        }
    }

    private func finishRequest(_ kind: String, granted: Bool, errorCode: String?) {
        requestInFlight = false
        refreshStatus()
        if let errorCode {
            output.string = "\(kind) request failed: \(errorCode)"
        } else {
            output.string = "\(kind) request \(granted ? "granted" : "not granted"). No items were read."
        }
    }

    @objc private func listEvents(_ sender: Any?) {
        list(.event, label: "Calendars")
    }

    @objc private func listReminders(_ sender: Any?) {
        list(.reminder, label: "Reminder lists")
    }

    private func list(_ entity: EKEntityType, label: String) {
        guard EKEventStore.authorizationStatus(for: entity) == .fullAccess else {
            output.string = "Full access is required to list \(label.lowercased())."
            refreshStatus()
            return
        }
        let calendars = store.calendars(for: entity)
        let rows = calendars.map { calendar in
            let writable = calendar.allowsContentModifications ? "writable" : "read only"
            return "\(String(reflecting: calendar.title))\t\(calendar.calendarIdentifier)\t\(writable)"
        }
        output.string = "\(label) (\(rows.count))\nTitle\tID\tAccess\n" + rows.joined(separator: "\n")
    }

    @objc private func enableBridge(_ sender: Any?) {
        startBridge()
        if localBridge != nil { bridgeEnablement.setEnabled(true) }
    }

    private func startBridge() {
        guard localBridge == nil else { return }
        guard clientRegistry.clients() != nil else {
            bridgeStatus.stringValue = "Local bridge: client policy store unavailable"
            return
        }
        do {
            localBridge = try LocalBridge(handle: { [weak self] envelope, completion in
                guard let self else { completion(["error": "app_unavailable"]); return }
                self.handleClient(envelope, completion: completion)
            }, onStop: { [weak self] in
                self?.localBridge = nil
                self?.refreshBridgeStatus()
            })
            refreshBridgeStatus()
        } catch {
            bridgeStatus.stringValue = "Local bridge: could not start (\(error))"
        }
    }

    @objc private func disableBridge(_ sender: Any?) {
        bridgeEnablement.setEnabled(false)
        localBridge?.stop()
    }

    @objc private func manageClients(_ sender: Any?) {
        clientManager.show(
            bridgeIsActive: { [weak self] in self?.localBridge?.active == true },
            enableBridge: { [weak self] in
                self?.enableBridge(nil)
                return self?.localBridge?.active == true
            },
            disableBridge: { [weak self] in self?.disableBridge(nil) })
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
        case .authorizationStatus:
            commands.runAuthorized(request, selected: selected,
                                   stillAuthorized: { [weak self] in
                guard let self else { return false }
                return self.clientRegistry.stillAuthorized(call) && self.localBridge?.active == true
            }) { [weak self] value in
                self?.finishClient(call, value, completion)
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
        completion(value)
    }

    private func refreshBridgeStatus() {
        bridgeStatus.stringValue = localBridge == nil ? "Local bridge: off" : "Local bridge: active"
        bridgeEnableButton.isEnabled = localBridge == nil
        bridgeDisableButton.isEnabled = localBridge != nil
        refreshMenu()
    }

    private func refreshMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()
        let calendar = name(EKEventStore.authorizationStatus(for: .event))
        let reminders = name(EKEventStore.authorizationStatus(for: .reminder))
        let bridgeLine = localBridge == nil ? "Bridge: off" : "Bridge: active"
        let loginStatus: String
        switch SMAppService.mainApp.status {
        case .enabled: loginStatus = "enabled"
        case .requiresApproval: loginStatus = "needs System Settings approval"
        case .notFound: loginStatus = "app unavailable"
        case .notRegistered: loginStatus = "off"
        @unknown default: loginStatus = "unknown"
        }
        let clientCount = clientRegistry.clients()?.filter { !$0.revoked }.count
        for line in ["Calendar: \(calendar)", "Reminders: \(reminders)",
                     bridgeLine,
                     "Active clients: \(clientCount.map(String.init) ?? "policy unavailable")",
                     "Actions: saved client grants", "Login: \(loginStatus)"] {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Controls…", action: #selector(openControls), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: localBridge == nil ? "Enable Local Bridge" : "Disable Bridge",
                                action: localBridge == nil ? #selector(enableBridge) : #selector(disableBridge),
                                keyEquivalent: ""))
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.isEnabled = installedLocation &&
            SMAppService.mainApp.status != .requiresApproval &&
            SMAppService.mainApp.status != .notFound
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items where item.action != nil { item.target = self }
        statusItem.menu = menu
    }

    private var installedLocation: Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        let userApps = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true).path
        return path.hasPrefix("/Applications/") || path.hasPrefix(userApps + "/")
    }
    @objc private func openControls(_ sender: Any?) {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func checkTestSources(_ sender: Any?) {
        output.string = testCollections.sourcePreview()
    }
    @objc private func createTestCollections(_ sender: Any?) {
        output.string = testCollections.create()
    }
    @objc private func removeTestCollections(_ sender: Any?) {
        testCollections.removeEmpty { [weak self] message in
            guard let self else { return }
            self.output.string = message
        }
    }
    @objc private func toggleLoginItem(_ sender: Any?) {
        guard installedLocation else {
            output.string = "Install the reviewed signed app in Applications before enabling login startup."
            openControls(nil)
            return
        }
        guard SMAppService.mainApp.status != .requiresApproval else {
            output.string = "Approve the login item in System Settings, then check its status here."
            openControls(nil)
            return
        }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            refreshMenu()
        } catch {
            output.string = "Login item update failed: \((error as NSError).domain) \((error as NSError).code)"
            openControls(nil)
        }
    }
    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
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
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
