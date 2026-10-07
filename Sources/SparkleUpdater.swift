import AppKit
import Sparkle

/// In-app updates (plan 04 §4): Sparkle 2 with its standard window, reading
/// `SUFeedURL`, the appcast attached to the latest GitHub release. Sparkle
/// checks the download's EdDSA signature against `SUPublicEDKey` and that the
/// new app is signed by the same team before it installs anything.
///
/// A menu bar app shouldn't have a window jump up from a scheduled check, so
/// those use Sparkle's gentle reminders: a found update shows as a menu item
/// and an Overview card, and Sparkle's window opens when the user picks one.
/// A check the user starts opens the window directly. Installing always takes
/// a click (`SUAllowsAutomaticUpdates` is off).
@MainActor
final class SparkleUpdater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    /// An update to point out, or nil once the user has opened it or the
    /// session ended.
    var foundUpdateChanged: (FoundUpdate?) -> Void = { _ in }

    private let gate: UpdateRelaunchGate
    private var controller: SPUStandardUpdaterController!
    private var started = false

    init(gate: UpdateRelaunchGate) {
        self.gate = gate
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self,
                                                  userDriverDelegate: self)
    }

    /// A build without the public key (one built from source) can't verify
    /// updates, so it never checks.
    static var isConfigured: Bool {
        !((Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String) ?? "").isEmpty
    }

    func start() {
        guard Self.isConfigured, !started else { return }
        do {
            try controller.updater.start()
            started = true
        } catch {
            NSLog("Updates are off: Sparkle couldn't start (%@)", error.localizedDescription)
        }
    }

    var controls: UpdaterControls {
        UpdaterControls(
            isAvailable: { [weak self] in self?.started ?? false },
            checkForUpdates: { [weak self] in
                guard let self, self.started else { return }
                self.controller.checkForUpdates(nil)
            },
            automaticChecks: { [weak self] in
                guard let self, self.started else { return false }
                return self.controller.updater.automaticallyChecksForUpdates
            },
            setAutomaticChecks: { [weak self] on in
                guard let self, self.started else { return }
                self.controller.updater.automaticallyChecksForUpdates = on
            },
            lastCheck: { [weak self] in self?.controller.updater.lastUpdateCheckDate })
    }

    // MARK: SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        gate.postpone(installHandler)
    }

    // MARK: SPUStandardUserDriverDelegate (called on the main thread)

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle shows a scheduled update itself only when the app is in front;
    /// otherwise it's left to the menu item and the Overview card.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        let found = FoundUpdate(version: update.displayVersionString, critical: update.isCriticalUpdate)
        MainActor.assumeIsolated { foundUpdateChanged(found) }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { foundUpdateChanged(nil) }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { foundUpdateChanged(nil) }
    }
}
