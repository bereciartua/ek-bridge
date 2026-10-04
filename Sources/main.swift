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
    private let targetStatus = NSTextField(labelWithString: "Item targets: none selected")
    private var armWritesButton: NSButton!
    private var localBridge: LocalBridge?
    private var requestInFlight = false
    private lazy var store = EKEventStore()
    private lazy var commands = EventKitCommands(store: store)
    private lazy var testCollections = TestCollections(store: store)
    private lazy var clientRegistry = ClientRegistry()
    private lazy var clientManager = ClientManagerUI(registry: clientRegistry, store: store)
    private let approvalGate = ExactActionApproval()
    private let approvalUI = ExactActionApprovalUI()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "◷"
        refreshMenu()
        let content = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        let title = NSTextField(labelWithString: "EventKit Bridge")
        title.font = .boldSystemFont(ofSize: 19)
        stack.addArrangedSubview(title)

        let explanation = NSTextField(wrappingLabelWithString:
            "Create named local clients and grant actions on individual calendars and reminder lists. The bridge is off until enabled here. Every write needs an exact on-screen approval.")
        explanation.maximumNumberOfLines = 3
        stack.addArrangedSubview(explanation)

        stack.addArrangedSubview(eventStatus)
        eventRequestButton = button("Request Calendar Access", #selector(requestEvents))
        eventListButton = button("List Calendars", #selector(listEvents))
        stack.addArrangedSubview(NSStackView(views: [eventRequestButton, eventListButton]))

        stack.addArrangedSubview(reminderStatus)
        reminderRequestButton = button("Request Reminders Access", #selector(requestReminders))
        reminderListButton = button("List Reminder Lists", #selector(listReminders))
        stack.addArrangedSubview(NSStackView(views: [reminderRequestButton, reminderListButton]))

        let bridgeTitle = NSTextField(labelWithString: "Temporary local bridge")
        bridgeTitle.font = .boldSystemFont(ofSize: 14)
        stack.addArrangedSubview(bridgeTitle)
        stack.addArrangedSubview(bridgeStatus)
        bridgeEnableButton = button("Enable for 15 Minutes", #selector(enableBridge))
        bridgeDisableButton = button("Disable", #selector(disableBridge))
        stack.addArrangedSubview(NSStackView(views: [bridgeEnableButton, bridgeDisableButton]))
        stack.addArrangedSubview(button("Manage Clients…", #selector(manageClients)))
        stack.addArrangedSubview(NSStackView(views: [
            button("Check Test Sources", #selector(checkTestSources)),
            button("Create Test Collections", #selector(createTestCollections)),
            button("Remove Empty Test Collections", #selector(removeTestCollections)),
        ]))
        armWritesButton = NSButton(checkboxWithTitle: "Per-action approval", target: nil, action: nil)
        armWritesButton.isEnabled = false

        let hint = NSTextField(wrappingLabelWithString:
            "Local only. Sessions expire after 15 minutes. A login launch starts with bridge off. Stored client grants do not turn the bridge on; writes need individual approval.")
        hint.textColor = .secondaryLabelColor
        hint.maximumNumberOfLines = 3
        stack.addArrangedSubview(hint)

        output.isEditable = false
        output.isSelectable = true
        output.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        output.string = "Choose a List button after granting access."
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = output
        stack.addArrangedSubview(scroll)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 610),
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
        refreshTargetStatus()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        approvalGate.cancelAll()
        localBridge?.stop()
        localBridge = nil
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
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
                self?.approvalGate.cancelAll()
                self?.commands.scope.writesArmed = false
                self?.commands.scope.generation += 1
                self?.armWritesButton.state = .off
                self?.refreshBridgeStatus()
            })
            refreshBridgeStatus()
        } catch {
            bridgeStatus.stringValue = "Local bridge: could not start (\(error))"
        }
    }

    @objc private func disableBridge(_ sender: Any?) {
        approvalGate.cancelAll()
        localBridge?.stop()
    }

    @objc private func manageClients(_ sender: Any?) {
        clientManager.show()
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
            writesArmed: false, generation: call.revision)
        if let error = CommandPolicy.validateShapeAndTarget(request, scope: selected) {
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
            if request.command.isWrite {
                reviewWrite(request, call: call, selected: selected, completion: completion)
            } else {
                commands.runAuthorized(request, selected: selected,
                                       stillAuthorized: { [weak self] in
                    guard let self else { return false }
                    return self.clientRegistry.stillAuthorized(call) && self.localBridge?.active == true
                }) { [weak self] value in
                    self?.finishClient(call, value, completion)
                }
            }
        }
    }

    private func reviewWrite(_ request: BridgeRequest, call: AuthorizedClientCall,
                             selected: BridgeScope,
                             completion: @escaping ([String: Any]) -> Void) {
        #if !EVENTKIT_LIVE_WRITES
        finishClient(call, ["error": "writes_not_built"], completion)
        #else
        guard let window, let targetName = commands.targetName(for: request) else {
            finishClient(call, ["error": "target_unavailable"], completion)
            return
        }
        let existing = commands.existingDescription(for: request)
        if request.parameters["itemID"] != nil && existing == nil {
            finishClient(call, ["error": "item_unavailable"], completion)
            return
        }
        let proposalFields: [String: Any] = [
            "version": 2, "epoch": approvalGate.epoch, "id": request.id,
            "command": request.command.rawValue,
            "issuedAt": Date().timeIntervalSince1970,
            "parameters": request.parameters,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: proposalFields, options: [.sortedKeys]) else {
            finishClient(call, ["error": "invalid_request"], completion)
            return
        }
        switch approvalGate.propose(
            data, peerVerified: true, scope: selected,
            now: Date().timeIntervalSince1970,
            uptime: ProcessInfo.processInfo.systemUptime) {
        case .failure(let error):
            finishClient(call, ["error": error.rawValue], completion)
        case .success(let proposal):
            approvalUI.review(
                proposal, clientName: call.clientName,
                targetName: targetName, existingItemDescription: existing,
                in: window, gate: approvalGate,
                currentScope: { [weak self] in
                    guard let self, self.clientRegistry.stillAuthorized(call),
                          self.localBridge?.active == true else { return BridgeScope() }
                    return selected
                }) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .failure(let error):
                        self.finishClient(call, ["error": error.rawValue], completion)
                    case .success(let approved):
                        guard self.clientRegistry.stillAuthorized(call),
                              self.localBridge?.active == true else {
                            self.finishClient(call, ["error": "scope_changed"], completion)
                            return
                        }
                        self.commands.runAuthorized(
                            approved.request, selected: selected,
                            stillAuthorized: { [weak self] in
                                guard let self else { return false }
                                return self.clientRegistry.stillAuthorized(call) &&
                                    self.localBridge?.active == true
                            }) { [weak self] value in
                                self?.finishClient(call, value, completion)
                            }
                    }
                }
        }
        #endif
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
        if let localBridge {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            bridgeStatus.stringValue = "Local bridge: active until \(formatter.string(from: localBridge.expiration))"
        } else {
            bridgeStatus.stringValue = "Local bridge: off"
        }
        bridgeEnableButton.isEnabled = localBridge == nil
        bridgeDisableButton.isEnabled = localBridge != nil
        refreshWriteControl()
        refreshMenu()
    }

    private func refreshMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()
        let calendar = name(EKEventStore.authorizationStatus(for: .event))
        let reminders = name(EKEventStore.authorizationStatus(for: .reminder))
        let bridgeLine: String
        if let localBridge {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            bridgeLine = "Bridge: active until \(formatter.string(from: localBridge.expiration))"
        } else {
            bridgeLine = "Bridge: off"
        }
        let loginStatus: String
        switch SMAppService.mainApp.status {
        case .enabled: loginStatus = "enabled"
        case .requiresApproval: loginStatus = "needs System Settings approval"
        case .notFound: loginStatus = "app unavailable"
        case .notRegistered: loginStatus = "off"
        @unknown default: loginStatus = "unknown"
        }
        #if EVENTKIT_LIVE_WRITES
        let writeStatus = "exact on-screen approval required"
        #else
        let writeStatus = "disabled in this build"
        #endif
        let clientCount = clientRegistry.clients()?.filter { !$0.revoked }.count
        for line in ["Calendar: \(calendar)", "Reminders: \(reminders)",
                     bridgeLine,
                     "Active clients: \(clientCount.map(String.init) ?? "policy unavailable")",
                     "Writes: \(writeStatus)", "Login: \(loginStatus)"] {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Controls…", action: #selector(openControls), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: localBridge == nil ? "Enable for 15 Minutes" : "Disable Bridge",
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

    private func refreshTargetStatus() {
        targetStatus.stringValue = "Calendar: \(commands.scope.calendarID == nil ? "none" : "selected") · Reminders: \(commands.scope.reminderListID == nil ? "none" : "selected")"
        refreshWriteControl()
        refreshMenu()
    }
    private var installedLocation: Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        let userApps = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true).path
        return path.hasPrefix("/Applications/") || path.hasPrefix(userApps + "/")
    }
    private func refreshWriteControl() {
        #if EVENTKIT_LIVE_WRITES
        armWritesButton.isEnabled = localBridge != nil &&
            (commands.scope.calendarID != nil || commands.scope.reminderListID != nil)
        #else
        armWritesButton.isEnabled = false
        #endif
    }
    private func disarmWrites() {
        commands.scope.writesArmed = false
        armWritesButton.state = .off
    }
    @objc private func openControls(_ sender: Any?) {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func chooseCalendar(_ sender: Any?) { chooseTarget(.event) }
    @objc private func chooseReminderList(_ sender: Any?) { chooseTarget(.reminder) }
    private func chooseTarget(_ type: EKEntityType) {
        guard EKEventStore.authorizationStatus(for: type) == .fullAccess else { return }
        let calendars = store.calendars(for: type)
        guard !calendars.isEmpty else { return }
        let picker = NSPopUpButton()
        for calendar in calendars {
            picker.addItem(withTitle: "\(calendar.title) [\(calendar.calendarIdentifier)]")
        }
        let alert = NSAlert()
        alert.messageText = type == .event ? "Choose calendar target" : "Choose reminder list target"
        alert.informativeText = "Only this target will be accessible through the local bridge during this app session."
        alert.accessoryView = picker
        alert.addButton(withTitle: "Select")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard calendars.indices.contains(picker.indexOfSelectedItem) else { return }
        let id = calendars[picker.indexOfSelectedItem].calendarIdentifier
        disarmWrites()
        if type == .event { commands.scope.calendarID = id }
        else { commands.scope.reminderListID = id }
        commands.scope.generation += 1
        refreshTargetStatus()
    }
    @objc private func clearTargets(_ sender: Any?) {
        commands.scope.calendarID = nil
        commands.scope.reminderListID = nil
        disarmWrites()
        commands.scope.generation += 1
        refreshTargetStatus()
    }
    @objc private func checkTestSources(_ sender: Any?) {
        output.string = testCollections.sourcePreview()
    }
    @objc private func createTestCollections(_ sender: Any?) {
        output.string = testCollections.create()
        disarmWrites()
        if let id = testCollections.calendarID { commands.scope.calendarID = id }
        if let id = testCollections.reminderListID { commands.scope.reminderListID = id }
        commands.scope.generation += 1
        refreshTargetStatus()
    }
    @objc private func removeTestCollections(_ sender: Any?) {
        disarmWrites()
        commands.scope.generation += 1
        refreshMenu()
        let calendarID = testCollections.calendarID
        let listID = testCollections.reminderListID
        testCollections.removeEmpty { [weak self] message in
            guard let self else { return }
            self.output.string = message
            self.disarmWrites()
            if self.testCollections.calendarID == nil && self.commands.scope.calendarID == calendarID {
                self.commands.scope.calendarID = nil
            }
            if self.testCollections.reminderListID == nil && self.commands.scope.reminderListID == listID {
                self.commands.scope.reminderListID = nil
            }
            self.commands.scope.generation += 1
            self.refreshTargetStatus()
        }
    }
    @objc private func toggleWrites(_ sender: Any?) {
        commands.scope.writesArmed = armWritesButton.state == .on
        refreshMenu()
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
        let app = NSApplication.shared
        let delegate = BridgeAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
