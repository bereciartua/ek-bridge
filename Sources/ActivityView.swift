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
        ActivityKindPicker(model: model, scope: .all)
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

/// All · Changes · Problems N.
struct ActivityKindPicker: View {
    @Bindable var model: BridgeAppModel
    let scope: ActivityScope

    var body: some View {
        Picker(String(localized: "Show"), selection: $model.activityKind) {
            Text(String(localized: "All")).tag(ActivityKind.all)
            Text(String(localized: "Changes")).tag(ActivityKind.changes)
            Text(String(localized: "Problems \(scope.entries(model).filter(\.isProblem).count)"))
                .tag(ActivityKind.problems)
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
        if scope == .all ? model.activity.isEmpty : rows.isEmpty && model.activitySearch.isEmpty && model.activityKind == .all {
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
                // Below the table (P6), with its two halves side by side when
                // there's room.
                let wide = proxy.size.width >= 620
                VStack(spacing: 0) {
                    ActivityTable(model: model, rows: rows, width: proxy.size.width,
                                  showsClient: scope == .all)
                        .overlay {
                            if rows.isEmpty {
                                if model.activitySearch.isEmpty {
                                    ContentUnavailableView(
                                        model.activityKind == .problems ? String(localized: "No problems")
                                            : model.activityKind == .changes ? String(localized: "No changes")
                                            : String(localized: "No requests"),
                                        systemImage: model.activityKind == .problems ? "checkmark.circle" : "list.bullet",
                                        description: Text(String(localized: "Nothing matches this filter.")))
                                } else {
                                    ContentUnavailableView.search(text: model.activitySearch)
                                }
                            }
                        }
                    if let selected {
                        Divider()
                        ActivityInspector(model: model, entry: selected, compact: wide)
                            .frame(height: min(wide ? 270 : 320, proxy.size.height * 0.55))
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
            guard entry.matches(model.activityKind) else { return false }
            guard !query.isEmpty else { return true }
            let target = entry.targetID.flatMap { id in
                model.collection(GrantKey(resource: CommandPresentation.targetsList(entry.command)
                                            ? .reminderList : .calendar, targetID: id))?.name
            }
            // Item titles only as far as they've been looked up (shown) already.
            return [model.clientName(entry.clientID), CommandPresentation.label(entry.command), entry.changeLabel,
                    entry.resultLabel, entry.outcome.label, entry.code, target ?? "", entry.agent ?? "",
                    model.cachedItemTitle(entry) ?? ""]
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

/// Activity's column widths (P6): Time, Connection, Change, Item, Result.
/// Result always fits the widest pill and Change keeps its labels whole
/// while Connection and Item still get room; those two share the rest and
/// truncate at the tail.
enum ActivityColumns {
    struct Widths: Equatable {
        var time, client, change, item, result: CGFloat
    }

    /// Space between columns, and a row's inset from the list's edges.
    static let spacing: CGFloat = 12
    static let rowInset: CGFloat = 17
    /// Row insets, column spacing and room for the scroller.
    static let overhead: CGFloat = 2 * rowInset + 4 * spacing + 6
    /// What Connection and Item keep before Change gives way.
    static let namesMinimum: CGFloat = 140

    /// `clientNames`: the connection names shown, so the column is no wider
    /// than they need (at most half of what Connection and Item share).
    static func widths(for tableWidth: CGFloat, showsClient: Bool = true, clientNames: [String]? = nil) -> Widths {
        let usable = max(tableWidth - overhead, 320)
        let time = max(widestTime, usable * 0.11)
        let result = max(widestResultLabel, usable * 0.18)
        let rest = max(usable - time - result, 0)
        let change = max(rest * 0.3, min(widestChangeLabel, rest - namesMinimum))
        let names = rest - change
        // Without the Connection column (a connection's Activity tab), Item takes it all.
        let needed = clientNames.map { width($0, NSFont.systemFont(ofSize: NSFont.systemFontSize)) + 8 } ?? names
        let client = showsClient ? min(names * 0.5, max(needed, 90)) : 0
        return Widths(time: time, client: client, change: change, item: names - client, result: result)
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
        return width(OutcomePresentation.allLabels + [String(localized: "Approved")], font) + 16 + 4
    }()

    /// The widest Time cell ("10:58 PM") in monospaced digits, with room for
    /// the cell; the full date is in the tooltip.
    static let widestTime: CGFloat = {
        let calendar = Calendar.current
        let samples = [10, 22].compactMap {
            calendar.date(bySettingHour: $0, minute: 58, second: 0, of: Date()).map(time)
        }
        return width(samples, NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)) + 4
    }()

    /// The widest Change label in the body font, with room for the cell.
    static let widestChangeLabel: CGFloat = {
        width(CommandPresentation.allChangeLabels, NSFont.systemFont(ofSize: NSFont.systemFontSize)) + 4
    }()

    /// A row's time of day; the day is in its section header.
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private static func width(_ labels: [String], _ font: NSFont) -> CGFloat {
        labels.map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 0
    }
}

/// Activity's rows under day headers (P6). A `List` with sections rather than
/// a `Table`: SwiftUI's sectioned `Table` performs reentrant NSTableView
/// delegate calls when it first loads (an AppKit warning that's due to become
/// an assert). Columns are fixed widths from `ActivityColumns`, with a header
/// row above the list; arrow keys move the selection as in a table.
struct ActivityTable: View {
    @Bindable var model: BridgeAppModel
    let rows: [ActivityEntry]
    /// The list's width. Columns are sized from it so nothing scrolls sideways.
    let width: CGFloat
    /// False on a connection's Activity tab: every row is that connection's.
    var showsClient = true

    var body: some View {
        let columns = ActivityColumns.widths(for: width, showsClient: showsClient,
                                             clientNames: Array(Set(rows.map { model.clientName($0.clientID) })))
        let days = ActivityDays.group(rows, now: model.now)
        VStack(spacing: 0) {
            header(columns)
            Divider()
            ScrollViewReader { proxy in
                List(selection: $model.activitySelection) {
                    ForEach(days) { day in
                        Section {
                            ForEach(day.entries) { entry in
                                ActivityRow(model: model, entry: entry, columns: columns, showsClient: showsClient)
                                    .tag(entry.id)
                                    .id(entry.id)
                            }
                        } header: {
                            Text(day.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                // A new filter is a new list: diffing whole day sections in
                // place makes AppKit's table reenter its delegate.
                .id(model.activityKind)
                .accessibilityLabel(String(localized: "Requests"))
                .onAppear { reveal(proxy) }
                .onChange(of: model.activitySelection) { _, _ in reveal(proxy) }
            }
        }
    }

    private func header(_ columns: ActivityColumns.Widths) -> some View {
        HStack(spacing: ActivityColumns.spacing) {
            title(String(localized: "Time"), columns.time)
            if showsClient { title(String(localized: "Connection"), columns.client) }
            title(String(localized: "Change"), columns.change)
            title(String(localized: "Item"), columns.item)
            title(String(localized: "Result"), columns.result)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ActivityColumns.rowInset)
        .padding(.vertical, 7)
        .accessibilityHidden(true)
    }

    private func title(_ text: String, _ width: CGFloat) -> some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: width, alignment: .leading)
    }

    /// Keeps a row selected from the menu bar or a deep link in view.
    private func reveal(_ proxy: ScrollViewProxy) {
        guard let id = model.activitySelection, rows.contains(where: { $0.id == id }) else { return }
        DispatchQueue.main.async { proxy.scrollTo(id) }
    }
}

/// One Activity row: time, connection, change, item and result.
struct ActivityRow: View {
    let model: BridgeAppModel
    let entry: ActivityEntry
    let columns: ActivityColumns.Widths
    let showsClient: Bool

    var body: some View {
        HStack(spacing: ActivityColumns.spacing) {
            Text(ActivityColumns.time(entry.at))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: columns.time, alignment: .leading)
                .help(RelativeTime.full(entry.at))
            if showsClient {
                Text(model.clientName(entry.clientID))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(entry.clientID == nil ? .secondary : .primary)
                    .frame(width: columns.client, alignment: .leading)
                    .help(model.clientName(entry.clientID))
            }
            Text(entry.changeLabel)
                .lineLimit(1)
                .frame(width: columns.change, alignment: .leading)
                .help(CommandPresentation.label(entry.command))
            ActivityItemCell(model: model, entry: entry)
                .frame(width: columns.item, alignment: .leading)
            Pill(label: entry.resultLabel, tone: entry.outcome.tone)
                .frame(width: columns.result, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// The calendar or list a row names, for the details pane and tooltips.
struct ActivityTargetLabel: View {
    let model: BridgeAppModel
    let key: GrantKey

    var body: some View {
        if let collection = model.collection(key) {
            HStack(spacing: 6) {
                ColorDot(color: collection.color, size: 8)
                Text("\(collection.name) · \(collection.account)").lineLimit(1).truncationMode(.tail)
            }
        } else {
            Text(model.unavailableName(key) ?? String(localized: "Unavailable")).foregroundStyle(.secondary)
        }
    }
}

/// The Item column: the item's colour dot and title, looked up now; "Deleted
/// item" when it's gone; a dash for reads.
struct ActivityItemCell: View {
    let model: BridgeAppModel
    let entry: ActivityEntry

    var body: some View {
        let collection = entry.targetKey.flatMap { model.collection($0) }
        switch model.itemDisplay(entry) {
        case .found(let item) where item.exists:
            let current = item.collectionID.flatMap { id in
                model.collections.first { $0.id == id && $0.resource == entry.targetKey?.resource }
            } ?? collection
            HStack(spacing: 6) {
                if let current { ColorDot(color: current.color, size: 8) }
                Text(item.title).lineLimit(1).truncationMode(.tail)
            }
            .help([item.title, current.map { "\($0.name) · \($0.account)" }, item.when]
                .compactMap { $0 }.joined(separator: "\n"))
        case .found:
            HStack(spacing: 6) {
                if let collection { ColorDot(color: collection.color, size: 8) }
                Text(String(localized: "Deleted item")).foregroundStyle(.secondary).lineLimit(1)
            }
            .help(collection.map { "\($0.name) · \($0.account)" } ?? "")
        case .noAccess(let resource):
            Text("—").foregroundStyle(.tertiary)
                .help(ActivityItemCard.noAccessText(resource))
                .accessibilityLabel(ActivityItemCard.noAccessText(resource))
        case .none:
            Group {
                if let collection {
                    Text(collection.name).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .help(collection.map { "\($0.name) · \($0.account)" } ?? "")
            .accessibilityLabel(collection?.name ?? String(localized: "None"))
        }
    }
}

/// The details pane's item card: title, where it is, when, Show in Calendar.
struct ActivityItemCard: View {
    let model: BridgeAppModel
    let entry: ActivityEntry

    static func noAccessText(_ resource: ClientResource) -> String {
        resource == .calendar ? String(localized: "Allow Calendar access to see item names.")
                              : String(localized: "Allow Reminders access to see item names.")
    }

    var body: some View {
        let display = model.itemDisplay(entry)
        if display != .none {
            VStack(alignment: .leading, spacing: 4) {
                switch display {
                case .found(let item) where item.exists:
                    Text(item.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                    location(item.collectionID)
                    changes(item)
                case .found:
                    Text(String(localized: "Deleted item")).font(.headline).foregroundStyle(.secondary)
                    location(nil)
                    // What the panel showed when it was answered this session.
                    if let summary = model.recentSummary(entry) { rows(summary, changedOnly: false) }
                case .noAccess(let resource):
                    Text(Self.noAccessText(resource)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .none:
                    EmptyView()
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.separator.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private func location(_ current: String?) -> some View {
        let key = current.flatMap { id in entry.targetKey.map { GrantKey(resource: $0.resource, targetID: id) } }
            ?? entry.targetKey
        if let key, let collection = model.collection(key) {
            Text("\(collection.name) · \(collection.account)").foregroundStyle(.secondary)
        }
    }

    /// Before → after from the approval panel when the change was answered
    /// this session (C03), otherwise the item's time now.
    @ViewBuilder
    private func changes(_ item: ItemSnapshot) -> some View {
        if let summary = model.recentSummary(entry), summary.rows.contains(where: { $0.before != nil }) {
            rows(summary, changedOnly: true)
        } else if let when = item.when {
            Text(when).foregroundStyle(.secondary)
        }
    }

    private func rows(_ summary: ApprovalSummary, changedOnly: Bool) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 2) {
            ForEach(Array(summary.rows.filter { !changedOnly || $0.before != nil }.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.label).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if let before = row.before {
                            Text(before).strikethrough().foregroundStyle(.secondary)
                                .accessibilityLabel(String(localized: "Before: \(before)"))
                            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        Text(row.value).lineLimit(2)
                            .accessibilityLabel(row.before == nil ? row.value : String(localized: "After: \(row.value)"))
                    }
                }
            }
        }
        .font(.callout)
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
        VStack(alignment: .leading, spacing: 14) {
            layout {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.changeLabel).font(.title3.weight(.semibold))
                        Pill(label: entry.resultLabel, tone: outcome.tone, icon: true)
                    }
                    .padding(.trailing, compact ? 0 : 24)
                    ActivityItemCard(model: model, entry: entry)
                    showItem(entry)
                }
                .frame(maxWidth: compact ? 380 : .infinity, alignment: .leading)
                facts(entry)
                    .padding(.trailing, compact ? 28 : 0)
            }
            explanation(entry, outcome: outcome, collection: collection)
        }
    }

    /// Show in Calendar / Reminders, for an item that's still there.
    @ViewBuilder
    private func showItem(_ entry: ActivityEntry) -> some View {
        if case .found(let item) = model.itemDisplay(entry), item.exists, let ref = entry.item {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button(ref.kind == "event" ? String(localized: "Show in Calendar")
                                           : String(localized: "Show in Reminders")) {
                    model.showItem(entry)
                }
                Text(String(localized: "Looked up now; only the item's ID is stored."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func facts(_ entry: ActivityEntry) -> some View {
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
                        ActivityTargetLabel(model: model, key: key)
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
            if let destination = entry.destinationID, let key = entry.targetKey {
                GridRow {
                    Text(entry.code == "success" ? String(localized: "Moved to") : String(localized: "Move to"))
                        .foregroundStyle(.secondary)
                    ActivityTargetLabel(model: model, key: GrantKey(resource: key.resource, targetID: destination))
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
        if entry.code == "forbidden", entry.clientID != nil, let action = Self.missingAction(entry) {
            let refused = refusedCollection(entry) ?? collection
            let list = entry.targetKey?.resource == .reminderList
            let name = model.clientName(entry.clientID)
            if Self.refusedOnDestination(entry) {
                let target = refused?.name ?? (list ? String(localized: "the list") : String(localized: "the calendar"))
                return String(localized: "\(name) doesn't have \(action) access to \(target), where it tried to move the item.")
            }
            let target = refused?.name ?? (list ? String(localized: "that list") : String(localized: "that calendar"))
            return String(localized: "\(name) doesn't have \(action) access to \(target).")
        }
        return outcome.why
    }

    /// The access a refused request lacked: the recorded bit (since 0.10),
    /// otherwise what the command needs.
    static func missingAction(_ entry: ActivityEntry) -> String? {
        switch entry.missing {
        case ClientGrant.read?: String(localized: "Read")
        case ClientGrant.create?: String(localized: "Create")
        case ClientGrant.edit?: String(localized: "Edit")
        case ClientGrant.delete?: String(localized: "Delete")
        case ClientGrant.complete?: String(localized: "Complete")
        default: CommandPresentation.requiredAction(entry.command)
        }
    }

    /// A move refused because the destination lacks Create.
    static func refusedOnDestination(_ entry: ActivityEntry) -> Bool {
        entry.isMove && entry.missing == ClientGrant.create
    }

    /// The calendar or list the refusal was about.
    private func refusedCollection(_ entry: ActivityEntry) -> CollectionInfo? {
        guard let key = entry.targetKey else { return nil }
        if Self.refusedOnDestination(entry), let destination = entry.destinationID {
            return model.collection(GrantKey(resource: key.resource, targetID: destination))
        }
        return model.collection(key)
    }

    private func fix(_ entry: ActivityEntry, outcome: OutcomePresentation,
                     collection: CollectionInfo?) -> String? {
        if entry.code == "forbidden", entry.clientID != nil, let action = Self.missingAction(entry) {
            let noun = entry.targetKey?.resource == .reminderList
                ? String(localized: "the list") : String(localized: "the calendar")
            if Self.refusedOnDestination(entry) {
                return String(localized: "Turn on \(action) for \(noun) it moves to, only if this tool should move items there.")
            }
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
            if entry.code == "forbidden", let refused = refusedCollection(entry) ?? collection {
                Button(String(localized: "Open \(client.name) ▸ \(refused.name)")) {
                    model.openClientAccess(client.id, focus: refused.key)
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
        // Ask for access (C04).
        case "access_once": String(localized: "You allowed it once")
        case "access_always": String(localized: "You allowed it from now on")
        case "access_denied": String(localized: "You didn't allow it")
        case "access_timeout": String(localized: "No answer in 45 s")
        default: nil
        }
    }
}

