import AppKit
import UserNotifications

/// What the model needs from macOS notifications; the UI-review build fakes it.
struct NotificationControls {
    var post: (AppNotification) -> Void
    var permission: (@escaping @MainActor (NotificationPermission) -> Void) -> Void
    /// Asks macOS once (the system prompt); later calls report the answer.
    var requestPermission: (@escaping @MainActor (Bool) -> Void) -> Void
    var openSettings: () -> Void

    @MainActor
    static var unavailable: NotificationControls {
        NotificationControls(post: { _ in }, permission: { done in MainActor.assumeIsolated { done(.denied) } },
                             requestPermission: { done in MainActor.assumeIsolated { done(false) } },
                             openSettings: {})
    }
}

/// Posts EK Bridge's notifications and reports clicks (P9). Permission is
/// asked lazily: the first time one is about to be posted, or a kind is
/// turned on in Settings, never at launch.
@MainActor
final class NotificationPoster: NSObject, UNUserNotificationCenterDelegate {
    /// A click: the action identifier (`UNNotificationDefaultActionIdentifier`
    /// for the notification itself) and its info.
    var onResponse: (String, NotificationKind?, [String: String]) -> Void = { _, _, _ in }
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
        let open = UNNotificationAction(identifier: AppNotification.openActivity,
                                        title: String(localized: "Open Activity"), options: [.foreground])
        let allow = UNNotificationAction(identifier: AppNotification.allow,
                                         title: String(localized: "Allow…"), options: [.foreground])
        let install = UNNotificationAction(identifier: AppNotification.installUpdate,
                                           title: String(localized: "Install Update…"), options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: NotificationKind.declined.category, actions: [open],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: NotificationKind.refused.category, actions: [allow, open],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: NotificationKind.update.category, actions: [install],
                                   intentIdentifiers: []),
        ])
    }

    var controls: NotificationControls {
        NotificationControls(
            post: { [weak self] in self?.post($0) },
            permission: { [weak self] done in self?.permission(done) },
            requestPermission: { [weak self] done in self?.requestPermission(done) },
            openSettings: {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            })
    }

    private func post(_ note: AppNotification) {
        let content = UNMutableNotificationContent()
        content.title = note.title
        content.body = note.body
        content.categoryIdentifier = note.kind.category
        content.userInfo = note.info.merging(["kind": note.kind.rawValue]) { first, _ in first }
        center.add(UNNotificationRequest(identifier: note.identifier, content: content, trigger: nil))
    }

    private func permission(_ done: @escaping @MainActor (NotificationPermission) -> Void) {
        center.getNotificationSettings { settings in
            let permission: NotificationPermission = switch settings.authorizationStatus {
            case .notDetermined: .notDetermined
            case .denied: .denied
            default: .allowed
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(permission) } }
        }
    }

    private func requestPermission(_ done: @escaping @MainActor (Bool) -> Void) {
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { done(granted) } }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Shown while EK Bridge is active too; the model already skips ones
        // for the page the window shows.
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        var info = [String: String]()
        for (key, value) in response.notification.request.content.userInfo {
            if let key = key as? String, let value = value as? String { info[key] = value }
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.onResponse(action, info["kind"].flatMap(NotificationKind.init(rawValue:)), info)
                completionHandler()
            }
        }
    }
}
