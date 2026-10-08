#if EVENTKIT_LIVE_TEST
import AppKit
import EventKit

/// The live-test copy's automation channel (docs/TESTING.md ▸ Live-test copy).
/// It exists only in builds with `-D EVENTKIT_LIVE_TEST`; release builds never
/// set the flag, and scripts/check_bundle.sh fails an app that contains
/// `marker`.
///
/// scripts/live_test.sh appends one JSON command per line to
/// `<data folder>/automation/commands.jsonl`; the app answers each with one
/// line in `responses.jsonl`, matched by `id`. Commands run one at a time,
/// through the same model functions as the app's buttons.
///
/// Test data only: collections are created, granted and removed only when
/// their names start with `collectionPrefix`, and nothing here reads items.
/// State reports other collections without their names.
@MainActor
final class LiveTestAutomation {
    static let marker = "EKB-LIVE-TEST-AUTOMATION"
    static let collectionPrefix = "EK Bridge Test · "
    private static let createdKey = "LiveTestCollectionIDs"

    struct Context {
        let model: BridgeAppModel
        let approvals: ApprovalCenter
        let store: EKEventStore
        let presentWindow: () -> Void
        let mainWindow: () -> NSWindow?
        let panelWindow: () -> NSWindow?
        /// A11: copies the app into Applications and relaunches it from there.
        var moveToApplications: (() -> String?)? = nil
    }

    private struct CommandError: Error { let message: String }

    private let context: Context
    private let folder: URL
    private var commandsURL: URL { folder.appendingPathComponent("commands.jsonl") }
    private var responsesURL: URL { folder.appendingPathComponent("responses.jsonl") }
    private var offset: UInt64 = 0
    private var partial = Data()
    private var queue = [[String: Any]]()
    private var running = false
    private var timer: Timer?
    /// When automation first saw each pending approval, for the arming delay.
    private var firstSeen = [UUID: Date]()

    init(context: Context, dataFolder: URL) {
        self.context = context
        folder = dataFolder.appendingPathComponent("automation", isDirectory: true)
    }

    func start() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    // MARK: Channel

    private func poll() {
        for item in context.approvals.pending where firstSeen[item.id] == nil { firstSeen[item.id] = Date() }
        firstSeen = firstSeen.filter { id, _ in context.approvals.pending.contains { $0.id == id } }
        guard let handle = try? FileHandle(forReadingFrom: commandsURL) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { offset = 0; partial = Data() }
        guard size > offset else { return }
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        offset += UInt64(data.count)
        partial.append(data)
        while let newline = partial.firstIndex(of: 10) {
            let line = partial[partial.startIndex..<newline]
            partial = Data(partial[partial.index(after: newline)...])
            guard !line.isEmpty else { continue }
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                queue.append(object)
            } else {
                respond(["id": NSNull(), "ok": false, "error": "not a JSON object"])
            }
        }
        runNext()
    }

    private func runNext() {
        guard !running, !queue.isEmpty else { return }
        running = true
        let command = queue.removeFirst()
        let id = command["id"] ?? NSNull()
        handle(command) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value): self.respond(["id": id, "ok": true, "result": value])
            case .failure(let error): self.respond(["id": id, "ok": false, "error": error.message])
            }
            self.running = false
            self.runNext()
        }
    }

    private func respond(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        data.append(10)
        if let handle = try? FileHandle(forWritingTo: responsesURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: responsesURL.path, contents: data,
                                           attributes: [.posixPermissions: 0o600])
        }
    }

    // MARK: Commands

    private typealias Completion = (Result<Any, CommandError>) -> Void

    private func handle(_ command: [String: Any], completion: @escaping Completion) {
        do {
            switch command["command"] as? String ?? "" {
            case "state": completion(.success(state()))
            case "navigate": completion(.success(try navigate(command)))
            case "openSheet": completion(.success(try openSheet(command)))
            case "windowSize": completion(.success(try windowSize(command)))
            case "appearance": completion(.success(try appearance(command)))
            case "createTestCollections": completion(.success(try createTestCollections(command)))
            case "removeTestCollections": completion(.success(try removeTestCollections()))
            case "createConnection": completion(.success(try createConnection(command)))
            case "setGrants": completion(.success(try setGrants(command)))
            case "pause", "resume": completion(.success(try setPaused(command)))
            case "setApproval": completion(.success(try setApproval(command)))
            case "setBridge": completion(.success(try setBridge(command)))
            case "setMCP": completion(.success(try setMCP(command)))
            case "requestAccess": completion(.success(try requestAccess(command)))
            case "answerPanel": try answerPanel(command, completion: completion)
            case "capture": completion(.success(try capture(command)))
            case "moveToApplications":
                guard let move = context.moveToApplications else {
                    throw CommandError(message: "moveToApplications isn't available in this build")
                }
                if let problem = move() { throw CommandError(message: problem) }
                completion(.success("moving"))
            case "quit":
                completion(.success("quitting"))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
            default:
                throw CommandError(message: "unknown command")
            }
        } catch let error as CommandError {
            completion(.failure(error))
        } catch {
            completion(.failure(CommandError(message: "\(error)")))
        }
    }

    private var model: BridgeAppModel { context.model }

    private func state() -> [String: Any] {
        model.refresh()
        let route: String
        switch model.route {
        case .overview: route = "overview"
        case .activity: route = "activity"
        case .settings: route = "settings"
        case .client(let id): route = "client:\(id)"
        }
        let names = testNames()
        let connections: [[String: Any]] = model.clients.map { client in
            [
                "id": client.id, "name": client.name, "revoked": client.revoked, "paused": client.paused,
                "approval": client.approval.rawValue,
                "kind": client.hasMCPToken && client.hasSigningKey ? "both" : client.hasMCPToken ? "agent" : "cli",
                "grants": client.grants.map { grant -> [String: Any] in
                    ["resource": grant.resource.rawValue, "mask": grant.mask,
                     "collection": names[grant.targetID] ?? "(not a test collection)"]
                },
            ]
        }
        let pending: [[String: Any]] = context.approvals.pending.map { item in
            ["kind": "change", "connection": item.clientName, "title": item.summary.title,
             "isDelete": item.summary.isDelete, "lookupFailed": item.summary.lookupFailed]
        }
        let activity: [[String: Any]] = model.activity.prefix(20).map { entry in
            var row: [String: Any] = ["at": ISO8601DateFormatter().string(from: entry.at),
                                      "connection": model.clientName(entry.clientID),
                                      "command": entry.command, "code": entry.code,
                                      "result": entry.outcome.label]
            if let via = entry.via { row["via"] = via }
            if let approval = entry.approval { row["approval"] = approval }
            if let target = entry.targetID { row["collection"] = names[target] ?? "(not a test collection)" }
            return row
        }
        let window = context.mainWindow()
        let panel = context.panelWindow()
        return [
            "marker": Self.marker,
            "bundlePath": Bundle.main.bundleURL.path,
            "bundleID": Bundle.main.bundleIdentifier ?? "",
            "route": route,
            "sheet": model.sheet?.id ?? NSNull(),
            "bridge": model.bridge.isOn ? "on" : "paused",
            "calendarAccess": accessText(model.calendarAccess),
            "remindersAccess": accessText(model.remindersAccess),
            "mcp": ["enabled": model.mcpEnabled, "listening": model.mcpIsListening,
                    "port": model.mcpListeningPort ?? model.mcpPort, "status": model.mcpStatusLine],
            "connections": connections,
            "pending": pending,
            "activity": activity,
            "notifications": [Any](),
            "testCollections": testCollections().map {
                ["id": $0.calendarIdentifier, "name": $0.title,
                 "resource": $0.allowedEntityTypes.contains(.event) ? "calendar" : "reminderList"]
            },
            "window": ["visible": window?.isVisible ?? false, "number": window?.windowNumber ?? 0,
                       "width": window?.contentLayoutRect.width ?? 0,
                       "height": window?.contentLayoutRect.height ?? 0],
            "panel": ["visible": panel?.isVisible ?? false, "number": panel?.windowNumber ?? 0],
        ]
    }

    private func accessText(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .fullAccess: "fullAccess"
        case .writeOnly: "writeOnly"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "notDetermined"
        @unknown default: "unknown"
        }
    }

    private func navigate(_ command: [String: Any]) throws -> String {
        let text = command["route"] as? String ?? ""
        let route: Route
        switch text {
        case "overview": route = .overview
        case "activity": route = .activity
        case "settings": route = .settings
        default:
            guard text.hasPrefix("client:") else { throw CommandError(message: "unknown route") }
            route = .client(try client(String(text.dropFirst(7))).id)
        }
        model.show(route)
        if case .client(let id) = route, let tab = command["tab"] as? String {
            switch tab {
            case "calendars": model.accessTab[id] = .calendar
            case "lists": model.accessTab[id] = .reminderList
            case "agent": model.connectTab[id] = .agent
            case "cli": model.connectTab[id] = .cli
            default: throw CommandError(message: "unknown tab")
            }
        }
        return text
    }

    private func openSheet(_ command: [String: Any]) throws -> String {
        switch command["name"] as? String {
        case "newClient": model.beginNewClient()
        case "none": model.sheet = nil
        default: throw CommandError(message: "unknown sheet")
        }
        return model.sheet?.id ?? "none"
    }

    private func windowSize(_ command: [String: Any]) throws -> [String: Double] {
        guard let width = command["w"] as? Double, let height = command["h"] as? Double,
              let window = context.mainWindow() else { throw CommandError(message: "needs w and h") }
        context.presentWindow()
        window.setContentSize(NSSize(width: width, height: height))
        return ["w": window.contentLayoutRect.width, "h": window.contentLayoutRect.height]
    }

    private func appearance(_ command: [String: Any]) throws -> String {
        switch command["appearance"] as? String {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "system": NSApp.appearance = nil
        default: throw CommandError(message: "appearance is light, dark or system")
        }
        return command["appearance"] as! String
    }

    // MARK: Test collections

    /// Calendars and lists whose names start with the test prefix.
    private func testCollections() -> [EKCalendar] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess
                || EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return [] }
        var result = [EKCalendar]()
        for type in [EKEntityType.event, .reminder] where EKEventStore.authorizationStatus(for: type) == .fullAccess {
            result += context.store.calendars(for: type).filter { $0.title.hasPrefix(Self.collectionPrefix) }
        }
        return result
    }

    private func testNames() -> [String: String] {
        Dictionary(testCollections().map { ($0.calendarIdentifier, $0.title) }, uniquingKeysWith: { a, _ in a })
    }

    private func createTestCollections(_ command: [String: Any]) throws -> [[String: String]] {
        guard let names = command["names"] as? [String], !names.isEmpty else {
            throw CommandError(message: "needs names")
        }
        let resource = command["resource"] as? String ?? "both"
        var types = [EKEntityType]()
        if resource == "calendar" || resource == "both" { types.append(.event) }
        if resource == "reminderList" || resource == "list" || resource == "both" { types.append(.reminder) }
        guard !types.isEmpty else { throw CommandError(message: "resource is calendar, reminderList or both") }
        for type in types where EKEventStore.authorizationStatus(for: type) != .fullAccess {
            throw CommandError(message: "no Full Access to \(type == .event ? "calendars" : "reminders") yet")
        }
        for name in names where !name.hasPrefix(Self.collectionPrefix) || name.count <= Self.collectionPrefix.count {
            throw CommandError(message: "test collection names start with “\(Self.collectionPrefix)”")
        }
        let existing = Set(testCollections().map { "\($0.allowedEntityTypes.contains(.event))|\($0.title)" })
        var created = [[String: String]]()
        var ids = UserDefaults.standard.stringArray(forKey: Self.createdKey) ?? []
        for name in names {
            for type in types {
                guard !existing.contains("\(type == .event)|\(name)") else {
                    throw CommandError(message: "“\(name)” already exists; run cleanup first")
                }
                guard let source = source(type) else { throw CommandError(message: "no source for test data") }
                let calendar = EKCalendar(for: type, eventStore: context.store)
                calendar.title = name
                calendar.source = source
                do {
                    try context.store.saveCalendar(calendar, commit: true)
                } catch {
                    throw CommandError(message: "couldn't create “\(name)”: \((error as NSError).code)")
                }
                ids.append(calendar.calendarIdentifier)
                UserDefaults.standard.set(ids, forKey: Self.createdKey)
                created.append(["id": calendar.calendarIdentifier, "name": name,
                                "resource": type == .event ? "calendar" : "reminderList"])
            }
        }
        model.refresh()
        return created
    }

    /// Removes every collection with the test prefix, with its test items.
    private func removeTestCollections() throws -> [String] {
        var removed = [String]()
        for calendar in testCollections() {
            // Recheck the name right before the destructive call.
            guard context.store.calendar(withIdentifier: calendar.calendarIdentifier)?.title
                .hasPrefix(Self.collectionPrefix) == true else { continue }
            do {
                try context.store.removeCalendar(calendar, commit: true)
                removed.append(calendar.title)
            } catch {
                throw CommandError(message: "couldn't remove “\(calendar.title)”: \((error as NSError).code)")
            }
        }
        UserDefaults.standard.removeObject(forKey: Self.createdKey)
        context.store.reset()
        model.refresh()
        return removed
    }

    /// Prefers a local source, then iCloud, like `TestCollections`.
    private func source(_ type: EKEntityType) -> EKSource? {
        let sources = context.store.sources
        if let local = sources.first(where: { $0.sourceType == .local && !$0.isDelegate
            && !$0.calendars(for: type).isEmpty }) { return local }
        if let iCloud = sources.first(where: { $0.title == "iCloud" && !$0.isDelegate
            && !$0.calendars(for: type).isEmpty }) { return iCloud }
        return type == .event ? context.store.defaultCalendarForNewEvents?.source
                              : context.store.defaultCalendarForNewReminders()?.source
    }

    // MARK: Connections

    private func client(_ value: String) throws -> ClientView {
        let matches = model.activeClients.filter { $0.id == value || $0.name == value }
        guard let client = matches.first else { throw CommandError(message: "no connection “\(value)”") }
        return client
    }

    private func clientID(_ command: [String: Any]) throws -> String {
        try client(command["connection"] as? String ?? "").id
    }

    /// Grants on test collections only. `startingAccess` (none, read, full)
    /// applies to every test collection; `grants` lists
    /// `{collection, resource?, mask}` by name or ID.
    private func grants(_ command: [String: Any]) throws -> [ClientGrant] {
        let collections = testCollections()
        var result = [String: ClientGrant]()
        func add(_ calendar: EKCalendar, _ mask: Int) {
            let resource: ClientResource = calendar.allowedEntityTypes.contains(.event) ? .calendar : .reminderList
            let allowed = ClientGrantEditing.allowedMask(resource: resource,
                                                         writable: calendar.allowsContentModifications)
            let masked = mask & allowed
            if masked > 0 {
                result[calendar.calendarIdentifier] = ClientGrant(resource: resource,
                                                                  targetID: calendar.calendarIdentifier, mask: masked)
            } else {
                result[calendar.calendarIdentifier] = nil
            }
        }
        switch command["startingAccess"] as? String ?? "none" {
        case "none": break
        case "read": collections.forEach { add($0, ClientGrant.read) }
        case "full": collections.forEach { add($0, 31) }
        default: throw CommandError(message: "startingAccess is none, read or full")
        }
        for item in command["grants"] as? [[String: Any]] ?? [] {
            let name = item["collection"] as? String ?? ""
            let resource = item["resource"] as? String
            let matches = collections.filter {
                ($0.title == name || $0.calendarIdentifier == name)
                    && (resource == nil || (resource == "calendar") == $0.allowedEntityTypes.contains(.event))
            }
            guard matches.count == 1, let mask = item["mask"] as? Int else {
                throw CommandError(message: "grants are only for one test collection each, with a mask")
            }
            add(matches[0], mask)
        }
        return Array(result.values)
    }

    private func saveGrants(_ clientID: String, _ grants: [ClientGrant]) throws {
        if case .failure(let error) = model.services.registry.replaceGrants(clientID: clientID, grants: grants) {
            throw CommandError(message: "couldn't save access: \(error.rawValue)")
        }
        context.approvals.withdraw(clientID: clientID)
        model.refresh()
    }

    private func createConnection(_ command: [String: Any]) throws -> [String: String] {
        guard let name = command["name"] as? String else { throw CommandError(message: "needs name") }
        guard let kind = ClientKind(rawValue: command["kind"] as? String ?? "agent") else {
            throw CommandError(message: "kind is agent, cli or both")
        }
        let grants = try grants(command)
        let ask: Bool? = (command["approval"] as? String).map { $0 == "ask" }
        if let issue = model.createClient(name: name, kind: kind, askBeforeChanges: ask) {
            throw CommandError(message: "name refused: \(issue)")
        }
        let created = try client(name)
        try saveGrants(created.id, grants)
        return ["id": created.id, "name": created.name]
    }

    private func setGrants(_ command: [String: Any]) throws -> Int {
        let id = try clientID(command)
        let grants = try grants(command)
        try saveGrants(id, grants)
        return grants.count
    }

    private func setPaused(_ command: [String: Any]) throws -> String {
        let id = try clientID(command)
        let paused = command["command"] as? String == "pause"
        model.setPaused(id, paused)
        guard model.client(id)?.paused == paused else { throw CommandError(message: "didn't change") }
        return paused ? "paused" : "resumed"
    }

    private func setApproval(_ command: [String: Any]) throws -> String {
        let id = try clientID(command)
        guard let mode = ApprovalMode(rawValue: command["mode"] as? String ?? "") else {
            throw CommandError(message: "mode is ask or allow")
        }
        model.setApproval(id, mode)
        return mode.rawValue
    }

    private func setBridge(_ command: [String: Any]) throws -> String {
        guard let on = command["on"] as? Bool else { throw CommandError(message: "needs on") }
        model.setBridgeEnabled(on)
        return model.bridge.isOn ? "on" : "paused"
    }

    private func setMCP(_ command: [String: Any]) throws -> Bool {
        guard let on = command["on"] as? Bool else { throw CommandError(message: "needs on") }
        model.setMCPServerEnabled(on, confirm: false)
        return model.mcpEnabled
    }

    /// Asks macOS for Full Access, as the setup checklist's buttons do. The
    /// first time, macOS shows its prompt to the person at the Mac.
    private func requestAccess(_ command: [String: Any]) throws -> String {
        switch command["resource"] as? String {
        case "calendar": model.requestAccess(.calendar)
        case "reminderList": model.requestAccess(.reminderList)
        default: throw CommandError(message: "resource is calendar or reminderList")
        }
        return "asked"
    }

    // MARK: Panel

    /// Waits for a pending item, then for the panel's arming delay, then
    /// answers through the same functions as the panel's buttons.
    private func answerPanel(_ command: [String: Any], completion: @escaping Completion) throws {
        let decision = command["decision"] as? String ?? ""
        guard ["allow", "deny", "allowWindow"].contains(decision) else {
            throw CommandError(message: decision.isEmpty || !["allowOnce", "allowAlways", "notNow"].contains(decision)
                ? "decision is allow, deny or allowWindow"
                : "\(decision) answers access requests, which this build doesn't have")
        }
        let deadline = Date().addingTimeInterval(command["timeout"] as? Double ?? 20)
        func attempt() {
            let center = context.approvals
            if let item = center.current, let seen = firstSeen[item.id],
               Date().timeIntervalSince(seen) >= 0.8 {
                let title = item.summary.title
                switch decision {
                case "deny": center.deny(item.id)
                case "allowWindow": center.allow(item.id, forWindow: true)
                default: center.allow(item.id)
                }
                completion(.success(["decision": decision, "title": title]))
            } else if Date() >= deadline {
                completion(.failure(CommandError(message: "no panel item to answer")))
            } else {
                if let item = center.current, firstSeen[item.id] == nil { firstSeen[item.id] = Date() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { attempt() }
            }
        }
        attempt()
    }

    // MARK: Capture

    /// Draws the window into a PNG in-process, so no Screen Recording
    /// permission is needed. `dir` defaults to the automation folder.
    private func capture(_ command: [String: Any]) throws -> String {
        guard let name = command["name"] as? String, !name.isEmpty, !name.contains("/") else {
            throw CommandError(message: "needs a file name")
        }
        let which = command["window"] as? String ?? "main"
        guard let window = which == "panel" ? context.panelWindow() : context.mainWindow(),
              window.isVisible else { throw CommandError(message: "\(which) window isn't visible") }
        guard let view = window.contentView?.superview ?? window.contentView else {
            throw CommandError(message: "no view")
        }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CommandError(message: "couldn't draw")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw CommandError(message: "couldn't encode")
        }
        let directory = (command["dir"] as? String).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? folder.appendingPathComponent("captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name.hasSuffix(".png") ? name : name + ".png")
        do { try png.write(to: url) } catch { throw CommandError(message: "couldn't write \(url.path)") }
        return url.path
    }
}
#endif
