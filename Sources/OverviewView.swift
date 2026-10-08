import EventKit
import SwiftUI

struct OverviewView: View {
    let model: BridgeAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if model.renameNoticePending {
                    RenameNotice(model: model)
                }
                if model.showsUpdateCard {
                    UpdateCard(model: model)
                }
                if !model.policyStoreAvailable {
                    PolicyUnavailableCard(model: model)
                }
                if let failure = model.mcpFailureText {
                    BannerView(banner: Banner(
                        kind: .warning, title: String(localized: "The MCP server couldn't start."),
                        message: failure,
                        actionTitle: model.mcpPortInUse ? String(localized: "Choose Another Port…")
                                                        : String(localized: "Try Again"),
                        action: { model.mcpPortInUse ? (model.sheet = .mcpPort) : model.retryMCPServer() }))
                }
                if model.showsSetupChecklist {
                    SetupChecklistView(model: model)
                } else {
                    BridgeStatusCard(model: model)
                    TodayLine(model: model)
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(title: String(localized: "macOS access"))
                        Card {
                            AccessStatusRow(model: model, resource: .calendar)
                            Divider().padding(.leading, 52)
                            AccessStatusRow(model: model, resource: .reminderList)
                        }
                    }
                    if model.policyStoreAvailable {
                        OverviewClients(model: model)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Shown once after the move from EventKit Bridge (`RenameMigration`), until dismissed.
struct RenameNotice: View {
    let model: BridgeAppModel

    var body: some View {
        BannerView(banner: Banner(
            kind: .info,
            title: String(localized: "\(LegacyIdentity.displayName) is now \(AppIdentity.displayName)."),
            message: message),
            onDismiss: { model.dismissRenameNotice() })
    }

    private var message: String {
        var text = String(localized: "Your settings, connections and Activity moved over. macOS asks for Calendar and Reminders access once more. Copy each agent's setup again from its connection's Connect ▸ AI agent: the launcher moved, and the server is now \(AppIdentity.mcpServerKey) (tools mcp__\(AppIdentity.mcpServerKey)__…). Then delete the old app, so it can't start again at login.")
        if model.commandLineTool == .elsewhere {
            text += " " + String(localized: "Install the command-line tool again from Settings ▸ Developer.")
        }
        return text
    }
}

/// An update a scheduled check found (Sparkle's gentle reminder). Install
/// Update opens Sparkle's window with the release notes; nothing installs
/// without a click there.
struct UpdateCard: View {
    let model: BridgeAppModel

    var body: some View {
        if let update = model.foundUpdate {
            BannerView(banner: Banner(
                kind: update.critical ? .warning : .info,
                title: update.critical
                    ? String(localized: "A security update is available: version \(update.version).")
                    : String(localized: "Version \(update.version) is available."),
                message: String(localized: "See what's new, then install it. \(AppIdentity.displayName) restarts, and your access, connections and agent setups stay as they are."),
                actionTitle: String(localized: "Install Update…"),
                action: { model.checkForUpdates() }),
                onDismiss: update.critical ? nil : { model.dismissFoundUpdate() })
        }
    }
}

struct PolicyUnavailableCard: View {
    let model: BridgeAppModel

    var body: some View {
        BannerView(banner: Banner(
            kind: .error, title: String(localized: "Connection settings can't be read."),
            message: String(localized: "The file in the data folder has unexpected permissions or contents, so agents and scripts can't connect. Quit other copies of the app, then check the folder."),
            actionTitle: String(localized: "Show in Finder"),
            action: { model.revealDataFolder() }))
    }
}

struct BridgeStatusCard: View {
    let model: BridgeAppModel

    var body: some View {
        Card {
            HStack(alignment: .center, spacing: 16) {
                AppIconTile(dimmed: !model.bridge.isOn)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.title2.weight(.semibold))
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let line = model.mcpStatusLine {
                        Label(line, systemImage: "server.rack")
                            .foregroundStyle(model.mcpFailureText == nil ? Color.secondary : Color.orange)
                            .font(.callout)
                    }
                    if let remote = model.remoteStatusLine {
                        Label(remote, systemImage: "globe")
                            .foregroundStyle(model.remoteFailureText == nil ? Color.secondary : Color.orange)
                            .font(.callout)
                    }
                    if case .failed = model.bridge {
                        Button(String(localized: "Try Again")) { model.setBridgeEnabled(true) }
                            .padding(.top, 4)
                    }
                }
                Spacer(minLength: 12)
                Toggle(isOn: Binding(get: { model.bridge.isOn },
                                     set: { model.setBridgeEnabled($0) })) {
                    Text(AppIdentity.displayName)
                }
                .toggleStyle(.switch)
                .controlSize(.large)
                .labelsHidden()
                .disabled(!model.policyStoreAvailable && !model.bridge.isOn)
                .accessibilityLabel(AppIdentity.displayName)
                .accessibilityValue(model.bridge.isOn ? String(localized: "On") : String(localized: "Paused"))
            }
            .padding(18)
        }
    }

    private var title: String {
        model.bridge.isOn ? String(localized: "\(AppIdentity.displayName) is on")
                          : String(localized: "\(AppIdentity.displayName) is paused")
    }

    private var subtitle: String {
        switch model.bridge {
        case .on:
            let count = model.activeClients.count - model.pausedCount
            let text = count == 1
                ? String(localized: "1 connection can use what you've allowed.")
                : String(localized: "\(count) connections can use what you've allowed.")
            return model.pausedCount == 0 ? text
                : text + " " + String(localized: "\(model.pausedCount) paused.")
        case .off:
            return String(localized: "Agents and scripts are refused until you turn it on. Their access is kept.")
        case .failed(let reason):
            return String(localized: "\(AppIdentity.displayName) couldn't start. \(reason)")
        }
    }
}

/// The app icon as a status tile, dimmed while EK Bridge is paused.
struct AppIconTile: View {
    var dimmed = false
    var size: CGFloat = 48

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .saturation(dimmed ? 0 : 1)
            .opacity(dimmed ? 0.55 : 1)
            .accessibilityHidden(true)
    }
}

struct TodayLine: View {
    let model: BridgeAppModel

    var body: some View {
        HStack {
            Text(text).foregroundStyle(.secondary)
            Spacer()
            if !model.activity.isEmpty {
                Button(String(localized: "View Activity")) { model.navigate(to: .activity) }
                    .buttonStyle(.link)
            }
        }
        .padding(.horizontal, 4)
    }

    private var text: String {
        let today = ActivityStats.today(model.activity, now: model.now)
        guard let last = today.last else { return String(localized: "No requests yet.") }
        var parts = [today.requests == 1 ? String(localized: "Today: 1 request")
                                         : String(localized: "Today: \(today.requests) requests")]
        if today.notAllowed > 0 { parts.append(String(localized: "\(today.notAllowed) not allowed")) }
        parts.append(String(localized: "last \(RelativeTime.ago(last, now: model.now).lowercased())"))
        return parts.joined(separator: " · ")
    }
}

struct OverviewClients: View {
    let model: BridgeAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: String(localized: "Connections"),
                         subtitle: String(localized: "Each connection has its own key and access."))
            if model.activeClients.isEmpty {
                Card {
                    Text(String(localized: "No connections yet. A connection is one agent or script with its own key."))
                        .foregroundStyle(.secondary)
                        .padding(16)
                }
            } else {
                CardRows(data: model.activeClients) { client in
                    Button { model.navigate(to: .client(client.id)) } label: {
                        OverviewClientRow(model: model, client: client)
                    }
                    .buttonStyle(RowButtonStyle())
                }
            }
            NewClientButton(model: model)
                .padding(.top, 4)
        }
    }
}

struct NewClientButton: View {
    let model: BridgeAppModel
    var prominent = false

    var body: some View {
        Button { model.beginNewClient() } label: {
            Label(String(localized: "Add a Connection…"), systemImage: "plus")
        }
        .modifier(Prominent(on: prominent))
        .disabled(!model.canCreateClient)
        .help(model.canCreateClient ? ""
              : String(localized: "You have 32 connections, the maximum. Remove one to add another."))
    }
}

struct OverviewClientRow: View {
    let model: BridgeAppModel
    let client: ClientView

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: client.name, id: client.id, size: 34)
                .opacity(client.paused ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(client.name).font(.body.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    if let badge = ClientTransport(client).badge {
                        TransportBadge(text: badge)
                    }
                    Text([model.agentSubtitle(client),
                          AccessSummary.text(grants: client.grants, collections: model.collections,
                                             hidden: model.hiddenResources,
                                             unavailableName: model.unavailableName)]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if AccessSummary.hasUngrantableBits(grants: client.grants, collections: model.collections) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help(String(localized: "Some access can't apply: a calendar or list is read only. Open the connection to review it."))
                            .accessibilityLabel(String(localized: "Some access can't apply"))
                    }
                }
            }
            Spacer(minLength: 12)
            if client.paused {
                Pill(label: String(localized: "Paused"), tone: .neutral)
            }
            Text(model.lastRequest(for: client.id).map { RelativeTime.ago($0, now: model.now) }
                 ?? String(localized: "No requests yet"))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// "MCP", "CLI" or "MCP + CLI" before a client's access summary.
struct TransportBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1))
            .fixedSize()
            .accessibilityLabel(text == "CLI" ? String(localized: "command line") : text)
    }
}

/// A full-width row that highlights on press, like a table row.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.primary.opacity(0.06) : Color.clear)
    }
}

// MARK: - Setup checklist (§6)

struct SetupChecklistView: View {
    let model: BridgeAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                PaneTitle(title: String(localized: "Set up \(AppIdentity.displayName)"))
                Text(String(localized: "Let tools on this Mac use the calendars and lists you choose. Requests never leave this Mac."))
                    .foregroundStyle(.secondary)
            }
            if let name = model.setupJustCompletedName {
                Card {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.green)
                        Text(String(localized: "\(name) connected. You're all set."))
                            .font(.title3.weight(.semibold))
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .transition(.opacity)
            } else {
                let input = model.checklistInput
                let states = SetupChecklist.states(input)
                let steps = SetupChecklist.steps(input)
                Card {
                    ForEach(Array(steps.enumerated()), id: \.element) { index, step in
                        if index > 0 { Divider().padding(.leading, 56) }
                        SetupStepRow(model: model, step: step, number: index + 1,
                                     state: states[step] ?? .pending,
                                     focus: SetupChecklist.focusClient(input))
                    }
                }
                Label(String(localized: "A connection is one agent or script with its own key. Give each one its own connection so you can see and remove it separately."),
                      systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.updaterAvailable {
                    // The one request that leaves this Mac, so it's named here.
                    Toggle(isOn: Binding(get: { model.automaticUpdateChecks },
                                         set: { model.setAutomaticUpdateChecks($0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "Check for updates automatically"))
                            Text(String(localized: "Once a day, asks GitHub for the latest version, sending only your IP address and the app's version. Change it any time in Settings."))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                HStack {
                    Spacer()
                    Button(String(localized: "Hide Setup")) { model.hideSetup() }
                        .buttonStyle(.link)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.setupJustCompletedName)
    }
}

struct SetupStepRow: View {
    let model: BridgeAppModel
    let step: SetupChecklist.Step
    let number: Int
    let state: SetupChecklist.State
    let focus: ClientView?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            indicator
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(isFinished ? .regular : .semibold))
                    .foregroundStyle(isFinished ? .secondary : .primary)
                if !isFinished, let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 16)
        // Finished steps collapse to one quiet line.
        .padding(.vertical, isFinished ? 7 : 12)
        .background(state == .current ? Color.accentColor.opacity(0.07) : Color.clear)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
    }

    private var isFinished: Bool { state == .done || state == .skipped }

    private var accessibilityText: String {
        let status: String = switch state {
        case .done: String(localized: "done")
        case .skipped: String(localized: "skipped")
        case .current: String(localized: "next step")
        case .optional: String(localized: "optional")
        case .pending: String(localized: "not done")
        }
        return String(localized: "Step \(number), \(title), \(status)")
    }

    @ViewBuilder private var indicator: some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.white, .green)
                .frame(width: 26)
        case .skipped:
            Image(systemName: "minus.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.white, .secondary)
                .frame(width: 26)
        case .current:
            Text("\(number)")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
        case .pending, .optional:
            Text("\(number)")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .overlay(Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.5))
        }
    }

    private var clientName: String { focus?.name ?? String(localized: "the connection") }

    private var title: String {
        if state == .done { return doneTitle }
        if state == .skipped {
            switch step {
            case .calendarAccess: return String(localized: "Calendar access skipped")
            case .remindersAccess: return String(localized: "Reminders access skipped")
            default: break
            }
        }
        return nextTitle
    }

    /// Finished steps read as what happened.
    private var doneTitle: String {
        switch step {
        case .calendarAccess: String(localized: "Calendar access allowed")
        case .remindersAccess: String(localized: "Reminders access allowed")
        case .createClient: String(localized: "Connection added")
        case .chooseAccess: String(localized: "Access chosen")
        case .turnOn: String(localized: "\(AppIdentity.displayName) turned on")
        case .mcpServer: String(localized: "MCP server turned on")
        case .testRequest: String(localized: "Tool connected")
        }
    }

    private var nextTitle: String {
        switch step {
        case .calendarAccess: String(localized: "Allow Calendar access")
        case .remindersAccess: String(localized: "Allow Reminders access")
        case .createClient: String(localized: "Add a connection")
        case .chooseAccess: String(localized: "Choose what \(clientName) can use")
        case .turnOn: String(localized: "Turn on \(AppIdentity.displayName)")
        case .mcpServer: String(localized: "Turn on the MCP server")
        case .testRequest: String(localized: "Connect your tool")
        }
    }

    private var detail: String? {
        switch step {
        case .calendarAccess, .remindersAccess:
            let resource: ClientResource = step == .calendarAccess ? .calendar : .reminderList
            if model.accessRequestDeclined.contains(resource) {
                return String(localized: "You chose not to allow access. You can change this in System Settings.")
            }
            if state == .optional {
                return step == .calendarAccess
                    ? String(localized: "Optional. Skip it if your tools only use reminders.")
                    : String(localized: "Optional. Skip it if your tools only use calendars.")
            }
            return AccessText.detail(resource, model.status(resource))
        case .createClient:
            return String(localized: "Name the tool or script that will connect. It gets its own key.")
        case .chooseAccess:
            return String(localized: "Pick calendars and lists, and what it can do with each. It has no access yet.")
        case .turnOn:
            return String(localized: "Agents and scripts can only connect while it's on. Your choice is kept after a restart.")
        case .mcpServer:
            return String(localized: "Lets AI agents on this Mac connect. Listens on this Mac only.")
        case .testRequest:
            if focus?.hasMCPToken == true {
                return String(localized: "Copy the setup for your agent, then ask it something like “What's on my calendar today?”")
            }
            if focus == nil {
                return String(localized: "Connect your agent, then ask it something like “What's on my calendar today?”")
            }
            return model.cliCommand == .source
                ? String(localized: "Copy the command and run it in Terminal, in the ek-bridge folder. This step completes when the request arrives.")
                : String(localized: "Copy the command and run it in Terminal. This step completes when the request arrives.")
        }
    }

    @ViewBuilder private var trailing: some View {
        let prominent = state == .current
        switch step {
        case .calendarAccess, .remindersAccess:
            let resource: ClientResource = step == .calendarAccess ? .calendar : .reminderList
            HStack(spacing: 10) {
                if state == .optional {
                    Button(String(localized: "Skip")) { model.skipSetupStep(step) }
                        .buttonStyle(.link)
                }
                if state != .skipped {
                    AccessStatusControls(model: model, resource: resource, prominent: prominent)
                }
            }
        case .createClient:
            if state == .done, let focus {
                Text(focus.name).foregroundStyle(.secondary).lineLimit(1)
            } else {
                NewClientButton(model: model, prominent: prominent)
            }
        case .chooseAccess:
            if state == .done, let focus {
                Text(AccessSummary.counts(focus.grants)).foregroundStyle(.secondary)
            } else {
                Button(String(localized: "Choose Access…")) {
                    if let focus { model.openClientAccess(focus.id, focus: nil) }
                }
                .modifier(Prominent(on: prominent))
                .disabled(focus == nil)
            }
        case .turnOn:
            Toggle(isOn: Binding(get: { model.bridge.isOn }, set: { model.setBridgeEnabled($0) })) {
                Text(AppIdentity.displayName)
            }
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel(String(localized: "Turn on \(AppIdentity.displayName)"))
        case .mcpServer:
            if state != .done {
                Button(String(localized: "Turn On")) { model.setLocalMCPAllowed(true) }
                    .modifier(Prominent(on: prominent))
            }
        case .testRequest:
            if state == .done {
                EmptyView()
            } else if let focus, focus.hasMCPToken {
                Button(String(localized: "Open Connect")) {
                    model.connectTab[focus.id] = .agent
                    model.navigate(to: .client(focus.id))
                }
                .modifier(Prominent(on: prominent))
            } else {
                HStack(spacing: 10) {
                    if model.waitingForTestRequest && model.bridge.isOn {
                        ProgressView().controlSize(.small)
                        Text(String(localized: "Waiting for a request…"))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    Button {
                        model.copyTestCommand()
                    } label: {
                        Label(String(localized: "Copy Command"), systemImage: "doc.on.doc")
                    }
                    .modifier(Prominent(on: prominent))
                    .disabled(focus == nil)
                    .help(focus.map { ConnectCommand.scopeStatus(clientName: $0.name, program: model.cliProgram) } ?? "")
                }
            }
        }
    }
}
