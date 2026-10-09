import Foundation

@main
struct RequestPipelineTests {
    static func main() {
        MainActor.assumeIsolated { run() }
    }

    // MARK: Fakes

    @MainActor
    final class Executor: BridgeCommandExecutor {
        enum Mode { case immediate, hold }
        var mode = Mode.immediate
        private(set) var calls = [(command: BridgeCommand, clientID: String, selected: BridgeScope)]()
        private var held = [(stillAuthorized: () -> Bool, completion: ([String: Any]) -> Void)]()

        var heldCount: Int { held.count }
        /// What an immediate call returns, when set.
        var result: [String: Any]?

        func runAuthorized(_ request: BridgeRequest, clientID: String, selected: BridgeScope,
                           stillAuthorized: @escaping () -> Bool, isCancelled: @escaping () -> Bool,
                           completion: @escaping ([String: Any]) -> Void) {
            calls.append((request.command, clientID, selected))
            switch mode {
            case .immediate: completion(result ?? ["ok": true, "command": request.command.rawValue])
            case .hold: held.append((stillAuthorized, completion))
            }
        }

        /// Completes the oldest held call asynchronously, as EventKit would.
        func completeOldest(_ result: [String: Any] = ["ok": true]) {
            let entry = held.removeFirst()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    entry.completion(entry.stillAuthorized() ? result : ["error": "scope_changed"])
                }
            }
        }
    }

    @MainActor
    final class Collections: CollectionSource {
        var calendarsAccess = "full"
        var remindersAccess = "denied"

        func access(_ resource: ClientResource) -> String {
            resource == .calendar ? calendarsAccess : remindersAccess
        }
        func collections(_ resource: ClientResource) -> [CollectionRecord]? {
            guard access(resource) == "full" else { return nil }
            return resource == .calendar
                ? [CollectionRecord(id: "CAL-A", name: "Work", account: "iCloud", writable: true),
                   CollectionRecord(id: "CAL-RO", name: "Holidays", account: "Subscribed", writable: false),
                   CollectionRecord(id: "CAL-OTHER", name: "Private", account: "iCloud", writable: true)]
                : [CollectionRecord(id: "LIST-A", name: "Groceries", account: "iCloud", writable: true),
                   CollectionRecord(id: "LIST-OTHER", name: "Secret", account: "iCloud", writable: true)]
        }
    }

    @MainActor
    final class Gate: ApprovalGate {
        enum Mode { case allow, window, deny, timeout, withdraw, never, tooMany }
        var mode = Mode.never
        private(set) var asked = [ApprovalRequest]()
        private var waiting = [(id: UUID, completion: (ApprovalDecision) -> Void)]()

        var waitingCount: Int { waiting.count }

        func request(_ approval: ApprovalRequest,
                     completion: @escaping (ApprovalDecision) -> Void) -> () -> Void {
            asked.append(approval)
            switch mode {
            case .allow: completion(.allowed)
            case .window: completion(.allowedByWindow)
            case .deny: completion(.denied)
            case .timeout: completion(.timedOut)
            case .withdraw: completion(.withdrawn)
            case .tooMany: completion(.tooMany)
            case .never:
                let id = UUID()
                waiting.append((id, completion))
                return { [weak self] in self?.resolve(id, .withdrawn) }
            }
            return {}
        }

        func answer(_ decision: ApprovalDecision) {
            resolve(waiting[0].id, decision)
        }

        private func resolve(_ id: UUID, _ decision: ApprovalDecision) {
            guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
            waiting.remove(at: index).completion(decision)
        }
    }

    @MainActor
    final class Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("eventkit-pipeline-\(UUID().uuidString)")
        let registry: ClientRegistry
        let executor = Executor()
        let collections = Collections()
        let gate = Gate()
        var bridgeOn = true
        var limiterClock: TimeInterval = 2_000_000_000
        var records = 0
        let limiter: RateLimiter
        var pipeline: RequestPipeline!
        let clientID: String

        init(approval: ApprovalMode = .allow, policy: RateLimiter.Policy = RateLimiter.Policy(),
             grants: [ClientGrant]? = nil) {
            let registry = ClientRegistry(directory: directory,
                                          now: { Date(timeIntervalSince1970: 2_000_000_000) })
            self.registry = registry
            var limiterNow: () -> TimeInterval = { 0 }
            limiter = RateLimiter(policy: policy, now: { limiterNow() })
            let clientID = RequestPipelineTests.value(
                registry.createClient(name: "Agent", credentials: [.mcpToken], approval: approval)).id
            self.clientID = clientID
            RequestPipelineTests.success(registry.replaceGrants(clientID: clientID, grants: grants ?? [
                ClientGrant(resource: .calendar, targetID: "CAL-A",
                            mask: ClientGrant.read | ClientGrant.create),
                ClientGrant(resource: .reminderList, targetID: "LIST-A",
                            mask: ClientGrant.read | ClientGrant.create | ClientGrant.complete),
            ]))
            pipeline = RequestPipeline(registry: registry, commands: executor, collections: collections,
                                       approvals: gate, limiter: limiter,
                                       bridgeActive: { [unowned self] in self.bridgeOn },
                                       didRecord: { [unowned self] in self.records += 1 })
            limiterNow = { [unowned self] in self.limiterClock }
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        /// Runs a request; the reply, or nil while it's still waiting.
        @discardableResult
        func send(_ request: BridgeRequest, client: String? = nil,
                  origin: RequestOrigin = .mcp(agent: "Claude Code 2.4.1")) -> Box {
            let box = Box()
            box.ticket = pipeline.handle(request, clientID: client ?? clientID, origin: origin) {
                precondition(box.reply == nil, "completion called twice")
                box.reply = $0
            }
            return box
        }

        var lastRow: ActivityRecord { registry.activity()!.first! }
    }

    @MainActor
    final class Box {
        var reply: [String: Any]?
        var ticket: PipelineTicket?
        var error: String? { reply?["error"] as? String }
    }

    // MARK: Requests

    static func readEvents(_ calendar: String = "CAL-A", limit: Int = 10) -> BridgeRequest {
        BridgeRequest(id: UUID().uuidString, command: .readEvents, parameters: [
            "calendarID": calendar, "start": 1_800_000_000.0, "end": 1_800_003_600.0, "limit": limit])
    }
    static func createEvent(_ calendar: String = "CAL-A", title: String = "Dentist") -> BridgeRequest {
        BridgeRequest(id: UUID().uuidString, command: .createEvent, parameters: [
            "calendarID": calendar, "title": title, "start": 1_800_000_000.0, "end": 1_800_003_600.0,
            "idempotencyKey": WriteIdempotencyKey.make()])
    }
    static func plain(_ command: BridgeCommand) -> BridgeRequest {
        BridgeRequest(id: UUID().uuidString, command: command, parameters: [:])
    }

    // MARK: Tests

    @MainActor
    static func run() {
        bridgeOff()
        clientPaused()
        rateLimits()
        authorizeBeforeValidation()
        approvals()
        changesWhileWaiting()
        inFlight()
        inlineCommands()
        originsMatch()
        activityFields()
        print("Request pipeline: bridge_off, client_paused, rate limits, authorize before validation, approvals "
              + "(user/window/denied/timeout/withdrawn/tooMany), changes and cancellation while waiting, "
              + "8 in flight, list_collections, counts, scope_status, CLI = MCP rows, request IDs, "
              + "item refs, missing access and move destinations passed")
    }

    /// C01: rows carry the request ID, writes their item, refusals the
    /// missing bit, and moves their destination.
    @MainActor
    static func activityFields() {
        let f = Fixture(grants: [
            ClientGrant(resource: .calendar, targetID: "CAL-A",
                        mask: ClientGrant.read | ClientGrant.create | ClientGrant.edit),
            ClientGrant(resource: .calendar, targetID: "CAL-RO", mask: ClientGrant.read),
        ])
        f.executor.result = ["item": ["id": "EV-NEW", "version": "1"]]
        let create = createEvent()
        precondition(f.send(create).reply?["item"] != nil)
        let rows = f.registry.activity()!
        precondition(rows[0].phase == ActivityRecord.result && rows[1].phase == ActivityRecord.start)
        precondition(rows[0].requestID == "\(f.clientID)|\(create.id)" && rows[0].requestID == rows[1].requestID)
        precondition(rows[0].item == ItemRef(kind: "event", id: "EV-NEW"), "\(rows[0])")
        precondition(rows[1].item == nil, "the start row has no item")
        // Reads never store an item.
        f.executor.result = ["items": [["id": "EV-NEW"]]]
        f.send(readEvents())
        precondition(f.lastRow.item == nil && f.lastRow.outcome == "success")
        // Forbidden: no grant for the action on that calendar → the missing bit.
        f.send(createEvent("CAL-RO"))
        precondition(f.lastRow.outcome == "forbidden" && f.lastRow.missing == ClientGrant.create &&
                     f.lastRow.phase == ActivityRecord.event && f.lastRow.destinationID == nil)
        f.send(BridgeRequest(id: UUID().uuidString, command: .deleteEvent,
                             parameters: ["calendarID": "CAL-A", "itemID": "EV1"]))
        precondition(f.lastRow.missing == ClientGrant.delete && f.lastRow.targetID == "CAL-A")
        // A move refused on its destination: Create there, and which one.
        f.send(BridgeRequest(id: UUID().uuidString, command: .updateEvent, parameters: [
            "calendarID": "CAL-A", "itemID": "EV1", "expectedVersion": "1", "targetCalendarID": "CAL-RO"]))
        precondition(f.lastRow.outcome == "forbidden" && f.lastRow.missing == ClientGrant.create &&
                     f.lastRow.destinationID == "CAL-RO" && f.lastRow.targetID == "CAL-A", "\(f.lastRow)")
        // A refused update still names its item when the request did.
        f.executor.result = ["error": "conflict"]
        f.send(BridgeRequest(id: UUID().uuidString, command: .updateEvent, parameters: [
            "calendarID": "CAL-A", "itemID": "EV1", "expectedVersion": "1791200000.123456", "title": "x",
            "idempotencyKey": WriteIdempotencyKey.make()]))
        precondition(f.lastRow.outcome == "error:conflict" && f.lastRow.item?.id == "EV1", "\(f.lastRow)")
        // A move that went through records its destination on both rows.
        f.executor.result = ["item": ["id": "EV1"]]
        let grants = f.registry.clients()!.first!.grants
        success(f.registry.replaceGrants(clientID: f.clientID, grants: grants.map {
            $0.targetID == "CAL-RO" ? ClientGrant(resource: .calendar, targetID: "CAL-RO", mask: 3) : $0 }))
        f.send(BridgeRequest(id: UUID().uuidString, command: .updateEvent, parameters: [
            "calendarID": "CAL-A", "itemID": "EV1", "expectedVersion": "1791200000.123456",
            "targetCalendarID": "CAL-RO", "idempotencyKey": WriteIdempotencyKey.make()]))
        precondition(f.registry.activity()!.prefix(2).allSatisfy { $0.destinationID == "CAL-RO" })
        precondition(f.lastRow.outcome == "success" && f.lastRow.item?.id == "EV1")
    }

    @MainActor
    static func bridgeOff() {
        let f = Fixture(approval: .ask)
        f.bridgeOn = false
        // Even a request that would fail every later check gets bridge_off.
        for request in [createEvent(), readEvents("CAL-NOT-GRANTED", limit: 0), plain(.listCollections)] {
            let box = f.send(request)
            precondition(box.error == "bridge_off" && box.reply?.count == 1)
            precondition(f.lastRow.outcome == "error:bridge_off")
            precondition(f.lastRow.via == "mcp" && f.lastRow.agent == "Claude Code 2.4.1")
            precondition(f.lastRow.clientID == f.clientID)
            precondition(f.lastRow.command == request.command.rawValue)
        }
        precondition(f.registry.activity()!.map(\.targetID) == [nil, "CAL-NOT-GRANTED", "CAL-A"])
        precondition(f.executor.calls.isEmpty && f.gate.asked.isEmpty && f.records == 3)
        precondition(!f.registry.activity()!.contains { $0.outcome == "accepted" })
        // Bridge-off requests take no rate-limit tokens.
        var policy = RateLimiter.Policy()
        policy.callBurst = 1
        let g = Fixture(policy: policy)
        g.bridgeOn = false
        for _ in 0..<5 { precondition(g.send(readEvents()).error == "bridge_off") }
        g.bridgeOn = true
        precondition(g.send(readEvents()).reply?["ok"] as? Bool == true)
        // CLI origin: the row says so.
        g.bridgeOn = false
        g.send(readEvents(), origin: .cli)
        precondition(g.lastRow.via == "cli" && g.lastRow.agent == nil)
    }

    @MainActor
    static func clientPaused() {
        var policy = RateLimiter.Policy()
        policy.callBurst = 1
        let f = Fixture(approval: .ask, policy: policy)
        let other = value(f.registry.createClient(name: "Other", credentials: [.mcpToken]))
        success(f.registry.replaceGrants(clientID: other.id, grants: [
            ClientGrant(resource: .calendar, targetID: "CAL-A", mask: ClientGrant.read)]))
        success(f.registry.setPaused(clientID: f.clientID, true))
        // Every request, even one that would fail later checks, is refused
        // before rate limits, grants, validation and approvals.
        for request in [createEvent(), readEvents("CAL-NOT-GRANTED", limit: 0), plain(.listCollections),
                        readEvents(), readEvents()] {
            let box = f.send(request)
            precondition(box.error == "client_paused" && box.reply?.count == 1)
            precondition(f.lastRow.outcome == "error:client_paused" && f.lastRow.clientID == f.clientID)
            precondition(f.lastRow.via == "mcp" && f.lastRow.agent == "Claude Code 2.4.1")
        }
        precondition(f.registry.activity()!.map(\.targetID) == ["CAL-A", "CAL-A", nil, "CAL-NOT-GRANTED", "CAL-A"])
        precondition(f.executor.calls.isEmpty && f.gate.asked.isEmpty && f.records == 5)
        precondition(!f.registry.activity()!.contains { $0.outcome == "accepted" })
        // Other clients are unaffected.
        precondition(f.send(readEvents(), client: other.id).reply?["ok"] as? Bool == true)
        // The bridge switch comes first.
        f.bridgeOn = false
        precondition(f.send(readEvents(), origin: .cli).error == "bridge_off")
        f.bridgeOn = true
        // Resumed: no rate-limit tokens were spent while paused, and access is as before.
        success(f.registry.setPaused(clientID: f.clientID, false))
        precondition(f.send(readEvents()).reply?["ok"] as? Bool == true)
        precondition(f.lastRow.outcome == "success")
        // Paused while a change waits for approval, then Allow → scope_changed.
        let w = Fixture(approval: .ask)
        let waiting = w.send(createEvent())
        precondition(waiting.reply == nil && w.gate.waitingCount == 1)
        success(w.registry.setPaused(clientID: w.clientID, true))
        w.gate.answer(.allowed)
        precondition(waiting.error == "scope_changed" && w.executor.calls.isEmpty)
        // Paused while a read runs in EventKit → scope_changed at the recheck.
        let r = Fixture()
        r.executor.mode = .hold
        let running = r.send(readEvents())
        success(r.registry.setPaused(clientID: r.clientID, true))
        r.executor.completeOldest()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(running.error == "scope_changed")
        // And resumed afterwards, the same client works again.
        success(r.registry.setPaused(clientID: r.clientID, false))
        r.executor.mode = .immediate
        precondition(r.send(readEvents()).reply?["ok"] as? Bool == true)
    }

    @MainActor
    static func rateLimits() {
        var policy = RateLimiter.Policy()
        policy.callBurst = 2
        policy.callsPerMinute = 6
        let f = Fixture(policy: policy)
        precondition(f.send(readEvents()).reply?["ok"] as? Bool == true)
        precondition(f.send(readEvents()).reply?["ok"] as? Bool == true)
        let limited = f.send(readEvents())
        precondition(limited.error == "rate_limited" && limited.reply?["retryAfter"] as? Int == 10)
        precondition(f.lastRow.outcome == "error:rate_limited" && f.lastRow.targetID == "CAL-A")
        precondition(f.lastRow.via == "mcp")
        // Before the grant check: a forbidden target is still just rate limited.
        let forbidden = f.send(readEvents("CAL-NOT-GRANTED"))
        precondition(forbidden.error == "rate_limited")
        precondition(f.executor.calls.count == 2)
        f.limiterClock += 10
        precondition(f.send(readEvents("CAL-NOT-GRANTED")).error == "forbidden")
        // Writes use the write bucket too.
        var writes = RateLimiter.Policy()
        writes.writeBurst = 1
        let w = Fixture(policy: writes)
        precondition(w.send(createEvent()).reply?["ok"] as? Bool == true)
        let second = w.send(createEvent())
        precondition(second.error == "rate_limited" && second.reply?["retryAfter"] as? Int == 3)
        precondition(w.send(readEvents()).reply?["ok"] as? Bool == true)
    }

    @MainActor
    static func authorizeBeforeValidation() {
        let f = Fixture(approval: .ask)
        // Not granted and malformed: the grant failure wins.
        let forbidden = f.send(readEvents("CAL-NOT-GRANTED", limit: 0))
        precondition(forbidden.error == "forbidden" && forbidden.reply?.count == 1)
        precondition(f.lastRow.outcome == "forbidden" && f.lastRow.targetID == "CAL-NOT-GRANTED")
        // Granted calendar, but no Create on the list for an edit.
        let edit = BridgeRequest(id: UUID().uuidString, command: .updateReminder, parameters: [
            "listID": "LIST-A", "itemID": "R1", "expectedVersion": "1", "title": "x",
            "idempotencyKey": WriteIdempotencyKey.make()])
        precondition(f.send(edit).error == "forbidden")
        // A target-less item command is forbidden too.
        precondition(f.send(BridgeRequest(id: UUID().uuidString, command: .readEvents,
                                          parameters: [:])).error == "forbidden")
        // Unknown client.
        let unknown = f.send(readEvents(), client: UUID().uuidString.lowercased())
        precondition(unknown.error == "unauthorized" && f.lastRow.clientID == nil)
        // Granted but invalid: policy error, executor and approval untouched.
        let invalid = f.send(readEvents(limit: 0))
        precondition(invalid.error == "invalid_parameters_or_target")
        precondition(f.lastRow.outcome == "error:invalid_parameters_or_target")
        var badWrite = createEvent()
        badWrite = BridgeRequest(id: badWrite.id, command: .createEvent,
                                 parameters: badWrite.parameters.merging(["title": "  "]) { _, new in new })
        precondition(f.send(badWrite).error == "invalid_parameters_or_target")
        let extraKey = BridgeRequest(id: UUID().uuidString, command: .listCollections,
                                     parameters: ["calendarID": "CAL-A"])
        precondition(f.send(extraKey).error == "invalid_parameters")
        precondition(f.executor.calls.isEmpty && f.gate.asked.isEmpty)
        // Each refused request still left its rows; nothing reached "success".
        precondition(!f.registry.activity()!.contains { $0.outcome == "success" })
    }

    @MainActor
    static func approvals() {
        // Reads never ask, even with Ask before changes.
        let f = Fixture(approval: .ask)
        f.gate.mode = .deny
        precondition(f.send(readEvents()).reply?["ok"] as? Bool == true)
        precondition(f.send(plain(.listCollections)).reply?["collections"] != nil)
        precondition(f.gate.asked.isEmpty)
        // Allow-mode clients never ask.
        let allowing = Fixture(approval: .allow)
        allowing.gate.mode = .deny
        precondition(allowing.send(createEvent()).reply?["ok"] as? Bool == true)
        precondition(allowing.gate.asked.isEmpty && allowing.lastRow.approval == nil)
        precondition(allowing.lastRow.outcome == "success")

        let cases: [(Gate.Mode, error: String?, detail: String?)] = [
            (.allow, nil, "user"),
            (.window, nil, "window"),
            (.deny, "approval_denied", "denied"),
            (.timeout, "approval_timed_out", "timeout"),
            (.withdraw, "scope_changed", nil),
            (.tooMany, "rate_limited", nil),
        ]
        for (mode, error, detail) in cases {
            let g = Fixture(approval: .ask)
            g.gate.mode = mode
            let box = g.send(createEvent(title: "Dentist"))
            precondition(g.gate.asked.count == 1)
            let asked = g.gate.asked[0]
            precondition(asked.clientID == g.clientID && asked.clientName == "Agent")
            precondition(asked.agent == "Claude Code 2.4.1" && asked.targetID == "CAL-A")
            precondition(asked.request.command == .createEvent && asked.revision > 0)
            precondition(asked.requestID == "\(g.clientID)|\(asked.request.id)" &&
                         asked.requestID == g.lastRow.requestID, "C03: the answer joins the row")
            precondition(box.error == error, "\(mode): \(String(describing: box.reply))")
            precondition(g.executor.calls.count == (error == nil ? 1 : 0), "\(mode)")
            precondition(g.lastRow.approval == detail, "\(mode)")
            precondition(g.lastRow.outcome == (error.map { "error:\($0)" } ?? "success"))
            precondition(g.lastRow.via == "mcp" && g.lastRow.targetID == "CAL-A")
            if mode == .tooMany { precondition(box.reply?["retryAfter"] as? Int == 45) }
            if error == nil {
                precondition(g.executor.calls[0].selected.calendarID == "CAL-A")
                precondition(g.executor.calls[0].selected.reminderListID == nil)
            }
        }
        // Writes on reminder lists ask too.
        let r = Fixture(approval: .ask)
        r.gate.mode = .allow
        let complete = BridgeRequest(id: UUID().uuidString, command: .completeReminder, parameters: [
            "listID": "LIST-A", "itemID": "R1", "expectedVersion": "1",
            "idempotencyKey": WriteIdempotencyKey.make()])
        precondition(r.send(complete).reply?["ok"] as? Bool == true && r.gate.asked.count == 1)
        precondition(r.executor.calls[0].selected.reminderListID == "LIST-A")
    }

    @MainActor
    static func changesWhileWaiting() {
        // A grant change while the panel is up, then Allow → scope_changed.
        let f = Fixture(approval: .ask)
        let box = f.send(createEvent())
        precondition(box.reply == nil && f.gate.waitingCount == 1)
        success(f.registry.replaceGrants(clientID: f.clientID, grants: [
            ClientGrant(resource: .calendar, targetID: "CAL-A", mask: ClientGrant.read | ClientGrant.create)]))
        f.gate.answer(.allowed)
        precondition(box.error == "scope_changed" && f.executor.calls.isEmpty)
        precondition(f.lastRow.outcome == "error:scope_changed" && f.lastRow.approval == "user")
        // Approval mode changed to Allow while waiting: the revision moved too.
        let m = Fixture(approval: .ask)
        let modeBox = m.send(createEvent())
        success(m.registry.setApproval(clientID: m.clientID, .allow))
        m.gate.answer(.allowed)
        precondition(modeBox.error == "scope_changed" && m.executor.calls.isEmpty)
        // Bridge off while waiting, then Allow → scope_changed.
        let b = Fixture(approval: .ask)
        let offBox = b.send(createEvent())
        b.bridgeOn = false
        b.gate.answer(.allowed)
        precondition(offBox.error == "scope_changed" && b.executor.calls.isEmpty)
        // Revoked while waiting.
        let v = Fixture(approval: .ask)
        let revokedBox = v.send(createEvent())
        success(v.registry.revoke(clientID: v.clientID))
        v.gate.answer(.allowedByWindow)
        precondition(revokedBox.error == "scope_changed" && v.executor.calls.isEmpty)
        // The caller cancels while waiting → cancelled; the request is withdrawn.
        let c = Fixture(approval: .ask)
        let cancelled = c.send(createEvent())
        cancelled.ticket!.cancel()
        precondition(cancelled.error == "cancelled" && c.executor.calls.isEmpty)
        precondition(c.gate.waitingCount == 0 && c.lastRow.outcome == "error:cancelled")
        precondition(c.lastRow.approval == nil)
        cancelled.ticket!.cancel()
        precondition(c.registry.activity()!.filter { $0.outcome == "error:cancelled" }.count == 1)
        // Nothing changed: Allow runs the write once.
        let ok = Fixture(approval: .ask)
        let okBox = ok.send(createEvent())
        ok.gate.answer(.allowed)
        precondition(okBox.reply?["ok"] as? Bool == true && ok.executor.calls.count == 1)
        precondition(ok.lastRow.approval == "user" && ok.lastRow.outcome == "success")
        okBox.ticket!.cancel()
        precondition(ok.executor.calls.count == 1, "cancelling after the answer changes nothing")
    }

    @MainActor
    static func inFlight() {
        let f = Fixture()
        f.executor.mode = .hold
        var boxes = [Box]()
        for _ in 0..<RequestPipeline.maxInFlightPerClient { boxes.append(f.send(readEvents())) }
        precondition(boxes.allSatisfy { $0.reply == nil } && f.executor.heldCount == 8)
        let ninth = f.send(readEvents())
        precondition(ninth.error == "rate_limited" && ninth.reply?["retryAfter"] as? Int == 1)
        precondition(f.lastRow.outcome == "error:rate_limited")
        // Inline commands count too.
        precondition(f.send(plain(.scopeStatus)).error == "rate_limited")
        // Another client is unaffected.
        let other = value(f.registry.createClient(name: "Other", credentials: [.mcpToken])).id
        precondition(f.send(plain(.scopeStatus), client: other).reply?["grants"] != nil)
        // A completion (asynchronous, like EventKit) frees a slot.
        f.executor.completeOldest()
        precondition(boxes[0].reply == nil, "completes asynchronously")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(boxes[0].reply?["ok"] as? Bool == true)
        precondition(f.lastRow.outcome == "success" && f.lastRow.targetID == "CAL-A")
        let tenth = f.send(readEvents())
        precondition(tenth.reply == nil && f.executor.heldCount == 8)
        precondition(f.send(readEvents()).error == "rate_limited")
        // A held call whose grant goes away completes with scope_changed.
        success(f.registry.replaceGrants(clientID: f.clientID, grants: []))
        while f.executor.heldCount > 0 { f.executor.completeOldest() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition((boxes.dropFirst() + [tenth]).allSatisfy { $0.error == "scope_changed" })
        // Requests that fail before dispatch free their slot at once.
        precondition(f.send(readEvents()).error == "forbidden")
        precondition(f.send(plain(.scopeStatus)).reply?["grants"] != nil)
    }

    @MainActor
    static func inlineCommands() {
        let f = Fixture(grants: [
            ClientGrant(resource: .calendar, targetID: "CAL-A", mask: 3),
            ClientGrant(resource: .reminderList, targetID: "LIST-A", mask: 31),
            ClientGrant(resource: .calendar, targetID: "CAL-GONE", mask: 1),
            ClientGrant(resource: .calendar, targetID: "CAL-RO", mask: 1),
        ])
        let listing = f.send(plain(.listCollections)).reply!
        precondition(Set(listing.keys) == ["calendarsAccess", "remindersAccess", "collections"])
        precondition(listing["calendarsAccess"] as? String == "full")
        precondition(listing["remindersAccess"] as? String == "denied")
        let rows = listing["collections"] as! [[String: Any]]
        precondition(rows.map { $0["id"] as! String } == ["CAL-A", "LIST-A", "CAL-GONE", "CAL-RO"],
                     "only granted IDs, in grant order")
        for row in rows {
            precondition(Set(row.keys) == ["resource", "id", "name", "account", "writable",
                                           "available", "mask"])
        }
        func same(_ row: [String: Any], _ expected: [String: Any]) -> Bool {
            NSDictionary(dictionary: row).isEqual(to: expected)
        }
        precondition(same(rows[0], ["resource": "calendar", "id": "CAL-A", "name": "Work",
                                    "account": "iCloud", "writable": true, "available": true, "mask": 3]))
        precondition(same(rows[1], ["resource": "reminderList", "id": "LIST-A", "name": NSNull(),
                                    "account": NSNull(), "writable": false, "available": false,
                                    "mask": 31]), "no Full Access: unavailable")
        precondition(same(rows[2], ["resource": "calendar", "id": "CAL-GONE", "name": NSNull(),
                                    "account": NSNull(), "writable": false, "available": false,
                                    "mask": 1]), "missing collection")
        precondition(same(rows[3], ["resource": "calendar", "id": "CAL-RO", "name": "Holidays",
                                    "account": "Subscribed", "writable": false, "available": true,
                                    "mask": 1]))
        let encoded = String(decoding: try! JSONSerialization.data(withJSONObject: listing), as: UTF8.self)
        precondition(!encoded.contains("OTHER") && !encoded.contains("Private") && !encoded.contains("Secret"))
        precondition(f.lastRow.command == "list_collections" && f.lastRow.outcome == "success")
        precondition(f.lastRow.targetID == nil && f.executor.calls.isEmpty)
        // With access granted later, the list row fills in.
        f.collections.remindersAccess = "full"
        let filled = (f.send(plain(.listCollections)).reply!["collections"] as! [[String: Any]])[1]
        precondition(filled["name"] as? String == "Groceries" && filled["available"] as? Bool == true)
        f.collections.remindersAccess = "denied"

        // No grants: an empty list, not an error.
        let empty = Fixture(grants: [])
        let none = empty.send(plain(.listCollections)).reply!
        precondition((none["collections"] as! [Any]).isEmpty && none["error"] == nil)

        // Counts: granted collections that exist; full_access_required without access.
        precondition(f.send(plain(.calendarCount)).reply?["count"] as? Int == 2)
        let noAccess = f.send(plain(.reminderListCount))
        precondition(noAccess.error == "full_access_required" && noAccess.reply?.count == 1)
        precondition(f.lastRow.outcome == "error:full_access_required")
        f.collections.remindersAccess = "full"
        precondition(f.send(plain(.reminderListCount)).reply?["count"] as? Int == 1)

        // scope_status keeps its shape: grants with resource, targetID and mask only.
        let status = f.send(plain(.scopeStatus)).reply!
        precondition(Set(status.keys) == ["grants"])
        let grants = status["grants"] as! [[String: Any]]
        precondition(grants.count == 4)
        precondition(grants.allSatisfy { Set($0.keys) == ["resource", "targetID", "mask"] })
        precondition(same(grants[0], ["resource": "calendar", "targetID": "CAL-A", "mask": 3]))
        precondition(same(grants[1], ["resource": "reminderList", "targetID": "LIST-A", "mask": 31]))
        precondition(f.executor.calls.isEmpty, "inline commands never reach EventKit")
    }

    /// The same requests via the CLI and via MCP leave identical rows apart
    /// from via/agent.
    @MainActor
    static func originsMatch() {
        var rows = [[ActivityRecord]]()
        for origin in [RequestOrigin.cli, .mcp(agent: "Claude Code 2.4.1")] {
            let f = Fixture(approval: .ask)
            f.gate.mode = .allow
            let key = WriteIdempotencyKey.make()
            let write = BridgeRequest(id: "1", command: .createEvent, parameters: [
                "calendarID": "CAL-A", "title": "Same", "start": 1_800_000_000.0,
                "end": 1_800_003_600.0, "idempotencyKey": key])
            for request in [readEvents(), write, readEvents("CAL-NOT-GRANTED"), plain(.scopeStatus)] {
                f.send(request, origin: origin)
            }
            f.bridgeOn = false
            f.send(readEvents(), origin: origin)
            rows.append(f.registry.activity()!.reversed())
        }
        precondition(rows[0].count == 8 && rows[1].count == 8)
        precondition(rows[0].allSatisfy { $0.via == "cli" && $0.agent == nil })
        precondition(rows[1].allSatisfy { $0.via == "mcp" && $0.agent == "Claude Code 2.4.1" })
        for (cli, mcp) in zip(rows[0], rows[1]) {
            precondition(cli.at == mcp.at && cli.command == mcp.command && cli.outcome == mcp.outcome &&
                         cli.targetID == mcp.targetID && cli.approval == mcp.approval)
        }
        precondition(rows[0].map(\.outcome) == ["accepted", "success", "accepted", "success", "forbidden",
                                                "accepted", "success", "error:bridge_off"])
        precondition(rows[0][3].approval == "user")
    }

    // MARK: Helpers

    static func value<T>(_ result: Result<T, ClientRegistryError>) -> T {
        switch result {
        case .success(let value): return value
        case .failure(let error): preconditionFailure("unexpected \(error)")
        }
    }
    static func success(_ result: Result<Void, ClientRegistryError>) {
        value(result)
    }
}
