import Foundation

@main
struct ExactActionApprovalTests {
    static func main() {
        var scope = BridgeScope()
        scope.calendarID = "synthetic-calendar"
        scope.generation = 7
        let gate = ExactActionApproval(epoch: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)
        let requestID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let original = wire(epoch: gate.epoch, id: requestID, issuedAt: 100,
                            title: "Synthetic original")

        expectError(gate.propose(original, peerVerified: false, scope: scope,
                                 now: 100, uptime: 100), .unverifiedPeer)
        let proposal = expectSuccess(gate.propose(original, peerVerified: true,
                                                   scope: scope, now: 100, uptime: 100))
        let altered = wire(epoch: gate.epoch, id: requestID, issuedAt: 100,
                           title: "Synthetic alteration")
        precondition(original != altered)
        let approved = expectSuccess(gate.approve(ticketID: proposal.ticketID,
                                                   displayedDigest: proposal.digest,
                                                   scope: scope, now: 101, uptime: 101))
        precondition(approved.rawRequest == original)
        precondition(approved.request.parameters["title"] as? String == "Synthetic original")
        expectError(gate.approve(ticketID: proposal.ticketID,
                                 displayedDigest: proposal.digest, scope: scope,
                                 now: 101, uptime: 101), .noPendingAction)
        expectError(gate.propose(altered, peerVerified: true, scope: scope,
                                 now: 102, uptime: 102), .replayedRequest)

        let wrongDigest = expectSuccess(gate.propose(
            wire(epoch: gate.epoch, issuedAt: 103, title: "Synthetic digest"),
            peerVerified: true, scope: scope, now: 103, uptime: 103))
        expectError(gate.approve(ticketID: wrongDigest.ticketID,
                                 displayedDigest: String(repeating: "0", count: 64),
                                 scope: scope, now: 104, uptime: 104), .tamperedRequest)
        expectError(gate.approve(ticketID: wrongDigest.ticketID,
                                 displayedDigest: wrongDigest.digest,
                                 scope: scope, now: 104, uptime: 104), .noPendingAction)

        expectError(gate.propose(wire(epoch: gate.epoch, issuedAt: 70),
                                 peerVerified: true, scope: scope,
                                 now: 101, uptime: 101), .staleRequest)
        var wrongTarget = scope
        wrongTarget.calendarID = "another-calendar"
        expectError(gate.propose(wire(epoch: gate.epoch, issuedAt: 105),
                                 peerVerified: true, scope: wrongTarget,
                                 now: 105, uptime: 105), .invalidTarget)

        let expiring = expectSuccess(gate.propose(wire(epoch: gate.epoch, issuedAt: 106),
                                                  peerVerified: true, scope: scope,
                                                  now: 106, uptime: 106))
        expectError(gate.approve(ticketID: expiring.ticketID,
                                 displayedDigest: expiring.digest, scope: scope,
                                 now: 106, uptime: 406), .expiredApproval)

        let changing = expectSuccess(gate.propose(wire(epoch: gate.epoch, issuedAt: 107),
                                                  peerVerified: true, scope: scope,
                                                  now: 107, uptime: 107))
        var changedScope = scope
        changedScope.generation += 1
        expectError(gate.approve(ticketID: changing.ticketID,
                                 displayedDigest: changing.digest, scope: changedScope,
                                 now: 108, uptime: 108), .scopeChanged)

        let cancelling = expectSuccess(gate.propose(wire(epoch: gate.epoch, issuedAt: 109),
                                                    peerVerified: true, scope: scope,
                                                    now: 109, uptime: 109))
        precondition(gate.cancel(ticketID: cancelling.ticketID))
        expectError(gate.approve(ticketID: cancelling.ticketID,
                                 displayedDigest: cancelling.digest, scope: scope,
                                 now: 110, uptime: 110), .noPendingAction)

        let beforeRestart = expectSuccess(gate.propose(wire(epoch: gate.epoch, issuedAt: 111),
                                                       peerVerified: true, scope: scope,
                                                       now: 111, uptime: 111))
        let nextLaunch = ExactActionApproval(epoch: UUID(
            uuidString: "33333333-3333-4333-8333-333333333333")!)
        expectError(nextLaunch.approve(ticketID: beforeRestart.ticketID,
                                       displayedDigest: beforeRestart.digest, scope: scope,
                                       now: 112, uptime: 112), .noPendingAction)
        expectError(nextLaunch.propose(wire(epoch: gate.epoch, issuedAt: 112),
                                       peerVerified: true, scope: scope,
                                       now: 112, uptime: 112), .invalidRequest)

        let futureGate = ExactActionApproval()
        let futureID = UUID()
        let futureRequest = wire(epoch: futureGate.epoch, id: futureID, issuedAt: 205)
        let futureProposal = expectSuccess(futureGate.propose(
            futureRequest, peerVerified: true, scope: scope, now: 200, uptime: 200))
        _ = expectSuccess(futureGate.approve(ticketID: futureProposal.ticketID,
                                             displayedDigest: futureProposal.digest,
                                             scope: scope, now: 201, uptime: 201))
        expectError(futureGate.propose(futureRequest, peerVerified: true,
                                       scope: scope, now: 231, uptime: 231), .replayedRequest)
        print("Exact action approval: identity, tamper, replay, expiry, scope, cancel, restart passed")
    }

    static func wire(epoch: String, id: UUID = UUID(), issuedAt: Double,
                     title: String = "Synthetic action") -> Data {
        let object: [String: Any] = [
            "version": 2, "epoch": epoch, "id": id.uuidString,
            "command": "create_event", "issuedAt": issuedAt,
            "parameters": [
                "calendarID": "synthetic-calendar", "title": title,
                "start": 1_800_000_000.0, "end": 1_800_003_600.0,
                "idempotencyKey": UUID().uuidString,
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func expectSuccess<T>(_ result: Result<T, ActionApprovalError>) -> T {
        switch result {
        case .success(let value): return value
        case .failure(let error): preconditionFailure("unexpected error: \(error)")
        }
    }

    static func expectError<T>(_ result: Result<T, ActionApprovalError>,
                               _ expected: ActionApprovalError) {
        switch result {
        case .success: preconditionFailure("expected \(expected)")
        case .failure(let error): precondition(error == expected)
        }
    }
}
