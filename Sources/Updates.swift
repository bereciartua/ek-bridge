import Foundation

/// The updater as the model sees it. `SparkleUpdater` provides the live
/// controls; the UI-review build passes fakes, so it never checks GitHub.
@MainActor
struct UpdaterControls {
    /// False when this copy can't update itself: a build without Sparkle's
    /// public key (built from source), or the updater couldn't start.
    var isAvailable: () -> Bool
    /// Opens Sparkle's window: checks now, or shows an update it already found.
    var checkForUpdates: () -> Void
    var automaticChecks: () -> Bool
    var setAutomaticChecks: (Bool) -> Void
    var lastCheck: () -> Date?

    static let unavailable = UpdaterControls(
        isAvailable: { false }, checkForUpdates: {}, automaticChecks: { false },
        setAutomaticChecks: { _ in }, lastCheck: { nil })
}

/// An update a scheduled check found. Shown in the menu and on Overview until
/// the user opens it, because a scheduled check never opens a window on its
/// own (Sparkle's gentle reminders).
struct FoundUpdate: Equatable {
    let version: String
    /// Marked `sparkle:criticalUpdate` in the appcast: a security fix.
    let critical: Bool
}

/// Holds Sparkle's relaunch while changes wait in the approval panel, so
/// installing an update never refuses a change the user is about to allow.
/// Once the queue is empty, or after `maximumWait`, Sparkle quits the app as
/// any quit does: listeners stop, the bridge stops without saving that choice,
/// and anything still waiting is refused.
@MainActor
final class UpdateRelaunchGate {
    static let pollInterval: TimeInterval = 0.5

    private let pendingApprovals: () -> Int
    private let maximumWait: TimeInterval
    private let now: () -> Date
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    private(set) var isWaiting = false

    /// `maximumWait` is the approval timeout plus a margin, so every waiting
    /// change is answered or times out first.
    init(pendingApprovals: @escaping () -> Int, maximumWait: TimeInterval,
         now: @escaping () -> Date = Date.init,
         schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, action in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(action) }
         }) {
        self.pendingApprovals = pendingApprovals
        self.maximumWait = maximumWait
        self.now = now
        self.schedule = schedule
    }

    /// Sparkle's `shouldPostponeRelaunchForUpdate`. False lets it relaunch
    /// now; true means `proceed` runs later, exactly once.
    func postpone(_ proceed: @escaping () -> Void) -> Bool {
        guard !isWaiting, pendingApprovals() > 0 else { return false }
        isWaiting = true
        wait(until: now().addingTimeInterval(maximumWait), proceed)
        return true
    }

    private func wait(until deadline: Date, _ proceed: @escaping () -> Void) {
        schedule(Self.pollInterval) { [weak self] in
            guard let self else { return }
            if self.pendingApprovals() == 0 || self.now() >= deadline {
                self.isWaiting = false
                proceed()
            } else {
                self.wait(until: deadline, proceed)
            }
        }
    }
}
