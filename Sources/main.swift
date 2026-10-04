import AppKit
import EventKit

@MainActor
final class BridgeAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let eventStatus = NSTextField(labelWithString: "")
    private let reminderStatus = NSTextField(labelWithString: "")
    private let output = NSTextView()
    private var eventRequestButton: NSButton!
    private var reminderRequestButton: NSButton!
    private var eventListButton: NSButton!
    private var reminderListButton: NSButton!
    private var bridgeEnableButton: NSButton!
    private var bridgeDisableButton: NSButton!
    private let bridgeStatus = NSTextField(labelWithString: "Local counts bridge: off")
    private var localBridge: LocalBridge?
    private var requestInFlight = false
    private lazy var store = EKEventStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let content = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        let title = NSTextField(labelWithString: "EventKit Bridge · Read-only prototype")
        title.font = .boldSystemFont(ofSize: 19)
        stack.addArrangedSubview(title)

        let explanation = NSTextField(wrappingLabelWithString:
            "macOS full access covers calendar or reminder items. This prototype lists only calendar and list names, IDs, and writability after you press List. It never reads or changes an item.")
        explanation.maximumNumberOfLines = 3
        stack.addArrangedSubview(explanation)

        stack.addArrangedSubview(eventStatus)
        eventRequestButton = button("Request Calendar Access", #selector(requestEvents))
        eventListButton = button("List Calendars", #selector(listEvents))
        stack.addArrangedSubview(NSStackView(views: [eventRequestButton, eventListButton]))

        stack.addArrangedSubview(reminderStatus)
        reminderRequestButton = button("Request Reminders Access", #selector(requestReminders))
        reminderListButton = button("List Reminder Lists", #selector(listReminders))
        stack.addArrangedSubview(NSStackView(views: [reminderRequestButton, reminderListButton]))

        let bridgeTitle = NSTextField(labelWithString: "Temporary local counts bridge")
        bridgeTitle.font = .boldSystemFont(ofSize: 14)
        stack.addArrangedSubview(bridgeTitle)
        stack.addArrangedSubview(bridgeStatus)
        bridgeEnableButton = button("Enable for 15 Minutes", #selector(enableBridge))
        bridgeDisableButton = button("Disable", #selector(disableBridge))
        stack.addArrangedSubview(NSStackView(views: [bridgeEnableButton, bridgeDisableButton]))

        let hint = NSTextField(labelWithString: "The local bridge accepts only permission status and calendar/list counts. No network server or startup service runs.")
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)

        output.isEditable = false
        output.isSelectable = true
        output.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        output.string = "Choose a List button after granting access."
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = output
        stack.addArrangedSubview(scroll)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 510),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "EventKit Bridge"
        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        refreshStatus()
        refreshBridgeStatus()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        localBridge?.stop()
        localBridge = nil
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func refreshStatus() {
        let events = EKEventStore.authorizationStatus(for: .event)
        let reminders = EKEventStore.authorizationStatus(for: .reminder)
        eventStatus.stringValue = "Calendar access: \(name(events))"
        reminderStatus.stringValue = "Reminders access: \(name(reminders))"
        eventRequestButton.isEnabled = !requestInFlight && events == .notDetermined
        reminderRequestButton.isEnabled = !requestInFlight && reminders == .notDetermined
        eventListButton.isEnabled = !requestInFlight && events == .fullAccess
        reminderListButton.isEnabled = !requestInFlight && reminders == .fullAccess
    }

    private func name(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "Not determined"
        case .restricted: "Restricted"
        case .denied: "Denied"
        case .fullAccess: "Full access"
        case .writeOnly: "Write only"
        @unknown default: "Unknown"
        }
    }

    @objc private func requestEvents(_ sender: Any?) {
        guard EKEventStore.authorizationStatus(for: .event) == .notDetermined else { return }
        requestInFlight = true
        refreshStatus()
        store.requestFullAccessToEvents { [weak self] granted, error in
            let errorCode = error.map { "\(($0 as NSError).domain) \(($0 as NSError).code)" }
            DispatchQueue.main.async { [weak self] in
                self?.finishRequest("Calendar", granted: granted, errorCode: errorCode)
            }
        }
    }

    @objc private func requestReminders(_ sender: Any?) {
        guard EKEventStore.authorizationStatus(for: .reminder) == .notDetermined else { return }
        requestInFlight = true
        refreshStatus()
        store.requestFullAccessToReminders { [weak self] granted, error in
            let errorCode = error.map { "\(($0 as NSError).domain) \(($0 as NSError).code)" }
            DispatchQueue.main.async { [weak self] in
                self?.finishRequest("Reminders", granted: granted, errorCode: errorCode)
            }
        }
    }

    private func finishRequest(_ kind: String, granted: Bool, errorCode: String?) {
        requestInFlight = false
        refreshStatus()
        if let errorCode {
            output.string = "\(kind) request failed: \(errorCode)"
        } else {
            output.string = "\(kind) request \(granted ? "granted" : "not granted"). No items were read."
        }
    }

    @objc private func listEvents(_ sender: Any?) {
        list(.event, label: "Calendars")
    }

    @objc private func listReminders(_ sender: Any?) {
        list(.reminder, label: "Reminder lists")
    }

    private func list(_ entity: EKEntityType, label: String) {
        guard EKEventStore.authorizationStatus(for: entity) == .fullAccess else {
            output.string = "Full access is required to list \(label.lowercased())."
            refreshStatus()
            return
        }
        let calendars = store.calendars(for: entity)
        let rows = calendars.map { calendar in
            let writable = calendar.allowsContentModifications ? "writable" : "read only"
            return "\(String(reflecting: calendar.title))\t\(calendar.calendarIdentifier)\t\(writable)"
        }
        output.string = "\(label) (\(rows.count))\nTitle\tID\tAccess\n" + rows.joined(separator: "\n")
    }

    @objc private func enableBridge(_ sender: Any?) {
        guard localBridge == nil else { return }
        do {
            localBridge = try LocalBridge(handle: { [weak self] command in
                self?.bridgeResult(for: command) ?? ["error": "app_unavailable"]
            }, onStop: { [weak self] in
                self?.localBridge = nil
                self?.refreshBridgeStatus()
            })
            refreshBridgeStatus()
        } catch {
            bridgeStatus.stringValue = "Local counts bridge: could not start (\(error))"
        }
    }

    @objc private func disableBridge(_ sender: Any?) {
        localBridge?.stop()
    }

    private func refreshBridgeStatus() {
        if let localBridge {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            bridgeStatus.stringValue = "Local counts bridge: active until \(formatter.string(from: localBridge.expiration))"
        } else {
            bridgeStatus.stringValue = "Local counts bridge: off"
        }
        bridgeEnableButton.isEnabled = localBridge == nil
        bridgeDisableButton.isEnabled = localBridge != nil
    }

    private func bridgeResult(for command: BridgeCommand) -> [String: Any] {
        switch command {
        case .authorizationStatus:
            return [
                "calendar": name(EKEventStore.authorizationStatus(for: .event)),
                "reminders": name(EKEventStore.authorizationStatus(for: .reminder)),
            ]
        case .calendarCount:
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                return ["error": "calendar_access_not_granted"]
            }
            return ["count": store.calendars(for: .event).count]
        case .reminderListCount:
            guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                return ["error": "reminders_access_not_granted"]
            }
            return ["count": store.calendars(for: .reminder).count]
        }
    }
}

@main
struct EventKitBridgeApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = BridgeAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
