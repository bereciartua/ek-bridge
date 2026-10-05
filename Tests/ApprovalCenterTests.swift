import Foundation

@main
struct ApprovalCenterTests {
    static func main() {
        MainActor.assumeIsolated { run() }
    }

    @MainActor
    final class Recorder {
        var decisions = [String: [ApprovalDecision]]()

        func completion(_ name: String) -> (ApprovalDecision) -> Void {
            { [self] decision in decisions[name, default: []].append(decision) }
        }
        func only(_ name: String) -> ApprovalDecision? {
            let all = decisions[name] ?? []
            precondition(all.count <= 1, "\(name) resolved \(all.count) times")
            return all.first
        }
    }

    @MainActor
    static func run() {
        var clock = Date(timeIntervalSince1970: 2_000_000_000)
        var scheduled = [(delay: TimeInterval, action: @MainActor () -> Void)]()
        var queueChanges = 0
        let center = ApprovalCenter(
            summarize: { request in
                ApprovalSummary(title: "\(request.clientName) wants to \(request.request.command.rawValue)",
                                rows: [], isDelete: false)
            },
            now: { clock },
            schedule: { delay, action in scheduled.append((delay, action)) })
        center.queueChanged = { queueChanges += 1 }
        let recorder = Recorder()

        func ask(_ name: String, client: String, revision: Int = 1) -> () -> Void {
            let request = BridgeRequest(id: UUID().uuidString, command: .createReminder,
                                        parameters: ["listID": "LIST", "title": name])
            return center.request(ApprovalRequest(clientID: client, clientName: "Client \(client)",
                                                  agent: "Agent 1.0", request: request,
                                                  targetID: "LIST", revision: revision),
                                  completion: recorder.completion(name))
        }

        // FIFO order, one queue for all clients; selection follows removals.
        _ = ask("a1", client: "A")
        _ = ask("b1", client: "B")
        _ = ask("a2", client: "A")
        precondition(center.pending.map(\.clientID) == ["A", "B", "A"])
        precondition(center.pending.map(\.clientName) == ["Client A", "Client B", "Client A"])
        precondition(center.pending[0].summary.title == "Client A wants to create_reminder")
        precondition(center.pending[0].agent == "Agent 1.0")
        precondition(center.pending.allSatisfy { $0.expiresAt == clock.addingTimeInterval(45) })
        precondition(queueChanges == 3, "one change per enqueue")
        precondition(center.selection == 0 && center.current?.id == center.pending[0].id)
        precondition(scheduled.count == 3 && scheduled.allSatisfy { $0.delay == ApprovalCenter.timeout })
        precondition(ApprovalCenter.timeout == 45)
        center.selection = 2
        let firstID = center.pending[0].id
        center.deny(firstID)
        precondition(recorder.only("a1") == .denied)
        precondition(center.pending.map(\.clientID) == ["B", "A"])
        precondition(center.selection == 1, "selection clamps to the last item")
        precondition(queueChanges == 4)
        center.deny(firstID)
        precondition(recorder.only("a1") == .denied && queueChanges == 4, "a second answer does nothing")
        center.selection = 7
        precondition(center.current?.id == center.pending[0].id, "an out-of-range selection shows the first")
        center.selection = 0

        // The 45 s timeout comes from the scheduled closure; firing a closure
        // for an item already answered does nothing.
        scheduled[1].action()
        precondition(recorder.only("b1") == .timedOut)
        precondition(center.pending.map(\.clientID) == ["A"])
        precondition(queueChanges == 5)
        scheduled[0].action()
        precondition(recorder.only("a1") == .denied && queueChanges == 5)

        // At most 3 pending per client; the 4th is refused at once without
        // queueing, and another client is unaffected.
        _ = ask("a3", client: "A")
        _ = ask("a4", client: "A")
        precondition(queueChanges == 7)
        _ = ask("a5", client: "A")
        precondition(recorder.only("a5") == .tooMany)
        precondition(center.pending.count == 3 && queueChanges == 7, "tooMany doesn't queue")
        _ = ask("b2", client: "B")
        precondition(recorder.only("b2") == nil && center.pending.count == 4)

        // The withdraw closure resolves exactly once.
        let withdrawC = ask("c1", client: "C")
        withdrawC()
        precondition(recorder.only("c1") == .withdrawn)
        withdrawC()
        precondition(recorder.only("c1") == .withdrawn)
        let answeredFirst = ask("c2", client: "C")
        center.allow(center.pending.last!.id)
        precondition(recorder.only("c2") == .allowed)
        answeredFirst()
        precondition(recorder.only("c2") == .allowed, "withdrawing after an answer does nothing")
        precondition(!center.hasAllowWindow("C"), "a plain Allow opens no window")

        // withdrawAll: everything waiting gets .withdrawn.
        let changesBefore = queueChanges
        center.withdrawAll()
        for name in ["a2", "a3", "a4", "b2"] { precondition(recorder.only(name) == .withdrawn, name) }
        precondition(center.pending.isEmpty && center.selection == 0)
        precondition(queueChanges == changesBefore + 4, "one change per resolved item")

        // Allow for 15 minutes: the next request from the same client at the
        // same revision resolves at once, without queueing.
        _ = ask("d1", client: "D", revision: 5)
        center.allow(center.pending[0].id, forWindow: true)
        precondition(recorder.only("d1") == .allowed && center.hasAllowWindow("D"))
        let changesAfterAllow = queueChanges
        let windowWithdraw = ask("d2", client: "D", revision: 5)
        precondition(recorder.only("d2") == .allowedByWindow)
        precondition(center.pending.isEmpty && queueChanges == changesAfterAllow,
                     "a window answer never queues")
        windowWithdraw()
        precondition(recorder.only("d2") == .allowedByWindow)
        precondition(!center.hasAllowWindow("E"), "windows are per client")
        _ = ask("e1", client: "E", revision: 5)
        precondition(recorder.only("e1") == nil && center.pending.count == 1)
        center.deny(center.pending[0].id)
        // Ends after 15 minutes.
        clock = clock.addingTimeInterval(ApprovalCenter.allowWindow - 1)
        _ = ask("d3", client: "D", revision: 5)
        precondition(recorder.only("d3") == .allowedByWindow)
        clock = clock.addingTimeInterval(1)
        precondition(!center.hasAllowWindow("D"))
        _ = ask("d4", client: "D", revision: 5)
        precondition(recorder.only("d4") == nil && center.pending.count == 1, "window over: queued")
        // Ends after a revision change.
        center.allow(center.pending[0].id, forWindow: true)
        precondition(recorder.only("d4") == .allowed && center.hasAllowWindow("D"))
        _ = ask("d5", client: "D", revision: 6)
        precondition(recorder.only("d5") == nil && center.pending.count == 1, "new revision: queued")
        _ = ask("d6", client: "D", revision: 5)
        precondition(recorder.only("d6") == nil && center.pending.count == 2,
                     "the window was cleared, not just skipped")
        // The window records the revision of the request that was allowed.
        center.allow(center.pending[0].id, forWindow: true)
        precondition(recorder.only("d5") == .allowed)
        _ = ask("d7", client: "D", revision: 6)
        precondition(recorder.only("d7") == .allowedByWindow)
        // Ends after withdraw(clientID:), which also withdraws D's waiting request.
        center.withdraw(clientID: "D")
        precondition(recorder.only("d6") == .withdrawn && !center.hasAllowWindow("D"))
        _ = ask("d8", client: "D", revision: 6)
        precondition(recorder.only("d8") == nil && center.pending.count == 1, "withdrawn window: queued")
        // withdraw(clientID:) leaves other clients alone.
        _ = ask("f1", client: "F")
        center.withdraw(clientID: "D")
        precondition(recorder.only("d8") == .withdrawn && recorder.only("f1") == nil)
        // withdrawAll also ends windows.
        center.allow(center.pending[0].id, forWindow: true)
        precondition(recorder.only("f1") == .allowed && center.hasAllowWindow("F"))
        center.withdrawAll()
        precondition(!center.hasAllowWindow("F"))

        // shutDown answers everything with .unavailable and ends windows.
        _ = ask("g1", client: "G")
        _ = ask("h1", client: "H")
        center.allow(center.pending[0].id, forWindow: true)
        _ = ask("h2", client: "H")
        let changesBeforeShutdown = queueChanges
        center.shutDown()
        precondition(recorder.only("h1") == .unavailable && recorder.only("h2") == .unavailable)
        precondition(recorder.only("g1") == .allowed)
        precondition(!center.hasAllowWindow("G") && center.pending.isEmpty)
        precondition(queueChanges == changesBeforeShutdown + 2)
        // Pending timeouts scheduled earlier are now harmless.
        let resolvedBefore = recorder.decisions.values.map(\.count).reduce(0, +)
        for entry in scheduled { entry.action() }
        precondition(recorder.decisions.values.map(\.count).reduce(0, +) == resolvedBefore)
        precondition(recorder.decisions.values.allSatisfy { $0.count == 1 }, "every request resolved exactly once")

        print("Approval center: FIFO and selection, 45 s timeout, 3 per client, 15-minute window, withdraw, shutdown, exactly-once passed")
    }
}
