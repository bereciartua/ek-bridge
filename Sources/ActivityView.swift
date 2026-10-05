import SwiftUI

/// Activity (§10): a filterable table with an inspector that explains each
/// outcome and how to fix it.
struct ActivityView: View {
    @Bindable var model: BridgeAppModel

    var body: some View {
        let scoped = clientScoped
        let rows = filtered(scoped)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                PaneTitle(title: String(localized: "Activity"))
                    .fixedSize()
                    .layoutPriority(1)
                Spacer(minLength: 12)
                Picker(String(localized: "Client"), selection: $model.activityClientFilter) {
                    Text(String(localized: "All Clients")).tag(ActivityClientFilter.all)
                    Divider()
                    ForEach(model.activeClients) { client in
                        Text(client.name).tag(ActivityClientFilter.client(client.id))
                    }
                    ForEach(model.revokedClients.filter { client in
                        model.activityClientFilter == .client(client.id) ||
                            model.activity.contains { $0.clientID == client.id }
                    }) { client in
                        Text(model.clientName(client.id)).tag(ActivityClientFilter.client(client.id))
                    }
                    Divider()
                    Text(String(localized: "Unknown client")).tag(ActivityClientFilter.unknown)
                }
                .labelsHidden()
                .frame(maxWidth: 170)
                .accessibilityLabel(String(localized: "Client"))
                Picker(String(localized: "Show"), selection: $model.activityProblemsOnly) {
                    Text(String(localized: "All")).tag(false)
                    Text(String(localized: "Problems \(scoped.filter(\.isProblem).count)")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(String(localized: "Show"))
                SearchField(text: $model.activitySearch, prompt: String(localized: "Search"),
                            accessibilityLabel: String(localized: "Search activity"))
                    .frame(minWidth: 110, maxWidth: 180)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 14)
            if model.activity.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "No requests yet"), systemImage: "list.bullet")
                } description: {
                    Text(String(localized: "Requests from your clients appear here, with what happened and why."))
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
                                      width: wide && selected != nil ? proxy.size.width - 251 : proxy.size.width)
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
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .onAppear { model.markActivityViewed() }
    }

    private var clientScoped: [ActivityEntry] {
        model.activity.filter { entry in
            switch model.activityClientFilter {
            case .all: true
            case .client(let id): entry.clientID == id
            case .unknown: entry.clientID == nil
            }
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
                    entry.outcome.label, entry.code, target ?? ""]
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

struct ActivityTable: View {
    @Bindable var model: BridgeAppModel
    let rows: [ActivityEntry]
    /// The table's width. Columns are sized from it so nothing scrolls sideways.
    let width: CGFloat

    var body: some View {
        // Inset style margins, column spacing and the scroller take about 84 pt.
        let usable = max(width - 84, 320)
        let time = max(62, usable * 0.14)
        let result = max(128, usable * 0.2)
        let rest = usable - time - result
        ScrollViewReader { proxy in
        Table(rows, selection: $model.activitySelection) {
            TableColumn(String(localized: "Time")) { entry in
                Text(RelativeTime.clock(entry.at, now: model.now))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help(RelativeTime.full(entry.at))
            }
            .width(time)
            TableColumn(String(localized: "Client")) { entry in
                Text(model.clientName(entry.clientID))
                    .foregroundStyle(entry.clientID == nil ? .secondary : .primary)
                    .help(model.clientName(entry.clientID))
            }
            .width(rest * 0.31)
            TableColumn(String(localized: "Request")) { entry in
                Text(CommandPresentation.label(entry.command))
            }
            .width(rest * 0.36)
            TableColumn(String(localized: "Calendar or list")) { entry in
                ActivityTargetCell(model: model, entry: entry)
            }
            .width(rest * 0.33)
            TableColumn(String(localized: "Result")) { entry in
                Pill(label: entry.outcome.label, tone: entry.outcome.tone)
            }
            .width(result)
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
                    Text(collection.name).lineLimit(1)
                }
                .help(String(localized: "ID: \(key.targetID)"))
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
                    Text(String(localized: "Client")).foregroundStyle(.secondary)
                    Text(model.clientName(entry.clientID))
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

    private func why(_ entry: ActivityEntry, outcome: OutcomePresentation,
                     collection: CollectionInfo?) -> String? {
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
        case .readEvents: String(localized: "read its events")
        case .readReminders: String(localized: "read its reminders")
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
