#if EVENTKIT_UI_REVIEW
import AppKit
import CryptoKit
import EventKit

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
@MainActor
final class UIReview {
    static let claudeID = "3f2a9c1e-7b4d-4e8a-9c21-5d6f0a1b2c3d"
    static let briefingID = "8c1d4e2f-5a6b-4c7d-8e9f-0a1b2c3d4e5f"
    static let obsidianID = "b7e3f1a2-9c4d-4e5f-a6b7-c8d9e0f1a2b3"
    static let revokedID = "d2c4e6f8-1a3b-4c5d-8e7f-9a0b1c2d3e4f"

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("eventkit-ui-review-\(UUID().uuidString)", isDirectory: true)
    private let suiteName = "eventkit-ui-review-\(UUID().uuidString)"
    private(set) lazy var defaults = UserDefaults(suiteName: suiteName)!
    private(set) lazy var registry = ClientRegistry(directory: directory)
    private(set) lazy var credentialFiles = ClientCredentialFiles(parent: directory)
    private let arguments = CommandLine.arguments
    var calendarStatus: EKAuthorizationStatus
    var remindersStatus: EKAuthorizationStatus
    var bridgeOn: Bool
    let many: Bool
    static var longNames: Bool { CommandLine.arguments.contains("--ui-long-names") }
    private var extraWindows = [MainWindowController]()
    private var extraReviews = [UIReview]()

    init(fresh: Bool? = nil, calendar: EKAuthorizationStatus? = nil,
         reminders: EKAuthorizationStatus? = nil) {
        calendarStatus = calendar ?? Self.status(CommandLine.arguments, "--ui-calendar")
        remindersStatus = reminders ?? Self.status(CommandLine.arguments, "--ui-reminders")
        bridgeOn = fresh == true ? false : !CommandLine.arguments.contains("--ui-bridge-off")
        many = CommandLine.arguments.contains("--ui-many-collections")
        if !(fresh ?? CommandLine.arguments.contains("--ui-fresh")) { seed() }
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
            loginItemStatus: { .notRegistered },
            setLoginItem: { _ in },
            isInstalledInApplications: { false },
            testCollections: nil)
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
        let now = Date()
        var clients = [[String: Any]]()
        let definitions: [(String, String, [[String: Any]])] = [
            (Self.claudeID, Self.longNames ? "Claude Code on the work laptop, with a long descriptive name" : "Claude Code", [
                grant("calendar", "cal-home", 1), grant("calendar", "cal-work", 7),
                grant("reminderList", "list-errands", 23), grant("calendar", "cal-signed-out", 1)]),
            (Self.briefingID, "Morning briefing", [
                grant("calendar", "cal-work", 1), grant("calendar", "cal-family", 1),
                grant("calendar", "cal-home", 1), grant("reminderList", "list-reminders", 1),
                grant("calendar", "cal-holidays", 3)]),
            (Self.obsidianID, "Obsidian sync", [grant("calendar", "cal-work", 5)]),
        ]
        for (id, name, grants) in definitions {
            let (public_, key) = verifier()
            clients.append(["id": id, "name": name, "verifier": public_, "revoked": false,
                            "revision": 4, "grants": grants])
            _ = credentialFiles.saveNew(clientID: id, key: key)
        }
        if CommandLine.arguments.contains("--ui-max-clients") {
            for index in 1...29 {
                clients.append(["id": UUID().uuidString.lowercased(), "name": "Script \(index)",
                                "verifier": verifier().0, "revoked": false, "revision": 1, "grants": []])
            }
        }
        clients.append(["id": Self.revokedID, "name": "Old shell script", "verifier": "", "revoked": true,
                        "revision": 6, "grants": [],
                        "revokedAt": now.addingTimeInterval(-86_400 * 6).timeIntervalSinceReferenceDate])
        // Oldest first, as stored. Each request has an "accepted" row and a result.
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
            (-200, Self.briefingID, "read_reminders", "success", "list-reminders"),
            (-150, Self.claudeID, "read_events", "success", "cal-work"),
            (-120, Self.claudeID, "read_events", "success", "cal-work"),
        ]
        var activity = [[String: Any]]()
        for (offset, client, command, outcome, target) in script {
            let at = now.addingTimeInterval(offset).timeIntervalSinceReferenceDate
            var row: [String: Any] = ["at": at, "command": command, "outcome": outcome]
            if let client { row["clientID"] = client }
            if let target { row["targetID"] = target }
            if outcome == "success" || outcome.hasPrefix("error:") {
                var accepted = row
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
        let state: [String: Any] = ["version": 3, "clients": clients, "activity": activity]
        let file = directory.appendingPathComponent("client-registry.json")
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
            FileManager.default.createFile(atPath: file.path, contents: data,
                                           attributes: [.posixPermissions: 0o600])
        }
    }

    // MARK: Modes

    func run(model: BridgeAppModel, window: MainWindowController, statusMenu: StatusMenuController) {
        model.bridgeDidChange(bridgeOn ? .on : .off)
        DispatchQueue.main.async { self.runMode(model: model, window: window, statusMenu: statusMenu) }
    }

    private func runMode(model: BridgeAppModel, window: MainWindowController, statusMenu: StatusMenuController) {
        if arguments.contains("--ui-window-lifecycle-test") {
            WindowLifecycleReview(model: model, controller: window).start()
        } else if arguments.contains("--ui-behavior-test") {
            BehaviorReview(model: model, controller: window).start()
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
        after(0.25) {
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
    private var steps = [(String, @MainActor () -> Bool)]()
    private var passed = [String]()

    init(model: BridgeAppModel, controller: MainWindowController) {
        self.model = model
        self.controller = controller
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
            let staged = self.model.draft?.mask(gone) == 0 && self.model.hasUnsavedChanges
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
            return self.model.route == .client(created.id) && self.model.banner?.kind == .info &&
                created.grants.isEmpty && self.model.keyFileStatus(created.id) == .present &&
                self.model.createClient(name: "shortcuts") == .duplicate("Shortcuts")
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
                self.model.keyFileStatus(revoked.id) == .missing
        }
        step("activity deep link") {
            guard let forbidden = self.model.activity.first(where: { $0.code == "forbidden" }) else { return false }
            self.model.openActivity(selecting: forbidden.id)
            return self.model.route == .activity && self.model.activitySelection == forbidden.id &&
                self.model.unseenProblemCount == 0
        }
        step("open client at the target row") {
            self.model.openClientAccess(claude, focus: GrantKey(resource: .reminderList, targetID: "list-groceries"))
            return self.model.route == .client(claude) && self.model.accessTab[claude] == .reminderList &&
                self.model.accessFocus?.targetID == "list-groceries"
        }
        next()
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
            step("activity") {
                self.model.navigate(to: .activity)
                self.model.activitySelection = self.model.activity.first { $0.code == "forbidden" }?.id
                return main
            }
            step("settings") {
                self.model.setShowDeveloperTools(true)
                self.model.navigate(to: .settings)
                return main
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
            step("restore") {
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
        if name.hasPrefix("setup") {
            return NSApp.windows.first { $0.isVisible && $0 !== controller.window && $0.contentViewController != nil }
        }
        guard let main = controller.window else { return nil }
        return name.hasPrefix("sheet") ? (main.attachedSheet ?? main) : main
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
