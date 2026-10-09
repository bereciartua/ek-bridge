import SwiftUI

/// Switch Tunnel… and Address ▸ Edit… (plan 08 T06, T07, mockups 02–05):
/// Choose · Start it · Paste and test · Switch, with the address in use
/// working until Switch. Shown by the Remote Access page while
/// `model.tunnelSwitch` is set.
struct TunnelSwitchView: View {
    let model: BridgeAppModel
    let change: TunnelSwitch

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            keepUsingBanner
            GuideStepsHeader(titles: change.steps.map(change.title),
                             current: change.steps.firstIndex(of: change.step) ?? 0)
            switch change.step {
            case .choose: choose
            case .start: start
            case .test, .confirm: test
            }
        }
    }

    /// *Cloud agents keep using https://… until you switch.* with Cancel.
    private var keepUsingBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(Color.accentColor).font(.body.weight(.semibold))
            (Text(String(localized: "Cloud agents keep using ")) + Text(change.fromOrigin).bold()
             + Text(change.kind == .editAddress ? String(localized: " until you save.")
                                                : String(localized: " until you switch.")))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(String(localized: "Cancel")) { model.cancelSwitch() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    // MARK: 1. Choose

    private var choose: some View {
        Card {
            ForEach(Array(TunnelProvider.allCases.enumerated()), id: \.element) { index, provider in
                if index > 0 { RowDivider() }
                let inUse = !change.canChoose(provider)
                let remembered = inUse ? nil : model.rememberedAddresses[provider]
                Button {
                    model.switchChoose(provider)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "circle")
                            .foregroundStyle(Color.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.name)
                            Text(provider.summary).font(.callout).foregroundStyle(.secondary)
                            if let remembered {
                                (Text(String(localized: "Last used: ")) + Text(remembered).font(.callout.monospaced()))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if inUse {
                            Pill(label: String(localized: "In use"), tone: .neutral)
                        } else {
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
                        }
                    }
                    .opacity(inUse ? 0.55 : 1)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())
                .disabled(inUse)
                .accessibilityLabel([provider.name, provider.summary,
                                     inUse ? String(localized: "In use") : nil,
                                     remembered.map { String(localized: "Last used: \($0)") }]
                    .compactMap { $0 }.joined(separator: ". "))
            }
        }
    }

    // MARK: 2. Start it

    private var start: some View {
        let provider = change.picked ?? .other
        let state = model.tunnelStartState
        return VStack(alignment: .leading, spacing: 12) {
            TunnelStartCard(model: model, provider: provider,
                            note: String(localized: "Both tunnels can run at the same time."))
            HStack {
                Spacer()
                Button(String(localized: "Back")) { model.switchBack() }
                if state.offersContinue {
                    Button(String(localized: "Continue")) { model.switchContinue() }
                        .buttonStyle(.borderedProminent)
                } else if state.offersStarted {
                    Button(String(localized: "I've Started It")) { model.switchContinue() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    // MARK: 3. Paste and test

    private var test: some View {
        let provider = change.picked ?? change.fromTunnel
        let normalized = model.switchNormalizedAddress
        let result = change.result(for: normalized)
        return VStack(alignment: .leading, spacing: 12) {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text(caption(provider))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField(String(localized: "Address"), text: Binding(
                        get: { model.tunnelSwitch?.address ?? "" }, set: { model.setSwitchAddress($0) }),
                              prompt: Text("https://my-mac.tail1234.ts.net"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.switchTest() }
                        .accessibilityLabel(String(localized: "New address for \(provider.name)"))
                    if let issue = model.switchAddressIssue {
                        Text(issue).font(.callout).foregroundStyle(.red)
                    }
                }
                .padding(16)
                if result != .notTested {
                    RowDivider()
                    testResult(result, provider: provider)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
            }
            HStack {
                Spacer()
                Button(String(localized: "Back")) { model.switchBack() }
                Button(result == .notTested ? String(localized: "Test") : String(localized: "Test Again")) {
                    model.switchTest()
                }
                .disabled(normalized == nil || !model.remoteEnabled || isTesting(result))
                .modifier(Prominent(on: !change.canConfirm(normalized: normalized)))
                Button(change.kind == .editAddress ? String(localized: "Save…") : String(localized: "Switch…")) {
                    model.switchConfirm()
                }
                .disabled(!change.canConfirm(normalized: normalized))
                .modifier(Prominent(on: change.canConfirm(normalized: normalized)))
            }
            if !model.remoteEnabled {
                Text(String(localized: "Turn on Remote Access to test the address."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func caption(_ provider: TunnelProvider) -> String {
        switch change.addressSource {
        case .runningTunnel: String(localized: "Filled in from the running tunnel. Check it, then test.")
        case .remembered: String(localized: "The address \(provider.name) had last time. Check it, then test.")
        case .inUse: String(localized: "The new address for \(provider.name), without a path. Test it, then save.")
        case .none: String(localized: "The tunnel's public https address, without a path. Test it before you switch.")
        }
    }

    private func isTesting(_ result: TunnelSwitch.Test) -> Bool {
        if case .testing = result { return true }
        return false
    }

    @ViewBuilder
    private func testResult(_ result: TunnelSwitch.Test, provider: TunnelProvider) -> some View {
        switch result {
        case .notTested:
            EmptyView()
        case .testing(let address):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(String(localized: "Testing \(address)…")).foregroundStyle(.secondary)
            }
        case .reachable(_, let ms, let tunnel):
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Pill(label: String(localized: "Reachable"), tone: .ok, icon: true)
                    Text(([tunnel.map { String(localized: "through \($0.name)") }, "\(ms) ms"].compactMap { $0 })
                        .joined(separator: " · "))
                    Spacer(minLength: 8)
                    Text(String(localized: "Nothing is saved yet")).font(.callout).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                if let other = change.otherTunnel {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Label(String(localized: "This address goes through \(other.name), not \(provider.name)."),
                              systemImage: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if change.kind == .switchTunnel && other != change.fromTunnel {
                            Button(String(localized: "Continue as \(other.name)")) { model.switchContinueAs(other) }
                        }
                    }
                    .font(.callout)
                }
            }
        case .notReachable(_, let reason):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Pill(label: String(localized: "Not reachable"), tone: .warn, icon: true)
                Text(model.currentTunnelHealth?.unreachableReason(provider, remotePort: model.remotePort) ?? reason)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(String(localized: "\(change.fromTunnel.name) keeps working")).font(.callout).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// Step 4 (mockup 05): what switching changes, by name, before anything is saved.
struct TunnelSwitchSheet: View {
    let model: BridgeAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let change = model.tunnelSwitch, let summary = model.tunnelSwitchSummary {
                Text(change.kind == .editAddress ? String(localized: "Save the new address?")
                                                 : String(localized: "Switch to \(summary.tunnel.name)?"))
                    .font(.headline)
                (Text(String(localized: "The MCP URL becomes ")) + Text(summary.mcpURL).font(.body.monospaced())
                 + Text("."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Card {
                    if summary.noCloudAgents {
                        section(String(localized: "No cloud agents use the current URL yet."), detail: nil)
                    }
                    if !summary.updateURLIn.isEmpty {
                        section(String(localized: "Update the URL in"),
                                detail: summary.updateURLIn.map { String(localized: "\($0) (remote token)") }
                                    .joined(separator: ", "))
                    }
                    if !summary.disconnected.isEmpty {
                        if !summary.updateURLIn.isEmpty { RowDivider() }
                        section(String(localized: "Disconnected; connect again"),
                                detail: summary.disconnected.map { String(localized: "\($0) (connected cloud app)") }
                                    .joined(separator: ", "))
                    }
                    if let old = summary.stopTunnel {
                        RowDivider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text(String(localized: "Then you can stop \(old.name)"))
                            HStack(alignment: .top) {
                                CodeBox(text: summary.stopCommands.joined(separator: "\n"))
                                CopyButton(text: summary.stopCommands.joined(separator: "\n"),
                                           title: String(localized: "Copy"), help: String(localized: "Copy Command"))
                            }
                        }
                        .padding(16)
                    }
                }
                HStack {
                    Spacer()
                    Button(String(localized: "Cancel")) { model.switchBack() }
                        .keyboardShortcut(.cancelAction)
                    Button(change.kind == .editAddress ? String(localized: "Save") : String(localized: "Switch")) {
                        model.switchCommit()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                Text(String(localized: "This switch is no longer open.")).font(.headline)
                HStack {
                    Spacer()
                    Button(String(localized: "Close")) { model.sheet = nil }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func section(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            if let detail {
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .accessibilityElement(children: .combine)
    }
}

/// A guide's numbered steps: done ones checked, the current one highlighted.
struct GuideStepsHeader: View {
    let titles: [String]
    /// Index into `titles`; `titles.count` means all done.
    let current: Int
    /// The highlighted step, when it isn't `current` (a finished guide highlights its last step).
    var highlighted: Int? = nil

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                let done = index < current
                let isCurrent = index == (highlighted ?? current)
                HStack(spacing: 8) {
                    ZStack {
                        Circle().strokeBorder(done ? Color.green : isCurrent ? Color.primary : Color.secondary,
                                              lineWidth: 1.5)
                        if done {
                            Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.green)
                        } else {
                            Text("\(index + 1)").font(.caption.weight(.semibold))
                        }
                    }
                    .frame(width: 22, height: 22)
                    Text(title)
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
                .accessibilityLabel(String(localized: "Step \(index + 1), \(title), \(done ? String(localized: "done") : isCurrent ? String(localized: "current") : String(localized: "not done"))"))
                if index < titles.count - 1 { Divider() }
            }
        }
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Palette.separator.opacity(0.6), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
    }
}
