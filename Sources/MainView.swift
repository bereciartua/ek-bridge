import SwiftUI

/// The single window (§4): Overview, Activity, Clients and Settings.
struct MainView: View {
    @Bindable var model: BridgeAppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 320)
        } detail: {
            DetailView(model: model)
                .frame(minWidth: 520)
        }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .newClient: NewClientSheet(model: model)
            case .rename(let id): RenameClientSheet(model: model, clientID: id)
            case .unavailableGrants(let id): UnavailableGrantsSheet(model: model, clientID: id)
            case .collectionIDs: CollectionIDsSheet(model: model)
            case .mcpPort: MCPPortSheet(model: model)
            case .remotePort: RemotePortSheet(model: model)
            case .remoteAddress: RemoteAddressSheet(model: model)
            case .pairing(let id): PairingSheet(model: model, id: id)
            case .oauthClient: OAuthClientSheet(model: model)
            }
        }
    }
}

struct SidebarView: View {
    let model: BridgeAppModel
    @State private var revokedExpanded = false

    private var selection: Binding<Route?> {
        Binding(get: { model.route }, set: { if let route = $0 { model.navigate(to: route) } })
    }

    var body: some View {
        List(selection: selection) {
            Label(String(localized: "Overview"), systemImage: "gauge.with.dots.needle.33percent")
                .tag(Route.overview)
            Label(String(localized: "Activity"), systemImage: "list.bullet")
                .badge(model.unseenProblemCount)
                .tag(Route.activity)
                .accessibilityLabel(model.unseenProblemCount > 0
                    ? String(localized: "Activity, \(model.unseenProblemCount) new problems")
                    : String(localized: "Activity"))
            Section {
                ForEach(model.activeClients) { client in
                    ClientSidebarRow(model: model, client: client)
                        .tag(Route.client(client.id))
                }
                if model.activeClients.isEmpty {
                    Text(String(localized: "No connections yet"))
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
                if !model.revokedClients.isEmpty {
                    DisclosureGroup(isExpanded: $revokedExpanded) {
                        ForEach(model.revokedClients) { client in
                            Label {
                                Text(client.name).foregroundStyle(.secondary)
                            } icon: {
                                AvatarView(name: client.name, id: client.id, size: 18).opacity(0.5)
                            }
                            .tag(Route.client(client.id))
                            .accessibilityLabel(String(localized: "\(client.name), removed"))
                        }
                    } label: {
                        Text(String(localized: "Removed (\(model.revokedClients.count))"))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                HStack {
                    Text(String(localized: "Connections"))
                    Spacer()
                    Button {
                        model.beginNewClient()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!model.canCreateClient)
                    .help(model.canCreateClient ? String(localized: "Add a Connection…")
                        : String(localized: "You have 32 connections, the maximum. Remove one to add another."))
                    .accessibilityLabel(String(localized: "Add a Connection…"))
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            let crowded = model.clients.count > 8
            VStack(spacing: 0) {
                Divider().opacity(crowded ? 1 : 0)
                List(selection: selection) {
                    Label(String(localized: "Settings"), systemImage: "slider.horizontal.3")
                        .tag(Route.settings)
                }
                .listStyle(.sidebar)
                .scrollDisabled(true)
                .frame(height: 44)
            }
            // Clients scroll under this row, so it needs its own surface.
            .background(crowded ? AnyShapeStyle(.bar) : AnyShapeStyle(.clear))
        }
    }
}

/// A client in the sidebar. Double-click the name to rename it in place.
struct ClientSidebarRow: View {
    let model: BridgeAppModel
    let client: ClientView
    @State private var editing = false
    @State private var draftName = ""
    @State private var issue: ClientNameIssue?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            AvatarView(name: client.name, id: client.id, size: 24)
                .opacity(client.paused ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 0) {
                if editing {
                    TextField(String(localized: "Name"), text: $draftName)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit(commit)
                        .onExitCommand { editing = false }
                        .onChange(of: focused) { _, isFocused in if !isFocused && editing { commit() } }
                        .help(issue.map(NameIssueText.message) ?? "")
                } else {
                    Text(client.name).lineLimit(1)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(issue == nil ? Color.secondary : Color.red)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture(count: 2).onEnded { beginEditing() })
        .contextMenu {
            Button(String(localized: "Rename…")) { model.sheet = .rename(client.id) }
            if client.hasMCPToken {
                Button(String(localized: "Show Token File in Finder")) { model.showTokenFile(client.id) }
            }
            if client.hasSigningKey {
                Button(String(localized: "Show Key File in Finder")) { model.showKeyFile(client.id) }
            }
            Divider()
            if client.paused {
                Button(String(localized: "Resume Connection")) { model.setPaused(client.id, false) }
            } else {
                Button(String(localized: "Pause Connection")) { model.setPaused(client.id, true) }
            }
            Button(String(localized: "Remove Connection…"), role: .destructive) { model.revokeClient(client.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(client.name), \(subtitle)")
        .accessibilityAction(named: String(localized: "Rename")) { model.sheet = .rename(client.id) }
    }

    private var subtitle: String {
        if editing, let issue { return NameIssueText.message(issue) }
        let state: String
        if client.paused {
            state = String(localized: "Paused")
        } else if let last = model.lastRequest(for: client.id) {
            state = RelativeTime.ago(last, now: model.now)
        } else if client.hasMCPToken && !client.grants.isEmpty {
            state = String(localized: "waiting")
        } else {
            state = client.grants.isEmpty ? String(localized: "New") : String(localized: "No requests yet")
        }
        return [ClientTransport(client).badge, state].compactMap { $0 }.joined(separator: " · ")
    }

    private func beginEditing() {
        draftName = client.name
        issue = nil
        editing = true
        DispatchQueue.main.async { focused = true }
    }

    private func commit() {
        guard editing else { return }
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == client.name { editing = false; return }
        if let problem = model.rename(client.id, to: draftName) {
            issue = problem
            NSSound.beep()
            DispatchQueue.main.async { focused = true }
        } else {
            issue = nil
            editing = false
        }
    }
}

enum NameIssueText {
    static func message(_ issue: ClientNameIssue) -> String {
        switch issue {
        case .empty: String(localized: "Enter a name.")
        case .tooLong: String(localized: "Use a shorter name (up to 80 bytes).")
        case .controlCharacters: String(localized: "Names can't contain tabs or line breaks.")
        case .duplicate(let name): String(localized: "Another connection is already called “\(name)”.")
        }
    }
}

struct DetailView: View {
    let model: BridgeAppModel

    var body: some View {
        VStack(spacing: 0) {
            if let banner = model.banner {
                BannerView(banner: banner, onDismiss: { model.dismissBanner() })
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Group {
                switch model.route {
                case .overview: OverviewView(model: model)
                case .activity: ActivityView(model: model)
                case .settings: SettingsView(model: model)
                case .client(let id):
                    if let client = model.client(id) {
                        if client.revoked {
                            RevokedClientView(model: model, client: client)
                        } else {
                            ClientDetailView(model: model, client: client)
                                .id(client.id)
                        }
                    } else {
                        OverviewView(model: model)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeOut(duration: 0.2), value: model.banner?.id)
        .background(Palette.pane)
    }
}
