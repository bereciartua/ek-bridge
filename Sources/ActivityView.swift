import AppKit
import SwiftUI

/// Activity (§10): a filterable table with an inspector that explains each
/// outcome and how to fix it.
struct ActivityView: View {
    @Bindable var model: BridgeAppModel

    var body: some View {
        VStack(spacing: 0) {
            // The filters move under the title when the pane is too narrow
            // for one row (the minimum window size).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    title
                    Spacer(minLength: 12)
                    filters
                }
                VStack(alignment: .leading, spacing: 10) {
                    title
                    HStack(spacing: 12) { filters }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 14)
            ActivityList(model: model, scope: .all)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
        .onAppear { model.markActivityViewed() }
    }

    private var title: some View {
        PaneTitle(title: String(localized: "Activity"))
            .fixedSize()
            .layoutPriority(1)
    }

    @ViewBuilder private var filters: some View {
        ActivityFilterMenu(model: model)
        ActivityProblemsPicker(model: model, scope: .all)
        SearchField(text: $model.activitySearch, prompt: String(localized: "Search"),
                    accessibilityLabel: String(localized: "Search activity"),
                    focusRequest: model.activitySearchFocusRequest)
            .frame(minWidth: 110, idealWidth: 180, maxWidth: 180)
    }
}

/// Which rows an `ActivityList` shows: everything (the Activity page, with
/// its connection and Via filters) or one connection's (its Activity tab).
enum ActivityScope: Equatable {
    case all
    case client(String)

    @MainActor
    func entries(_ model: BridgeAppModel) -> [ActivityEntry] {
        switch self {
        case .client(let id): return model.activity.filter { $0.clientID == id }
        case .all:
            return model.activity.filter { entry in
                let client = switch model.activityClientFilter {
                case .all: true
                case .client(let id): entry.clientID == id
                case .unknown: entry.clientID == nil
                }
                let via = switch model.activityVia {
                case .all: true
                case .mcp: entry.via == "mcp"
                case .remote: entry.via == "remote"
                // Rows from before 0.4.0 have no via, and all came from the command line.
                case .cli: entry.via == nil || entry.via == "cli"
                }
                return client && via
            }
        }
    }
}

/// All / Problems N.
struct ActivityProblemsPicker: View {
    @Bindable var model: BridgeAppModel
    let scope: ActivityScope

    var body: some View {
        Picker(String(localized: "Show"), selection: $model.activityProblemsOnly) {
            Text(String(localized: "All")).tag(false)
            Text(String(localized: "Problems \(scope.entries(model).filter(\.isProblem).count)")).tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel(String(localized: "Show"))
    }
}

/// The Activity table and its details, for the Activity page and for a
/// connection's Activity tab (without the Connection column).
struct ActivityList: View {
    @Bindable var model: BridgeAppModel
    let scope: ActivityScope

    var body: some View {
        let rows = filtered(scope.entries(model))
        if scope == .all ? model.activity.isEmpty : rows.isEmpty && model.activitySearch.isEmpty && !model.activityProblemsOnly {
            ContentUnavailableView {
                Label(String(localized: "No requests yet"), systemImage: "list.bullet")
            } description: {
                Text(scope == .all ? String(localized: "Requests from your connections appear here, with what happened and why.")
                                   : String(localized: "This connection's requests appear here, with what happened and why."))
            }
        } else {
            GeometryReader { proxy in
                // Only rows the filters show; a hidden selection closes the details.
                let selected = rows.first { $0.id == model.activitySelection }
                // Beside the table when there's room for both, below it otherwise.
                let wide = proxy.size.width >= 780
                let layout = wide
                    ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                layout {
                    ActivityTable(model: model, rows: rows,
                                  width: wide && selected != nil ? proxy.size.width - 251 : proxy.size.width,
                                  showsClient: scope == .all)
                        .overlay {
                            if rows.isEmpty {
                                if model.activitySearch.isEmpty {
                                    ContentUnavailableView(
                                        model.activityProblemsOnly ? String(localized: "No problems")
                                                                   : String(localized: "No requests"),
                                        systemImage: model.activityProblemsOnly ? "checkmark.circle" : "list.bullet",
                                        description: Text(String(localized: "Nothing matches this filter.")))
                                } else {
                                    ContentUnavailableView.search(text: model.activitySearch)
                                }
                            }
                        }
                    if let selected {
                        Divider()
                        ActivityInspector(model: model, entry: selected, compact: !wide)
                            .frame(width: wide ? 250 : nil,
                                   height: wide ? nil : min(250, proxy.size.height * 0.55))
                            .transition(.opacity)
                    }
                }
            }
            .animation(.easeOut(duration: 0.18), value: model.activitySelection == nil)
            .background(Palette.card)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Palette.separator.opacity(0.6), lineWidth: 0.5))
        }
    }

    private func filtered(_ entries: [ActivityEntry]) -> [ActivityEntry] {
        let query = model.activitySearch.trimmingCharacters(in: .whitespaces)
        return entries.filter { entry in
            if model.activityProblemsOnly && !entry.isProblem { return false }
            guard !query.isEmpty else { return true }
            let target = entry.targetID.flatMap { id in
                model.collection(GrantKey(resource: CommandPresentation.targetsList(entry.command)
                                            ? .reminderList : .calendar, targetID: id))?.name
            }
            return [model.clientName(entry.clientID), CommandPresentation.label(entry.command),
                    entry.outcome.label, entry.code, target ?? "", entry.agent ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
}

extension ActivityEntry {
    var targetKey: GrantKey? {
        targetID.map {
            GrantKey(resource: CommandPresentation.targetsList(command) ? .reminderList : .calendar,
                     targetID: $0)
        }
    }
}

/// Activity's column widths. The Result column always fits the widest
/// outcome label, and Request keeps its labels whole while Client and
/// Calendar or list still get room; those two share the rest and truncate
/// at the tail.
enum ActivityColumns {
    struct Widths: Equatable {
        var time, via, client, request, target, result: CGFloat
    }

    /// Inset style margins, column spacing and the scroller.
    static let overhead: CGFloat = 104
    /// What Client and Calendar or list keep before Request gives way.
    static let namesMinimum: CGFloat = 120

    static func widths(for tableWidth: CGFloat, showsClient: Bool = true) -> Widths {
        let usable = max(tableWidth - overhead, 320)
        let time = max(widestTime, usable * 0.12)
        let result = max(widestResultLabel, usable * 0.2)
        let via: CGFloat = 22
        let rest = max(usable - time - result - via, 0)
        let request = max(rest * 0.34, min(widestRequestLabel, rest - namesMinimum))
        let names = rest - request
        // Without the Connection column (a connection's Activity tab), Calendar or list takes it all.
        let client = showsClient ? names / 2 : 0
        return Widths(time: time, via: via, client: client, request: request, target: names - client,
                      result: result)
    }

    /// The table's width in a main window this wide, with the sidebar at its
    /// ideal width and no inspector beside the table (for tests).
    static func tableWidth(windowWidth: CGFloat) -> CGFloat {
        windowWidth - 230 - 2 * 24
    }

    /// The widest Result pill: `Pill`'s callout medium font, its 8 pt
    /// padding on each side, and a little room for the cell.
    static let widestResultLabel: CGFloat = {
        let font = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize,
                                     weight: .medium)
        return width(OutcomePresentation.allLabels, font) + 16 + 4
    }()

    /// The widest Time cell this year (`RelativeTime.clock`: "10:58 PM"
    /// today, "Yesterday", "Dec 28" before) in monospaced digits, with room
    /// for the cell. Earlier years truncate, with the full date in the tooltip.
    static let widestTime: CGFloat = {
        let calendar = Calendar.current
        let now = Date()
        let year = calendar.component(.year, from: now)
        var samples = [10, 22].compactMap {
            calendar.date(bySettingHour: $0, minute: 58, second: 0, of: now)
                .map { RelativeTime.clock($0, now: $0, calendar: calendar) }
        }
        samples.append(String(localized: "Yesterday"))
        for month in [5, 9, 12] {
            if let day = calendar.date(from: DateComponents(year: year, month: month, day: 28)) {
                samples.append(RelativeTime.clock(day, now: day.addingTimeInterval(2 * 86_400), calendar: calendar))
            }
        }
        return width(samples, NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)) + 4
    }()

    /// The widest Request label in the body font, with room for the cell.
    static let widestRequestLabel: CGFloat = {
        width(CommandPresentation.allShortLabels, NSFont.systemFont(ofSize: NSFont.systemFontSize)) + 4
    }()

    private static func width(_ labels: [String], _ font: NSFont) -> CGFloat {
        labels.map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 0
    }
}

struct ActivityTable: View {
    @Bindable var model: BridgeAppModel
    let rows: [ActivityEntry]
    /// The table's width. Columns are sized from it so nothing scrolls sideways.
    let width: CGFloat
    /// False on a connection's Activity tab: every row is that connection's.
    var showsClient = true
    /// Only hides the Connection column on a connection's tab.
    @State private var customization = TableColumnCustomization<ActivityEntry>()

    var body: some View {
        let columns = ActivityColumns.widths(for: width, showsClient: showsClient)
        ScrollViewReader { proxy in
        Table(rows, selection: $model.activitySelection, columnCustomization: $customization) {
            TableColumn(String(localized: "Time")) { entry in
                Text(RelativeTime.clock(entry.at, now: model.now))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help(RelativeTime.full(entry.at))
            }
            .width(min: columns.time, ideal: columns.time, max: columns.time)
            TableColumn(String(localized: "Via")) { entry in
                ViaIcon(via: entry.via)
            }
            .width(min: columns.via, ideal: columns.via, max: columns.via)
            TableColumn(String(localized: "Connection")) { entry in
                Text(model.clientName(entry.clientID))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(entry.clientID == nil ? .secondary : .primary)
                    .help(model.clientName(entry.clientID))
            }
            // The one flexible column: it takes whatever the others leave.
            .width(min: columns.client, ideal: columns.client)
            .customizationID("client")
            .defaultVisibility(showsClient ? .automatic : .hidden)
            TableColumn(String(localized: "Request")) { entry in
                Text(CommandPresentation.shortLabel(entry.command))
                    .lineLimit(1)
                    .help(CommandPresentation.label(entry.command))
            }
            .width(min: columns.request, ideal: columns.request, max: columns.request)
            TableColumn(String(localized: "Calendar or list")) { entry in
                ActivityTargetCell(model: model, entry: entry)
            }
            .width(min: columns.target, ideal: columns.target, max: columns.target)
            TableColumn(String(localized: "Result")) { entry in
                Pill(label: entry.outcome.label, tone: entry.outcome.tone)
            }
            .width(min: columns.result, ideal: columns.result, max: columns.result)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .accessibilityLabel(String(localized: "Requests"))
        .onAppear { reveal(proxy) }
        .onChange(of: model.activitySelection) { _, _ in reveal(proxy) }
        }
    }

    /// Keeps a row selected from the menu bar or a deep link in view.
    private func reveal(_ proxy: ScrollViewProxy) {
        guard let id = model.activitySelection, rows.contains(where: { $0.id == id }) else { return }
        DispatchQueue.main.async { proxy.scrollTo(id) }
    }
}

struct ActivityTargetCell: View {
    let model: BridgeAppModel
    let entry: ActivityEntry

    var body: some View {
        if let key = entry.targetKey {
            if let collection = model.collection(key) {
                HStack(spacing: 6) {
                    ColorDot(color: collection.color, size: 8)
                    Text(collection.name).lineLimit(1).truncationMode(.tail)
                }
                .help("\(collection.name)\n" + String(localized: "ID: \(key.targetID)"))
            } else {
                Text(String(localized: "Unavailable"))
                    .foregroundStyle(.secondary)
                    .help(String(localized: "ID: \(key.targetID)"))
            }
        } else {
            Text("—").foregroundStyle(.tertiary)
                .accessibilityLabel(String(localized: "None"))
        }
    }
}

struct ActivityInspector: View {
    let model: BridgeAppModel
    let entry: ActivityEntry
    /// Below the table: summary and explanation side by side.
    var compact = false

    var body: some View {
        ScrollView {
            details(entry)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .topTrailing) {
            Button { model.activitySelection = nil } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help(String(localized: "Close Details"))
            .accessibilityLabel(String(localized: "Close Details"))
            .padding(8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Request details"))
    }

    @ViewBuilder
    private func details(_ entry: ActivityEntry) -> some View {
        let outcome = entry.outcome
        let collection = entry.targetKey.flatMap { model.collection($0) }
        let layout = compact
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 20))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
        layout {
            summary(entry, outcome: outcome, collection: collection)
                .frame(maxWidth: compact ? 330 : .infinity, alignment: .leading)
            explanation(entry, outcome: outcome, collection: collection)
        }
    }

    @ViewBuilder
    private func summary(_ entry: ActivityEntry, outcome: OutcomePresentation,
                         collection: CollectionInfo?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(CommandPresentation.label(entry.command)).font(.title3.weight(.semibold))
                    .padding(.trailing, compact ? 0 : 24)
                Pill(label: outcome.label, tone: outcome.tone, icon: true)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text(String(localized: "Connection")).foregroundStyle(.secondary)
                    Text(model.clientName(entry.clientID))
                }
                if let via = entry.via {
                    GridRow {
                        Text(String(localized: "Via")).foregroundStyle(.secondary)
                        Text(viaText(entry, via))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let note = model.remoteNote(for: entry) {
                        GridRow {
                            Text(String(localized: "From")).foregroundStyle(.secondary)
                            Text(String(localized: "\(note.address) (as the tunnel reported)"))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if let approval = ApprovalText.detail(entry.approval) {
                    GridRow {
                        Text(String(localized: "Approval")).foregroundStyle(.secondary)
                        Text(approval)
                    }
                }
                if let key = entry.targetKey {
                    GridRow {
                        Text(key.resource == .calendar ? String(localized: "Calendar") : String(localized: "List"))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            if let collection {
                                Text("\(collection.name) · \(collection.account)")
                            } else {
                                Text(String(localized: "Unavailable")).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 4) {
                                MonoText(text: key.targetID)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                CopyButton(text: key.targetID, help: key.resource == .calendar
                                           ? String(localized: "Copy Calendar ID")
                                           : String(localized: "Copy List ID"))
                                    .buttonStyle(.borderless)
                                    .controlSize(.small)
                            }
                        }
                    }
                }
                GridRow {
                    Text(String(localized: "When")).foregroundStyle(.secondary)
                    Text(RelativeTime.full(entry.at))
                }
                GridRow {
                    Text(String(localized: "Code")).foregroundStyle(.secondary)
                    Text(entry.code).font(.body.monospaced()).textSelection(.enabled)
                }
            }
            .font(.callout)
        }
    }

    @ViewBuilder
    private func explanation(_ entry: ActivityEntry, outcome: OutcomePresentation,
                             collection: CollectionInfo?) -> some View {
        if let why = why(entry, outcome: outcome, collection: collection) {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "Why")).font(.headline)
                Text(why).fixedSize(horizontal: false, vertical: true)
                if let fix = fix(entry, outcome: outcome, collection: collection) {
                    Text(String(localized: "What to do")).font(.headline).padding(.top, 4)
                    Text(fix).fixedSize(horizontal: false, vertical: true)
                }
                contextButton(entry, collection: collection)
                    .padding(.top, 4)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.trailing, compact ? 28 : 0)
        }
    }

    private func viaText(_ entry: ActivityEntry, _ via: String) -> String {
        let agent = entry.agent.map { String(localized: "\($0), as reported") }
        switch via {
        case "mcp": return agent.map { String(localized: "MCP (\($0))") } ?? String(localized: "MCP")
        case "remote":
            let tunnel = model.remoteNote(for: entry)?.tunnel.map { String(localized: "tunnel: \($0)") }
            let detail = [agent, tunnel].compactMap { $0 }.joined(separator: "; ")
            return detail.isEmpty ? String(localized: "MCP · remote")
                                  : String(localized: "MCP · remote (\(detail))")
        default: return String(localized: "Command line")
        }
    }

    private func why(_ entry: ActivityEntry, outcome: OutcomePresentation,
                     collection: CollectionInfo?) -> String? {
        if entry.code == "approval_denied" && entry.isMCP {
            return String(localized: "You declined this change. The agent was told not to retry unless you ask it to.")
        }
        if entry.code == "forbidden", entry.clientID != nil,
           let action = CommandPresentation.requiredAction(entry.command) {
            let target = collection?.name ?? (entry.targetKey?.resource == .reminderList
                ? String(localized: "that list") : String(localized: "that calendar"))
            return String(localized: "\(model.clientName(entry.clientID)) doesn't have \(action) access to \(target).")
        }
        return outcome.why
    }

    private func fix(_ entry: ActivityEntry, outcome: OutcomePresentation,
                     collection: CollectionInfo?) -> String? {
        if entry.code == "forbidden", entry.clientID != nil,
           let action = CommandPresentation.requiredAction(entry.command) {
            let noun = entry.targetKey?.resource == .reminderList
                ? String(localized: "the list") : String(localized: "the calendar")
            return String(localized: "Turn on \(action) for \(noun) only if this tool should \(Self.purpose(entry.command)).")
        }
        return outcome.fix
    }

    static func purpose(_ command: String) -> String {
        switch BridgeCommand(rawValue: command) {
        case .readEvents, .getEvent: String(localized: "read its events")
        case .readReminders, .getReminder: String(localized: "read its reminders")
        case .createEvent: String(localized: "add events")
        case .createReminder: String(localized: "add reminders")
        case .updateEvent: String(localized: "change events")
        case .updateReminder: String(localized: "change reminders")
        case .deleteEvent: String(localized: "delete events")
        case .deleteReminder: String(localized: "delete reminders")
        case .completeReminder: String(localized: "complete reminders")
        default: String(localized: "do this")
        }
    }

    @ViewBuilder
    private func contextButton(_ entry: ActivityEntry, collection: CollectionInfo?) -> some View {
        let client = model.client(entry.clientID)
        if entry.code == "full_access_required" {
            Button(String(localized: "Open Privacy Settings")) {
                model.openPrivacySettings(CommandPresentation.targetsList(entry.command) ? .reminderList : .calendar)
            }
        } else if let client, !client.revoked {
            if entry.code == "forbidden", let collection {
                Button(String(localized: "Open \(client.name) ▸ \(collection.name)")) {
                    model.openClientAccess(client.id, focus: collection.key)
                }
            } else {
                Button(String(localized: "Open \(client.name)")) {
                    model.navigate(to: .client(client.id))
                }
            }
        } else if outcome(entry).tone == .bad && entry.code != "unauthorized" {
            Button(String(localized: "Open Overview")) { model.navigate(to: .overview) }
        }
    }

    private func outcome(_ entry: ActivityEntry) -> OutcomePresentation { entry.outcome }
}

/// The narrow Via column: sparkles for MCP, a terminal for the command line.
struct ViaIcon: View {
    let via: String?

    var body: some View {
        switch via {
        case "mcp":
            Image(systemName: "sparkles").foregroundStyle(.purple)
                .help(String(localized: "via MCP"))
                .accessibilityLabel(String(localized: "via MCP"))
        case "remote":
            Image(systemName: "cloud").foregroundStyle(.blue)
                .help(String(localized: "via Remote Access"))
                .accessibilityLabel(String(localized: "via Remote Access"))
        case "cli":
            Image(systemName: "terminal").foregroundStyle(.secondary)
                .help(String(localized: "via command line"))
                .accessibilityLabel(String(localized: "via command line"))
        default:
            Text("").accessibilityHidden(true)
        }
    }
}

/// "All Clients · MCP": one menu for the client and transport filters.
struct ActivityFilterMenu: View {
    @Bindable var model: BridgeAppModel

    var body: some View {
        Menu {
            Section(String(localized: "Connection")) {
                choice(String(localized: "All Connections"), model.activityClientFilter == .all) {
                    model.activityClientFilter = .all
                }
                ForEach(model.activeClients) { client in
                    choice(client.name, model.activityClientFilter == .client(client.id)) {
                        model.activityClientFilter = .client(client.id)
                    }
                }
                ForEach(model.revokedClients.filter { client in
                    model.activityClientFilter == .client(client.id) ||
                        model.activity.contains { $0.clientID == client.id }
                }) { client in
                    choice(model.clientName(client.id), model.activityClientFilter == .client(client.id)) {
                        model.activityClientFilter = .client(client.id)
                    }
                }
                choice(String(localized: "Unknown connection"), model.activityClientFilter == .unknown) {
                    model.activityClientFilter = .unknown
                }
            }
            Section(String(localized: "Via")) {
                ForEach(ActivityViaFilter.allCases, id: \.self) { via in
                    choice(title(via), model.activityVia == via) { model.activityVia = via }
                }
            }
        } label: {
            Text(label)
        }
        .fixedSize()
        .frame(maxWidth: 220)
        .accessibilityLabel(String(localized: "Filter by connection and transport"))
    }

    private var label: String {
        let client = switch model.activityClientFilter {
        case .all: String(localized: "All Connections")
        case .client(let id): model.clientName(id)
        case .unknown: String(localized: "Unknown connection")
        }
        return model.activityVia == .all ? client : "\(client) · \(title(model.activityVia))"
    }

    private func title(_ via: ActivityViaFilter) -> String {
        switch via {
        case .all: String(localized: "All")
        case .mcp: String(localized: "MCP")
        case .remote: String(localized: "Remote Access")
        case .cli: String(localized: "Command line")
        }
    }

    private func choice(_ title: String, _ selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}

enum ApprovalText {
    static func detail(_ approval: String?) -> String? {
        switch approval {
        case "user": String(localized: "You approved")
        case "window": String(localized: "Allowed by a 15-minute allowance")
        case "denied": String(localized: "You declined")
        case "timeout": String(localized: "No answer in 45 s")
        default: nil
        }
    }
}

