import SwiftUI

// Remote Access (§22.7): the Settings card, the client page's Cloud section,
// the pairing sheet, and the address and port sheets. Remote tokens are never
// displayed; Copy Remote Token… asks first.

/// The Remote Access page (B10, mockup 08): an introduction until it's set
/// up, a four-step guide (choose a tunnel, turn on and start it, paste its
/// address, test), then status and settings.
struct RemoteAccessPage: View {
    let model: BridgeAppModel

    private enum Mode { case intro, guide, setUp }

    private var mode: Mode {
        if model.remoteGuideActive { return .guide }
        if model.remoteOrigin != nil { return .setUp }
        return model.remoteEnabled ? .guide : .intro
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                switch mode {
                case .intro: intro
                case .guide: RemoteGuideView(model: model)
                case .setUp: RemoteSetUpView(model: model)
                }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: model.remoteGuideStep) { _, step in
            if step == .done { model.remoteGuideActive = false }
        }
        // Is the tunnel running on this Mac? (plan 08 §5.4)
        .onAppear { model.checkTunnelNow() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                PaneTitle(title: String(localized: "Remote Access"))
                // Until the live cloud matrix has run (docs/TESTING.md).
                Pill(label: String(localized: "Experimental"), tone: .warn)
                    .help(String(localized: "Not yet tested with every cloud agent and tunnel."))
                Spacer()
                if mode == .setUp {
                    Toggle(String(localized: "Remote Access"),
                           isOn: Binding(get: { model.remoteEnabled }, set: { model.setRemoteAccessEnabled($0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
            // Kept inline: it says what turning this on exposes.
            Text(String(localized: "Lets cloud agents (claude.ai, ChatGPT, cloud coding agents) reach this Mac through a tunnel you run. Off by default; one click turns it off."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Label(String(localized: "Only connections you allow can be used from the cloud, each with its own token or signed-in app, and only while this Mac is awake and running \(AppIdentity.displayName)."),
                          systemImage: "lock")
                    Label(String(localized: "Agents on this Mac don't need it: they connect locally."),
                          systemImage: "desktopcomputer")
                }
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(String(localized: "Set Up Remote Access…")) { model.remoteGuideActive = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }
}

/// The guide's four steps.
struct RemoteGuideView: View {
    let model: BridgeAppModel
    @State private var address = ""
    @State private var addressIssue: String?

    var body: some View {
        let step = model.remoteGuideStep
        VStack(alignment: .leading, spacing: 14) {
            RemoteGuideHeader(current: step)
            switch step {
            case .chooseTunnel: chooseTunnel
            case .startTunnel: startTunnel
            case .pasteAddress: pasteAddress
            case .test, .done: test
            }
        }
    }

    private var chooseTunnel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card {
                ForEach(Array(TunnelProvider.allCases.enumerated()), id: \.element) { index, provider in
                    if index > 0 { RowDivider() }
                    Button {
                        model.tunnelChoice = provider
                        model.remoteGuideActive = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: provider == model.tunnelChoice ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(provider == model.tunnelChoice ? Color.accentColor : Color.secondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.displayName)
                                Text(provider.summary).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(RowButtonStyle())
                    .accessibilityLabel("\(provider.displayName). \(provider.summary)")
                }
            }
        }
    }

    private var startTunnel: some View {
        let provider = model.tunnelChoice
        let hostname = model.remoteOrigin.flatMap(URL.init(string:))?.host
        let commands = provider.commands(port: model.remotePort, hostname: hostname)
        return VStack(alignment: .leading, spacing: 12) {
            Card {
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name).font(.headline)
                    HStack(spacing: 4) {
                        Text(provider.summary).foregroundStyle(.secondary)
                        Button(String(localized: "Change tunnel")) { model.chooseTunnelAgain() }
                            .buttonStyle(.link)
                    }
                    .font(.callout)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                RowDivider()
                if !model.remoteEnabled {
                    HStack(spacing: 12) {
                        Text(String(localized: "First, turn on Remote Access. Port \(String(model.remotePort)) opens on this Mac for the tunnel; nothing is reachable until the tunnel runs."))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 12)
                        Button(String(localized: "Turn On Remote Access")) { model.setRemoteAccessEnabled(true) }
                            .buttonStyle(.borderedProminent)
                            .fixedSize()
                    }
                    .padding(16)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        if !commands.isEmpty {
                            HStack(alignment: .top) {
                                CodeBox(text: commands.joined(separator: "\n"))
                                CopyButton(text: commands.joined(separator: "\n"), title: String(localized: "Copy"),
                                           help: String(localized: "Copy Commands"))
                            }
                        }
                        if let config = provider.configFile(port: model.remotePort, hostname: hostname) {
                            Text("~/.cloudflared/config.yml").font(.callout.monospaced()).foregroundStyle(.secondary)
                            HStack(alignment: .top) {
                                CodeBox(text: config)
                                CopyButton(text: config, help: String(localized: "Copy config.yml"))
                            }
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(String(localized: "Run it in Terminal. It prints the tunnel's https address; you paste it next."))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            InfoButton(text: (provider.steps + provider.notes).joined(separator: "\n\n"))
                        }
                        .font(.callout)
                    }
                    .padding(16)
                }
            }
            HStack {
                Spacer()
                Button(String(localized: "Back")) { model.chooseTunnelAgain() }
                Button(String(localized: "I've Started It")) { model.remoteTunnelStarted = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.remoteEnabled)
            }
        }
    }

    private var pasteAddress: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "The tunnel's public https address, without a path. For Tailscale Funnel it looks like https://my-mac.tail1234.ts.net."))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField(String(localized: "Address"), text: $address, prompt: Text("https://my-mac.tail1234.ts.net"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                        .accessibilityLabel(String(localized: "Tunnel address"))
                    if let addressIssue {
                        Text(addressIssue).font(.callout).foregroundStyle(.red)
                    }
                }
                .padding(16)
            }
            HStack {
                Spacer()
                Button(String(localized: "Back")) {
                    model.remoteTunnelStarted = false
                    model.remoteEditingAddress = false
                }
                Button(String(localized: "Save Address"), action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear { address = model.remoteOrigin ?? "" }
    }

    private func save() {
        addressIssue = model.setRemoteAddress(address)
        if addressIssue == nil { model.testRemoteAccess() }
    }

    private var test: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card {
                HStack(spacing: 10) {
                    switch model.remoteTest {
                    case .notTested, .testing:
                        ProgressView().controlSize(.small)
                        Text(String(localized: "Testing \(model.remoteOrigin ?? "")…")).foregroundStyle(.secondary)
                    case .reachable:
                        Pill(label: String(localized: "Reachable"), tone: .ok, icon: true)
                    case .notReachable(let reason, _):
                        Pill(label: String(localized: "Not reachable"), tone: .warn, icon: true)
                        Text(reason).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .padding(16)
            }
            if case .notReachable = model.remoteTest {
                HStack {
                    Spacer()
                    Button(String(localized: "Back")) { model.remoteEditingAddress = true }
                    Button(String(localized: "Try Again")) { model.testRemoteAccess() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .onAppear { if model.remoteTest == .notTested { model.testRemoteAccess() } }
    }
}

/// ① Choose a tunnel ② Start it ③ Paste its address ④ Test.
struct RemoteGuideHeader: View {
    let current: RemoteGuide.Step

    var body: some View {
        HStack(spacing: 0) {
            ForEach([RemoteGuide.Step.chooseTunnel, .startTunnel, .pasteAddress, .test], id: \.rawValue) { step in
                let done = step.rawValue < current.rawValue
                let isCurrent = step == current || (current == .done && step == .test)
                HStack(spacing: 8) {
                    ZStack {
                        Circle().strokeBorder(done ? Color.green : isCurrent ? Color.primary : Color.secondary,
                                              lineWidth: 1.5)
                        if done {
                            Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.green)
                        } else {
                            Text("\(step.rawValue)").font(.caption.weight(.semibold))
                        }
                    }
                    .frame(width: 22, height: 22)
                    Text(title(step))
                        .fontWeight(isCurrent ? .semibold : .regular)
                        .foregroundStyle(done ? Color.green : isCurrent ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isCurrent ? Color.accentColor.opacity(0.08) : Color.clear)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(String(localized: "Step \(step.rawValue), \(title(step)), \(done ? String(localized: "done") : isCurrent ? String(localized: "current") : String(localized: "not done"))"))
                if step != .test { Divider() }
            }
        }
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Palette.separator.opacity(0.6), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func title(_ step: RemoteGuide.Step) -> String {
        switch step {
        case .chooseTunnel: String(localized: "Choose a tunnel")
        case .startTunnel: String(localized: "Start it")
        case .pasteAddress: String(localized: "Paste its address")
        case .test, .done: String(localized: "Test")
        }
    }
}

/// Set up: status, address, URL, port, turn-off timer, keep awake, the
/// tunnel, and the connections that can be used from the cloud.
struct RemoteSetUpView: View {
    let model: BridgeAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card {
                statusRow
                RowDivider()
                ValueRow(label: String(localized: "Address")) {
                    if let origin = model.remoteOrigin {
                        MonoText(text: origin)
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                } actions: {
                    Button(String(localized: "Edit…")) { model.sheet = .remoteAddress }
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
                                Text(RemoteAccessPage.autoOffTitle(interval)).tag(interval)
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
                RowDivider()
                ValueRow(label: String(localized: "Tunnel")) {
                    Text(model.tunnelChoice.name)
                } actions: {
                    Button(String(localized: "Change")) { model.chooseTunnelAgain() }
                        .buttonStyle(.link)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(title: String(localized: "Cloud access"))
                if model.cloudClients.isEmpty {
                    Text(String(localized: "No connection can be used from the cloud yet. Turn on Allow cloud access on a connection's Connect tab."))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    CardRows(data: model.cloudClients) { client in
                        Button {
                            model.clientTab[client.id] = .connect
                            model.clientScrollTarget = "cloud"
                            model.navigate(to: .client(client.id))
                        } label: {
                            HStack(spacing: 10) {
                                AvatarView(name: client.name, id: client.id, size: 24)
                                Text(client.name)
                                Spacer()
                                Text(String(localized: "Connect ▸ From the cloud")).foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(RowButtonStyle())
                    }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(localized: "Use a separate connection for each cloud agent, with only the access it needs."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                InfoButton(text: String(localized: "Port \(String(model.remotePort)) is open only while Remote Access is on. Cloud agents reach this Mac only while it's awake, logged in and running \(AppIdentity.displayName).\n\nRemote tokens and cloud apps never work on this Mac's local port, and local tokens never work remotely. Turning off Remote Access cuts off every cloud agent at once."))
            }
            .font(.callout)
        }
    }

    private var statusRow: some View {
        ValueRow(label: String(localized: "Status")) {
            HStack(spacing: 10) {
                if !model.remoteEnabled {
                    Pill(label: String(localized: "Off"), tone: .neutral)
                } else if let failure = model.remoteFailureText {
                    Pill(label: String(localized: "Couldn't start"), tone: .bad, icon: true)
                    Text(failure).fixedSize(horizontal: false, vertical: true)
                } else if model.remoteOrigin == nil {
                    Pill(label: String(localized: "Waiting for tunnel"), tone: .neutral)
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
            } else if model.remoteEnabled {
                Button(String(localized: "Test")) { model.testRemoteAccess() }
                    .disabled(model.remoteOrigin == nil || model.remoteTest == .testing)
                    .help(String(localized: "Fetch this app's health URL through the tunnel"))
            }
        }
    }
}

extension RemoteAccessPage {
    static func autoOffTitle(_ interval: TimeInterval) -> String {
        switch interval {
        case 0: String(localized: "Never")
        case 3_600: String(localized: "After 1 hour")
        case 28_800: String(localized: "After 8 hours")
        default: String(localized: "After 1 day")
        }
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
                // "Use a separate connection for each cloud agent" lives on the Remote Access page (B13).
                EmptyView()
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
                Text(String(localized: "Add the tunnel's address on the Remote Access page first."))
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
                    HStack(spacing: 4) {
                        Text(String(localized: "About \(agent.displayName)")).font(.callout).foregroundStyle(.secondary)
                        InfoButton(text: footnote)
                    }
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
                      ? String(localized: "Add the tunnel's address on the Remote Access page first.") : "")
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

/// the Remote Access page ▸ Address.
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

/// the Remote Access page ▸ Port.
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
