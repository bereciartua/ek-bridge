import AppKit
import EventKit
import SwiftUI

/// The floating Ask-before-changes panel (§13.6). Non-activating, so typing
/// in the agent's terminal can never approve a change by accident; Return and
/// Escape work only after the user clicks into it.
@MainActor
final class ApprovalPanelController {
    private let center: ApprovalCenter
    private var panel: NSPanel?
    private var host: NSHostingController<ApprovalPanelView>?
    private var shownCount = 0

    init(center: ApprovalCenter) {
        self.center = center
    }

    /// Shows, updates or hides the panel to match the queue.
    func update() {
        if center.pending.isEmpty {
            panel?.orderOut(nil)
            shownCount = 0
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Fit the content: rows and the queue stepper change its height. The
        // top edge stays put.
        if let host {
            let size = host.sizeThatFits(in: NSSize(width: 400, height: 2_000))
            if size.height > 1, size != panel.contentLayoutRect.size {
                let top = panel.frame.maxY
                panel.setContentSize(size)
                if panel.isVisible { panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: top)) }
            }
        }
        if !panel.isVisible {
            position(panel)
            panel.orderFrontRegardless()
        }
        if center.pending.count > shownCount, let newest = center.pending.last {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: newest.summary.title,
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        shownCount = center.pending.count
    }

    func bringForward() {
        guard let panel, !center.pending.isEmpty else { return }
        panel.orderFrontRegardless()
    }

    var window: NSWindow? { panel }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
                            styleMask: [.nonactivatingPanel, .titled, .utilityWindow, .fullSizeContentView],
                            backing: .buffered, defer: true)
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.title = String(localized: "Ask before changes")
        let host = NSHostingController(rootView: ApprovalPanelView(center: center))
        host.sizingOptions = []
        panel.contentViewController = host
        self.host = host
        return panel
    }

    /// Top right of the screen with the menu bar.
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.screens.first else { return }
        panel.layoutIfNeeded()
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 12, y: frame.maxY - size.height - 12))
    }
}

struct ApprovalPanelView: View {
    let center: ApprovalCenter
    @State private var allowWindow = false
    /// The change the buttons may act on. When the shown change switches
    /// (one expired, or the user stepped), they wait a moment so a click
    /// meant for the old one can't approve the new one.
    @State private var armedID: UUID?

    var body: some View {
        if let item = center.current {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: 40, height: 40)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.summary.title)
                                .font(.headline)
                                .fixedSize(horizontal: false, vertical: true)
                            if let subtitle = item.summary.subtitle {
                                HStack(spacing: 5) {
                                    if let color = item.summary.collectionColor {
                                        ColorDot(color: color, size: 8)
                                    }
                                    Text(subtitle).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    details(item)
                    Toggle(String(localized: "Allow changes from \(item.clientName) for 15 minutes"),
                           isOn: $allowWindow)
                        .toggleStyle(.checkbox)
                }
                .padding(16)
                Divider()
                footer(item)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
            .frame(width: 400)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: item.id, initial: true) { _, id in
                allowWindow = false
                armedID = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if center.current?.id == id { armedID = id }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(item.summary.title)
        } else {
            Color.clear.frame(width: 400, height: 1)
        }
    }

    private func details(_ item: PendingApproval) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(Array(item.summary.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.label).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            if let before = row.before {
                                Text(before)
                                    .strikethrough()
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel(String(localized: "Before: \(before)"))
                            }
                            Text(row.value)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityLabel(row.before == nil ? row.value
                                                    : String(localized: "After: \(row.value)"))
                        }
                    }
                }
                if let agent = item.agent {
                    GridRow {
                        Text(String(localized: "Agent")).foregroundStyle(.secondary)
                        Text(String(localized: "\(agent) (as reported)")).foregroundStyle(.secondary)
                    }
                }
            }
            if item.summary.lookupFailed {
                Label(String(localized: "Couldn't load the current item."), systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func footer(_ item: PendingApproval) -> some View {
        HStack(spacing: 8) {
            if center.pending.count > 1 {
                Text(String(localized: "\(center.selection + 1) of \(center.pending.count)"))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button { center.selection = max(0, center.selection - 1) } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .disabled(center.selection == 0)
                .accessibilityLabel(String(localized: "Previous change"))
                Button { center.selection = min(center.pending.count - 1, center.selection + 1) } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .disabled(center.selection >= center.pending.count - 1)
                .accessibilityLabel(String(localized: "Next change"))
                Text("·").foregroundStyle(.secondary)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, Int(item.expiresAt.timeIntervalSince(context.date).rounded(.up)))
                Text(String(localized: "Expires in \(left) s"))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(String(localized: "Deny")) { center.deny(item.id) }
                .keyboardShortcut(.cancelAction)
                .disabled(armedID != item.id)
            if item.summary.isDelete {
                Button(String(localized: "Delete"), role: .destructive) {
                    center.allow(item.id, forWindow: allowWindow)
                }
                .keyboardShortcut(.defaultAction)
                .tint(.red)
                .buttonStyle(.borderedProminent)
                .disabled(armedID != item.id)
            } else {
                Button(String(localized: "Allow")) { center.allow(item.id, forWindow: allowWindow) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(armedID != item.id)
            }
        }
    }
}

/// Builds the panel's text from the request parameters and a fresh EventKit
/// lookup of the current item, never from anything the agent wrote about it.
@MainActor
enum ApprovalSummaries {
    static func build(_ approval: ApprovalRequest, store: EKEventStore?,
                      collections: [CollectionInfo]) -> ApprovalSummary {
        let request = approval.request
        let p = request.parameters
        let command = request.command
        let reminders = CommandPresentation.targetsList(command.rawValue)
        let collection = approval.targetID.flatMap { id in
            collections.first { $0.id == id && $0.resource == (reminders ? .reminderList : .calendar) }
        }
        let subtitle = collection.map { "\($0.name) · \($0.account)" }
        let title = String(localized: "\(approval.clientName) wants to \(verb(command))")
        var rows = [ApprovalSummary.Row]()
        var lookupFailed = false
        let itemID = p["itemID"] as? String

        switch command {
        case .createEvent:
            rows.append(.init(label: String(localized: "Event"), value: text(p["title"])))
            rows.append(.init(label: String(localized: "When"), value: eventTime(p)))
            if let notes = p["notes"] as? String {
                rows.append(.init(label: String(localized: "Notes"), value: notes))
            }
        case .updateEvent, .deleteEvent:
            let event = itemID.flatMap { store?.event(withIdentifier: $0) }
            lookupFailed = event == nil
            let currentTitle = event?.title
            let currentTime = event.map { span($0.startDate, $0.endDate, allDay: $0.isAllDay) }
            if command == .deleteEvent {
                rows.append(.init(label: String(localized: "Event"), value: currentTitle ?? "–"))
                if let currentTime { rows.append(.init(label: String(localized: "When"), value: currentTime)) }
            } else {
                let newTitle = text(p["title"])
                let newTime = eventTime(p)
                rows.append(.init(label: String(localized: "Event"), value: newTitle,
                                  before: currentTitle != newTitle ? currentTitle : nil))
                rows.append(.init(label: String(localized: "When"), value: newTime,
                                  before: currentTime != newTime ? currentTime : nil))
            }
        case .createReminder:
            rows.append(.init(label: String(localized: "Reminder"), value: text(p["title"])))
            if let due = p["due"] as? [String: Any], let value = dueText(due) {
                rows.append(.init(label: String(localized: "Due"), value: value))
            }
            if let repeats = (p["recurrence"] as? [String: Any]).flatMap(repeatText) {
                rows.append(.init(label: String(localized: "Repeats"), value: repeats))
            }
        case .updateReminder, .completeReminder, .deleteReminder:
            let reminder = itemID.flatMap { store?.calendarItem(withIdentifier: $0) as? EKReminder }
            lookupFailed = reminder == nil
            let currentDue = reminder?.dueDateComponents.flatMap(dueText(components:))
            if command == .updateReminder {
                let newTitle = text(p["title"])
                rows.append(.init(label: String(localized: "Reminder"), value: newTitle,
                                  before: reminder?.title != newTitle ? reminder?.title : nil))
                if let due = p["due"] as? [String: Any] {
                    let value = dueText(due) ?? String(localized: "None")
                    rows.append(.init(label: String(localized: "Due"), value: value,
                                      before: (currentDue ?? String(localized: "None")) != value
                                        ? (currentDue ?? String(localized: "None")) : nil))
                } else if let currentDue {
                    rows.append(.init(label: String(localized: "Due"), value: currentDue))
                }
                if let recurrence = p["recurrence"] as? [String: Any] {
                    rows.append(.init(label: String(localized: "Repeats"),
                                      value: repeatText(recurrence) ?? String(localized: "Never")))
                }
            } else {
                rows.append(.init(label: String(localized: "Reminder"), value: reminder?.title ?? "–"))
                if let currentDue { rows.append(.init(label: String(localized: "Due"), value: currentDue)) }
                if command == .completeReminder, p["recurrenceScope"] as? String == "occurrence" {
                    rows.append(.init(label: String(localized: "Repeats"),
                                      value: String(localized: "Only this occurrence is completed")))
                }
            }
        default:
            break
        }
        return ApprovalSummary(title: title, subtitle: subtitle, rows: rows,
                               isDelete: command == .deleteEvent || command == .deleteReminder,
                               lookupFailed: lookupFailed, collectionColor: collection?.color)
    }

    static func verb(_ command: BridgeCommand) -> String {
        switch command {
        case .createEvent: String(localized: "add an event")
        case .updateEvent: String(localized: "change an event")
        case .deleteEvent: String(localized: "delete an event")
        case .createReminder: String(localized: "add a reminder")
        case .updateReminder: String(localized: "change a reminder")
        case .completeReminder: String(localized: "complete a reminder")
        case .deleteReminder: String(localized: "delete a reminder")
        default: String(localized: "make a change")
        }
    }

    private static func text(_ value: Any?) -> String { value as? String ?? "–" }

    private static func seconds(_ value: Any?) -> Date? {
        (value as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
    }

    private static func eventTime(_ p: [String: Any]) -> String {
        guard let start = seconds(p["start"]), let end = seconds(p["end"]) else { return "–" }
        if p["allDay"] != nil, let zone = (p["timeZone"] as? String).flatMap(TimeZone.init(identifier:)) {
            return allDaySpan(start, end, zone: zone)
        }
        return span(start, end, allDay: false)
    }

    static func span(_ start: Date, _ end: Date, allDay: Bool) -> String {
        if allDay { return allDaySpan(start, end, zone: .current) }
        let day = start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        let from = start.formatted(date: .omitted, time: .shortened)
        let sameDay = Calendar.current.isDate(start, inSameDayAs: end)
        let to = sameDay ? end.formatted(date: .omitted, time: .shortened)
                         : end.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
        return "\(day), \(from)–\(to)"
    }

    private static func allDaySpan(_ start: Date, _ end: Date, zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let style = Date.FormatStyle(timeZone: zone).weekday(.abbreviated).month(.abbreviated).day()
        let last = end.addingTimeInterval(-1)
        let first = start.formatted(style)
        return calendar.isDate(start, inSameDayAs: last)
            ? String(localized: "\(first), all day")
            : String(localized: "\(first) – \(last.formatted(style)), all day")
    }

    private static func dueText(_ due: [String: Any]) -> String? {
        switch due["kind"] as? String {
        case "timed":
            guard let at = seconds(due["at"]) else { return nil }
            return at.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
        case "all_day":
            return due["date"] as? String
        default:
            return nil
        }
    }

    private static func dueText(components: DateComponents) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = components.timeZone ?? .current
        guard let date = calendar.date(from: components) else { return nil }
        return components.hour == nil
            ? date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            : date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }

    private static func repeatText(_ recurrence: [String: Any]) -> String? {
        guard recurrence["kind"] as? String == "rule", let frequency = recurrence["frequency"] as? String
        else { return nil }
        let interval = (recurrence["interval"] as? NSNumber)?.intValue ?? 1
        let unit: String
        switch frequency {
        case "daily": unit = interval == 1 ? String(localized: "Every day") : String(localized: "Every \(interval) days")
        case "weekly": unit = interval == 1 ? String(localized: "Every week") : String(localized: "Every \(interval) weeks")
        case "monthly": unit = interval == 1 ? String(localized: "Every month") : String(localized: "Every \(interval) months")
        default: unit = interval == 1 ? String(localized: "Every year") : String(localized: "Every \(interval) years")
        }
        var parts = [unit]
        if let days = recurrence["weekdays"] as? [String], !days.isEmpty {
            let codes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
            let names = days.compactMap { code in
                codes.firstIndex(of: code).map { Calendar.current.weekdaySymbols[$0] }
            }
            parts.append(String(localized: "on \(names.formatted(.list(type: .and)))"))
        }
        if let day = recurrence["dayOfMonth"] as? NSNumber {
            parts.append(String(localized: "on day \(day.intValue)"))
        }
        if let end = recurrence["end"] as? [String: Any] {
            if let count = end["count"] as? NSNumber {
                parts.append(String(localized: "\(count.intValue) times"))
            } else if let until = seconds(end["at"]) {
                parts.append(String(localized: "until \(until.formatted(date: .abbreviated, time: .omitted))"))
            }
        }
        return parts.joined(separator: " ")
    }
}
