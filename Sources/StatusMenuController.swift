import AppKit
import Observation

/// The menu bar extra (§5): status and shortcuts only. The icon follows the
/// model; the menu is rebuilt each time it opens so relative times are fresh.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let model: BridgeAppModel
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var header: StatusHeaderView?

    init(model: BridgeAppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateIcon()
        observe()
    }

    var button: NSStatusBarButton? { statusItem.button }

    private func observe() {
        withObservationTracking {
            _ = model.bridge
            _ = model.needsAttention
            _ = model.statusSubtitle
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.updateIcon()
                self?.header?.update()
                self?.observe()
            }
        }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let symbol: String
        let state: String
        if model.needsAttention {
            symbol = "calendar.badge.exclamationmark"
            state = String(localized: "needs attention")
        } else if model.bridge.isOn {
            symbol = "calendar.badge.checkmark"
            state = String(localized: "on")
        } else {
            symbol = "calendar"
            state = String(localized: "off")
        }
        let label = String(localized: "\(AppIdentity.displayName), \(state)")
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))
        image?.isTemplate = true
        button.image = image
        button.appearsDisabled = !model.bridge.isOn && !model.needsAttention
        button.setAccessibilityLabel(label)
        button.toolTip = "\(AppIdentity.displayName)\n\(model.statusSubtitle)"
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        model.refresh()
        rebuild()
    }

    func menuDidClose(_ menu: NSMenu) {
        header = nil
    }

    private func rebuild() {
        menu.removeAllItems()

        let headerView = StatusHeaderView(model: model) { [weak self] on in
            self?.toggleBridge(on)
        }
        header = headerView
        let headerItem = NSMenuItem()
        headerItem.view = headerView
        menu.addItem(headerItem)
        menu.addItem(.separator())

        let problems = model.problems
        for problem in problems {
            let title = item(problem.title, image: symbol("exclamationmark.triangle.fill", color: .systemOrange)) { [weak self] in
                self?.fix(problem)
            }
            menu.addItem(title)
            let fixTitle = problem.opensPrivacySettings
                ? String(localized: "Open Privacy Settings…")
                : String(localized: "Open \(AppIdentity.displayName)…")
            menu.addItem(item(fixTitle, image: blankImage()) { [weak self] in self?.fix(problem) })
        }
        if !problems.isEmpty { menu.addItem(.separator()) }

        let recent = Array(model.activity.prefix(3))
        if !recent.isEmpty {
            menu.addItem(NSMenuItem.sectionHeader(title: String(localized: "Recent requests")))
            for entry in recent {
                let row = item("", image: outcomeImage(entry.outcome.tone)) { [weak self] in
                    self?.model.openActivity(selecting: entry.id)
                }
                row.attributedTitle = recentTitle(entry)
                row.setAccessibilityLabel(String(localized: "\(model.clientName(entry.clientID)), \(CommandPresentation.label(entry.command)), \(entry.outcome.label), \(RelativeTime.ago(entry.at, now: model.now))"))
                menu.addItem(row)
            }
            menu.addItem(item(String(localized: "Show All Activity…")) { [weak self] in
                self?.model.openActivity()
            })
            menu.addItem(.separator())
        }

        menu.addItem(item(String(localized: "Open \(AppIdentity.displayName)…"), key: "o") { [weak self] in
            self?.model.showWindow()
        })
        menu.addItem(item(String(localized: "Settings…"), key: ",") { [weak self] in
            self?.model.show(.settings)
        })
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Quit \(AppIdentity.displayName)"), key: "q") {
            NSApp.terminate(nil)
        })
    }

    private func toggleBridge(_ on: Bool) {
        if model.hasUnsavedChanges {
            // The save prompt can't run inside menu tracking.
            menu.cancelTracking()
            DispatchQueue.main.async { [weak self] in self?.model.setBridgeEnabled(on) }
        } else {
            model.setBridgeEnabled(on)
            header?.update()
        }
    }

    private func fix(_ problem: AttentionProblem) {
        switch problem {
        case .calendarAccess: model.openPrivacySettings(.calendar)
        case .remindersAccess: model.openPrivacySettings(.reminderList)
        case .policyStoreUnavailable, .bridgeFailed: model.show(.overview)
        }
    }

    private func recentTitle(_ entry: ActivityEntry) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: 310)]
        let text = NSMutableAttributedString(
            string: "\(model.clientName(entry.clientID)) · \(CommandPresentation.label(entry.command))",
            attributes: [.font: NSFont.menuFont(ofSize: 0), .paragraphStyle: paragraph])
        text.append(NSAttributedString(
            string: "\t\(RelativeTime.short(entry.at, now: model.now))",
            attributes: [.font: NSFont.menuFont(ofSize: 0), .paragraphStyle: paragraph,
                         .foregroundColor: NSColor.secondaryLabelColor]))
        return text
    }

    private func item(_ title: String, key: String = "", image: NSImage? = nil,
                      action: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, keyEquivalent: key, handler: action)
        item.image = image
        return item
    }

    private func outcomeImage(_ tone: OutcomeTone) -> NSImage? {
        switch tone {
        case .ok: symbol("checkmark.circle.fill", color: .systemGreen)
        case .bad: symbol("xmark.circle.fill", color: .systemRed)
        case .warn: symbol("exclamationmark.triangle.fill", color: .systemOrange)
        case .neutral: symbol("minus.circle.fill", color: .systemGray)
        }
    }

    private func symbol(_ name: String, color: NSColor) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, color]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = false
        return image
    }

    private func blankImage() -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16))
    }
}

/// An NSMenuItem that runs a closure, so the menu needs no selector table.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}

/// The menu header: name, status line and the bridge switch, like the Wi‑Fi menu.
@MainActor
final class StatusHeaderView: NSView {
    private let model: BridgeAppModel
    private let onToggle: (Bool) -> Void
    private let title = NSTextField(labelWithString: AppIdentity.displayName)
    private let subtitle = NSTextField(wrappingLabelWithString: "")
    private let toggle = NSSwitch()

    init(model: BridgeAppModel, onToggle: @escaping (Bool) -> Void) {
        self.model = model
        self.onToggle = onToggle
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 54))
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1)
        subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 2
        subtitle.preferredMaxLayoutWidth = 240
        toggle.target = self
        toggle.action = #selector(toggled)
        toggle.setAccessibilityLabel(String(localized: "Bridge"))
        let labels = NSStackView(views: [title, subtitle])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        let row = NSStackView(views: [labels, toggle])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        toggle.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: 320),
        ])
        update()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update() {
        subtitle.stringValue = model.statusSubtitle
        toggle.state = model.bridge.isOn ? .on : .off
        toggle.isEnabled = model.policyStoreAvailable || model.bridge.isOn
        setAccessibilityElement(false)
        layoutSubtreeIfNeeded()
        setFrameSize(NSSize(width: 320, height: fittingSize.height))
    }

    @objc private func toggled() {
        onToggle(toggle.state == .on)
    }
}
