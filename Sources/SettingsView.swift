import ServiceManagement
import SwiftUI

/// Settings (§11): General, Developer (its tools off by default) and About.
struct SettingsView: View {
    let model: BridgeAppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    PaneTitle(title: String(localized: "Settings"))
                    general
                    MCPServerSettings(model: model)
                        .id("mcp")
                    RemoteAccessSettings(model: model)
                        .id("remote")
                    developer
                        .id("developer")
                    about
                        .id("about")
                }
                .padding(24)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { scroll(proxy) }
            .onChange(of: model.settingsScrollTarget) { _, _ in scroll(proxy) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let target = model.settingsScrollTarget else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(target, anchor: .top)
            model.settingsScrollTarget = nil
        }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: String(localized: "General"))
            Card {
                SettingsRow(title: String(localized: "Start at login"),
                            caption: AppIdentity.isLiveTest
                                ? String(localized: "Not available in the test copy.")
                                : String(localized: "\(AppIdentity.displayName) also remembers whether it was on.")) {
                    Toggle(String(localized: "Start at login"),
                           isOn: Binding(get: { model.loginItem == .enabled },
                                         set: { model.setStartAtLogin($0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(!model.canChangeStartAtLogin)
                }
                if !model.isInstalledInApplications && !AppIdentity.isLiveTest {
                    RowDivider()
                    NotInApplicationsNotice(model: model)
                } else if model.loginItem == .requiresApproval {
                    RowDivider()
                    SettingsNotice(
                        text: String(localized: "Start at login needs your approval in System Settings."),
                        button: String(localized: "Open Login Items"), action: model.openLoginItemsSettings)
                }
                if let error = model.loginItemError {
                    RowDivider()
                    Label(error, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
                RowDivider()
                SettingsRow(title: String(localized: "Show in Dock"),
                            caption: String(localized: "The menu bar icon is always shown.")) {
                    Picker(String(localized: "Show in Dock"),
                           selection: Binding(get: { model.dockMode }, set: { model.setDockMode($0) })) {
                        ForEach(DockIconMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                RowDivider()
                SettingsRow(title: String(localized: "Check for updates automatically"),
                            caption: updatesCaption) {
                    Toggle(String(localized: "Check for updates automatically"),
                           isOn: Binding(get: { model.automaticUpdateChecks },
                                         set: { model.setAutomaticUpdateChecks($0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(!model.updaterAvailable)
                }
                if model.updaterAvailable {
                    RowDivider()
                    SettingsRow(title: String(localized: "Updates"), caption: lastCheckCaption) {
                        Button(String(localized: "Check for Updates…")) { model.checkForUpdates() }
                    }
                }
            }
        }
    }

    private var updatesCaption: String {
        model.updaterAvailable
            ? String(localized: "Once a day, \(AppIdentity.displayName) asks GitHub for its latest version, sending only your IP address and the app's version. An update installs only when you click.")
            : String(localized: "This copy was built from source and can't update itself. Releases are on GitHub.")
    }

    private var lastCheckCaption: String {
        if let found = model.foundUpdate {
            return String(localized: "Version \(found.version) is available.")
        }
        guard let date = model.lastUpdateCheck else { return String(localized: "Not checked yet.") }
        return String(localized: "Last checked: \(RelativeTime.ago(date, now: model.now)).")
    }

    private var developer: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: String(localized: "Developer"))
            Card {
                SettingsRow(title: String(localized: "Command-line tool"),
                            caption: commandLineToolCaption) {
                    if model.commandLineTool == .installed {
                        Pill(label: String(localized: "Installed"), tone: .ok)
                    } else {
                        Button(String(localized: "Install Command-Line Tool")) { model.installCommandLineTool() }
                            .disabled(model.commandLineTool == .unavailable)
                    }
                }
                RowDivider()
                SettingsRow(title: String(localized: "Show developer tools"),
                            caption: String(localized: "For contributors testing \(AppIdentity.displayName) with throwaway data.")) {
                    Toggle(String(localized: "Show developer tools"),
                           isOn: Binding(get: { model.showDeveloperTools },
                                         set: { model.setShowDeveloperTools($0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                if model.showDeveloperTools {
                    RowDivider()
                    SettingsRow(title: String(localized: "Test calendar and list"),
                                caption: String(localized: "Created by this app, empty, and safe to remove.")) {
                        Pill(label: model.testCollectionsState.label,
                             tone: model.testCollectionsState == .created ? .ok
                                : model.testCollectionsState == .partlyCreated ? .warn : .neutral)
                    }
                    HStack(spacing: 8) {
                        Button(String(localized: "Check Sources")) { model.checkTestSources() }
                        Button(String(localized: "Create Test Collections")) { model.createTestCollections() }
                            .disabled(model.testCollectionsState != .notCreated)
                        Button(String(localized: "Remove Empty Test Collections")) { model.removeTestCollections() }
                            .disabled(model.testCollectionsState == .notCreated)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    RowDivider()
                    SettingsRow(title: String(localized: "Collection IDs"),
                                caption: String(localized: "Every calendar and list EventKit can see, with its ID.")) {
                        Button(String(localized: "Show IDs…")) { model.sheet = .collectionIDs }
                    }
                    RowDivider()
                    SettingsRow(title: String(localized: "MCP traffic since launch"),
                                caption: mcpTraffic) {
                        EmptyView()
                    }
                    RowDivider()
                    SettingsRow(title: String(localized: "Data folder"),
                                caption: (model.dataFolderPath as NSString).abbreviatingWithTildeInPath,
                                monospacedCaption: true) {
                        Button { model.revealDataFolder() } label: {
                            Label(String(localized: "Show in Finder"), systemImage: "folder")
                        }
                    }
                }
            }
            if model.showDeveloperTools, let output = model.developerOutput {
                Card {
                    HStack(alignment: .top) {
                        Text(output)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        CopyButton(text: output, help: String(localized: "Copy Output"))
                            .buttonStyle(.borderless)
                    }
                    .padding(14)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(String(localized: "Output"))
            }
        }
    }

    private var commandLineToolCaption: String {
        switch model.commandLineTool {
        case .installed:
            String(localized: "bridge-client is in ~/.local/bin and runs this copy of the app’s command-line tool.")
        case .notInstalled where model.cliLinkedByHomebrew:
            String(localized: "Homebrew already linked bridge-client to this copy of the app. Installing also adds it to ~/.local/bin.")
        case .notInstalled:
            String(localized: "Adds bridge-client to ~/.local/bin for scripts and Terminal. No administrator password needed.")
        case .elsewhere:
            String(localized: "~/.local/bin/bridge-client points to another copy of the app. Install it again to use this one.")
        case .unavailable:
            String(localized: "This copy of the app has no bridge-client.")
        }
    }

    /// Counts only, never bodies.
    private var mcpTraffic: String {
        let counts = model.mcpCounters
        var parts = [String(localized: "\(counts.requests) requests"),
                     String(localized: "\(counts.authFailures) failed authentications")]
        parts += counts.byStatus.keys.sorted().map { String(localized: "\(counts.byStatus[$0]!) × \(String($0))") }
        return parts.joined(separator: " · ")
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: String(localized: "About"))
            Card {
                SettingsRow(title: AppIdentity.displayName,
                            caption: String(localized: "Scoped Calendar and Reminders access for tools on your Mac.")) {
                    Text(String(localized: "Version \(AppIdentity.version) (\(AppIdentity.build))"))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                RowDivider()
                SettingsRow(title: String(localized: "Setup checklist"),
                            caption: model.canShowSetupAgain || model.showsSetupChecklist
                                ? String(localized: "The first-run steps on Overview.")
                                : String(localized: "Setup is complete.")) {
                    Button(String(localized: "Show Setup Checklist")) { model.showSetupAgain() }
                        .disabled(!model.canShowSetupAgain)
                }
                RowDivider()
                // The Help menu's links, wrapped onto two lines when narrow.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { links(AppLinks.documentation + AppLinks.community) }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 16) { links(AppLinks.documentation) }
                        HStack(spacing: 16) { links(AppLinks.community) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }
}

private func links(_ items: [AppLinks.Item]) -> some View {
    ForEach(items, id: \.url) { link in
        Link(link.title, destination: link.url)
            .fixedSize()
    }
}

struct RowDivider: View {
    var body: some View { Divider().padding(.leading, 16) }
}

struct SettingsRow<Control: View>: View {
    let title: String
    var caption: String? = nil
    var monospacedCaption = false
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let caption {
                    Text(caption)
                        .font(monospacedCaption ? .callout.monospaced() : .callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }
}

struct SettingsNotice: View {
    let text: String
    let button: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(button, action: action)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// The one warning for an app outside Applications (Settings ▸ General,
/// Settings ▸ MCP Server, Connect), with the fix.
struct NotInApplicationsNotice: View {
    let model: BridgeAppModel
    /// Inside a card row: the row's own padding.
    var padded = true

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(String(localized: "\(AppIdentity.displayName) isn't in Applications. Start at login and agent setups need it there."))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(String(localized: "Move to Applications…")) { model.beginMoveToApplications() }
        }
        .padding(.horizontal, padded ? 16 : 0)
        .padding(.vertical, padded ? 10 : 0)
    }
}

/// Settings ▸ MCP Server (§13.4), with the Ask before changes defaults.
struct MCPServerSettings: View {
    let model: BridgeAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: String(localized: "MCP Server"))
            Card {
                SettingsRow(title: String(localized: "MCP server"),
                            caption: String(localized: "Lets AI agents on this Mac connect. Each agent still needs a connection with access.")) {
                    Toggle(String(localized: "MCP server"),
                           isOn: Binding(get: { model.mcpEnabled }, set: { model.setMCPServerEnabled($0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                RowDivider()
                statusRow
                if model.mcpPortInUse {
                    HStack(spacing: 8) {
                        Spacer()
                        Button(String(localized: "Try Again")) { model.retryMCPServer() }
                        Button(String(localized: "Choose Another Port…")) { model.sheet = .mcpPort }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
                RowDivider()
                ValueRow(label: String(localized: "Port")) {
                    MonoText(text: String(model.mcpPort))
                } actions: {
                    Button(String(localized: "Change…")) { model.sheet = .mcpPort }
                }
                RowDivider()
                ValueRow(label: String(localized: "Launcher")) {
                    MonoText(text: model.launcherPath)
                } actions: {
                    CopyButton(text: model.launcherPath, help: String(localized: "Copy Path"))
                    Button { model.revealLauncher() } label: { Image(systemName: "folder") }
                        .help(String(localized: "Show in Finder"))
                        .accessibilityLabel(String(localized: "Show in Finder"))
                }
                if !model.isInstalledInApplications {
                    RowDivider()
                    NotInApplicationsNotice(model: model)
                }
                RowDivider()
                ValueRow(label: String(localized: "Today")) {
                    Text(model.mcpTodayText)
                } actions: {
                    if model.activity.contains(where: \.isMCP) {
                        Button(String(localized: "Show in Activity")) {
                            model.activityVia = .mcp
                            model.openActivity(keepingVia: true)
                        }
                        .buttonStyle(.link)
                    }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(localized: "Ask before changes")).font(.headline)
                Text(String(localized: "Each connection can be changed on its page. Reads never ask."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 6)
            Card {
                SettingsRow(title: String(localized: "New AI agent connections")) {
                    approvalPicker(.agent)
                }
                RowDivider()
                SettingsRow(title: String(localized: "New command-line connections")) {
                    approvalPicker(.cli)
                }
                RowDivider()
                SettingsRow(title: String(localized: "Set every existing connection to one mode.")) {
                    Menu(String(localized: "Apply to All Connections…")) {
                        Button(String(localized: "Ask me first")) { model.applyApprovalToAll(.ask) }
                        Button(String(localized: "Allow without asking")) { model.applyApprovalToAll(.allow) }
                    }
                    .fixedSize()
                    .disabled(model.activeClients.isEmpty)
                }
            }
        }
    }

    private var statusRow: some View {
        ValueRow(label: String(localized: "Status")) {
            HStack(spacing: 10) {
                if !model.mcpEnabled {
                    Pill(label: String(localized: "Off"), tone: .neutral)
                } else {
                    switch model.mcpStatus {
                    case .listening:
                        Pill(label: String(localized: "Listening"), tone: .ok, icon: true)
                        MonoText(text: model.mcpURL)
                    case .failed:
                        Pill(label: String(localized: "Couldn't start"), tone: .bad, icon: true)
                        Text(model.mcpFailureText ?? "").fixedSize(horizontal: false, vertical: true)
                    case .starting, .off:
                        ProgressView().controlSize(.small)
                        Text(String(localized: "Starting…")).foregroundStyle(.secondary)
                    }
                }
            }
        } actions: {
            if model.mcpIsListening {
                CopyButton(text: model.mcpURL, help: String(localized: "Copy URL"))
            } else if model.mcpEnabled, !model.mcpPortInUse, case .failed = model.mcpStatus {
                Button(String(localized: "Try Again")) { model.retryMCPServer() }
            }
        }
    }

    private func approvalPicker(_ kind: ClientKind) -> some View {
        Picker(kind == .cli ? String(localized: "New command-line connections") : String(localized: "New AI agent connections"),
               selection: Binding(get: { model.defaultApproval(for: kind) },
                                  set: { model.setNewClientApproval($0, for: kind) })) {
            Text(String(localized: "Ask me first")).tag(ApprovalMode.ask)
            Text(String(localized: "Allow without asking")).tag(ApprovalMode.allow)
        }
        .labelsHidden()
        .fixedSize()
    }
}

/// A label, a value and trailing buttons, as in the Connect card.
struct ValueRow<Value: View, Actions: View>: View {
    let label: String
    @ViewBuilder var value: Value
    @ViewBuilder var actions: Actions

    var body: some View {
        ConnectRow(label: label, value: { value }, actions: { actions })
    }
}

