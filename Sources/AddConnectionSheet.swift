import SwiftUI

// Add a Connection (B05, mockup 02): pick an agent or a script, a name, the
// starting access and Ask before changes, in one sheet. Nothing is granted
// until the user clicks Add and Connect.

/// What a tile in the sheet creates.
enum AddConnectionTile: Hashable {
    case agent(AgentKind)
    case script
    case cloud

    var kind: ClientKind { self == .script ? .cli : .agent }
    var agent: AgentKind? { if case .agent(let agent) = self { agent } else { nil } }

    var title: String {
        switch self {
        case .agent(let agent): agent.displayName
        case .script: String(localized: "Script or command line")
        case .cloud: String(localized: "Cloud agent")
        }
    }

    /// The name filled in for a new connection.
    var suggestedName: String {
        switch self {
        case .agent(.other): String(localized: "Agent")
        case .agent(let agent): agent.displayName
        case .script: String(localized: "Script")
        case .cloud: String(localized: "Cloud agent")
        }
    }
}

/// The sheet's Starting access popup.
enum StartingAccessChoice: Hashable { case readAll, readAllPlusOne, nothing }

extension AgentKind {
    /// The common agents shown before More agents…
    static let common: [AgentKind] = [.claudeCode, .claudeDesktop, .codex, .cursor, .vsCode, .geminiCLI]

    /// Two letters on the agent's tile; no vendor logos.
    var initials: String {
        switch self {
        case .claudeCode: "CC"
        case .claudeDesktop: "CD"
        case .codex: "Cx"
        case .cursor: "Cu"
        case .vsCode: "VS"
        case .geminiCLI: "Ge"
        case .devinDesktop: "Dv"
        case .zed: "Ze"
        case .cline: "Cl"
        case .jetBrains: "JB"
        case .other: "··"
        }
    }

    var tileColor: Color {
        switch self {
        case .claudeCode: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .claudeDesktop: Color(red: 0.77, green: 0.40, blue: 0.26)
        case .codex: Color(white: 0.27)
        case .cursor: Color(white: 0.15)
        case .vsCode: Color(red: 0.12, green: 0.44, blue: 0.92)
        case .geminiCLI: Color(red: 0.31, green: 0.50, blue: 0.94)
        case .devinDesktop: Color(red: 0.12, green: 0.55, blue: 0.53)
        case .zed: Color(red: 0.33, green: 0.30, blue: 0.75)
        case .cline: Color(red: 0.29, green: 0.33, blue: 0.40)
        case .jetBrains: Color(red: 0.86, green: 0.24, blue: 0.49)
        case .other: Color(white: 0.55)
        }
    }
}

struct AddConnectionSheet: View {
    let model: BridgeAppModel
    @State private var tile = AddConnectionTile.agent(.claudeCode)
    @State private var showMore = false
    @State private var name = ""
    /// The name the sheet filled in; a tile change replaces it only while unedited.
    @State private var filledName = ""
    @State private var access = StartingAccessChoice.readAll
    /// Set once the user picks a starting access; until then it follows the tile.
    @State private var accessEdited = false
    @State private var writeTarget: GrantKey?
    @State private var ask: Bool?
    @State private var submitted: ClientNameIssue?
    @State private var started = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    /// Installed agents first (in AgentKind order), then the other common ones.
    private var mainAgents: [AgentKind] {
        let installed = AgentKind.allCases.filter { model.installedAgents.contains($0) }
        return installed + AgentKind.common.filter { !installed.contains($0) }
    }

    private var moreAgents: [AgentKind] {
        AgentKind.allCases.filter { !mainAgents.contains($0) && $0 != .other } + [.other]
    }

    private var canChooseAccess: Bool { !model.collections.isEmpty }

    private var writable: [CollectionInfo] {
        model.collections.sortedForDisplay().filter(\.writable)
    }

    private var startingAccess: StartingAccess {
        guard canChooseAccess else { return .nothing }
        switch access {
        case .readAll: return .readAll
        case .nothing: return .nothing
        case .readAllPlusOne: return writeTarget.map { .readAllPlusOne($0) } ?? .readAll
        }
    }

    private var askOn: Bool { ask ?? (model.defaultApproval(for: tile.kind) == .ask) }

    var body: some View {
        let issue = model.nameIssue(name)
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Add a Connection")).font(.headline)
                Text(String(localized: "Choose what will use your calendars. Agents found on this Mac come first."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(mainAgents, id: \.self) { agent in tileButton(.agent(agent)) }
                tileButton(.script)
                if showMore {
                    ForEach(moreAgents, id: \.self) { agent in tileButton(.agent(agent)) }
                } else {
                    moreButton
                }
                if model.remoteEnabled { tileButton(.cloud) }
            }
            Divider()
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text(String(localized: "Name"))
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(String(localized: "Name"), text: $name)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(create)
                            .accessibilityLabel(String(localized: "Name"))
                        if let shown = visibleIssue(issue) {
                            Text(NameIssueText.message(shown)).font(.callout).foregroundStyle(.red)
                        }
                    }
                }
                GridRow {
                    Text(String(localized: "Starting access"))
                    accessControls
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Toggle(String(localized: "Ask me before each change"), isOn: Binding(
                    get: { askOn }, set: { ask = $0 }))
                    .toggleStyle(.checkbox)
                Text(askCaption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { model.sheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Add and Connect"), action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(issue != nil)
            }
            .padding(.top, 2)
        }
        .padding(20)
        .frame(width: 560)
        .onAppear(perform: start)
    }

    // MARK: Tiles

    private func tileButton(_ option: AddConnectionTile) -> some View {
        let selected = option == tile
        let installed = option.agent.map { model.installedAgents.contains($0) }
        return Button { choose(option) } label: {
            VStack(spacing: 6) {
                badge(option)
                Text(option.title)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let installed, option.agent != .other {
                    Text(installed ? String(localized: "Installed") : String(localized: "Not found"))
                        .font(.caption.weight(installed ? .semibold : .regular))
                        .foregroundStyle(installed ? Color.green : Color.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 104)
            .padding(.horizontal, 6)
            .background(selected ? Color.accentColor.opacity(0.1) : Palette.card,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Palette.separator.opacity(0.6),
                              lineWidth: selected ? 2 : 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(option, installed: installed))
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    private func accessibilityLabel(_ option: AddConnectionTile, installed: Bool?) -> String {
        guard let installed, option.agent != .other else { return option.title }
        return installed ? String(localized: "\(option.title), installed")
                         : String(localized: "\(option.title), not found")
    }

    @ViewBuilder private func badge(_ option: AddConnectionTile) -> some View {
        switch option {
        case .agent(let agent):
            Text(agent.initials)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(agent.tileColor.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
        case .script:
            symbolBadge("apple.terminal", color: Color(white: 0.4))
        case .cloud:
            symbolBadge("globe", color: .blue)
        }
    }

    private func symbolBadge(_ symbol: String, color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
    }

    private var moreButton: some View {
        Button { showMore = true } label: {
            VStack(spacing: 6) {
                symbolBadge("ellipsis", color: Color(white: 0.55))
                Text(String(localized: "More agents…")).font(.callout)
            }
            .frame(maxWidth: .infinity, minHeight: 104)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Palette.separator.opacity(0.6), lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "More agents"))
    }

    // MARK: Access

    @ViewBuilder private var accessControls: some View {
        if canChooseAccess {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Picker(String(localized: "Starting access"), selection: Binding(
                        get: { access }, set: { access = $0; accessEdited = true })) {
                        Text(String(localized: "Read all calendars and lists")).tag(StartingAccessChoice.readAll)
                        Text(String(localized: "Read all; add and change in one…"))
                            .tag(StartingAccessChoice.readAllPlusOne)
                            .disabled(writable.isEmpty)
                        Text(String(localized: "Nothing yet; I'll choose next")).tag(StartingAccessChoice.nothing)
                    }
                    .labelsHidden()
                    .fixedSize()
                    InfoButton(text: String(localized: "Applies to the calendars and lists you have now. Change it any time in the connection's Access."))
                }
                if access == .readAllPlusOne {
                    Picker(String(localized: "Calendar or list it can change"), selection: $writeTarget) {
                        let calendars = writable.filter { $0.resource == .calendar }
                        let lists = writable.filter { $0.resource == .reminderList }
                        if !calendars.isEmpty {
                            Section(String(localized: "Calendars")) {
                                ForEach(calendars) { Text($0.name).tag(Optional($0.key)) }
                            }
                        }
                        if !lists.isEmpty {
                            Section(String(localized: "Lists")) {
                                ForEach(lists) { Text($0.name).tag(Optional($0.key)) }
                            }
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel(String(localized: "Calendar or list it can change"))
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Nothing yet"))
                Text(String(localized: "Allow Calendar or Reminders access first to choose more."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var askCaption: String {
        let who = name.trimmingCharacters(in: .whitespaces).isEmpty ? tile.suggestedName : name
        switch startingAccess {
        case .nothing:
            return askOn ? String(localized: "\(who) has no access yet. Once you allow a change, it waits for you.")
                         : String(localized: "\(who) has no access yet.")
        case .readAll:
            return askOn ? String(localized: "\(who) can read freely; every add, change or delete waits for you.")
                         : String(localized: "\(who) can read freely and can't make changes yet.")
        case .readAllPlusOne(let key):
            let target = model.collection(key)?.name ?? ""
            return askOn ? String(localized: "\(who) can read freely; every add, change or delete waits for you.")
                         : String(localized: "\(who) can change \(target) without asking.")
        }
    }

    // MARK: Actions

    private func start() {
        guard !started else { return }
        started = true
        choose(model.newConnectionPreset ?? .agent(mainAgents.first ?? .claudeCode))
        model.newConnectionPreset = nil
        writeTarget = writable.first?.key
        if let preset = model.newConnectionAccessPreset {
            access = preset
            accessEdited = true
            model.newConnectionAccessPreset = nil
        }
    }

    private func choose(_ option: AddConnectionTile) {
        let unedited = name == filledName
        tile = option
        if option.agent.map({ !AgentKind.common.contains($0) && !mainAgents.contains($0) }) == true {
            showMore = true
        }
        // A script starts with nothing, an agent reads everything, until the user picks.
        if !accessEdited { access = option.kind == .cli ? .nothing : .readAll }
        if unedited {
            filledName = model.suggestedName(option.suggestedName)
            name = filledName
        }
        submitted = nil
    }

    // Empty is shown as a disabled button, not an error.
    private func visibleIssue(_ issue: ClientNameIssue?) -> ClientNameIssue? {
        if let submitted { return submitted }
        guard let issue, issue != .empty else { return nil }
        return issue
    }

    private func create() {
        guard model.nameIssue(name) == nil else { return }
        submitted = model.createClient(name: name, kind: tile.kind, askBeforeChanges: askOn,
                                       startingAccess: startingAccess, agent: tile.agent,
                                       cloud: tile == .cloud)
    }
}
