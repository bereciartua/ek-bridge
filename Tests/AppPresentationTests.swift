import EventKit
import Foundation

@main
struct AppPresentationTests {
    static func main() throws {
        try outcomeMapCoversEmittedCodes()
        writeImpliesRead()
        stagedGrants()
        accessSummary()
        attention()
        checklist()
        activity()
        formatting()
        print("App presentation: outcome map coverage, write implies Read, staged grants, summaries, attention, checklist, activity, formatting passed")
    }

    // Every code the bridge can return has an entry in the outcome map.
    static func outcomeMapCoversEmittedCodes() throws {
        let sources = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        // Recursive, so Sources/MCP is covered too.
        let files = (FileManager.default.subpaths(atPath: sources.path) ?? [])
            .filter { path in
                let name = (path as NSString).lastPathComponent
                return name.hasSuffix(".swift") && !name.hasPrefix("Synthetic") &&
                    name != "TestCollections.swift" && name != "BridgeClient.swift" &&
                    name != "MCPLauncher.swift" &&
                    // OAuth protocol errors (RFC 6749), not bridge outcomes.
                    !name.hasPrefix("OAuth") && name != "CIMDFetcher.swift"
            }
        let patterns = [
            #""error": "([a-z_]+)""#,
            #"\.reject\("([a-z_]+)"\)"#,
            #"return "([a-z]+(?:_[a-z]+)+)""#,
            #"\? nil : "([a-z]+(?:_[a-z]+)+)""#,
            #"case [a-zA-Z]+ = "([a-z]+(?:_[a-z]+)+)""#,
            #"FieldError\("([a-z_]+)"\)"#,
        ].map { try! NSRegularExpression(pattern: $0) }
        var codes = Set<String>()
        for file in files {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for pattern in patterns {
                for match in pattern.matches(in: text, range: range) {
                    codes.insert(String(text[Range(match.range(at: 1), in: text)!]))
                }
            }
        }
        // Commands (`case readEvents = "read_events"`) aren't outcomes.
        codes.subtract(CommandPresentation.allCommands)
        // From ClientRegistry's authorize failures, returned as raw values.
        codes.formUnion(["unauthorized", "forbidden", "unavailable", "success"])
        precondition(codes.count > 40, "the scan found \(codes.count) codes")
        let missing = codes.filter { !OutcomePresentation.isKnown($0) }.sorted()
        precondition(missing.isEmpty, "outcome map is missing \(missing)")
        let forbidden = OutcomePresentation.of("forbidden")
        precondition(forbidden.label == "Not allowed" && forbidden.tone == .bad)
        precondition(OutcomePresentation.of("error:conflict").label == "Out of date")
        precondition(OutcomePresentation.of("error:recurrence_whatever").label == "Not supported")
        let unknown = OutcomePresentation.of("error:mystery_code")
        precondition(unknown.label == "Error" && unknown.tone == .neutral &&
                     unknown.why == "The bridge returned mystery_code.")
        precondition(OutcomePresentation.of("success").tone == .ok)
        precondition(!OutcomePresentation.of("already_completed").tone.isProblem)
        precondition(CommandPresentation.label("complete_reminder") == "Complete reminder")
        precondition(CommandPresentation.label("calendar_count") == "Count calendars")
        precondition(CommandPresentation.requiredAction("update_event") == "Edit")
        precondition(CommandPresentation.requiredAction("scope_status") == nil)
    }

    static func writeImpliesRead() {
        let editOnEmpty = ClientGrantEditing.toggling(0, bit: ClientGrant.edit, on: true)
        precondition(editOnEmpty == 5, "checking Edit on an empty row yields read + edit")
        let readOff = ClientGrantEditing.toggling(editOnEmpty, bit: ClientGrant.read, on: false)
        precondition(readOff == 4 && ClientGrantEditing.writeWithoutRead(readOff))
        precondition(!ClientGrantEditing.writeWithoutRead(5))
        precondition(ClientGrantEditing.toggling(1, bit: ClientGrant.read, on: false) == 0)
        precondition(ClientGrantEditing.withImpliedRead(0) == 0)
        precondition(ClientGrantEditing.withImpliedRead(16) == 17)
        precondition(ClientGrantEditing.toggling(4, bit: ClientGrant.delete, on: true) == 13)
    }

    static func stagedGrants() {
        let legacy = ClientGrant(resource: .calendar, targetID: "legacy", mask: ClientGrant.create)
        let gone = ClientGrant(resource: .calendar, targetID: "gone", mask: 3)
        let holidays = ClientGrant(resource: .calendar, targetID: "holidays", mask: 3)
        let client = ClientView(id: "c", name: "Tool", revoked: false,
                                grants: [legacy, gone, holidays])
        var draft = GrantDraft(client: client)
        let listed: [(key: GrantKey, writable: Bool)] = [
            (GrantKey(resource: .calendar, targetID: "legacy"), true),
            (GrantKey(resource: .calendar, targetID: "work"), true),
            (GrantKey(resource: .calendar, targetID: "holidays"), false),
        ]
        precondition(!draft.hasChanges && draft.changedCells == 0)
        // A legacy mask 2 (create without read) round-trips unchanged.
        let untouched = draft.grantsToSave(base: client.grants, listed: listed)
        precondition(untouched.contains(legacy))
        precondition(untouched.contains(gone), "unavailable grants are preserved")
        precondition(untouched.first { $0.targetID == "holidays" }?.mask == 1,
                     "write bits on a now read-only calendar are dropped on save")
        let work = GrantKey(resource: .calendar, targetID: "work")
        draft.set(work, mask: ClientGrantEditing.toggling(0, bit: ClientGrant.edit, on: true))
        precondition(draft.changedCells == 2 && draft.isChanged(work))
        draft.set(work, mask: 0)
        precondition(!draft.hasChanges, "undoing to the saved mask clears the change")
        draft.set(work, mask: 5)
        let goneKey = GrantKey(resource: .calendar, targetID: "gone")
        draft.set(goneKey, mask: 0)
        precondition(draft.changedCells == 4)
        let saved = draft.grantsToSave(base: client.grants, listed: listed)
        precondition(saved.contains(ClientGrant(resource: .calendar, targetID: "work", mask: 5)))
        precondition(!saved.contains { $0.targetID == "gone" }, "removed unavailable grants go")
        precondition(saved.first == legacy, "unchanged rows keep their order")
    }

    static func accessSummary() {
        let collections = [
            info(.calendar, "work", "Work", "iCloud"),
            info(.calendar, "home", "Home", "iCloud"),
            info(.calendar, "family", "Family", "iCloud"),
            info(.reminderList, "errands", "Errands", "iCloud"),
        ]
        let grants = [
            ClientGrant(resource: .calendar, targetID: "work", mask: 7),
            ClientGrant(resource: .calendar, targetID: "home", mask: 1),
            ClientGrant(resource: .calendar, targetID: "family", mask: 1),
            ClientGrant(resource: .calendar, targetID: "missing", mask: 1),
            ClientGrant(resource: .reminderList, targetID: "errands", mask: 23),
        ]
        let text = AccessSummary.text(grants: grants, collections: collections)
        precondition(text == "Family, Home, 1 unavailable calendar: read · Work: read, create, edit · Errands: read, create, edit, complete", text)
        precondition(AccessSummary.text(grants: [], collections: collections) == "No access yet")
        precondition(AccessSummary.text(grants: grants, collections: collections, maxGroups: 1)
            == "Family, Home, 1 unavailable calendar: read · +2 more")
        precondition(AccessSummary.counts(grants) == "4 calendars, 1 list")
        precondition(AccessSummary.text(grants: grants, collections: collections, hidden: [.calendar]) ==
                     "Errands: read, create, edit, complete · 4 calendars (no Calendar access)")
        precondition(AccessSummary.counts([]) == "No access yet")
    }

    static func attention() {
        let calendarClient = ClientView(id: "a", name: "A", revoked: false, grants: [
            ClientGrant(resource: .calendar, targetID: "x", mask: 1)])
        let revokedReminders = ClientView(id: "b", name: "B", revoked: true, grants: [
            ClientGrant(resource: .reminderList, targetID: "y", mask: 1)])
        func problems(_ bridge: BridgeRunState = .on, calendar: EKAuthorizationStatus = .fullAccess,
                      reminders: EKAuthorizationStatus = .fullAccess,
                      clients: [ClientView] = [calendarClient],
                      policy: Bool = true) -> [AttentionProblem] {
            AttentionLogic.problems(bridge: bridge, calendar: calendar, reminders: reminders,
                                    clients: clients, policyStoreAvailable: policy)
        }
        precondition(problems().isEmpty)
        precondition(problems(.off).isEmpty, "off is not attention")
        precondition(problems(.failed("x")) == [.bridgeFailed])
        precondition(problems(policy: false) == [.policyStoreUnavailable])
        precondition(problems(calendar: .denied) == [.calendarAccess(.denied)])
        precondition(problems(calendar: .writeOnly) == [.calendarAccess(.writeOnly)])
        precondition(problems(reminders: .denied).isEmpty, "no client uses reminders")
        precondition(problems(reminders: .denied, clients: [calendarClient, revokedReminders]).isEmpty,
                     "revoked clients don't count")
        precondition(problems(calendar: .denied, clients: []).isEmpty)
        precondition(problems(.failed("x"), calendar: .notDetermined, policy: false) ==
                     [.bridgeFailed, .policyStoreUnavailable, .calendarAccess(.notDetermined)])
        precondition(AttentionProblem.remindersAccess(.denied).title == "Reminders access is turned off")
        // Only an enabled MCP server that failed is a problem.
        precondition(AttentionLogic.problems(bridge: .on, calendar: .fullAccess, reminders: .fullAccess,
                                             clients: [], policyStoreAvailable: true,
                                             mcpFailure: "Port 47615 is in use") ==
                     [.mcpServerFailed("Port 47615 is in use")])
    }

    static func checklist() {
        typealias Step = SetupChecklist.Step
        var input = SetupChecklist.Input(calendar: .notDetermined, reminders: .notDetermined,
                                         clients: [], bridgeOn: false, successfulClientIDs: [])
        var states = SetupChecklist.states(input)
        precondition(states[.calendarAccess] == .current)
        precondition(SetupChecklist.steps(input).dropFirst().allSatisfy { states[$0] == .pending })
        precondition(states[.mcpServer] == nil, "the MCP step needs an MCP client")
        input.calendar = .fullAccess
        states = SetupChecklist.states(input)
        precondition(states[.calendarAccess] == .done && states[.remindersAccess] == .current)
        var client = ClientView(id: "c", name: "Claude Code", revoked: false, grants: [])
        input.clients = [client]
        states = SetupChecklist.states(input)
        precondition(states[.remindersAccess] == .optional, "only Calendars is fine")
        precondition(states[.createClient] == .done && states[.chooseAccess] == .current)
        precondition(SetupChecklist.focusClient(input)?.id == "c")
        client = ClientView(id: "c", name: "Claude Code", revoked: false, grants: [
            ClientGrant(resource: .calendar, targetID: "w", mask: 1)])
        input.clients = [client]
        input.bridgeOn = true
        states = SetupChecklist.states(input)
        precondition(states[.chooseAccess] == .done && states[.turnOn] == .done &&
                     states[.testRequest] == .current)
        precondition(!SetupChecklist.isComplete(input))
        input.successfulClientIDs = ["c"]
        precondition(SetupChecklist.isComplete(input))
        input.skipped = [.remindersAccess]
        precondition(SetupChecklist.states(input)[.remindersAccess] == .skipped)
        // An MCP client adds "Turn on the MCP server" before "Connect your tool".
        var agent = ClientView(id: "a", name: "Agent", revoked: false, grants: [
            ClientGrant(resource: .calendar, targetID: "w", mask: 1)])
        agent.hasSigningKey = false
        agent.hasMCPToken = true
        var mcp = input
        mcp.clients = [agent]
        mcp.successfulClientIDs = []
        precondition(SetupChecklist.steps(mcp).suffix(3) == [.turnOn, .mcpServer, .testRequest])
        precondition(SetupChecklist.states(mcp)[.mcpServer] == .current)
        mcp.mcpListening = true
        precondition(SetupChecklist.states(mcp)[.mcpServer] == .done &&
                     SetupChecklist.states(mcp)[.testRequest] == .current)
        precondition(Step.mcpServer.rawValue == 7 && Step.testRequest.rawValue == 6,
                     "stored skipped steps keep their meaning")
        precondition(ClientTransport(agent).badge == "MCP" && ClientTransport(client).badge == "CLI")
        agent.hasSigningKey = true
        precondition(ClientTransport(agent).badge == "MCP + CLI")
        // Steps stay usable out of order: turning the bridge on first works.
        let early = SetupChecklist.Input(calendar: .notDetermined, reminders: .notDetermined,
                                         clients: [], bridgeOn: true, successfulClientIDs: [])
        precondition(SetupChecklist.states(early)[.turnOn] == .done)
        // A revoked client's request doesn't complete setup.
        let revoked = SetupChecklist.Input(
            calendar: .fullAccess, reminders: .fullAccess,
            clients: [ClientView(id: "r", name: "Old", revoked: true, grants: [])],
            bridgeOn: true, successfulClientIDs: ["r"])
        precondition(SetupChecklist.states(revoked)[.createClient] == .current)
    }

    static func activity() {
        let now = Date()
        let rows = [
            ClientActivity(at: now, clientID: "a", command: "read_events", outcome: "success", targetID: "w"),
            ClientActivity(at: now, clientID: "a", command: "read_events", outcome: "accepted", targetID: "w"),
            ClientActivity(at: now.addingTimeInterval(-60), clientID: "b", command: "create_reminder",
                           outcome: "forbidden", targetID: "g"),
            ClientActivity(at: now.addingTimeInterval(-120), clientID: nil, command: "read_events",
                           outcome: "unauthorized"),
            ClientActivity(at: now.addingTimeInterval(-86_400 * 3), clientID: "b",
                           command: "update_event", outcome: "error:conflict"),
        ]
        let entries = ActivityEntry.entries(from: rows)
        precondition(entries.count == 4, "accepted rows are hidden")
        precondition(Set(entries.map(\.id)).count == 4)
        precondition(ActivityStats.lastRequest(for: "b", in: entries) == now.addingTimeInterval(-60))
        precondition(ActivityStats.lastRequest(for: "z", in: entries) == nil)
        precondition(entries[3].code == "conflict" && entries[3].isProblem)
        let today = ActivityStats.today(entries, now: now)
        let expected = Calendar.current.isDate(now.addingTimeInterval(-120), inSameDayAs: now) ? 3 : 1
        precondition(today.requests == expected && today.last == now)
        precondition(ActivityStats.unseenProblems(entries, since: nil) == 3)
        precondition(ActivityStats.unseenProblems(entries, since: now.addingTimeInterval(-90)) == 1)
        let again = ActivityEntry.entries(from: [ClientActivity(at: now, clientID: "x",
            command: "read_events", outcome: "success")] + rows)
        precondition(again.last?.id == entries.last?.id, "IDs are stable when rows are added")
    }

    static func formatting() {
        precondition(ClientAvatar.initials("Claude Code") == "CC")
        precondition(ClientAvatar.initials("morning briefing sync") == "MB")
        precondition(ClientAvatar.initials("HAL-9000") == "H9")
        precondition(ClientAvatar.initials("  ") == "?")
        precondition(ClientAvatar.colorIndex("abc") == ClientAvatar.colorIndex("abc"))
        precondition((0..<8).contains(ClientAvatar.colorIndex(UUID().uuidString)))
        let now = Date()
        precondition(RelativeTime.short(now.addingTimeInterval(-5), now: now) == "now")
        precondition(RelativeTime.short(now.addingTimeInterval(-125), now: now) == "2 min")
        precondition(RelativeTime.ago(now.addingTimeInterval(-125), now: now) == "2 min ago")
        precondition(RelativeTime.ago(now.addingTimeInterval(-3_700), now: now) == "1 h ago")
        let calendar = Calendar.current
        let noonYesterday = calendar.date(bySettingHour: 12, minute: 0, second: 0,
            of: calendar.date(byAdding: .day, value: -1, to: now)!)!
        let lateToday = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: now)!
        precondition(RelativeTime.clock(noonYesterday, now: lateToday) == "Yesterday")
        // Only actions a collection allows are named; the rest is flagged.
        let holidays = CollectionInfo(resource: .calendar, id: "hol", name: "US Holidays", account: "iCloud",
                                      writable: false, color: nil)
        let workCalendar = CollectionInfo(resource: .calendar, id: "wrk", name: "Work", account: "iCloud",
                                          writable: true, color: nil)
        let readCreate = ClientGrant.read | ClientGrant.create
        precondition(AccessSummary.segments(grants: [ClientGrant(resource: .calendar, targetID: "hol", mask: readCreate)],
                                            collections: [holidays]) == ["US Holidays: read"])
        precondition(AccessSummary.hasUngrantableBits(
            grants: [ClientGrant(resource: .calendar, targetID: "hol", mask: readCreate)], collections: [holidays]))
        precondition(AccessSummary.segments(grants: [ClientGrant(resource: .calendar, targetID: "wrk", mask: readCreate)],
                                            collections: [workCalendar]) == ["Work: read, create"])
        precondition(!AccessSummary.hasUngrantableBits(
            grants: [ClientGrant(resource: .calendar, targetID: "wrk", mask: readCreate)], collections: [workCalendar]))
        // Unlisted collections aren't flagged: they're unavailable, not read only.
        precondition(!AccessSummary.hasUngrantableBits(
            grants: [ClientGrant(resource: .calendar, targetID: "gone", mask: readCreate)], collections: [holidays]))
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "UTC")!
        let october5 = gregorian.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 9))!
        let october8 = gregorian.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 9))!
        let lastYear = gregorian.date(from: DateComponents(year: 2025, month: 10, day: 5, hour: 9))!
        precondition(!RelativeTime.clock(october5, now: october8, calendar: gregorian).contains("2026"))
        precondition(RelativeTime.clock(lastYear, now: october8, calendar: gregorian).contains("2025"))
        precondition(RelativeTime.ago(noonYesterday, now: lateToday) == "Yesterday")
        precondition(ConnectCommand.scopeStatus(clientName: "Claude Code") ==
                     #"python3 client.py scope_status --client "Claude Code""#)
        let twinA = ClientView(id: "a", name: "Twin", revoked: false, grants: [])
        let twinB = ClientView(id: "b", name: "twin ", revoked: false, grants: [])
        let gone = ClientView(id: "c", name: "Solo", revoked: true, grants: [])
        let solo = ClientView(id: "d", name: "Solo", revoked: false, grants: [])
        precondition(ConnectCommand.scopeStatus(for: twinA, among: [twinA, twinB]) ==
                     "python3 client.py scope_status --client a", "ambiguous names use the ID")
        precondition(ConnectCommand.scopeStatus(for: solo, among: [twinA, gone, solo]) ==
                     #"python3 client.py scope_status --client "Solo""#)
        precondition(ConnectCommand.scopeStatus(for: solo, among: [solo], program: "bridge-client") ==
                     #"bridge-client scope_status --client "Solo""#, "the installed tool")
        precondition(ConnectCommand.scopeStatus(for: twinA, among: [twinA, twinB], program: "bridge-client") ==
                     "bridge-client scope_status --client a")
        precondition(ConnectCommand.shellQuoted("It's $HOME") == #"'It'\''s $HOME'"#)
        precondition(ConnectCommand.shellQuoted("/Users/x/Library/Application Support/k.json") ==
                     #""/Users/x/Library/Application Support/k.json""#)
    }

    static func info(_ resource: ClientResource, _ id: String, _ name: String,
                     _ account: String, writable: Bool = true) -> CollectionInfo {
        CollectionInfo(resource: resource, id: id, name: name, account: account,
                       writable: writable, color: nil)
    }
}
