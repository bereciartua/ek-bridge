import SwiftUI

// Remote Access (§22.7): the Settings card, the client page's Cloud section,
// the pairing sheet, and the address and port sheets. Remote tokens are never
// displayed; Copy Remote Token… asks first.

struct RemoteAccessSettings: View {
    let model: BridgeAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SectionTitle(title: String(localized: "Remote Access"))
                // Until the live cloud matrix has run (docs/TESTING.md).
                Pill(label: String(localized: "Experimental"), tone: .warn)
                    .help(String(localized: "Not yet tested with every cloud agent and tunnel."))
                Text(String(localized: "For cloud agents, through a tunnel you run"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Card {
                SettingsRow(title: String(localized: "Remote Access"),
                            caption: String(localized: "Only connections with cloud access turned on can connect.")) {
                    Toggle(String(localized: "Remote Access"),
                           isOn: Binding(get: { model.remoteEnabled }, set: { model.setRemoteAccessEnabled($0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                if model.remoteEnabled {
                    RowDivider()
                    statusRow
                    RowDivider()
                    TunnelGuideRow(model: model)
                    RowDivider()
                    ValueRow(label: String(localized: "Address")) {
                        if let origin = model.remoteOrigin {
                            MonoText(text: origin)
                        } else {
                            Text(String(localized: "Paste the tunnel's address after it's running."))
                                .foregroundStyle(.secondary)
                        }
                    } actions: {
                        Button(model.remoteOrigin == nil ? String(localized: "Add…") : String(localized: "Edit…")) {
                            model.sheet = .remoteAddress
                        }
                    }
                    RowDivider()
                    ValueRow(label: String(localized: "MCP URL")) {
                        if let url = model.remoteMCPURL {
                            MonoText(text: url)
                        } else {
                            Text("—").foregroundStyle(.tertiary)
                        }
                    } actions: {
                        if let url = model.remoteMCPURL {
                            CopyButton(text: url, help: String(localized: "Copy URL"))
                        }
                        Button(String(localized: "Reset Path…")) { model.resetRemoteSecret() }
                    }
                    RowDivider()
                    ValueRow(label: String(localized: "Port")) {
                        MonoText(text: String(model.remotePort))
                    } actions: {
                        Button(String(localized: "Change…")) { model.sheet = .remotePort }
                    }
                    RowDivider()
                    ValueRow(label: String(localized: "Turn off")) {
                        HStack(spacing: 16) {
                            Picker(String(localized: "Turn off automatically"), selection: Binding(
                                get: { model.remoteAutoOff }, set: { model.setRemoteAutoOff($0) })) {
                                ForEach(RemoteDefaults.autoOffChoices, id: \.self) { interval in
                                    Text(Self.autoOffTitle(interval)).tag(interval)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                            if let offAt = model.remoteOffAt {
                                Text(String(localized: "at \(offAt.formatted(date: .omitted, time: .shortened))"))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle(String(localized: "Keep this Mac awake while on power"),
                                   isOn: Binding(get: { model.keepAwake }, set: { model.setKeepAwake($0) }))
                                .toggleStyle(.checkbox)
                                .fixedSize()
                        }
                    } actions: { EmptyView() }
                }
            }
            Label(String(localized: "Port \(String(model.remotePort)) is open only while Remote Access is on. Cloud agents reach this Mac only while it's awake, logged in and running \(AppIdentity.displayName). Remote tokens and cloud apps never work on this Mac's local port, and local tokens never work remotely."),
                  systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusRow: some View {
        ValueRow(label: String(localized: "Status")) {
            HStack(spacing: 10) {
                if let failure = model.remoteFailureText {
                    Pill(label: String(localized: "Couldn't start"), tone: .bad, icon: true)
                    Text(failure).fixedSize(horizontal: false, vertical: true)
                } else if model.remoteOrigin == nil {
                    Pill(label: String(localized: "Waiting for tunnel"), tone: .neutral)
                    Text(String(localized: "Set up a tunnel to port \(String(model.remotePort)), then add its address."))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    switch model.remoteTest {
                    case .notTested:
                        Pill(label: String(localized: "Not tested"), tone: .neutral)
                    case .testing:
                        ProgressView().controlSize(.small)
                        Text(String(localized: "Testing…")).foregroundStyle(.secondary)
                    case .reachable(let rtt, let tunnel, let at):
                        Pill(label: String(localized: "Reachable"), tone: .ok, icon: true)
                        Text(([String(localized: "tested \(RelativeTime.ago(at, now: model.now).lowercased())"),
                               "\(Int((rtt * 1000).rounded())) ms"] + (tunnel.map { [$0] } ?? []))
                            .joined(separator: " · "))
                            .foregroundStyle(.secondary)
                    case .notReachable(let reason, _):
                        Pill(label: String(localized: "Not reachable"), tone: .warn, icon: true)
                        Text(reason).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } actions: {
            if model.remoteFailureText != nil {
                Button(String(localized: "Choose Another Port…")) { model.sheet = .remotePort }
            } else {
                Button(String(localized: "Test")) { model.testRemoteAccess() }
                    .disabled(model.remoteOrigin == nil || model.remoteTest == .testing)
                    .help(String(localized: "Fetch this app's health URL through the tunnel"))
            }
        }
    }

    static func autoOffTitle(_ interval: TimeInterval) -> String {
        switch interval {
        case 0: String(localized: "Never")
        case 3_600: String(localized: "After 1 hour")
        case 28_800: String(localized: "After 8 hours")
        default: String(localized: "After 1 day")
        }
    }
}

/// Provider chips and the commands to run (the app never runs tunnels).
struct TunnelGuideRow: View {
    let model: BridgeAppModel

    var body: some View {
        let provider = model.tunnelChoice
        let hostname = model.remoteOrigin.flatMap(URL.init(string:))?.host
        let commands = provider.commands(port: model.remotePort, hostname: hostname)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Text(String(localized: "Tunnel"))
                    .foregroundStyle(.secondary)
                    .frame(width: 76, alignment: .leading)
                FlowLayout(spacing: 6) {
                    ForEach(TunnelProvider.allCases) { option in
                        AgentChip(title: option.name, selected: option == provider) {
                            model.tunnelChoice = option
                        }
                    }
                }
            }
            if !commands.isEmpty {
                HStack(alignment: .top) {
                    CodeBox(text: commands.joined(separator: "\n"))
                    CopyButton(text: commands.joined(separator: "\n"), help: String(localized: "Copy Commands"))
                }
            }
            if let config = provider.configFile(port: model.remotePort, hostname: hostname) {
                Text(String(localized: "~/.cloudflared/config.yml"))
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                HStack(alignment: .top) {
                    CodeBox(text: config)
                    CopyButton(text: config, help: String(localized: "Copy config.yml"))
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(provider.steps.enumerated()), id: \.offset) { index, step in
                    Text(provider.steps.count == 1 ? step : "\(index + 1). \(step)")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(provider.notes.enumerated()), id: \.offset) { _, note in
                    Label(note, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.callout)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Tunnel setup"))
    }
}

/// The client page's Cloud section (§22.4, §22.7).
struct CloudSection: View {
    let model: BridgeAppModel
    let client: ClientView

    private var agent: CloudAgentKind { model.cloudAgentChoice[client.id] ?? .claudeAI }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: String(localized: "Cloud"))
            // Shown only while Remote Access is on; the client page has a
            // one-line note when it's off (ClientDetailView).
            Card {
                SettingsRow(title: String(localized: "Allow cloud access"),
                            caption: client.cloudAccess ? model.cloudSummary(client)
                                : String(localized: "Off: cloud agents can't use this connection.")) {
                    Toggle(String(localized: "Allow cloud access"), isOn: Binding(
                        get: { client.cloudAccess }, set: { model.setCloudAccess(client.id, $0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                if client.cloudAccess { details }
            }
            if client.cloudAccess {
                Label(String(localized: "Use a separate connection for each cloud agent, with only the access it needs. Turning off Remote Access cuts off every cloud agent at once."),
                      systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var details: some View {
        RowDivider()
        ValueRow(label: String(localized: "Agent")) {
            Picker(String(localized: "Cloud agent"), selection: Binding(
                get: { agent }, set: { model.cloudAgentChoice[client.id] = $0 })) {
                ForEach(CloudAgentKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .labelsHidden()
            .fixedSize()
        } actions: {
            TransportBadge(text: agent.credential == .oauth ? "OAuth"
                           : agent.credential == .bearer ? String(localized: "Token") : "—")
        }
        RowDivider()
        ValueRow(label: String(localized: "URL")) {
            if let url = model.remoteMCPURL {
                MonoText(text: url)
            } else {
                Text(String(localized: "Add the tunnel's address in Settings ▸ Remote Access first."))
                    .foregroundStyle(.secondary)
            }
        } actions: {
            if let url = model.remoteMCPURL { CopyButton(text: url, help: String(localized: "Copy URL")) }
        }
        if let url = model.remoteMCPURL {
            let snippet = agent.snippet(CloudSetupContext(serverKey: AppIdentity.mcpServerKey, mcpURL: url,
                                                          clientName: client.name))
            RowDivider()
            VStack(alignment: .leading, spacing: 8) {
                if snippet.kind != .values || agent.credential == .bearer {
                    HStack {
                        Spacer()
                        CopyButton(text: snippet.text, title: String(localized: "Copy"),
                                   help: String(localized: "Copy the setup for \(agent.displayName)"))
                    }
                    CodeBox(text: snippet.text)
                }
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(snippet.steps.enumerated()), id: \.offset) { index, step in
                        Text(snippet.steps.count == 1 ? step : "\(index + 1). \(step)")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.callout)
                ForEach(Array(agent.warnings.enumerated()), id: \.offset) { _, warning in
                    Label {
                        Text(warning).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .font(.callout)
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
        }
        let connections = model.oauthConnections(client.id)
        if !connections.isEmpty {
            RowDivider()
            ForEach(connections) { connection in
                ValueRow(label: connection.id == connections.first?.id ? String(localized: "Connected") : "") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(connection.appName)
                        Text([String(localized: "Connected \(connection.createdAt.formatted(.dateTime.month(.abbreviated).day()))"),
                              connection.lastUsedAt.map {
                                  String(localized: "last used \(RelativeTime.ago($0, now: model.now).lowercased())")
                              }].compactMap { $0 }.joined(separator: " · "))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } actions: {
                    Button(String(localized: "Revoke"), role: .destructive) { model.revokeConnection(connection) }
                }
            }
        }
        if let last = model.remoteConnections[client.id] {
            RowDivider()
            ValueRow(label: String(localized: "Last use")) {
                Text([last.agent.map { String(localized: "\($0) (as reported)") },
                      RelativeTime.ago(last.at, now: model.now)].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
            } actions: { EmptyView() }
        }
        RowDivider()
        HStack(spacing: 8) {
            if model.pairingClientID == client.id {
                ProgressView().controlSize(.small)
                Text(String(localized: "Pairing is open. Connect the app in its settings now."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if client.hasRemoteToken {
                Button(String(localized: "Reset Remote Token…")) { model.resetRemoteToken(client.id) }
            }
            Button(String(localized: "Copy Remote Token…")) { model.copyRemoteToken(client.id) }
                .modifier(Prominent(on: agent.credential == .bearer))
            if let redirect = agent.preRegisteredRedirectURI {
                Button(String(localized: "Set Up OAuth Client…")) {
                    model.setUpOAuthClient(client.id, appName: agent.displayName, redirectURI: redirect)
                }
                .disabled(model.remoteOrigin == nil)
            }
            Button(String(localized: "Connect a Cloud App…")) { model.connectCloudApp(client.id) }
                .modifier(Prominent(on: agent.credential == .oauth))
                .disabled(model.remoteOrigin == nil)
                .help(model.remoteOrigin == nil
                      ? String(localized: "Add the tunnel's address in Settings first.") : "")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// "claude.ai wants to connect": the code must match the browser's.
struct PairingSheet: View {
    let model: BridgeAppModel
    let id: UUID
    /// Allow is enabled a moment after a request appears, so a click meant for something else
    /// can't approve it.
    @State private var armed = false

    var body: some View {
        let request = model.pairingRequest(id)
        VStack(alignment: .leading, spacing: 14) {
            if let request {
                Text(String(localized: "\(request.appName) wants to connect")).font(.headline)
                Text(String(localized: "It will use the access of “\(model.clientName(request.clientID))” from the internet, through Remote Access."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let url = request.appURL {
                    Text(url).font(.callout.monospaced()).foregroundStyle(.secondary)
                }
                Text(String(localized: "Returns to \(request.redirectHost)"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(request.code)
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .accessibilityLabel(String(localized: "Code \(request.code)"))
                Text(String(localized: "Allow only if the same code is showing in your browser."))
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button(String(localized: "Deny")) { model.answerPairing(id, allow: false) }
                        .keyboardShortcut(.cancelAction)
                    Button(String(localized: "Allow")) { model.answerPairing(id, allow: true) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!armed)
                }
            } else {
                Text(String(localized: "This request expired.")).font(.headline)
                HStack {
                    Spacer()
                    Button(String(localized: "Close")) { model.sheet = nil }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .task(id: id) {
            armed = false
            try? await Task.sleep(for: .seconds(1))
            armed = true
        }
    }
}

/// Gemini Enterprise's OAuth client: the values to enter in its console. The secret is never shown,
/// only copied, and is gone once the sheet closes.
struct OAuthClientSheet: View {
    let model: BridgeAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let details = model.oauthClientDetails {
                Text(String(localized: "OAuth Client for “\(model.clientName(details.bridgeClientID))”"))
                    .font(.headline)
                Text(String(localized: "Enter these values in the app's OAuth settings. Pairing is open for 10 minutes; when the app asks you to sign in, check the code and allow it. If pairing has closed by then, reopen it with Connect a Cloud App… on the connection's page."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                    row(String(localized: "Authorization URL"), details.authorizationURL)
                    row(String(localized: "Token URL"), details.tokenURL)
                    row(String(localized: "Client ID"), details.clientID)
                    GridRow {
                        Text(String(localized: "Client secret")).foregroundStyle(.secondary)
                        Text(OAuthServer.secretPrefix + " ••••••••••••••••")
                            .font(.body.monospaced())
                            .accessibilityLabel(String(localized: "Hidden"))
                        Button(String(localized: "Copy Secret")) { model.copyOAuthClientSecret() }
                    }
                    row(String(localized: "Scopes"), OAuthServer.scope)
                    row(String(localized: "Redirect URI"), details.redirectURI, copy: false)
                }
                Label(String(localized: "You can copy the secret only while this sheet is open. If you lose it, click Set Up OAuth Client… again for a new one."),
                      systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(String(localized: "These details are no longer available.")).font(.headline)
            }
            HStack {
                Spacer()
                Button(String(localized: "Done")) { model.oauthClientDetails = nil; model.sheet = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600)
        .onDisappear { model.oauthClientDetails = nil }
    }

    private func row(_ label: String, _ value: String, copy: Bool = true) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if copy {
                CopyButton(text: value, help: String(localized: "Copy \(label)"))
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
    }
}

/// Settings ▸ Remote Access ▸ Address.
struct RemoteAddressSheet: View {
    let model: BridgeAppModel
    @State private var text = ""
    @State private var submitted: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Tunnel Address")).font(.headline)
            Text(String(localized: "The public https address your tunnel gives this Mac, without a path. For Tailscale Funnel it looks like https://my-mac.tail1234.ts.net."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(String(localized: "Address"), text: $text, prompt: Text("https://my-mac.tail1234.ts.net"))
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(save)
            if let submitted {
                Text(submitted).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { model.sheet = nil }.keyboardShortcut(.cancelAction)
                Button(String(localized: "Save"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            text = model.remoteOrigin ?? ""
            focused = true
        }
    }

    private func save() { submitted = model.setRemoteAddress(text) }
}

/// Settings ▸ Remote Access ▸ Port.
struct RemotePortSheet: View {
    let model: BridgeAppModel
    @State private var text = ""
    @State private var submitted: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Remote Access Port")).font(.headline)
            TextField(String(localized: "Port"), text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
                .onSubmit(save)
            if let submitted {
                Text(submitted).font(.callout).foregroundStyle(.red)
            }
            Text(String(localized: "Point your tunnel at the new port afterwards. It must differ from the MCP server's port."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { model.sheet = nil }.keyboardShortcut(.cancelAction)
                Button(String(localized: "Use This Port"), action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { text = String(model.remotePort) }
    }

    private func save() { submitted = model.changeRemotePort(text) }
}
