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
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
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
            _ = model.pendingApprovalCount
            _ = model.remoteEnabled
            _ = model.resumeAt
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
        let glyph = MenuBarGlyphState.for(needsAttention: model.needsAttention, bridgeOn: model.bridge.isOn)
        let state = switch glyph {
        case .attention: String(localized: "needs attention")
        case .on: String(localized: "on")
        case .paused: String(localized: "paused")
        }
        let pending = model.pendingApprovalCount
        var label = String(localized: "\(AppIdentity.displayName), \(state)")
        if pending > 0 {
            label += ", " + (pending == 1 ? String(localized: "1 change waiting for approval")
                                          : String(localized: "\(pending) changes waiting for approval"))
        }
        let image = MenuBarGlyph.image(glyph)
        image.accessibilityDescription = label
        button.image = image
        // The pending count, and a globe while Remote Access is on, sit beside
        // the icon.
        let title = NSMutableAttributedString()
        if AppIdentity.isLiveTest {
            // The live-test copy can never be mistaken for the real one.
            title.append(NSAttributedString(string: "TEST ", attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .heavy)]))
        }
        if model.remoteEnabled, let globe = NSImage(systemSymbolName: "globe",
                                                   accessibilityDescription: String(localized: "Remote Access on")) {
            let attachment = NSTextAttachment()
            attachment.image = globe.withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
            title.append(NSAttributedString(attachment: attachment))
        }
        if pending > 0 {
            title.append(NSAttributedString(string: "\(pending)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold),
                .foregroundColor: NSColor.systemRed]))
        }
        button.imagePosition = title.length > 0 ? .imageLeading : .imageOnly
        button.attributedTitle = title
        if model.remoteEnabled { label += ", " + String(localized: "Remote Access on") }
        button.setAccessibilityLabel(label)
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

    /// Header; Pause EK Bridge ▸ or Turn On EK Bridge; MCP and Remote lines;
    /// Needs you; Recent changes; then the app items (mockup 09).
    private func rebuild() {
        menu.removeAllItems()

        let headerView = StatusHeaderView(model: model) { [weak self] on in
            self?.toggleBridge(on)
        }
        header = headerView
        let headerItem = NSMenuItem()
        headerItem.view = headerView
        menu.addItem(headerItem)
        if model.bridge.isOn {
            let pause = NSMenuItem(title: String(localized: "Pause \(AppIdentity.displayName)"), action: nil,
                                   keyEquivalent: "")
            let choices = NSMenu()
            for choice in PauseChoice.allCases {
                let title = switch choice {
                case .oneHour: String(localized: "For 1 Hour")
                case .untilTomorrow: String(localized: "Until Tomorrow")
                case .untilTurnedOn: String(localized: "Until I Turn It On")
                }
                choices.addItem(item(title) { [weak self] in self?.pauseBridge(choice) })
            }
            pause.submenu = choices
            menu.addItem(pause)
        } else if model.policyStoreAvailable {
            menu.addItem(item(String(localized: "Turn On \(AppIdentity.displayName)")) { [weak self] in
                self?.toggleBridge(true)
            })
        }
        // Nothing while paused (the header says so) or when no connection uses MCP.
        if let mcpLine = model.mcpStatusLine {
            let mcpItem = item(mcpLine) { [weak self] in
                self?.model.settingsScrollTarget = "mcp"
                self?.model.show(.settings)
            }
            mcpItem.attributedTitle = iconTitle(symbol("server.rack", color: model.mcpFailureText == nil
                                                       ? .secondaryLabelColor : .systemOrange), mcpLine)
            mcpItem.toolTip = String(localized: "Open Settings ▸ Advanced")
            menu.addItem(mcpItem)
        }
        if model.remoteEnabled {
            let line = model.remoteMenuLine
            let remoteItem = item(line) { [weak self] in self?.model.show(.remoteAccess) }
            remoteItem.attributedTitle = iconTitle(symbol("globe", color: .systemBlue), line)
            menu.addItem(remoteItem)
            // One click cuts all cloud access (R5).
            let off = item(String(localized: "Turn Off Remote Access")) { [weak self] in
                self?.model.applyRemoteEnabled(false)
            }
            off.attributedTitle = iconTitle(nil, String(localized: "Turn Off Remote Access"))
            menu.addItem(off)
        }
        menu.addItem(.separator())

        let needsYou = needsYouItems()
        if !needsYou.isEmpty {
            menu.addItem(NSMenuItem.sectionHeader(title: String(localized: "Needs you")))
            needsYou.forEach(menu.addItem)
            menu.addItem(.separator())
        }

        let recent = Array(model.activity.filter(\.isWrite).prefix(3))
        if !recent.isEmpty {
            menu.addItem(NSMenuItem.sectionHeader(title: String(localized: "Recent changes")))
            for entry in recent {
                let row = item("") { [weak self] in
                    self?.model.openActivity(selecting: entry.id)
                }
                row.attributedTitle = recentTitle(entry)
                row.setAccessibilityLabel(String(localized: "\(model.clientName(entry.clientID)), \(CommandPresentation.label(entry.command)), \(entry.outcome.label), \(RelativeTime.ago(entry.at, now: model.now))"))
                menu.addItem(row)
            }
        }
        if !model.activity.isEmpty {
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
        if model.updaterAvailable {
            menu.addItem(item(String(localized: "Check for Updates…")) { [weak self] in
                self?.model.checkForUpdates()
            })
        }
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Quit \(AppIdentity.displayName)"), key: "q") {
            NSApp.terminate(nil)
        })
    }

    /// Changes waiting for approval, problems with their fix, and an update.
    private func needsYouItems() -> [NSMenuItem] {
        var items = [NSMenuItem]()
        let pending = model.pendingApprovalCount
        if pending > 0 {
            let title = pending == 1 ? String(localized: "1 change waiting for approval…")
                                     : String(localized: "\(pending) changes waiting for approval…")
            let approvals = item(title) { [weak self] in self?.model.showApprovals() }
            approvals.attributedTitle = iconTitle(symbol("hand.raised.fill", color: .systemBlue), title)
            items.append(approvals)
        }
        for problem in model.problems {
            let title = item(problem.title) { [weak self] in self?.model.fix(problem) }
            title.attributedTitle = iconTitle(symbol("exclamationmark.triangle.fill", color: .systemOrange),
                                              problem.title)
            items.append(title)
            let fixTitle = problem.opensPrivacySettings
                ? String(localized: "Open Privacy Settings…")
                : String(localized: "Open \(AppIdentity.displayName)…")
            let fixItem = item(fixTitle) { [weak self] in self?.model.fix(problem) }
            // Indented to line up with the problem's text, after its icon.
            fixItem.attributedTitle = iconTitle(nil, fixTitle)
            items.append(fixItem)
        }
        if let update = model.foundUpdate {
            let title = update.critical
                ? String(localized: "Security Update Available: \(update.version)…")
                : String(localized: "Update Available: \(update.version)…")
            let updateItem = item(title) { [weak self] in self?.model.checkForUpdates() }
            updateItem.attributedTitle = iconTitle(
                symbol("arrow.down.circle.fill", color: update.critical ? .systemRed : .systemBlue), title)
            items.append(updateItem)
        }
        return items
    }

    private func pauseBridge(_ choice: PauseChoice) {
        if model.hasUnsavedChanges {
            // The save prompt can't run inside menu tracking.
            menu.cancelTracking()
            DispatchQueue.main.async { [weak self] in self?.model.pause(for: choice) }
        } else {
            model.pause(for: choice)
        }
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

    // Menu item images aren't shown on every macOS version, so status icons
    // are drawn as text attachments inside the title.
    private static let iconWidth: CGFloat = 16
    private static let ageTab: CGFloat = 288

    private func iconTitle(_ image: NSImage?, _ text: String, trailing: String? = nil) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: Self.iconWidth + 6),
                              NSTextTab(textAlignment: .right, location: Self.ageTab)]
        let font = NSFont.menuFont(ofSize: 0)
        let result = NSMutableAttributedString()
        if let image {
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: font.descender + 1, width: image.size.width,
                                       height: image.size.height)
            result.append(NSAttributedString(attachment: attachment))
        }
        result.append(NSAttributedString(string: "\t" + text))
        if let trailing {
            result.append(NSAttributedString(string: "\t" + trailing,
                                             attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
        }
        result.addAttributes([.font: font, .paragraphStyle: paragraph],
                             range: NSRange(location: 0, length: result.length))
        return result
    }

    /// "Claude Code · Update event · Work" (item names come with Activity's item IDs).
    private func recentTitle(_ entry: ActivityEntry) -> NSAttributedString {
        let target = entry.targetID.flatMap { id in model.collections.first { $0.id == id }?.name }
        let text = [model.clientName(entry.clientID), CommandPresentation.label(entry.command), target]
            .compactMap { $0 }.joined(separator: " · ")
        return iconTitle(outcomeImage(entry.outcome.tone), text,
                         trailing: RelativeTime.short(entry.at, now: model.now))
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
    private var widthConstraint: NSLayoutConstraint!
    static let width: CGFloat = 360

    init(model: BridgeAppModel, onToggle: @escaping (Bool) -> Void) {
        self.model = model
        self.onToggle = onToggle
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 54))
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1)
        subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 2
        subtitle.preferredMaxLayoutWidth = Self.width - 110
        toggle.target = self
        toggle.action = #selector(toggled)
        toggle.setAccessibilityLabel(AppIdentity.displayName)
        let labels = NSStackView(views: [title, subtitle])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        let row = NSStackView(views: [labels, toggle])
        row.orientation = .horizontal
        row.distribution = .fill
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
        ])
        // Menus don't stretch item views, so the header sets the menu's width:
        // wide enough for every standard item, with the switch at the edge.
        widthConstraint = widthAnchor.constraint(equalToConstant: Self.width)
        widthConstraint.isActive = true

        update()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update() {
        title.stringValue = model.bridgeTitle
        subtitle.stringValue = model.statusSubtitle
        toggle.state = model.bridge.isOn ? .on : .off
        toggle.isEnabled = model.policyStoreAvailable || model.bridge.isOn
        setAccessibilityElement(false)
        layoutSubtreeIfNeeded()
        setFrameSize(NSSize(width: frame.width, height: fittingSize.height))
    }

    @objc private func toggled() {
        onToggle(toggle.state == .on)
    }
}
