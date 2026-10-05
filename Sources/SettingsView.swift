import ServiceManagement
import SwiftUI

/// Settings (§11): General, Developer (off by default) and About.
struct SettingsView: View {
    let model: BridgeAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PaneTitle(title: String(localized: "Settings"))
                general
                developer
                about
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: String(localized: "General"))
            Card {
                SettingsRow(title: String(localized: "Start at login"),
                            caption: String(localized: "The bridge also remembers whether it was on.")) {
                    Toggle(String(localized: "Start at login"),
                           isOn: Binding(get: { model.loginItem == .enabled },
                                         set: { model.setStartAtLogin($0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(!model.isInstalledInApplications || model.loginItem == .notFound)
                }
                if !model.isInstalledInApplications {
                    RowDivider()
                    SettingsNotice(
                        text: String(localized: "Move \(AppIdentity.displayName) to your Applications folder to start it at login."),
                        button: String(localized: "Show in Finder"), action: model.revealRunningApp)
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
            }
        }
    }

    private var developer: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: String(localized: "Developer"))
            Card {
                SettingsRow(title: String(localized: "Show developer tools"),
                            caption: String(localized: "For contributors testing the bridge with throwaway data.")) {
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
            }
        }
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
