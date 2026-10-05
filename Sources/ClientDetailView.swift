import SwiftUI

// The client page (§8). The key itself is never shown, copied, or put in a
// tooltip or accessibility value: only the client ID, the key file path and a
// command that reads the key file. The MCP token is never shown either; it can
// be copied only through Copy Token…, after a confirmation.

struct ClientDetailView: View {
    let model: BridgeAppModel
    let client: ClientView

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        ClientHeader(model: model, client: client)
                        ConnectSection(model: model, client: client)
                        AccessSection(model: model, client: client)
                            .id("access")
                    }
                    .padding(24)
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear { scroll(proxy) }
                .onChange(of: model.clientScrollTarget) { _, _ in scroll(proxy) }
            }
            if model.hasUnsavedChanges || model.showSavedToast {
                SaveBar(model: model)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.hasUnsavedChanges || model.showSavedToast)
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let target = model.clientScrollTarget else { return }
        DispatchQueue.main.async {
            withAnimation {
                if let focus = model.accessFocus {
                    proxy.scrollTo(focus, anchor: .center)
                } else {
                    proxy.scrollTo(target, anchor: .top)
                }
            }
            model.clientScrollTarget = nil
        }
    }
}

struct ClientHeader: View {
    let model: BridgeAppModel
    let client: ClientView

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                PaneTitle(title: client.name)
                Text(subtitle).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
            Button {
                model.openActivity(client: client.id)
            } label: {
                Label(String(localized: "Activity"), systemImage: "list.bullet")
            }
            .help(String(localized: "Show this client's requests"))
            ActionMenuButton(accessibilityLabel: String(localized: "More actions for \(client.name)"),
                             help: String(localized: "More actions")) {
                ClientMenu.items(model: model, client: client)
            }
            .fixedSize()
            }
            .padding(.top, 4)
        }
    }

    private var subtitle: String {
        let last = model.lastRequest(for: client.id)
            .map { String(localized: "Last request \(RelativeTime.ago($0, now: model.now).lowercased())") }
            ?? String(localized: "No requests yet")
        return "\(last) · \(AccessSummary.counts(client.grants))"
    }
}

/// The ⋯ menu on a client page, also used by the sidebar's context menu.
enum ClientMenu {
    @MainActor
    static func items(model: BridgeAppModel, client: ClientView) -> [ActionMenuButton.Item] {
        var items: [ActionMenuButton.Item] = [
            .init(title: String(localized: "Rename…"), systemImage: "pencil",
                  action: { model.sheet = .rename(client.id) }),
            .separator,
            .header(String(localized: "MCP Access")),
        ]
        if client.hasMCPToken {
            items += [
                .init(title: String(localized: "Reset MCP Token…"), systemImage: "arrow.triangle.2.circlepath",
                      action: { model.resetMCPToken(client.id) }),
                .init(title: String(localized: "Remove MCP Access…"), systemImage: "minus.circle",
                      action: { model.removeMCPAccess(client.id) }),
                .init(title: String(localized: "Show Token File in Finder"), systemImage: "folder",
                      action: { model.showTokenFile(client.id) }),
            ]
        } else {
            items.append(.init(title: String(localized: "Turn On MCP Access"), systemImage: "sparkles",
                               action: { model.turnOnMCPAccess(client.id) }))
        }
        items.append(.header(String(localized: "Command Line")))
        if client.hasSigningKey {
            items += [
                .init(title: String(localized: "Rotate Key…"), systemImage: "arrow.triangle.2.circlepath",
                      action: { model.rotateKey(client.id) }),
                .init(title: String(localized: "Remove Command-Line Key…"), systemImage: "minus.circle",
                      action: { model.removeSigningKey(client.id) }),
                .init(title: String(localized: "Show Key File in Finder"), systemImage: "folder",
                      action: { model.showKeyFile(client.id) }),
            ]
        } else {
            items.append(.init(title: String(localized: "Add Command-Line Key"), systemImage: "terminal",
                               action: { model.addSigningKey(client.id) }))
        }
        items += [
            .separator,
            .init(title: String(localized: "Revoke Client…"), destructive: true,
                  action: { model.revokeClient(client.id) }),
        ]
        return items
    }
}

struct ConnectSection: View {
    let model: BridgeAppModel
    let client: ClientView

    private var tab: ConnectTab {
        model.connectTab[client.id] ?? (client.hasMCPToken || !client.hasSigningKey ? .agent : .cli)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(title: String(localized: "Connect"))
                Spacer()
                Picker(String(localized: "Connects from"), selection: Binding(
                    get: { tab }, set: { model.connectTab[client.id] = $0 })) {
                    Label(String(localized: "AI agent (MCP)"), systemImage: "sparkles").tag(ConnectTab.agent)
                    Label(String(localized: "Command line"), systemImage: "terminal").tag(ConnectTab.cli)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            switch tab {
            case .agent: ConnectAgentTab(model: model, client: client)
            case .cli:
                if client.hasSigningKey {
                    CommandLineConnect(model: model, client: client)
                } else {
                    EmptyConnectCard(text: String(localized: "This client has no command-line key."),
                                     button: String(localized: "Add Command-Line Key")) {
                        model.addSigningKey(client.id)
                    }
                }
            }
        }
    }
}

/// Connect ▸ Command line: the client ID, key file and a first command.
struct CommandLineConnect: View {
    let model: BridgeAppModel
    let client: ClientView

    var body: some View {
        let keyURL = model.keyFileURL(client.id)
        let keyStatus = model.keyFileStatus(client.id)
        VStack(alignment: .leading, spacing: 10) {
            Card {
                ConnectRow(label: String(localized: "Client ID")) {
                    MonoText(text: client.id, truncation: .tail)
                } actions: {
                    CopyButton(text: client.id, help: String(localized: "Copy Client ID"))
                }
                Divider().padding(.leading, 16)
                ConnectRow(label: String(localized: "Key file")) {
                    MonoText(text: keyURL.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "–")
                } actions: {
                    Button { model.showKeyFile(client.id) } label: {
                        Label(String(localized: "Show in Finder"), systemImage: "folder")
                    }
                    if let keyURL {
                        CopyButton(text: keyURL.path, help: String(localized: "Copy Path"))
                    }
                }
                if keyStatus != .present {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(keyStatus == .missing
                             ? String(localized: "The key file is missing. Rotate the key to create a new one.")
                             : String(localized: "The key file has unsafe permissions or isn't a regular file. Check it in Finder, or revoke this client."))
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if keyStatus == .missing {
                            Button(String(localized: "Rotate Key…")) { model.rotateKey(client.id) }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                }
                Divider().padding(.leading, 16)
                ConnectRow(label: String(localized: "Try it")) {
                    VStack(alignment: .leading, spacing: 2) {
                        MonoText(text: ConnectCommand.scopeStatus(for: client, among: model.clients),
                                 truncation: .tail, lines: 2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(String(localized: "Run it in Terminal, in the eventkit-bridge folder."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } actions: {
                    CopyButton(text: ConnectCommand.scopeStatus(for: client, among: model.clients),
                               title: String(localized: "Copy Command"),
                               help: String(localized: "Copy a command that checks this client's access"))
                }
            }
            Label(String(localized: "The key is never shown here. Apps running as you can read the key file, so keep it out of repositories, chats and screenshots."),
                  systemImage: "lock")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 2)
        }
    }
}

struct ConnectRow<Value: View, Actions: View>: View {
    let label: String
    @ViewBuilder var value: Value
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            value
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) { actions }
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

// MARK: - Access (§8.3)

/// Changes: Ask me first / Allow without asking. Saved at once, not staged.
struct ApprovalControl: View {
    let model: BridgeAppModel
    let client: ClientView

    var body: some View {
        let writes = client.grants.contains { $0.mask & ~ClientGrant.read != 0 }
        HStack(spacing: 6) {
            if !writes {
                Text(String(localized: "Only applies to changes."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text(String(localized: "Changes:")).foregroundStyle(.secondary)
            Picker(String(localized: "Changes"), selection: Binding(
                get: { client.approval }, set: { model.setApproval(client.id, $0) })) {
                Label(String(localized: "Ask me first"), systemImage: "hand.raised").tag(ApprovalMode.ask)
                Label(String(localized: "Allow without asking"), systemImage: "checkmark.shield").tag(ApprovalMode.allow)
            }
            .labelsHidden()
            .fixedSize()
            .disabled(!writes)
            .accessibilityLabel(String(localized: "Ask before changes"))
        }
        .help(String(localized: "Ask me first shows a prompt for every create, edit, complete or delete from this client. Reads never ask."))
    }
}

struct AccessSection: View {
    let model: BridgeAppModel
    let client: ClientView
    @State private var filter = ""
    @State private var grantedOnly = false

    private var tab: ClientResource { model.accessTab[client.id] ?? .calendar }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle(title: String(localized: "Access"))
                Spacer()
                ApprovalControl(model: model, client: client)
            }
            HStack(spacing: 12) {
                Picker(String(localized: "Type"), selection: Binding(
                    get: { tab }, set: { model.accessTab[client.id] = $0 })) {
                    Text(String(localized: "Calendars \(grantedCount(.calendar))")).tag(ClientResource.calendar)
                    Text(String(localized: "Reminders \(grantedCount(.reminderList))")).tag(ClientResource.reminderList)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                SearchField(text: $filter, prompt: String(localized: "Filter"),
                            accessibilityLabel: String(localized: "Filter calendars and lists"))
                    .frame(minWidth: 90, maxWidth: 200)
                Toggle(String(localized: "Granted only"), isOn: $grantedOnly)
                    .toggleStyle(.checkbox)
                    .fixedSize()
            }
            if model.status(tab) != .fullAccess {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(tab == .calendar
                             ? String(localized: "Allow Calendar access to see your calendars here. Access you already gave is kept.")
                             : String(localized: "Allow Reminders access to see your lists here. Access you already gave is kept."))
                        AccessStatusControls(model: model, resource: tab, prominent: true)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                AccessTable(model: model, client: client, resource: tab,
                            filter: filter, grantedOnly: grantedOnly)
                let unavailable = model.unavailableGrants(client).filter { $0.resource == tab }
                if !unavailable.isEmpty {
                    BannerView(banner: Banner(
                        kind: .warning,
                        title: tab == .calendar
                            ? (unavailable.count == 1 ? String(localized: "1 calendar isn't available right now.")
                               : String(localized: "\(unavailable.count) calendars aren't available right now."))
                            : (unavailable.count == 1 ? String(localized: "1 list isn't available right now.")
                               : String(localized: "\(unavailable.count) lists aren't available right now.")),
                        message: String(localized: "Its account may be signed out. \(client.name) keeps its access until you remove it."),
                        actionTitle: String(localized: "Review…"),
                        action: { model.sheet = .unavailableGrants(client.id) }))
                }
            }
        }
    }

    private func grantedCount(_ resource: ClientResource) -> Int {
        guard let draft = model.draft else { return client.grants.filter { $0.resource == resource }.count }
        return Set(draft.staged.keys).filter { $0.resource == resource }.count
    }
}

struct AccessTable: View {
    let model: BridgeAppModel
    let client: ClientView
    let resource: ClientResource
    let filter: String
    let grantedOnly: Bool

    static let cellWidth: CGFloat = 64

    var body: some View {
        let actions = AccessWords.actions(for: resource)
        let rows = visibleRows
        let groups = Dictionary(grouping: rows, by: \.account)
        let accounts = rows.map(\.account).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        Card {
            HStack(spacing: 0) {
                Text(resource == .calendar ? String(localized: "Calendar") : String(localized: "List"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(actions, id: \.bit) { action in
                    Text(action.title).frame(width: Self.cellWidth)
                }
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .accessibilityHidden(true)
            Divider()
            if rows.isEmpty {
                Text(emptyText)
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(accounts, id: \.self) { account in
                Text(account)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Palette.groupHeader)
                    .accessibilityAddTraits(.isHeader)
                ForEach(groups[account] ?? []) { collection in
                    Divider()
                    AccessRow(model: model, collection: collection, actions: actions,
                              clientName: client.name)
                        .id(collection.key)
                }
                if account != accounts.last { Divider() }
            }
        }
    }

    private var visibleRows: [CollectionInfo] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        return model.collections(resource).sortedForDisplay().filter { collection in
            (!grantedOnly || (model.draft?.mask(collection.key) ?? 0) != 0 ||
                (model.draft?.savedMask(collection.key) ?? 0) != 0) &&
            (query.isEmpty || collection.name.localizedCaseInsensitiveContains(query) ||
                collection.account.localizedCaseInsensitiveContains(query))
        }
    }

    private var emptyText: String {
        if !filter.isEmpty { return String(localized: "Nothing matches “\(filter)”.") }
        if grantedOnly { return String(localized: "Nothing granted yet. Turn off Granted only to see everything.") }
        return resource == .calendar ? String(localized: "No calendars found.")
                                     : String(localized: "No lists found.")
    }
}

struct AccessRow: View {
    let model: BridgeAppModel
    let collection: CollectionInfo
    let actions: [(bit: Int, word: String, title: String)]
    let clientName: String
    @State private var highlighted = false

    var body: some View {
        let mask = model.draft?.mask(collection.key) ?? 0
        let saved = model.draft?.savedMask(collection.key) ?? 0
        let changed = model.draft?.isChanged(collection.key) ?? false
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                ColorDot(color: collection.color)
                Text(collection.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(String(localized: "ID: \(collection.id)"))
                if !collection.writable {
                    Label(String(localized: "Read only"), systemImage: "lock")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                        .fixedSize()
                }
                if changed {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                        .help(String(localized: "Unsaved change"))
                        .accessibilityLabel(String(localized: "Unsaved change"))
                }
                if let warning = warning(mask: mask, saved: saved) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(warning)
                        .accessibilityLabel(warning)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(actions, id: \.bit) { action in
                cell(action, mask: mask)
                    .frame(width: AccessTable.cellWidth)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(background(changed: changed))
        .contentShape(Rectangle())
        .contextMenu {
            Button(String(localized: "Read Only")) { model.apply(.readOnly, to: collection) }
            Button(String(localized: "Full Access")) { model.apply(.fullAccess, to: collection) }
            Button(String(localized: "No Access")) { model.apply(.noAccess, to: collection) }
            Divider()
            Button(collection.resource == .calendar ? String(localized: "Copy Calendar ID")
                                                    : String(localized: "Copy List ID")) {
                Pasteboard.copy(collection.id)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(rowLabel)
        .onAppear { flashIfFocused() }
        .onChange(of: model.accessFocus) { _, _ in flashIfFocused() }
    }

    @ViewBuilder
    private func cell(_ action: (bit: Int, word: String, title: String), mask: Int) -> some View {
        if action.bit == ClientGrant.read || collection.writable {
            Toggle(isOn: Binding(get: { mask & action.bit != 0 },
                                 set: { model.setAction(collection.key, bit: action.bit, on: $0) })) {
                Text(action.title)
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel(String(localized: "\(action.title), \(collection.name)"))
        } else {
            Text("—")
                .foregroundStyle(.tertiary)
                .accessibilityLabel(String(localized: "\(action.title), \(collection.name), not available for a read-only calendar"))
        }
    }

    private func warning(mask: Int, saved: Int) -> String? {
        if !collection.writable && saved & ~ClientGrant.read != 0 {
            return collection.resource == .calendar
                ? String(localized: "Write access will be removed when you save, because this calendar is now read only.")
                : String(localized: "Write access will be removed when you save, because this list is now read only.")
        }
        if ClientGrantEditing.writeWithoutRead(mask) {
            return String(localized: "Without Read, this client can't look up items to edit, complete or delete them.")
        }
        return nil
    }

    private var rowLabel: String {
        var parts = [collection.name, collection.account]
        if !collection.writable { parts.append(String(localized: "read only")) }
        return parts.joined(separator: ", ")
    }

    private func background(changed: Bool) -> Color {
        if highlighted { return Color.accentColor.opacity(0.2) }
        return changed ? Color.accentColor.opacity(0.07) : Color.clear
    }

    private func flashIfFocused() {
        guard model.accessFocus == collection.key else { return }
        withAnimation(.easeIn(duration: 0.2)) { highlighted = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeOut(duration: 0.6)) { highlighted = false }
            if model.accessFocus == collection.key { model.accessFocus = nil }
        }
    }
}

struct SaveBar: View {
    let model: BridgeAppModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                if model.hasUnsavedChanges, let draft = model.draft {
                    Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(draft.changedCells == 1 ? String(localized: "1 unsaved change")
                                                 : String(localized: "\(draft.changedCells) unsaved changes"))
                    Spacer()
                    Button(String(localized: "Revert")) { model.revertDraft() }
                    Button(String(localized: "Save")) { model.saveDraft() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("s", modifiers: .command)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(String(localized: "Saved.")).foregroundStyle(.green).bold()
                    Text(String(localized: "Changes apply to the next request.")).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .frame(minHeight: 52)
        }
        .background(.bar)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Revoked clients

struct RevokedClientView: View {
    let model: BridgeAppModel
    let client: ClientView

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    PaneTitle(title: client.name)
                    Pill(label: String(localized: "Revoked"), tone: .neutral)
                }
                Card {
                    ConnectRow(label: String(localized: "Client ID")) {
                        MonoText(text: client.id, truncation: .tail)
                    } actions: {
                        CopyButton(text: client.id, help: String(localized: "Copy Client ID"))
                    }
                    if let revokedAt = client.revokedAt {
                        Divider().padding(.leading, 16)
                        ConnectRow(label: String(localized: "Revoked")) {
                            Text(RelativeTime.full(revokedAt))
                        } actions: { EmptyView() }
                    }
                }
                Text(String(localized: "Its key no longer works and it has no access. Revoked clients are kept so Activity stays understandable. To reconnect this tool, create a new client."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(String(localized: "Show Activity")) { model.openActivity(client: client.id) }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Sheets

struct NewClientSheet: View {
    let model: BridgeAppModel
    @State private var name = ""
    @State private var kind = ClientKind.agent
    @State private var ask: Bool?
    @State private var submitted: ClientNameIssue?
    @FocusState private var focused: Bool

    var body: some View {
        let issue = model.nameIssue(name)
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "New Client")).font(.headline)
            Text(String(localized: "Name the agent or script that will connect. It starts with no access."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Name"))
                TextField(String(localized: "Name"), text: $name,
                          prompt: Text(String(localized: "For example, Claude Code")))
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { create() }
                    .accessibilityLabel(String(localized: "Name"))
                if let shown = visibleIssue(issue) {
                    Text(NameIssueText.message(shown)).font(.callout).foregroundStyle(.red)
                } else {
                    Text(String(localized: "Shown in Activity and the menu bar. Use one client per tool."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Connects from"))
                Picker(String(localized: "Connects from"), selection: $kind) {
                    ForEach(ClientKind.allCases) { option in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title(option))
                            if let caption = caption(option) {
                                Text(caption)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.bottom, 4)
                        .tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .accessibilityLabel(String(localized: "Connects from"))
            }
            VStack(alignment: .leading, spacing: 2) {
                Toggle(String(localized: "Ask me before each change"), isOn: Binding(
                    get: { ask ?? (model.defaultApproval(for: kind) == .ask) }, set: { ask = $0 }))
                    .toggleStyle(.checkbox)
                Text(String(localized: "Preset from Settings. You can change this later on the client's page."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
            Text(String(localized: "A new client has no access. You choose its calendars and lists next."))
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { model.sheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Create")) { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(issue != nil)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { focused = true }
    }

    private func title(_ option: ClientKind) -> String {
        switch option {
        case .agent: String(localized: "AI agent (MCP)")
        case .cli: String(localized: "Command line")
        case .both: String(localized: "Both")
        }
    }

    private func caption(_ option: ClientKind) -> String? {
        switch option {
        case .agent: String(localized: "For Claude Code, Codex, Claude Desktop, Cursor and other agents. What the agent reads is sent to its AI provider.")
        case .cli: String(localized: "For scripts that run client.py.")
        case .both: nil
        }
    }

    // Empty is shown as a disabled button, not an error.
    private func visibleIssue(_ issue: ClientNameIssue?) -> ClientNameIssue? {
        if let submitted { return submitted }
        guard let issue, issue != .empty else { return nil }
        return issue
    }

    private func create() {
        guard model.nameIssue(name) == nil else { return }
        // Untouched, the checkbox follows the default for the chosen kind.
        submitted = model.createClient(name: name, kind: kind, askBeforeChanges: ask)
    }
}

/// Settings ▸ MCP Server ▸ Port ▸ Change…
struct MCPPortSheet: View {
    let model: BridgeAppModel
    @State private var text = ""
    @State private var submitted: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Choose Another Port")).font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Port"))
                TextField(String(localized: "Port"), text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(save)
                    .frame(width: 120)
                if let submitted {
                    Text(submitted).font(.callout).foregroundStyle(.red)
                }
                Text(String(localized: "From 1024 to 65535. Agents set up with a direct URL need the new address. Launcher setups keep working."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { model.sheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Use This Port"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(Int(text.trimmingCharacters(in: .whitespaces)) == nil)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            text = String(model.mcpPort)
            focused = true
        }
    }

    private func save() {
        submitted = model.changeMCPPort(text)
    }
}

struct RenameClientSheet: View {
    let model: BridgeAppModel
    let clientID: String
    @State private var name = ""
    @State private var submitted: ClientNameIssue?
    @FocusState private var focused: Bool

    var body: some View {
        let original = model.client(clientID)?.name ?? ""
        let issue = model.nameIssue(name, excluding: clientID)
        let unchanged = name.trimmingCharacters(in: .whitespacesAndNewlines) == original
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Rename Client")).font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Name"))
                TextField(String(localized: "Name"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { rename() }
                    .accessibilityLabel(String(localized: "Name"))
                if let shown = submitted ?? (issue == .empty ? nil : issue) {
                    Text(NameIssueText.message(shown)).font(.callout).foregroundStyle(.red)
                }
                Text(String(localized: "Tools keep working. Commands that use --client \(ConnectCommand.shellQuoted(original)) need the new name; commands that use the client ID or key file don't."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { model.sheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Rename")) { rename() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(issue != nil || unchanged)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            name = original
            focused = true
        }
    }

    private func rename() {
        let original = model.client(clientID)?.name ?? ""
        guard model.nameIssue(name, excluding: clientID) == nil,
              name.trimmingCharacters(in: .whitespacesAndNewlines) != original else { return }
        submitted = model.rename(clientID, to: name)
    }
}

struct UnavailableGrantsSheet: View {
    let model: BridgeAppModel
    let clientID: String

    var body: some View {
        let client = model.client(clientID)
        let keys = client.map { model.unavailableGrants($0, staged: false) } ?? []
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Unavailable calendars and lists")).font(.headline)
            Text(String(localized: "EventKit doesn't list these right now. Their account may be signed out, or they were deleted. \(client?.name ?? "") keeps its access until you remove it. Removals apply when you save."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Card {
                ForEach(Array(keys.enumerated()), id: \.element) { index, key in
                    if index > 0 { Divider().padding(.leading, 16) }
                    let mask = model.draft?.mask(key) ?? 0
                    let saved = model.draft?.savedMask(key) ?? 0
                    HStack(spacing: 10) {
                        Image(systemName: key.resource == .calendar ? "calendar" : "list.bullet")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            MonoText(text: key.targetID)
                            Text(AccessWords.words(saved).capitalizingFirstLetter)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if mask == 0 {
                            Text(String(localized: "Removed")).foregroundStyle(.secondary)
                            Button(String(localized: "Undo")) {
                                model.restoreSaved(key)
                            }
                        } else {
                            Button(String(localized: "Remove")) { model.removeUnavailable(key) }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
            HStack {
                Spacer()
                Button(String(localized: "Done")) { model.sheet = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
    }
}

extension String {
    var capitalizingFirstLetter: String { prefix(1).uppercased() + dropFirst() }
}

struct CollectionIDsSheet: View {
    let model: BridgeAppModel
    @State private var filter = ""

    var body: some View {
        let rows = model.collections.sortedForDisplay().filter {
            filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) ||
                $0.account.localizedCaseInsensitiveContains(filter) ||
                $0.id.localizedCaseInsensitiveContains(filter)
        }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(localized: "Collection IDs")).font(.headline)
                Spacer()
                SearchField(text: $filter, prompt: String(localized: "Filter"))
                    .frame(width: 200)
            }
            Table(rows) {
                TableColumn(String(localized: "Name")) { row in
                    HStack(spacing: 6) {
                        ColorDot(color: row.color, size: 8)
                        Text(row.name)
                    }
                }
                TableColumn(String(localized: "Account"), value: \.account)
                TableColumn(String(localized: "Type")) { row in
                    Text(row.resource == .calendar ? String(localized: "Calendar") : String(localized: "List"))
                }
                .width(70)
                TableColumn(String(localized: "Writable")) { row in
                    Text(row.writable ? String(localized: "Yes") : String(localized: "Read only"))
                }
                .width(80)
                TableColumn(String(localized: "ID")) { row in
                    HStack {
                        MonoText(text: row.id)
                        Spacer()
                        CopyButton(text: row.id, help: String(localized: "Copy ID"))
                            .buttonStyle(.borderless)
                    }
                }
                .width(min: 200, ideal: 280)
            }
            .frame(minHeight: 300)
            HStack {
                Text(String(localized: "\(rows.count) shown")).foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "Done")) { model.sheet = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 760, height: 480)
    }
}
