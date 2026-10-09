import Foundation

/// C04: when a refused write may ask for access, the throttle, and Allow Once.
@main
struct AccessRequestsTests {
    static func main() {
        policy()
        throttle()
        temporaryGrants()
        print("Access requests: eligibility (writes only, Read required, writable, single action, the switch), "
              + "throttle per connection, collection and action, temporary grants bound to request and revision passed")
    }

    static func missing(mask: Int = ClientGrant.read, bit: Int = ClientGrant.create,
                        resource: ClientResource = .reminderList, asks: Bool = true,
                        client: String = "c", target: String = "L") -> MissingAccess {
        MissingAccess(clientID: client, clientName: "Claude Code", revision: 3, resource: resource, targetID: target,
                      currentMask: mask, missingBit: bit, asksForAccess: asks)
    }

    static func policy() {
        let eligible = { (m: MissingAccess, command: BridgeCommand, writable: Bool?) in
            AccessRequestPolicy.eligible(m, command: command, writable: writable)
        }
        precondition(eligible(missing(), .createReminder, true))
        precondition(eligible(missing(bit: ClientGrant.complete), .completeReminder, true))
        precondition(eligible(missing(mask: 3, bit: ClientGrant.edit), .updateReminder, true))
        // Reads never ask, and Read is never what's asked for.
        precondition(!eligible(missing(bit: ClientGrant.read), .readReminders, true))
        precondition(!eligible(missing(bit: ClientGrant.read), .createReminder, true))
        // Only where it can read already.
        precondition(!eligible(missing(mask: ClientGrant.create, bit: ClientGrant.edit), .updateReminder, true))
        // Writable and listed only.
        precondition(!eligible(missing(), .createReminder, false))
        precondition(!eligible(missing(), .createReminder, nil))
        // The connection's switch.
        precondition(!eligible(missing(asks: false), .createReminder, true))
        // One action at a time; Complete only on lists.
        precondition(!eligible(missing(bit: ClientGrant.create | ClientGrant.edit), .createReminder, true))
        precondition(!eligible(missing(bit: 0), .createReminder, true))
        precondition(!eligible(missing(bit: ClientGrant.complete, resource: .calendar), .completeReminder, true))
        precondition(eligible(missing(bit: ClientGrant.delete, resource: .calendar), .deleteEvent, true))
    }

    static func throttle() {
        var throttle = AccessRequestThrottle()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let ask = missing()
        precondition(throttle.allows(ask, now: start))
        throttle.record(ask, now: start)
        precondition(!throttle.allows(ask, now: start.addingTimeInterval(3_599)))
        precondition(throttle.allows(ask, now: start.addingTimeInterval(3_600)))
        // Another action, collection or connection isn't throttled by it.
        precondition(throttle.allows(missing(bit: ClientGrant.delete), now: start))
        precondition(throttle.allows(missing(target: "M"), now: start))
        precondition(throttle.allows(missing(client: "d"), now: start))
        precondition(throttle.allows(missing(resource: .calendar), now: start))
        // Not Now records again: another hour from then.
        throttle.record(ask, now: start.addingTimeInterval(1_800))
        precondition(!throttle.allows(ask, now: start.addingTimeInterval(3_700)))
        precondition(throttle.allows(ask, now: start.addingTimeInterval(5_400)))
        // A clock that went back doesn't keep it quiet forever.
        precondition(throttle.allows(ask, now: start.addingTimeInterval(-60)))
    }

    static func temporaryGrants() {
        let grants = [ClientGrant(resource: .reminderList, targetID: "L", mask: 1),
                      ClientGrant(resource: .calendar, targetID: "L", mask: 1),
                      ClientGrant(resource: .reminderList, targetID: "M", mask: 1)]
        let once = TemporaryGrant(requestID: "c|r1", resource: .reminderList, targetID: "L",
                                  bit: ClientGrant.create, revision: 3)
        let applied = once.applied(to: grants, requestID: "c|r1", revision: 3)
        precondition(applied[0].mask == 3 && applied[1].mask == 1 && applied[2].mask == 1)
        // Another request, or the same one after a change of revision: nothing.
        precondition(once.applied(to: grants, requestID: "c|r2", revision: 3) == grants)
        precondition(once.applied(to: grants, requestID: "c|r1", revision: 4) == grants)
        precondition(once.applied(to: grants, requestID: nil, revision: 3) == grants)
        // Never a new grant.
        let elsewhere = TemporaryGrant(requestID: "c|r1", resource: .reminderList, targetID: "N",
                                       bit: ClientGrant.create, revision: 3)
        precondition(elsewhere.applied(to: grants, requestID: "c|r1", revision: 3) == grants)
    }
}
