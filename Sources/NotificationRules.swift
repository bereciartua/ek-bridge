import Foundation

/// Notifications, opt-in by kind (P9, D6).
enum NotificationKind: String, CaseIterable {
    /// A change or access request nobody answered in 45 s. On by default.
    case declined
    /// An agent was refused without an access panel (ineligible or throttled). Off by default.
    case refused
    /// An update is available. On by default.
    case update

    var defaultsKey: String {
        switch self {
        case .declined: "NotifyDeclined"
        case .refused: "NotifyRefused"
        case .update: "NotifyUpdate"
        }
    }

    var isOnByDefault: Bool { self != .refused }

    /// The `UNNotificationCategory` identifier.
    var category: String { "ekb.\(self.rawValue)" }
}

/// What macOS allows for EK Bridge's notifications.
enum NotificationPermission: Equatable {
    case notDetermined, allowed, denied
}

/// One notification, built here so its words can be tested. `info` goes in
/// the notification's userInfo, for the click: never keys or tokens.
struct AppNotification: Equatable {
    let kind: NotificationKind
    let title: String
    let body: String
    var info = [String: String]()
    /// Replaces an earlier one with the same ID (an update's version).
    var identifier = UUID().uuidString

    static let requestIDKey = "requestID"
    static let clientIDKey = "clientID"
    static let resourceKey = "resource"
    static let targetIDKey = "targetID"
    static let versionKey = "version"

    /// Action identifiers.
    static let openActivity = "open-activity"
    static let allow = "allow"
    static let installUpdate = "install-update"
}

enum NotificationRules {
    /// At most one "refused" notification per connection in this time.
    static let refusedInterval: TimeInterval = 10 * 60

    /// Whether to post: the kind is on, the user isn't already looking at
    /// the place it would open, and a refusal isn't too soon after the
    /// connection's last one.
    static func shouldPost(_ kind: NotificationKind, enabled: Set<NotificationKind>, windowShowsIt: Bool,
                           lastPosted: Date?, now: Date) -> Bool {
        guard enabled.contains(kind), !windowShowsIt else { return false }
        if kind == .refused, let lastPosted, now >= lastPosted,
           now.timeIntervalSince(lastPosted) < refusedInterval {
            return false
        }
        return true
    }

    /// "Claude Code wanted to change an event (“Design review”). Nobody answered in 45 s."
    /// `request` is the panel's title, "Claude Code wants to change an event".
    /// The item's title appears in the notification only; EK Bridge never stores it.
    static func declined(panelTitle: String, item: String?, requestID: String?, clientID: String) -> AppNotification {
        let wanted = panelTitle.replacingOccurrences(of: String(localized: " wants to "),
                                                     with: String(localized: " wanted to "))
        let what = item.map { String(localized: "\(wanted) (“\($0)”)") } ?? wanted
        return AppNotification(kind: .declined, title: String(localized: "A change wasn't made"),
                               body: String(localized: "\(what). Nobody answered in 45 s."),
                               info: info(requestID: requestID, clientID: clientID))
    }

    /// "Claude Code can't add reminders to Groceries, and nobody answered in 45 s."
    static func declinedAccess(askTitle: String, requestID: String?, clientID: String) -> AppNotification {
        AppNotification(kind: .declined, title: String(localized: "A change wasn't made"),
                        body: String(localized: "\(askTitle), and nobody answered in 45 s."),
                        info: info(requestID: requestID, clientID: clientID))
    }

    /// "Cursor can't add events to Home."
    static func refused(clientName: String, command: String, collection: String?, requestID: String?,
                        clientID: String, resource: String?, targetID: String?) -> AppNotification {
        let list = CommandPresentation.targetsList(command)
        let things = list ? String(localized: "reminders") : String(localized: "events")
        let name = collection ?? (list ? String(localized: "a list") : String(localized: "a calendar"))
        let phrase: String = switch BridgeCommand(rawValue: command) {
        case .createEvent, .createReminder: String(localized: "add \(things) to \(name)")
        case .updateEvent, .updateReminder: String(localized: "change \(things) in \(name)")
        case .deleteEvent, .deleteReminder: String(localized: "delete \(things) in \(name)")
        case .completeReminder: String(localized: "complete reminders in \(name)")
        default: String(localized: "read \(name)")
        }
        var info = info(requestID: requestID, clientID: clientID)
        info[AppNotification.resourceKey] = resource
        info[AppNotification.targetIDKey] = targetID
        return AppNotification(kind: .refused, title: String(localized: "An agent was refused"),
                               body: String(localized: "\(clientName) can't \(phrase)."), info: info)
    }

    /// "EK Bridge 0.10.1 is available."
    static func update(version: String) -> AppNotification {
        AppNotification(kind: .update, title: String(localized: "Update available"),
                        body: String(localized: "\(AppIdentity.displayName) \(version) is available."),
                        info: [AppNotification.versionKey: version], identifier: "update-\(version)")
    }

    private static func info(requestID: String?, clientID: String) -> [String: String] {
        var info = [AppNotification.clientIDKey: clientID]
        info[AppNotification.requestIDKey] = requestID
        return info
    }
}
