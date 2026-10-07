import Foundation

@main
struct UpdateRelaunchGateTests {
    static func main() {
        MainActor.assumeIsolated { run() }
    }

    @MainActor
    static func run() {
        var clock = Date(timeIntervalSince1970: 2_000_000_000)
        var scheduled = [(delay: TimeInterval, action: @MainActor () -> Void)]()
        var pending = 0
        var checks = 0
        func gate() -> UpdateRelaunchGate {
            UpdateRelaunchGate(pendingApprovals: { pending }, maximumWait: 50, now: { clock },
                               schedule: { delay, action in scheduled.append((delay, action)) })
        }
        /// Runs the next scheduled poll, `delay` later.
        func tick() {
            precondition(!scheduled.isEmpty, "nothing scheduled")
            let next = scheduled.removeFirst()
            clock = clock.addingTimeInterval(next.delay)
            next.action()
        }

        // Nothing waiting: Sparkle relaunches at once and nothing is scheduled.
        var proceeded = 0
        let idle = gate()
        precondition(idle.postpone { proceeded += 1 } == false)
        precondition(scheduled.isEmpty && proceeded == 0 && !idle.isWaiting)
        checks += 1

        // Changes waiting: held, polled every half second, released once the
        // queue empties, exactly once.
        pending = 2
        let held = gate()
        precondition(held.postpone { proceeded += 1 } == true)
        precondition(held.isWaiting && proceeded == 0)
        precondition(scheduled.count == 1 && scheduled[0].delay == UpdateRelaunchGate.pollInterval)
        tick()
        precondition(proceeded == 0 && scheduled.count == 1, "still waiting while changes are pending")
        pending = 1
        tick()
        precondition(proceeded == 0 && scheduled.count == 1)
        pending = 0
        tick()
        precondition(proceeded == 1 && scheduled.isEmpty && !held.isWaiting)
        checks += 1

        // A second request while waiting isn't held again.
        pending = 1
        let busy = gate()
        precondition(busy.postpone { proceeded += 1 } == true)
        precondition(busy.postpone { proceeded += 100 } == false)
        checks += 1

        // A change nobody answers: released at the deadline, not before.
        scheduled.removeAll()
        proceeded = 0
        let stuck = gate()
        let start = clock
        precondition(stuck.postpone { proceeded += 1 } == true)
        while proceeded == 0 { tick() }
        precondition(proceeded == 1 && scheduled.isEmpty && !stuck.isWaiting)
        precondition(clock.timeIntervalSince(start) >= 50 && clock.timeIntervalSince(start) < 50.6,
                     "released \(clock.timeIntervalSince(start)) s after the request")
        checks += 1

        // A gate that's gone doesn't call back.
        scheduled.removeAll()
        var released = false
        do {
            let gone = gate()
            precondition(gone.postpone { released = true })
        }
        pending = 0
        tick()
        precondition(!released)
        checks += 1

        // Controls for a copy that can't update itself do nothing.
        let off = UpdaterControls.unavailable
        off.checkForUpdates()
        off.setAutomaticChecks(true)
        precondition(!off.isAvailable() && !off.automaticChecks() && off.lastCheck() == nil)
        checks += 1

        print("Update relaunch gate: \(checks) checks of holding, polling, the deadline, release once, and unavailable controls passed")
    }
}
