import AppKit
import EventKit
import SwiftUI

extension ClientView: Identifiable {}

extension OutcomeTone {
    var color: Color {
        switch self {
        case .ok: .green
        case .warn: .orange
        case .bad: .red
        case .neutral: .secondary
        }
    }
}

extension CollectionColor {
    var swiftUI: Color { Color(red: red, green: green, blue: blue) }
}

enum Palette {
    /// Card surface: white in light mode, raised grey in dark mode.
    static let card = Color(nsColor: adaptive(light: .white, dark: NSColor(white: 0.17, alpha: 1),
                                              lightContrast: .white, darkContrast: NSColor(white: 0.12, alpha: 1)))
    /// Detail pane background, one step behind the cards.
    static let pane = Color(nsColor: adaptive(light: NSColor(white: 0.962, alpha: 1),
                                              dark: NSColor(white: 0.115, alpha: 1),
                                              lightContrast: NSColor(white: 0.93, alpha: 1),
                                              darkContrast: .black))

    private static func adaptive(light: NSColor, dark: NSColor,
                                 lightContrast: NSColor, darkContrast: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                               .accessibilityHighContrastDarkAqua]) {
            case .darkAqua: dark
            case .accessibilityHighContrastDarkAqua: darkContrast
            case .accessibilityHighContrastAqua: lightContrast
            default: light
            }
        }
    }
    static let separator = Color(nsColor: .separatorColor)
    static let groupHeader = Color(nsColor: .underPageBackgroundColor).opacity(0.5)
    static let avatars: [Color] = [.purple, .orange, .teal, .blue, .pink, .indigo, .green, .brown]
}

/// A rounded group like System Settings. The border uses a dynamic color, so
/// it follows appearance changes while the window is open.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Palette.separator.opacity(0.6), lineWidth: 0.5))
    }
}

/// Rows separated by inset dividers inside a card.
struct CardRows<Data: RandomAccessCollection, Row: View>: View where Data.Element: Identifiable {
    let data: Data
    @ViewBuilder var row: (Data.Element) -> Row

    var body: some View {
        Card {
            ForEach(Array(data.enumerated()), id: \.element.id) { index, element in
                if index > 0 { Divider().padding(.leading, 16) }
                row(element)
            }
        }
    }
}

struct SectionTitle: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.headline)
            if let subtitle {
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .padding(.leading, 2)
    }
}

struct PaneTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 22, weight: .bold))
            .lineLimit(1)
            .truncationMode(.tail)
            .accessibilityAddTraits(.isHeader)
    }
}

struct Pill: View {
    let label: String
    let tone: OutcomeTone
    var icon: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            if icon {
                Image(systemName: symbol)
                    .imageScale(.small)
            }
            Text(label)
        }
        .font(.callout.weight(.medium))
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(tone == .neutral ? Color.secondary : tone.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 2.5)
        .background((tone == .neutral ? Color.secondary : tone.color).opacity(0.14), in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch tone {
        case .ok: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .bad: "xmark.circle.fill"
        case .neutral: "minus.circle.fill"
        }
    }
}

struct AvatarView: View {
    let name: String
    let id: String
    var size: CGFloat = 28

    var body: some View {
        Text(ClientAvatar.initials(name))
            .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Palette.avatars[ClientAvatar.colorIndex(id)].gradient,
                        in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct ColorDot: View {
    let color: CollectionColor?
    var size: CGFloat = 10

    var body: some View {
        Circle()
            .fill(color?.swiftUI ?? Color.secondary)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Copies one string. After copying, the label reads "Copied" for 1.5 s and
/// VoiceOver announces it.
struct CopyButton: View {
    let text: String
    var title: String? = nil
    let help: String
    @State private var copied = false

    var body: some View {
        Button {
            Pasteboard.copy(text)
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: String(localized: "Copied"),
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
            withAnimation(.easeOut(duration: 0.15)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation { copied = false }
            }
        } label: {
            if let title {
                Label(copied ? String(localized: "Copied") : title,
                      systemImage: copied ? "checkmark" : "doc.on.doc")
            } else {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .frame(width: 16)
            }
        }
        .help(help)
        .accessibilityLabel(copied ? String(localized: "Copied") : (title ?? help))
    }
}

struct BannerView: View {
    let banner: Banner
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .font(.body.weight(.semibold))
            VStack(alignment: .leading, spacing: 2) {
                (Text(banner.title).bold() +
                 Text(banner.message.map { " " + $0 } ?? ""))
                    .fixedSize(horizontal: false, vertical: true)
                if let code = banner.code {
                    Text(code)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            if let title = banner.actionTitle, let action = banner.action {
                Button(title, action: action)
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Dismiss"))
                .accessibilityLabel(String(localized: "Dismiss"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(color.opacity(0.25), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
    }

    private var symbol: String {
        switch banner.kind {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch banner.kind {
        case .info: .accentColor
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}

/// The shared macOS access status row (§12): Overview, setup, empty states.
struct AccessStatusRow: View {
    let model: BridgeAppModel
    let resource: ClientResource
    var prominent = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: resource == .calendar ? "calendar" : "list.bullet")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(resource == .calendar ? String(localized: "Calendars") : String(localized: "Reminders"))
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            AccessStatusControls(model: model, resource: resource, prominent: prominent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }

    private var detail: String? {
        let status = model.status(resource)
        if status == .denied && model.accessRequestDeclined.contains(resource) {
            return String(localized: "You chose not to allow access. You can change this in System Settings.")
        }
        return AccessText.detail(resource, status)
    }
}

/// Pill plus the one action that fixes the state.
struct AccessStatusControls: View {
    let model: BridgeAppModel
    let resource: ClientResource
    var prominent = false

    var body: some View {
        let status = model.status(resource)
        HStack(spacing: 10) {
            if let pill = AccessText.pill(status) {
                Pill(label: pill.label, tone: pill.tone, icon: status == .fullAccess)
            }
            switch status {
            case .notDetermined:
                if model.accessRequestInFlight.contains(resource) {
                    ProgressView().controlSize(.small)
                }
                Button(String(localized: "Allow Access…")) { model.requestAccess(resource) }
                    .disabled(model.accessRequestInFlight.contains(resource))
                    .modifier(Prominent(on: prominent))
            case .denied, .writeOnly:
                Button(String(localized: "Open Privacy Settings")) { model.openPrivacySettings(resource) }
                    .modifier(Prominent(on: prominent))
            default:
                EmptyView()
            }
        }
    }
}

struct Prominent: ViewModifier {
    let on: Bool

    func body(content: Content) -> some View {
        if on { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
    }
}

/// A native search field (rounded, with the magnifier and clear button).
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    var accessibilityLabel: String? = nil
    /// Each change moves keyboard focus into the field (⌘F).
    var focusRequest = 0

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        field.setAccessibilityLabel(accessibilityLabel ?? prompt)
        field.target = context.coordinator
        field.action = #selector(Coordinator.changed(_:))
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        if focusRequest != context.coordinator.focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, focusRequest: focusRequest) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var focusRequest: Int
        init(text: Binding<String>, focusRequest: Int) {
            self.text = text
            self.focusRequest = focusRequest
        }

        @objc func changed(_ sender: NSSearchField) { text.wrappedValue = sender.stringValue }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { text.wrappedValue = field.stringValue }
        }
    }
}

/// Monospaced, selectable value text used for IDs, paths and commands.
struct MonoText: View {
    let text: String
    var truncation: Text.TruncationMode = .middle
    var lines = 1

    var body: some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .lineLimit(lines)
            .truncationMode(truncation)
            .textSelection(.enabled)
            .help(text)
    }
}

/// A bordered "⋯" button that pops up a native menu. Destructive items are
/// red, which SwiftUI menus can't guarantee on every macOS version.
struct ActionMenuButton: NSViewRepresentable {
    struct Item {
        var title = ""
        var systemImage: String? = nil
        var destructive = false
        var isSeparator = false
        var isHeader = false
        var action: () -> Void = {}

        static let separator = Item(isSeparator: true)
        static func header(_ title: String) -> Item { Item(title: title, isHeader: true) }
    }

    let accessibilityLabel: String
    let help: String
    let items: () -> [Item]

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "ellipsis",
                                             accessibilityDescription: accessibilityLabel)!,
                              target: context.coordinator, action: #selector(Coordinator.show(_:)))
        button.bezelStyle = .push
        button.setAccessibilityLabel(accessibilityLabel)
        button.toolTip = help
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.items = items
        button.setAccessibilityLabel(accessibilityLabel)
        button.toolTip = help
    }

    func makeCoordinator() -> Coordinator { Coordinator(items: items) }

    @MainActor
    final class Coordinator: NSObject {
        var items: () -> [Item]
        init(items: @escaping () -> [Item]) { self.items = items }

        @objc func show(_ sender: NSButton) {
            let menu = NSMenu()
            for item in items() {
                if item.isSeparator { menu.addItem(.separator()); continue }
                if item.isHeader { menu.addItem(.sectionHeader(title: item.title)); continue }
                let entry = ClosureMenuItem(title: item.title, keyEquivalent: "", handler: item.action)
                if let symbol = item.systemImage {
                    entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                }
                if item.destructive {
                    entry.attributedTitle = NSAttributedString(string: item.title, attributes: [
                        .foregroundColor: NSColor.systemRed, .font: NSFont.menuFont(ofSize: 0)])
                }
                menu.addItem(entry)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        }
    }
}
