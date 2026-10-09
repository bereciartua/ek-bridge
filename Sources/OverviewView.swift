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
                    NeedsYouSection(model: model)
                    TodaySection(model: model)
                    if model.calendarAccess != .fullAccess || model.remindersAccess != .fullAccess {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionTitle(title: String(localized: "macOS access"))
                            Card {
                                AccessStatusRow(model: model, resource: .calendar)
                                Divider().padding(.leading, 52)
                                AccessStatusRow(model: model, resource: .reminderList)
                            }
                        }
                    }
                    if model.policyStoreAvailable && model.activeClients.isEmpty {
                        Card {
                            HStack {
                                Text(String(localized: "No connections yet.")).foregroundStyle(.secondary)
                                Spacer()
                                NewClientButton(model: model)
                            }
                            .padding(16)
                        }
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
            text += " " + String(localized: "Install the command-line tool again from Settings ▸ Advanced.")
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
                    Text(([subtitle] + (model.mcpFailureText == nil ? [model.mcpStatusLine].compactMap { $0 } : []))
                            .joined(separator: " · "))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.mcpFailureText != nil, let line = model.mcpStatusLine {
                        Label(line, systemImage: "server.rack")
                            .foregroundStyle(Color.orange)
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

    private var title: String { model.bridgeTitle }

    private var subtitle: String {
        switch model.bridge {
        case .on:
            let count = model.activeClients.count - model.pausedCount
            let text = count == 1
                ? String(localized: "1 connection can use what you've allowed")
                : String(localized: "\(count) connections can use what you've allowed")
            return model.pausedCount == 0 ? text
                : text + " · " + String(localized: "\(model.pausedCount) paused")
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

/// Needs you (B12): approvals waiting, problems, unavailable calendars,
/// refused requests since Activity was last seen, an update. Hidden when empty.
struct NeedsYouSection: View {
    let model: BridgeAppModel

    var body: some View {
        let items = model.needsYouItems
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: String(localized: "Needs you"))
                Card {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        if index > 0 { Divider().padding(.leading, 52) }
                        row(item)
                    }
                }
            }
        }
    }

    private func row(_ item: NeedsYouItem) -> some View {
        let (symbol, color, title, detail, action, perform) = describe(item)
        return HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Button(action, action: perform).fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .accessibilityElement(children: .contain)
    }

    private func describe(_ item: NeedsYouItem)
        -> (String, Color, String, String?, String, () -> Void) {
        switch item {
        case .approvals(let count):
            return ("hand.raised", .accentColor,
                    count == 1 ? String(localized: "1 change waiting for approval")
                               : String(localized: "\(count) changes waiting for approval"),
                    String(localized: "Answer in the approval panel."), String(localized: "Review…"),
                    { model.showApprovals() })
        case .accessRequest(let title):
            return ("hand.raised", .accentColor, title,
                    String(localized: "It's waiting for your answer in the panel."), String(localized: "Allow…"),
                    { model.showApprovals() })
        case .problem(let problem):
            let fix: String = switch problem {
            case .calendarAccess, .remindersAccess: String(localized: "Open Privacy Settings…")
            case .remoteAccessFailed: String(localized: "Open Remote Access…")
            default: String(localized: "Fix…")
            }
            let detail: String? = switch problem {
            case .calendarAccess(let status): AccessText.detail(.calendar, status)
            case .remindersAccess(let status): AccessText.detail(.reminderList, status)
            case .remoteAccessFailed(let reason): reason
            default: nil
            }
            return ("exclamationmark.triangle.fill", .orange, problem.title, detail, fix, { model.fix(problem) })
        case .unavailable(let id, let connection, let key, let name, let mask):
            let title = name.map { String(localized: "\($0) isn't available") }
                ?? (key.resource == .calendar ? String(localized: "A calendar isn't available")
                                              : String(localized: "A list isn't available"))
            let words = AccessWords.words(mask).isEmpty ? String(localized: "its") : AccessWords.words(mask)
            return ("exclamationmark.triangle.fill", .orange, title,
                    String(localized: "\(connection) keeps \(words) access until you remove it"),
                    String(localized: "Review…"), { model.openClientAccess(id, focus: nil) })
        case .refused(let count, let since):
            let title: String
            if let since {
                let when = Calendar.current.isDateInToday(since)
                    ? since.formatted(date: .omitted, time: .shortened)
                    : since.formatted(.dateTime.month(.abbreviated).day().hour().minute())
                title = count == 1 ? String(localized: "1 request was refused since \(when)")
                                   : String(localized: "\(count) requests were refused since \(when)")
            } else {
                title = count == 1 ? String(localized: "1 request was refused")
                                   : String(localized: "\(count) requests were refused")
            }
            return ("xmark.octagon", .red, title, String(localized: "Activity says why, and how to fix it."),
                    String(localized: "Open Activity"), { model.openProblems() })
        case .update(let version, let critical):
            return ("arrow.down.circle", critical ? .red : .accentColor,
                    critical ? String(localized: "A security update is available: version \(version)")
                             : String(localized: "Version \(version) is available"),
                    nil, String(localized: "Install Update…"), { model.checkForUpdates() })
        }
    }
}

/// Today (B12): requests, changes and problems, then the latest changes.
struct TodaySection: View {
    let model: BridgeAppModel

    var body: some View {
        let today = ActivityStats.today(model.activity, now: model.now)
        let changes = Array(model.activity.filter {
            $0.isWrite && Calendar.current.isDate($0.at, inSameDayAs: model.now)
        }.prefix(5))
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle(title: String(localized: "Today"))
                Spacer()
                if !model.activity.isEmpty {
                    Button(String(localized: "Open Activity")) { model.openActivity() }
                        .buttonStyle(.link)
                }
            }
            Card {
                HStack(spacing: 0) {
                    stat(today.requests, today.requests == 1 ? String(localized: "request") : String(localized: "requests"))
                    Divider()
                    stat(today.changes, today.changes == 1 ? String(localized: "change") : String(localized: "changes"))
                    Divider()
                    stat(today.problems, today.problems == 1 ? String(localized: "problem") : String(localized: "problems"),
                         warn: today.problems > 0)
                }
                .fixedSize(horizontal: false, vertical: true)
                if changes.isEmpty {
                    Divider()
                    Text(today.requests == 0 ? String(localized: "No requests yet today.")
                                             : String(localized: "No changes today; agents only read."))
                        .foregroundStyle(.secondary)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(changes) { entry in
                        Divider()
                        Button { model.openActivity(selecting: entry.id) } label: {
                            ChangeRow(model: model, entry: entry)
                        }
                        .buttonStyle(RowButtonStyle())
                    }
                }
            }
        }
    }

    private func stat(_ value: Int, _ label: String, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.title.weight(.semibold)).monospacedDigit()
                .foregroundStyle(warn ? Color.orange : Color.primary)
            Text(label).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// "9:48 · ● Update event · Work · Claude Code · Approved" (item names come with C06).
struct ChangeRow: View {
    let model: BridgeAppModel
    let entry: ActivityEntry

    var body: some View {
        let collection = entry.targetKey.flatMap(model.collection)
        HStack(spacing: 10) {
            Text(entry.at.formatted(date: .omitted, time: .shortened))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            ColorDot(color: collection?.color, size: 8)
            (Text(CommandPresentation.label(entry.command))
             + Text(collection.map { " · \($0.name)" } ?? "")
             + Text(" · \(model.clientName(entry.clientID))").foregroundColor(.secondary))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Pill(label: label, tone: entry.outcome.tone)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// "Approved" for a change the user allowed in the panel.
    private var label: String {
        entry.code == "success" && (entry.approval == "user" || entry.approval == "window")
            ? String(localized: "Approved") : entry.outcome.label
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

// MARK: - Setup checklist (B09, mockup 01)

struct SetupChecklistView: View {
    let model: BridgeAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                PaneTitle(title: String(localized: "Set up \(AppIdentity.displayName)"))
                Text(String(localized: "Let your AI agent use the calendars and lists you choose. Requests stay on this Mac."))
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
                let focus = SetupChecklist.focusClient(input)
                Card {
                    ForEach(Array(SetupChecklist.steps(input).enumerated()), id: \.element) { index, step in
                        if index > 0 { Divider().padding(.leading, 56) }
                        SetupStepRow(model: model, step: step, number: index + 1,
                                     state: states[step] ?? .pending, focus: focus)
                    }
                }
                if states[.connect] == .current, let focus, focus.hasMCPToken {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle").foregroundStyle(.secondary).accessibilityHidden(true)
                        Text(String(localized: "Then ask it: “What's on my calendar today?”")).foregroundStyle(.secondary)
                        Text("·").foregroundStyle(.secondary).accessibilityHidden(true)
                        Button(String(localized: "Copy the setup instead")) { model.copySetupFromSetup(focus) }
                            .buttonStyle(.link)
                    }
                    .font(.callout)
                }
                if model.updaterAvailable {
                    // The one request that leaves this Mac, so it's named here.
                    Card {
                        Toggle(isOn: Binding(get: { model.automaticUpdateChecks },
                                             set: { model.setAutomaticUpdateChecks($0) })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(localized: "Check for updates automatically"))
                                Text(String(localized: "Once a day, asks GitHub for the latest version, sending only your IP address and the app's version."))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                HStack {
                    Text(String(localized: "Connecting a script instead?")).foregroundStyle(.secondary)
                    Button(String(localized: "Add a command-line connection…")) { model.beginNewClient(preset: .script) }
                        .buttonStyle(.link)
                        .disabled(!model.canCreateClient)
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
        .padding(.vertical, isFinished ? 9 : 14)
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
        case .done, .skipped:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.white, .green)
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

    private var name: String { focus?.name ?? String(localized: "your agent") }
    private var agentName: String {
        guard let focus else { return String(localized: "your agent") }
        return model.agent(for: focus.id).displayName
    }
    private var isScript: Bool { focus.map { $0.hasSigningKey && !$0.hasMCPToken } ?? false }
    private var waiting: Bool { model.waitingForTestRequest && model.bridge.isOn }

    private var title: String {
        switch step {
        case .macOSAccess:
            guard state == .done else { return String(localized: "Allow access to Calendar and Reminders") }
            return accessSummary
        case .addConnection:
            guard state == .done, let focus else { return String(localized: "Add your agent") }
            return String(localized: "\(focus.name) added · \(model.startingSummary(focus))")
        case .connect, .testRequest:
            if state == .done { return String(localized: "\(name) connected") }
            return isScript ? String(localized: "Connect your script") : String(localized: "Connect \(name)")
        default:
            return ""
        }
    }

    /// "Calendar and Reminders allowed", "Calendar allowed · Reminders skipped"…
    private var accessSummary: String {
        func part(_ resource: ClientResource) -> String? {
            let status = model.status(resource)
            let noun = AccessText.noun(resource)
            if status == .fullAccess { return nil }
            if status == .denied { return String(localized: "\(noun) off") }
            return String(localized: "\(noun) skipped")
        }
        switch (part(.calendar), part(.reminderList)) {
        case (nil, nil): return String(localized: "Calendar and Reminders allowed")
        case (nil, let other?): return String(localized: "Calendar allowed · \(other)")
        case (let other?, nil): return String(localized: "Reminders allowed · \(other)")
        case (let first?, let second?): return "\(first) · \(second)"
        }
    }

    private var detail: String? {
        switch step {
        case .macOSAccess:
            if model.accessRequestDeclined.contains(.calendar) || model.accessRequestDeclined.contains(.reminderList) {
                return String(localized: "You chose not to allow access. You can change this in System Settings.")
            }
            return String(localized: "\(AppIdentity.displayName) needs Full Access to the ones your agent uses. You can skip either one.")
        case .addConnection:
            return String(localized: "Choose the agent and what it can read. You can change it later.")
        case .connect, .testRequest:
            if waiting {
                return isScript ? String(localized: "Run the copied command in Terminal.")
                                : String(localized: "Then ask it: “What's on my calendar today?”")
            }
            if isScript {
                return String(localized: "Copy a command that checks its access and run it in Terminal. Done when the request arrives.")
            }
            return String(localized: "Adds \(AppIdentity.displayName) to \(agentName) and turns \(AppIdentity.displayName) on. Done when \(name)'s first request arrives.")
        default:
            return nil
        }
    }

    @ViewBuilder private var trailing: some View {
        let prominent = state == .current
        switch step {
        case .macOSAccess:
            if state == .done {
                Pill(label: String(localized: "Full Access"), tone: .ok, icon: true)
            } else {
                accessButtons(prominent: prominent)
            }
        case .addConnection:
            if state == .done, let focus {
                Button(String(localized: "Change")) { model.openClientAccess(focus.id, focus: nil) }
                    .buttonStyle(.link)
            } else {
                Button(String(localized: "Add Your Agent…")) { model.beginNewClient() }
                    .modifier(Prominent(on: prominent))
                    .disabled(!model.canCreateClient)
            }
        case .connect, .testRequest:
            if state != .done {
                HStack(spacing: 10) {
                    if waiting {
                        ProgressView().controlSize(.small)
                        Text(String(localized: "Waiting for \(name)…"))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    } else if let focus {
                        if isScript {
                            Button {
                                model.copyTestCommand()
                            } label: {
                                Label(String(localized: "Copy Test Command"), systemImage: "doc.on.doc")
                            }
                            .modifier(Prominent(on: prominent))
                            .help(ConnectCommand.scopeStatus(clientName: focus.name, program: model.cliProgram))
                        } else {
                            let agent = model.agent(for: focus.id)
                            Button(agent.oneClick ? String(localized: "Add to \(agent.displayName)…")
                                                  : String(localized: "Open Connect")) {
                                model.connectFromSetup(focus)
                            }
                            .modifier(Prominent(on: prominent))
                            .disabled(!focus.hasMCPToken)
                        }
                    }
                }
            }
        default:
            EmptyView()
        }
    }

    /// Allow Calendar… and Allow Reminders… until each is decided; Skip for
    /// the second once the first is allowed.
    @ViewBuilder private func accessButtons(prominent: Bool) -> some View {
        let input = model.checklistInput
        let anyAllowed = model.calendarAccess == .fullAccess || model.remindersAccess == .fullAccess
        HStack(spacing: 10) {
            ForEach([ClientResource.calendar, .reminderList], id: \.self) { resource in
                let status = model.status(resource)
                if !SetupChecklist.decided(resource, input) {
                    if status == .notDetermined {
                        if anyAllowed {
                            Button(String(localized: "Skip")) {
                                model.skipSetupStep(resource == .calendar ? .calendarAccess : .remindersAccess)
                            }
                            .buttonStyle(.link)
                        }
                        Button(resource == .calendar ? String(localized: "Allow Calendar…")
                                                     : String(localized: "Allow Reminders…")) {
                            model.requestAccess(resource)
                        }
                        .disabled(model.accessRequestInFlight.contains(resource))
                        .modifier(Prominent(on: prominent))
                    } else {
                        AccessStatusControls(model: model, resource: resource, prominent: prominent)
                    }
                }
            }
        }
    }
}
