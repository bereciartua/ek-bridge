import SwiftUI

// Connect ▸ AI agent (§13.3). The token is never displayed: snippets point at
// the launcher or the token file, and Copy Token… asks first.

struct ConnectAgentTab: View {
    let model: BridgeAppModel
    let client: ClientView

    var body: some View {
        if !client.hasMCPToken {
            EmptyConnectCard(
                text: String(localized: "This connection has no MCP access yet."),
                button: String(localized: "Turn On MCP Access"), prominent: true) {
                model.turnOnMCPAccess(client.id)
            }
        } else if !model.bridge.isOn {
            EmptyConnectCard(
                text: String(localized: "\(AppIdentity.displayName) is paused, so agents can't connect."),
                button: String(localized: "Turn On \(AppIdentity.displayName)"), prominent: true) {
                model.setBridgeEnabled(true)
            }
        } else if !model.localMCPAllowed {
            EmptyConnectCard(
                text: String(localized: "The local MCP server is turned off in Settings ▸ Advanced."),
                button: String(localized: "Turn It On"), prominent: true) {
                model.setLocalMCPAllowed(true)
            }
        } else if let failure = model.mcpFailureText {
            EmptyConnectCard(text: String(localized: "The MCP server couldn't start. \(failure)"),
                             button: String(localized: "Open Settings"), prominent: false,
                             warning: true) {
                model.settingsScrollTarget = "mcp"
                model.navigate(to: .settings)
            }
        } else {
            AgentSetupCard(model: model, client: client)
        }
    }
}

struct EmptyConnectCard: View {
    let text: String
    let button: String
    var prominent = false
    var warning = false
    let action: () -> Void

    var body: some View {
        Card {
            HStack(spacing: 12) {
                if warning {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .accessibilityHidden(true)
                }
                Text(text).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button(button, action: action).modifier(Prominent(on: prominent))
            }
            .padding(16)
        }
    }
}

struct AgentSetupCard: View {
    let model: BridgeAppModel
    let client: ClientView

    private var agent: AgentKind { model.agent(for: client.id) }
    private var methodKey: String { "\(client.id)|\(agent.rawValue)" }
    private var method: SetupMethod {
        let chosen = model.methodChoice[methodKey] ?? agent.recommended
        return agent.methods.contains(chosen) ? chosen : agent.recommended
    }

    var body: some View {
        let context = SetupContext(url: model.mcpURL, launcherPath: model.launcherPath, clientID: client.id,
                                   tokenPath: model.tokenFileURL(client.id)?.path ?? "")
        let snippet = agent.snippet(method, context)
        VStack(alignment: .leading, spacing: 10) {
            Card {
                ConnectRow(label: String(localized: "Agent")) {
                    FlowLayout(spacing: 6) {
                        ForEach(AgentKind.allCases) { kind in
                            AgentChip(title: kind.displayName, selected: kind == agent) {
                                model.setAgent(kind, for: client.id)
                            }
                        }
                    }
                } actions: { EmptyView() }
                if agent.methods.count > 1 && agent != .other {
                    RowDivider()
                    ConnectRow(label: String(localized: "Method")) {
                        Picker(String(localized: "Method"), selection: Binding(
                            get: { method }, set: { model.methodChoice[methodKey] = $0 })) {
                            ForEach(agent.methods, id: \.self) { option in
                                Text(methodTitle(option)).tag(option)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .horizontalRadioGroupLayout()
                        .labelsHidden()
                    } actions: { EmptyView() }
                }
                RowDivider()
                SnippetView(model: model, client: client, agent: agent, method: method, snippet: snippet)
                RowDivider()
                statusRow
                RowDivider()
                tokenRow(snippet)
                RowDivider()
                ConnectRow(label: String(localized: "Server")) {
                    MonoText(text: model.mcpURL)
                } actions: {
                    MCPServerPill(model: model)
                    CopyButton(text: model.mcpURL, help: String(localized: "Copy URL"))
                }
            }
            Label(String(localized: "The token is never shown. The recommended setups read it from a private file, so it never lands in the agent's config, your shell history or the clipboard."),
                  systemImage: "lock")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 2)
            Label(AgentSetup.cloudFootnote, systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 2)
        }
    }

    private func methodTitle(_ option: SetupMethod) -> String {
        let name: String
        switch (option, agent) {
        case (.launcher, _): name = String(localized: "Launcher")
        case (.directHTTP, .claudeCode), (.directHTTP, .devinDesktop):
            name = String(localized: "Direct HTTP, token read from file")
        case (.directHTTP, .vsCode): name = String(localized: "Direct HTTP, token typed into VS Code")
        case (.directHTTP, _): name = String(localized: "Direct HTTP, token in an environment variable")
        }
        return option == agent.recommended ? String(localized: "Recommended: \(name.lowercasedFirst)") : name
    }

    private var statusRow: some View {
        ConnectRow(label: String(localized: "Status")) {
            switch model.mcpConnection(for: client) {
            case .waiting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "Waiting for the agent…")).foregroundStyle(.secondary)
                }
            case .connected(let agent, let at):
                let fresh = model.now.timeIntervalSince(at) < 600
                HStack(spacing: 8) {
                    Circle().fill(fresh ? Color.green : Color.secondary).frame(width: 9, height: 9)
                        .accessibilityHidden(true)
                    (Text(String(localized: "Connected")).bold()
                     + Text(agent.map { " · \($0) " } ?? " ")
                     + Text(agent == nil ? "" : String(localized: "(as reported)")).foregroundStyle(.secondary)
                     + Text(" · \(RelativeTime.ago(at, now: model.now).lowercased())"))
                        .lineLimit(2)
                }
            case .refused(let code, _):
                Label(String(localized: "Last request was refused: \(OutcomePresentation.of(code).label)"),
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } actions: {
            if case .refused(_, let entryID) = model.mcpConnection(for: client) {
                Button(String(localized: "Show in Activity")) { model.openActivity(selecting: entryID) }
                    .buttonStyle(.link)
            } else if model.lastRequest(for: client.id) != nil {
                Button(String(localized: "Show in Activity")) { model.openActivity(client: client.id) }
                    .buttonStyle(.link)
            }
        }
    }

    private func tokenRow(_ snippet: SetupSnippet) -> some View {
        let status = model.tokenFileStatus(client.id)
        return VStack(alignment: .leading, spacing: 0) {
            ConnectRow(label: String(localized: "Token")) {
                HStack(spacing: 6) {
                    // A fixed mask, never derived from the token.
                    MonoText(text: ClientRegistry.mcpTokenPrefix + " ••••••••••••••••")
                        .fixedSize()
                        .accessibilityLabel(String(localized: "Token hidden"))
                    if let issued = client.mcpIssuedAt {
                        Text("· " + String(localized: "created \(issued.formatted(.dateTime.month(.abbreviated).day()))"))
                            .foregroundStyle(.secondary)
                    }
                }
            } actions: {
                if snippet.needsLiteralToken {
                    Button { model.copyToken(client.id) } label: {
                        Label(String(localized: "Copy Token…"), systemImage: "key")
                    }
                }
                Button(String(localized: "Reset…")) { model.resetMCPToken(client.id) }
            }
            if status != .present {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(status == .missing
                         ? String(localized: "The token file is missing. Reset the token to create a new one.")
                         : String(localized: "The token file has unsafe permissions or isn't a regular file. Check it in Finder, or reset the token."))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(String(localized: "Show in Finder")) { model.showTokenFile(client.id) }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
        }
    }
}

/// The local server's real state: Listening, Starting… or Couldn't start.
struct MCPServerPill: View {
    let model: BridgeAppModel

    var body: some View {
        switch model.mcpStatus {
        case .listening: Pill(label: String(localized: "Listening"), tone: .ok, icon: true)
        case .failed: Pill(label: String(localized: "Couldn't start"), tone: .bad, icon: true)
        case .starting, .off: Pill(label: String(localized: "Starting…"), tone: .neutral)
        }
    }
}

/// The snippet for one agent and method, with its steps and warnings.
struct SnippetView: View {
    let model: BridgeAppModel
    let client: ClientView
    let agent: AgentKind
    let method: SetupMethod
    let snippet: SetupSnippet
    @State private var showExtra = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(heading).foregroundStyle(.secondary)
                Spacer()
                if let url = snippet.installURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label(String(localized: "Install in VS Code"), systemImage: "arrow.down.app")
                    }
                }
                CopyButton(text: snippet.text,
                           title: snippet.kind == .shellCommand ? String(localized: "Copy Command")
                                                                : String(localized: "Copy"),
                           help: String(localized: "Copy the setup for \(agent.displayName)"))
            }
            CodeBox(text: snippet.text)
            if !snippet.steps.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    // A single step isn't a list, so it has no number.
                    ForEach(Array(snippet.steps.enumerated()), id: \.offset) { index, step in
                        Text(snippet.steps.count == 1 ? step : "\(index + 1). \(step)")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.callout)
            }
            if let folder = snippet.destinationFolder,
               FileManager.default.fileExists(atPath: (folder as NSString).expandingTildeInPath) {
                Button {
                    // The config file itself if it exists, else its folder.
                    let file = snippet.destination.map { ($0 as NSString).expandingTildeInPath }
                    let target = file.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
                        ?? (folder as NSString).expandingTildeInPath
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target)])
                } label: {
                    Label(String(localized: "Show Config File in Finder"), systemImage: "folder")
                }
            }
            ForEach(Array(snippet.extraSnippets.enumerated()), id: \.offset) { _, extra in
                DisclosureGroup(extra.title, isExpanded: $showExtra) {
                    VStack(alignment: .trailing, spacing: 6) {
                        CodeBox(text: extra.text)
                        CopyButton(text: extra.text, title: String(localized: "Copy"),
                                   help: String(localized: "Copy"))
                    }
                    .padding(.top, 4)
                }
                .font(.callout)
            }
            if snippet.skipsListenerCheck {
                warning(AgentSetup.listenerCheckCaveat)
            }
            if method == .launcher && agent != .other && !model.isInstalledInApplications {
                NotInApplicationsNotice(model: model, padded: false)
            }
            if let footnote = agent.footnote {
                Label(footnote, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Setup for \(agent.displayName)"))
    }

    private var heading: String {
        switch snippet.kind {
        case .shellCommand: String(localized: "Run in Terminal")
        case .values: String(localized: "Values for your agent")
        case .json, .toml:
            snippet.destination.map { String(localized: "Add to \($0)") } ?? String(localized: "Add to the agent's settings")
        }
    }

    private func warning(_ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .font(.callout)
    }
}

/// Monospaced, selectable text in a box, up to eight lines before it scrolls.
struct CodeBox: View {
    let text: String

    var body: some View {
        let lines = max(1, text.split(separator: "\n", omittingEmptySubsequences: false).count)
        ScrollView(.vertical) {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
        }
        .frame(minHeight: 34, maxHeight: lines > 8 || text.count > 600 ? 150 : nil)
        .fixedSize(horizontal: false, vertical: lines <= 8 && text.count <= 600)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

struct AgentChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? Color.accentColor : Color.primary.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

/// Lays children out left to right, wrapping to new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows = [(indices: [Int], width: CGFloat, height: CGFloat)]()
        var current = (indices: [Int](), width: CGFloat(0), height: CGFloat(0))
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width && !current.indices.isEmpty {
                rows.append(current)
                current = ([index], size.width, size.height)
            } else {
                current = (current.indices + [index], needed, max(current.height, size.height))
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
