import AppKit
import EventKit
import SwiftUI

/// Shown instead of the delete's rows when the item didn't load.
struct BlindDeleteWarning: View {
    let itemID: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "\(AppIdentity.displayName) can't show what will be deleted."))
                    .font(.callout.weight(.semibold))
                Group {
                    if let itemID {
                        Text(String(localized: "The item didn't load (ID \(ApprovalSummary.shortID(itemID)))."))
                            .help(itemID)
                    } else {
                        Text(String(localized: "The item didn't load."))
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

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
        fit(panel)
        // Once more after SwiftUI has drawn the change (a new selection's
        // rows, say), which the first measurement can miss.
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, !self.center.pending.isEmpty else { return }
            self.fit(panel)
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

    /// Fits the content: rows, warnings and the queue stepper change its
    /// height. The top edge stays put.
    private func fit(_ panel: NSPanel) {
        guard let host else { return }
        let size = host.sizeThatFits(in: NSSize(width: 400, height: 2_000))
        if size.height > 1, size != panel.contentLayoutRect.size {
            let top = panel.frame.maxY
            panel.setContentSize(size)
            if panel.isVisible { panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: top)) }
        }
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
        // The title bar is hidden, so its safe area would only add a gap at
        // the top, and measure differently before and after the panel shows.
        content.ignoresSafeArea()
    }

    @ViewBuilder
    private var content: some View {
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
                            Text(Self.attributed(row.value, bold: row.emphasis))
                                .lineLimit(6)
                                .fixedSize(horizontal: false, vertical: true)
                                .help(row.full ?? "")
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
            if item.summary.isBlindDelete {
                BlindDeleteWarning(itemID: item.summary.itemIDForDisplay)
            } else if item.summary.lookupFailed {
                Label(String(localized: "Couldn't load the current item."), systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// `text` with the first `bold` substring emphasized. Built without
    /// Markdown: the text comes from the request and may contain anything.
    static func attributed(_ text: String, bold: String?) -> AttributedString {
        var result = AttributedString(text)
        if let bold, !bold.isEmpty, let range = result.range(of: bold) {
            result[range].font = .body.bold()
        }
        return result
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
            if item.summary.isBlindDelete {
                // Nothing to review, so Return denies, Escape still denies,
                // and deleting takes a click.
                Button(String(localized: "Delete Anyway"), role: .destructive) {
                    center.allow(item.id, forWindow: allowWindow)
                }
                .buttonStyle(.bordered)
                .disabled(armedID != item.id)
                Button(String(localized: "Deny")) { center.deny(item.id) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(armedID != item.id)
                    .background {
                        Button(String(localized: "Deny")) { center.deny(item.id) }
                            .keyboardShortcut(.cancelAction)
                            .disabled(armedID != item.id)
                            .opacity(0)
                            .accessibilityHidden(true)
                    }
            } else {
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
}
