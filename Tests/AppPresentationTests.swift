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
                     unknown.why == "EK Bridge returned mystery_code.")
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
        // Three steps, with raw values that never reuse 0.8's.
        precondition(Step.macOSAccess.rawValue == 10 && Step.addConnection.rawValue == 11 &&
                     Step.connect.rawValue == 12, "stored skipped steps keep their meaning")
        precondition(Step.mcpServer.rawValue == 7 && Step.testRequest.rawValue == 6 &&
                     Step.calendarAccess.rawValue == 1 && Step.remindersAccess.rawValue == 2)
        var input = SetupChecklist.Input(calendar: .notDetermined, reminders: .notDetermined,
                                         clients: [], bridgeOn: false, successfulClientIDs: [])
        precondition(SetupChecklist.steps(input) == [.macOSAccess, .addConnection, .connect])
        var states = SetupChecklist.states(input)
        precondition(states == [.macOSAccess: .current, .addConnection: .pending, .connect: .pending])
        // macOS access: one type allowed and the other decided (allowed, off, or skipped).
        input.calendar = .fullAccess
        precondition(SetupChecklist.states(input)[.macOSAccess] == .current, "Reminders still undecided")
        for (reminders, skipped) in [(EKAuthorizationStatus.fullAccess, false), (.denied, false), (.notDetermined, true)] {
            var decided = input
            decided.reminders = reminders
            if skipped { decided.skipped = [.remindersAccess] }
            precondition(SetupChecklist.states(decided)[.macOSAccess] == .done, "reminders \(reminders) \(skipped)")
        }
        var onlyReminders = input
        onlyReminders.calendar = .denied
        onlyReminders.reminders = .fullAccess
        precondition(SetupChecklist.isDone(.macOSAccess, onlyReminders))
        var neither = input
        neither.calendar = .denied
        neither.reminders = .denied
        precondition(!SetupChecklist.isDone(.macOSAccess, neither), "nothing allowed isn't done")
        var skippedBoth = input
        skippedBoth.calendar = .notDetermined
        skippedBoth.skipped = [.calendarAccess, .remindersAccess]
        precondition(!SetupChecklist.isDone(.macOSAccess, skippedBoth), "skipping both isn't done")
        input.reminders = .fullAccess
        states = SetupChecklist.states(input)
        precondition(states[.macOSAccess] == .done && states[.addConnection] == .current &&
                     states[.connect] == .pending)
        // Add your agent: done once a connection has some access.
        var client = ClientView(id: "c", name: "Claude Code", revoked: false, grants: [])
        input.clients = [client]
        precondition(SetupChecklist.states(input)[.addConnection] == .current, "no access yet")
        precondition(SetupChecklist.focusClient(input)?.id == "c")
        client = ClientView(id: "c", name: "Claude Code", revoked: false, grants: [
            ClientGrant(resource: .calendar, targetID: "w", mask: 1)])
        input.clients = [client]
        states = SetupChecklist.states(input)
        precondition(states[.addConnection] == .done && states[.connect] == .current)
        precondition(!SetupChecklist.isComplete(input))
        // Connect: done with the first successful request (EK Bridge on or not when checked).
        input.successfulClientIDs = ["c"]
        precondition(SetupChecklist.isComplete(input))
        // Out of order: a request before macOS access is decided still leaves that step.
        var early = input
        early.calendar = .notDetermined
        early.reminders = .notDetermined
        precondition(SetupChecklist.states(early) == [.macOSAccess: .current, .addConnection: .done, .connect: .done])
        // A removed connection's request doesn't complete setup, nor does its access count.
        let revoked = SetupChecklist.Input(
            calendar: .fullAccess, reminders: .fullAccess,
            clients: [ClientView(id: "r", name: "Old", revoked: true, grants: [
                ClientGrant(resource: .calendar, targetID: "w", mask: 1)])],
            bridgeOn: true, successfulClientIDs: ["r"])
        precondition(SetupChecklist.states(revoked)[.addConnection] == .current &&
                     SetupChecklist.states(revoked)[.connect] == .pending)
        precondition(SetupChecklist.isDone(.testRequest, input), "0.8's step still answers for existing installs")
        var agent = ClientView(id: "a", name: "Agent", revoked: false, grants: [])
        agent.hasSigningKey = false
        agent.hasMCPToken = true
        precondition(ClientTransport(agent).badge == "MCP" && ClientTransport(client).badge == "CLI")
        agent.hasSigningKey = true
        precondition(ClientTransport(agent).badge == "MCP + CLI")
    }

    static func activity() {
        let now = Date()
        var serial = 0
        func row(_ at: Date, _ client: String?, _ command: String, _ outcome: String,
                 _ target: String? = nil) -> ActivityRecord {
            serial += 1
            let phase = outcome == "accepted" ? ActivityRecord.start : ActivityRecord.result
            var record = ActivityRecord(id: "\(client ?? "-")|r\(serial)|\(phase)", requestID: "\(client ?? "-")|r\(serial)",
                                        phase: phase, at: at, clientID: client, command: command, outcome: outcome)
            record.targetID = target
            return record
        }
        let rows = [
            row(now, "a", "read_events", "success", "w"),
            row(now, "a", "read_events", "accepted", "w"),
            row(now.addingTimeInterval(-60), "b", "create_reminder", "forbidden", "g"),
            row(now.addingTimeInterval(-120), nil, "read_events", "unauthorized"),
            row(now.addingTimeInterval(-86_400 * 3), "b", "update_event", "error:conflict"),
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
        // Changes are writes that went through; problems are any problem row.
        let writes = ActivityEntry.entries(from: [
            row(now, "a", "update_event", "success", "w"),
            row(now, "a", "create_reminder", "forbidden", "l"),
            row(now, "a", "read_events", "success", "w"),
            row(now, "a", "delete_event", "error:approval_denied", "w"),
        ])
        let counts = ActivityStats.today(writes, now: now)
        precondition(counts.requests == 4 && counts.changes == 1 && counts.problems == 1,
                     "\(counts.changes) changes, \(counts.problems) problems")
        precondition(writes.filter(\.isWrite).count == 3)
        // Needs you: order, the update only without its card, and nothing when all is well.
        let gone = NeedsYou.Unavailable(connectionID: "c", connectionName: "Claude Code",
                                        key: GrantKey(resource: .calendar, targetID: "x"), name: "Project", mask: 1)
        let items = NeedsYou.items(pendingApprovals: 2, problems: [.bridgeFailed], unavailable: [gone],
                                   unseenProblems: 3, lastViewed: now, update: ("1.0", false), updateCardShown: false)
        precondition(items == [.approvals(2), .problem(.bridgeFailed),
                               .unavailable(connectionID: "c", connectionName: "Claude Code",
                                            key: GrantKey(resource: .calendar, targetID: "x"), name: "Project", mask: 1),
                               .refused(count: 3, since: now), .update(version: "1.0", critical: false)])
        precondition(NeedsYou.items(pendingApprovals: 0, problems: [], unavailable: [], unseenProblems: 0,
                                    lastViewed: nil, update: ("1.0", true), updateCardShown: true).isEmpty)
        precondition(NeedsYou.items(pendingApprovals: 0, problems: [], unavailable: [], unseenProblems: 0,
                                    lastViewed: nil, update: nil, updateCardShown: false).isEmpty)
        precondition(ActivityStats.unseenProblems(entries, since: nil) == 3)
        precondition(ActivityStats.unseenProblems(entries, since: now.addingTimeInterval(-90)) == 1)
        // C02: change labels, the Changes filter, Approved, day headers.
        precondition(CommandPresentation.pastTense("create_event") == "Added event")
        precondition(CommandPresentation.pastTense("update_event", moved: true) == "Moved event")
        precondition(CommandPresentation.pastTense("update_reminder") == "Changed reminder")
        precondition(CommandPresentation.pastTense("complete_reminder") == "Completed")
        precondition(CommandPresentation.pastTense("read_events") == nil)
        precondition(CommandPresentation.changeLabel("delete_reminder", moved: false, succeeded: false) == "Delete reminder")
        precondition(CommandPresentation.changeLabel("read_events", moved: false, succeeded: true) == "Read events")
        precondition(CommandPresentation.allChangeLabels.contains("Moved reminder"))
        var moved = row(now, "a", "update_event", "success", "w")
        moved.destinationID = "h"
        moved.approval = "user"
        let movedEntry = ActivityEntry.entries(from: [moved])[0]
        precondition(movedEntry.isMove && movedEntry.changeLabel == "Moved event" && movedEntry.resultLabel == "Approved")
        precondition(writes.filter { $0.matches(.changes) }.count == 3 && writes.filter { $0.matches(.problems) }.count == 1)
        precondition(writes.filter { $0.matches(.all) }.count == 4)
        precondition(writes[0].resultLabel == "Allowed")
        // C06: "Moved “Design review”", or the change and calendar without a name.
        precondition(movedEntry.headline(item: "Design review", collection: "Work") == "Moved “Design review”")
        precondition(movedEntry.headline(item: nil, collection: "Work") == "Moved event · Work")
        precondition(writes[1].headline(item: "Milk", collection: "Groceries") == "Add “Milk”", "not allowed: present tense")
        precondition(writes[2].headline(item: "x", collection: "Work") == "Read events · Work", "reads have no item verb")
        precondition(CommandPresentation.verb("complete_reminder", moved: false, succeeded: true) == "Completed")
        // Day groups: newest first, across a daylight-saving change (US, Nov 1 2026).
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        func at(_ day: Int, _ hour: Int) -> Date {
            newYork.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
        }
        let dstRows = [row(at(2, 1), "a", "read_events", "success"), row(at(1, 23), "a", "read_events", "success"),
                       row(at(1, 1), "a", "read_events", "success"), row(at(1, 0), "a", "read_events", "success"),
                       row(at(31, 12).addingTimeInterval(-31 * 86_400), "a", "read_events", "success")]
        let days = ActivityDays.group(ActivityEntry.entries(from: dstRows), now: at(2, 9), calendar: newYork)
        precondition(days.map(\.entries.count) == [1, 3, 1], "\(days.map(\.entries.count))")
        precondition(days.map(\.title)[0...1] == ["Today", "Yesterday"])
        precondition(days[2].id == "2026-10-31" && days[2].title.contains("October 31"), days[2].title)
        let lastYear = ActivityDays.title(at(2, 9).addingTimeInterval(-400 * 86_400), now: at(2, 9), calendar: newYork)
        precondition(lastYear.contains("2025"), lastYear)
        let again = ActivityEntry.entries(from: [row(now, "x", "read_events", "success")] + rows)
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
        // Pause for…: an hour, 8:00 the next local morning (across DST changes), or open-ended.
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let utc = ISO8601DateFormatter()
        let fallEve = utc.date(from: "2026-11-01T02:00:00Z")!  // Oct 31, 22:00 EDT
        precondition(PauseSchedule.resumeDate(.untilTomorrow, now: fallEve, calendar: newYork)
                     == utc.date(from: "2026-11-01T13:00:00Z")!, "Nov 1, 8:00 EST")
        let springEve = utc.date(from: "2026-03-08T03:00:00Z")!  // Mar 7, 22:00 EST
        precondition(PauseSchedule.resumeDate(.untilTomorrow, now: springEve, calendar: newYork)
                     == utc.date(from: "2026-03-08T12:00:00Z")!, "Mar 8, 8:00 EDT")
        let earlyMorning = utc.date(from: "2026-10-08T06:30:00Z")!  // 2:30 EDT: still the next day
        precondition(PauseSchedule.resumeDate(.untilTomorrow, now: earlyMorning, calendar: newYork)
                     == utc.date(from: "2026-10-09T12:00:00Z")!)
        precondition(PauseSchedule.resumeDate(.oneHour, now: fallEve, calendar: newYork)
                     == fallEve.addingTimeInterval(3_600))
        precondition(PauseSchedule.resumeDate(.untilTurnedOn, now: fallEve, calendar: newYork) == nil)
        let afternoon = utc.date(from: "2026-10-08T18:00:00Z")!
        precondition(PauseSchedule.untilText(afternoon.addingTimeInterval(3_600), now: afternoon, calendar: newYork)
                     .hasPrefix("until ") &&
                     !PauseSchedule.untilText(afternoon.addingTimeInterval(3_600), now: afternoon,
                                              calendar: newYork).contains("tomorrow"))
        precondition(PauseSchedule.untilText(utc.date(from: "2026-10-09T12:00:00Z")!, now: afternoon,
                                             calendar: newYork).hasPrefix("until tomorrow at "))
        // The Remote Access guide's step is derived from what's done.
        func guide(_ chosen: Bool, _ on: Bool, _ started: Bool, _ origin: String?, _ reachable: Bool) -> RemoteGuide.Step {
            RemoteGuide.step(tunnelChosen: chosen, remoteOn: on, started: started, origin: origin, reachable: reachable)
        }
        precondition(guide(false, false, false, nil, false) == .chooseTunnel)
        precondition(guide(false, true, true, "https://a", true) == .chooseTunnel, "choosing again starts over")
        precondition(guide(true, false, false, nil, false) == .startTunnel)
        precondition(guide(true, false, true, "https://a", false) == .startTunnel, "Remote Access off")
        precondition(guide(true, true, false, nil, false) == .startTunnel, "on, not started yet")
        precondition(guide(true, true, true, nil, false) == .pasteAddress)
        precondition(guide(true, true, false, "https://a", false) == .test, "an address means it was started")
        precondition(guide(true, true, true, "https://a", false) == .test)
        precondition(guide(true, true, true, "https://a", true) == .done)
        // The local MCP server runs only while EK Bridge is on, allowed, and used.
        precondition(MCPRunPolicy.shouldRun(bridgeOn: true, allowed: true, hasMCPConnections: true))
        precondition(!MCPRunPolicy.shouldRun(bridgeOn: false, allowed: true, hasMCPConnections: true))
        precondition(!MCPRunPolicy.shouldRun(bridgeOn: true, allowed: false, hasMCPConnections: true))
        precondition(!MCPRunPolicy.shouldRun(bridgeOn: true, allowed: true, hasMCPConnections: false))
        // 0.8's switch: never touched or on → allowed; off stays off only without MCP connections.
        precondition(MCPRunPolicy.migratedAllowed(old: nil, hasMCPConnections: false))
        precondition(MCPRunPolicy.migratedAllowed(old: true, hasMCPConnections: false))
        precondition(MCPRunPolicy.migratedAllowed(old: false, hasMCPConnections: true))
        precondition(!MCPRunPolicy.migratedAllowed(old: false, hasMCPConnections: false))
        precondition(MenuBarGlyphState.for(needsAttention: false, bridgeOn: true) == .on)
        precondition(MenuBarGlyphState.for(needsAttention: false, bridgeOn: false) == .paused)
        precondition(MenuBarGlyphState.for(needsAttention: true, bridgeOn: true) == .attention)
        precondition(MenuBarGlyphState.for(needsAttention: true, bridgeOn: false) == .attention)
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
