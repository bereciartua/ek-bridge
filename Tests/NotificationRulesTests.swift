import Foundation

/// C05: when a notification is posted, and what it says.
@main
struct NotificationRulesTests {
    static func main() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let on: Set<NotificationKind> = [.declined, .update]
        // Defaults (D6): declined and update on, refused off.
        precondition(NotificationKind.allCases.filter(\.isOnByDefault) == [.declined, .update])
        precondition(NotificationKind.tunnelDown.defaultsKey == "NotifyTunnelDown" && !NotificationKind.tunnelDown.isOnByDefault,
                     "tunnel down is off by default")
        precondition(NotificationKind.refused.defaultsKey == "NotifyRefused")
        let post = { (kind: NotificationKind, enabled: Set<NotificationKind>, showing: Bool, last: Date?) in
            NotificationRules.shouldPost(kind, enabled: enabled, windowShowsIt: showing, lastPosted: last, now: now)
        }
        precondition(post(.declined, on, false, nil))
        precondition(!post(.refused, on, false, nil), "off unless turned on")
        precondition(post(.refused, [.refused], false, nil))
        precondition(!post(.declined, on, true, nil), "not while the window shows it")
        // One refusal notification per connection every 10 minutes.
        precondition(!post(.refused, [.refused], false, now.addingTimeInterval(-599)))
        precondition(post(.refused, [.refused], false, now.addingTimeInterval(-600)))
        precondition(post(.refused, [.refused], false, now.addingTimeInterval(60)), "a clock that went back")
        precondition(post(.declined, on, false, now), "only refusals are rate limited")
        // Words.
        let declined = NotificationRules.declined(panelTitle: "Claude Code wants to move an event",
                                                  item: "Design review", requestID: "c|r", clientID: "c")
        precondition(declined.title == "A change wasn't made")
        precondition(declined.body == "Claude Code wanted to move an event (“Design review”). Nobody answered in 45 s.")
        precondition(declined.info == [AppNotification.requestIDKey: "c|r", AppNotification.clientIDKey: "c"])
        precondition(NotificationRules.declined(panelTitle: "Cursor wants to delete a reminder", item: nil,
                                                requestID: nil, clientID: "c").body
                     == "Cursor wanted to delete a reminder. Nobody answered in 45 s.")
        precondition(NotificationRules.declinedAccess(askTitle: "Claude Code can't add reminders to Groceries",
                                                      requestID: nil, clientID: "c").body
                     == "Claude Code can't add reminders to Groceries, and nobody answered in 45 s.")
        let refused = NotificationRules.refused(clientName: "Cursor", command: "create_event", collection: "Home",
                                                requestID: "c|r", clientID: "c", resource: "calendar", targetID: "H")
        precondition(refused.body == "Cursor can't add events to Home." && refused.kind == .refused)
        precondition(refused.info[AppNotification.targetIDKey] == "H" && refused.info[AppNotification.resourceKey] == "calendar")
        precondition(NotificationRules.refused(clientName: "A", command: "complete_reminder", collection: nil,
                                               requestID: nil, clientID: "c", resource: nil, targetID: nil).body
                     == "A can't complete reminders in a list.")
        let update = NotificationRules.update(version: "0.10.1")
        precondition(update.body == "\(AppIdentity.displayName) 0.10.1 is available." && update.identifier == "update-0.10.1")
        // Tunnel down (plan 08, D10): once per running → down change, only while on, at most every 30 minutes.
        let down = { (was: Bool?, now_: Bool, on: Bool, last: Date?) in
            NotificationRules.shouldPostTunnelDown(wasDown: was, isDown: now_, remoteOn: on, lastPosted: last, now: now)
        }
        precondition(down(false, true, true, nil), "running → down")
        precondition(!down(nil, true, true, nil), "not on launch (or turning on) when already down")
        precondition(!down(true, true, true, nil), "only on the change")
        precondition(!down(false, false, true, nil), "still running")
        precondition(!down(false, true, false, nil), "not while Remote Access is off")
        precondition(!down(false, true, true, now.addingTimeInterval(-1_799)), "at most every 30 minutes")
        precondition(down(false, true, true, now.addingTimeInterval(-1_800)), "…then again")
        precondition(down(false, true, true, now.addingTimeInterval(60)), "a clock that went back")
        let tunnel = NotificationRules.tunnelDown(tunnelName: "Tailscale Funnel")
        precondition(tunnel.title == "Tunnel down" && tunnel.body == "Tailscale Funnel stopped. Cloud agents can't reach this Mac."
                     && tunnel.kind == .tunnelDown && tunnel.identifier == "tunnel-down" && tunnel.info.isEmpty)
        precondition(!post(.tunnelDown, [], false, nil) && post(.tunnelDown, [.tunnelDown], false, nil), "the switch")
        // Never a key or a token in what's passed to macOS.
        for note in [declined, refused, update] {
            precondition(!(note.body + note.title + note.info.values.joined()).contains("ekb_"))
        }
        print("Notification rules: defaults, the switch, window focus, one refusal per connection every 10 minutes, tunnel down, texts passed")
    }
}
