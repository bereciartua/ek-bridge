import AppKit
import EventKit

// This window edits policy, not EventKit items. Credentials are written directly
// to a private file and are never placed in a text field or on the clipboard.
@MainActor
final class ClientManagerUI {
    private struct Collection {
        let resource: ClientResource
        let id: String
        let name: String
        let account: String
        let writable: Bool

        init(resource: ClientResource, calendar: EKCalendar) {
            self.resource = resource
            self.id = calendar.calendarIdentifier
            self.name = calendar.title
            self.account = calendar.source.title
            self.writable = calendar.allowsContentModifications
        }

        #if EVENTKIT_UI_REVIEW
        init(resource: ClientResource, id: String, name: String,
             account: String, writable: Bool) {
            self.resource = resource
            self.id = id
            self.name = name
            self.account = account
            self.writable = writable
        }
        #endif
    }

    private struct GrantRow {
        let collection: Collection
        let controls: [(bit: Int, button: NSButton)]
    }

    private let registry: ClientRegistry
    private let store: EKEventStore
    private let credentialFiles = ClientCredentialFiles()
    // AppKit's window controller retains each window and disables release on
    // close, so a later menu action can safely present that same window.
    private var windowController: NSWindowController?
    private var activityWindowController: NSWindowController?
    #if EVENTKIT_UI_REVIEW
    var reviewActivityWindow: NSWindow? { activityWindowController?.window }
    func showReviewActivity() { showActivity(nil) }
    #endif
    #if EVENTKIT_UI_REVIEW
    var reviewWindow: NSWindow? { windowController?.window }
    #endif
    private var clientList = NSStackView()
    private var detail = FlippedStackView()
    private var bridgeLabel = NSTextField(labelWithString: "")
    private var clients = [ClientView]()
    private var selectedID: String?
    private var rows = [GrantRow]()
    private var dirty = false
    private var saveButton: NSButton?
    private var discardButton: NSButton?
    private var bridgeIsActive: () -> Bool = { false }
    private var enableBridge: () -> Bool = { false }
    private var disableBridge: () -> Void = {}

    init(registry: ClientRegistry, store: EKEventStore) {
        self.registry = registry
        self.store = store
    }

    func show(bridgeIsActive: @escaping () -> Bool,
              enableBridge: @escaping () -> Bool,
              disableBridge: @escaping () -> Void) {
        self.bridgeIsActive = bridgeIsActive
        self.enableBridge = enableBridge
        self.disableBridge = disableBridge
        if windowController == nil { makeWindow() }
        if windowController?.window?.isVisible == true {
            windowController?.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        reload()
        windowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() {
        let root = NSStackView()
        root.orientation = .vertical
        root.distribution = .fill
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 16
        header.edgeInsets = NSEdgeInsets(top: 18, left: 22, bottom: 18, right: 22)
        let heading = NSTextField(labelWithString: "Clients & permissions")
        heading.font = .boldSystemFont(ofSize: 21)
        header.addArrangedSubview(heading)
        let spacer = NSView()
        header.addArrangedSubview(spacer)
        let create = button("New client", #selector(createClient))
        create.bezelStyle = .rounded
        header.addArrangedSubview(create)
        root.addArrangedSubview(header)

        let divider = NSBox()
        divider.boxType = .separator
        root.addArrangedSubview(divider)

        let body = NSStackView()
        body.orientation = .horizontal
        body.alignment = .top
        body.spacing = 0
        root.addArrangedSubview(body)

        let sidebar = NSStackView()
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 12
        sidebar.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        let clientsHeading = sectionTitle("LOCAL CLIENTS")
        sidebar.addArrangedSubview(clientsHeading)
        clientList.orientation = .vertical
        clientList.alignment = .leading
        clientList.spacing = 5
        sidebar.addArrangedSubview(clientList)
        let sideSpacer = NSView()
        sidebar.addArrangedSubview(sideSpacer)
        sidebar.addArrangedSubview(label(
            "A client starts with no access. Each grant is limited to one calendar or reminder list.",
            secondary: true))
        sidebar.widthAnchor.constraint(equalToConstant: 245).isActive = true
        body.addArrangedSubview(sidebar)

        let verticalDivider = NSView()
        verticalDivider.wantsLayer = true
        verticalDivider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        verticalDivider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        body.addArrangedSubview(verticalDivider)
        verticalDivider.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 12
        detail.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 26, right: 24)
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.setContentCompressionResistancePriority(.required, for: .vertical)
        document.addSubview(detail)
        scroll.documentView = document
        NSLayoutConstraint.activate([
            detail.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            detail.topAnchor.constraint(equalTo: document.topAnchor),
            detail.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
        ])
        body.addArrangedSubview(scroll)

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1080, height: 730))
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(greaterThanOrEqualToConstant: 990),
            header.widthAnchor.constraint(equalTo: root.widthAnchor),
            body.widthAnchor.constraint(equalTo: root.widthAnchor),
            body.heightAnchor.constraint(greaterThanOrEqualToConstant: 400),
            scroll.heightAnchor.constraint(equalTo: body.heightAnchor),
            scroll.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -246),
        ])
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 730),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Clients & Permissions — EventKit Bridge"
        window.minSize = NSSize(width: 990, height: 540)
        window.contentView = content
        window.setContentSize(NSSize(width: 1080, height: 730))
        window.center()
        windowController = NSWindowController(window: window)
    }

    private func reload() {
        guard let current = registry.clients() else {
            clients = []
            clear(clientList)
            clear(detail)
            detail.addArrangedSubview(label("Client policy is unavailable. Disable the bridge and inspect the local policy store.", secondary: false))
            return
        }
        clients = current
        if !clients.contains(where: { $0.id == selectedID && !$0.revoked }) {
            selectedID = clients.first(where: { !$0.revoked })?.id
        }
        dirty = false
        renderClients()
        renderDetail()
    }

    private func renderClients() {
        clear(clientList)
        let active = clients.filter { !$0.revoked }
        if active.isEmpty {
            clientList.addArrangedSubview(label("No active clients", secondary: true))
        }
        for (index, client) in active.enumerated() {
            let selected = client.id == selectedID
            let title = "\(selected ? "●" : "○")  \(client.name)"
            let choice = button(title, #selector(selectClient(_:)))
            choice.tag = index
            choice.alignment = .left
            choice.font = selected ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: 13)
            choice.widthAnchor.constraint(equalToConstant: 205).isActive = true
            clientList.addArrangedSubview(choice)
        }
        let revokedCount = clients.filter(\.revoked).count
        if revokedCount > 0 {
            clientList.addArrangedSubview(label("\(revokedCount) revoked", secondary: true))
        }
    }

    private func renderDetail() {
        clear(detail)
        rows = []
        guard let client = clients.first(where: { $0.id == selectedID && !$0.revoked }) else {
            detail.addArrangedSubview(title("Choose a client"))
            detail.addArrangedSubview(label("Create a client to grant access to selected calendars and reminder lists.", secondary: true))
            renderBridge()
            return
        }

        let top = NSStackView()
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 12
        top.addArrangedSubview(title(client.name))
        top.addArrangedSubview(NSView())
        top.addArrangedSubview(button("Activity…", #selector(showActivity)))
        top.addArrangedSubview(button("Rotate key…", #selector(rotateKey)))
        top.addArrangedSubview(button("Revoke…", #selector(revokeClient)))
        detail.addArrangedSubview(top)
        top.widthAnchor.constraint(equalTo: detail.widthAnchor, constant: -48).isActive = true

        detail.addArrangedSubview(label("Client ID: \(client.id)", secondary: true, monospaced: true))
        detail.addArrangedSubview(label(
            "The credential is saved privately on this Mac. Other processes running as your macOS user can read its file.",
            secondary: true))
        sectionGap()
        detail.addArrangedSubview(sectionTitle("COLLECTION PERMISSIONS"))
        detail.addArrangedSubview(label(
            "Choose exactly what this client may do. Saved grants continue to work while the bridge is active until you change or revoke them.",
            secondary: true))

        let visible = availableCollections()
        for resource in [ClientResource.calendar, .reminderList] {
            let group = visible.filter { $0.resource == resource }
            detail.addArrangedSubview(subtitle(resource == .calendar ? "Calendars" : "Reminder lists"))
            if group.isEmpty {
                let access = EKEventStore.authorizationStatus(for: resource == .calendar ? .event : .reminder)
                detail.addArrangedSubview(label(
                    access == .fullAccess ? "No collections found." : "Full Access is needed to show these collections. Existing grants are preserved.",
                    secondary: true))
            }
            for collection in group {
                addGrantRow(collection, client: client)
            }
            sectionGap()
        }

        let visibleKeys = Set(visible.map { "\($0.resource.rawValue):\($0.id)" })
        let unavailable = client.grants.filter {
            !visibleKeys.contains("\($0.resource.rawValue):\($0.targetID)")
        }
        if !unavailable.isEmpty {
            detail.addArrangedSubview(label(
                "\(unavailable.count) saved grant(s) are not currently listed by EventKit. They will be preserved when you save. Restore Full Access or reconnect the account to edit them.",
                secondary: true))
        }

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 10
        let save = button("Save permissions", #selector(saveGrants))
        let discard = button("Discard changes", #selector(discardChanges))
        save.isEnabled = dirty
        discard.isEnabled = dirty
        saveButton = save
        discardButton = discard
        actions.addArrangedSubview(save)
        actions.addArrangedSubview(discard)
        detail.addArrangedSubview(actions)
        detail.addArrangedSubview(label(
            "Read-only collections cannot be granted write actions. Clearing every box removes a collection grant.",
            secondary: true))
        sectionGap()
        renderBridge()
    }

    private func availableCollections() -> [Collection] {
        #if EVENTKIT_UI_REVIEW
        return (0..<24).map { index in
            Collection(resource: index < 16 ? .calendar : .reminderList,
                       id: "synthetic-\(index)", name: "Sample collection \(index + 1)",
                       account: "Preview account", writable: true)
        }
        #else
        var collections = [Collection]()
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            collections += store.calendars(for: .event).map { Collection(resource: .calendar, calendar: $0) }
        }
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess {
            collections += store.calendars(for: .reminder).map { Collection(resource: .reminderList, calendar: $0) }
        }
        return collections.sorted {
            if $0.resource != $1.resource { return $0.resource == .calendar }
            if $0.account != $1.account { return $0.account.localizedStandardCompare($1.account) == .orderedAscending }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        #endif
    }

    private func addGrantRow(_ collection: Collection, client: ClientView) {
        let old = client.grants.first {
            $0.resource == collection.resource && $0.targetID == collection.id
        }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.wantsLayer = true
        stack.layer?.cornerRadius = 8
        stack.layer?.borderWidth = 1
        stack.layer?.borderColor = NSColor.separatorColor.cgColor
        let name = subtitle(collection.name)
        stack.addArrangedSubview(name)
        let access = collection.writable ? "Writable" : "Read only"
        stack.addArrangedSubview(label("\(collection.account) · \(access) · ID \(collection.id)",
                                       secondary: true, monospaced: false))
        if !collection.writable, (old?.mask ?? 0) & ~ClientGrant.read != 0 {
            stack.addArrangedSubview(label(
                "Previously saved write actions will be removed when you save while this collection is read only.",
                secondary: true))
        }
        let choices = NSStackView()
        choices.orientation = .horizontal
        choices.spacing = 15
        let options: [(String, Int)] = collection.resource == .calendar
            ? [("Read", ClientGrant.read), ("Create", ClientGrant.create),
               ("Edit", ClientGrant.edit), ("Delete", ClientGrant.delete)]
            : [("Read", ClientGrant.read), ("Create", ClientGrant.create),
               ("Edit", ClientGrant.edit), ("Delete", ClientGrant.delete),
               ("Complete", ClientGrant.complete)]
        let controls = options.map { name, bit -> (bit: Int, button: NSButton) in
            let check = NSButton(checkboxWithTitle: name, target: self,
                                 action: #selector(grantChanged))
            check.isEnabled = bit == ClientGrant.read || collection.writable
            check.state = (old?.mask ?? 0) & bit != 0 ? .on : .off
            choices.addArrangedSubview(check)
            return (bit, check)
        }
        stack.addArrangedSubview(choices)
        detail.addArrangedSubview(stack)
        stack.widthAnchor.constraint(equalTo: detail.widthAnchor, constant: -48).isActive = true
        rows.append(GrantRow(collection: collection, controls: controls))
    }

    private func renderBridge() {
        detail.addArrangedSubview(sectionTitle("LOCAL BRIDGE"))
        let active = bridgeIsActive()
        bridgeLabel.stringValue = active ? "Active · enrolled clients can use their saved grants" : "Off · client requests are unavailable"
        bridgeLabel.textColor = active ? .systemGreen : .secondaryLabelColor
        detail.addArrangedSubview(bridgeLabel)
        detail.addArrangedSubview(button(active ? "Turn bridge off" : "Turn bridge on",
                                         #selector(toggleBridge)))
        detail.addArrangedSubview(label(
            "Turning it on is saved across launches. Turning it off stops all client requests without changing grants.",
            secondary: true))
    }

    @objc private func selectClient(_ sender: NSButton) {
        let active = clients.filter { !$0.revoked }
        guard active.indices.contains(sender.tag), confirmDiscardIfNeeded() else { return }
        selectedID = active[sender.tag].id
        dirty = false
        renderClients()
        renderDetail()
    }

    @objc private func grantChanged(_ sender: NSButton) {
        dirty = true
        saveButton?.isEnabled = true
        discardButton?.isEnabled = true
    }


    @objc private func discardChanges(_ sender: Any?) {
        guard confirmDiscardIfNeeded() else { return }
        dirty = false
        renderDetail()
    }

    @objc private func saveGrants(_ sender: Any?) {
        guard let client = clients.first(where: { $0.id == selectedID && !$0.revoked }) else { return }
        var grants = client.grants
        for row in rows {
            let mask = row.controls.reduce(0) { $0 | ($1.button.state == .on ? $1.bit : 0) }
            grants = ClientGrantEditing.replacing(
                grants, resource: row.collection.resource, targetID: row.collection.id,
                requestedMask: mask, writable: row.collection.writable)
        }
        switch registry.replaceGrants(clientID: client.id, grants: grants) {
        case .success:
            reload()
            message("Permissions saved", "Changes take effect now. Requests already in progress must be sent again.")
        case .failure(let error):
            message("Could not save permissions", "No new permissions were applied. \(error.rawValue)")
        }
    }

    @objc private func createClient(_ sender: Any?) {
        guard confirmDiscardIfNeeded() else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
        field.placeholderString = "For example, My local task"
        let alert = NSAlert()
        alert.messageText = "New local client"
        alert.informativeText = "Name the app or task that will connect. It starts with no permissions; you can grant collections after creation."
        alert.accessoryView = field
        alert.addButton(withTitle: "Create client")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        switch registry.createClient(name: field.stringValue) {
        case .success(let issued):
            switch credentialFiles.saveNew(clientID: issued.id, key: issued.key) {
            case .success:
                selectedID = issued.id
                reload()
                message("Client created", "Its signing credential was saved privately. It has no collection permissions yet.")
            case .failure(let error):
                let revoked = registry.revoke(clientID: issued.id)
                let cleanup = credentialFiles.remove(clientID: issued.id)
                reload()
                message("Could not save credential", "\(error.rawValue). \(Self.cleanupStatus(revoked: revoked, file: cleanup))")
            }
        case .failure(let error):
            message("Could not create client", error.rawValue)
        }
    }

    @objc private func rotateKey(_ sender: Any?) {
        guard let client = selectedClient(), confirmDiscardIfNeeded() else { return }
        switch credentialFiles.canReplace(clientID: client.id) {
        case .failure(let error):
            message("Cannot rotate key", "The saved credential is missing or unsafe (\(error.rawValue)). Revoke this client and create a new one if needed.")
            return
        case .success: break
        }
        guard confirm("Rotate \(client.name)’s key?",
                      "Its old key stops working immediately. The app will replace its private credential file. Any running client request may need to be sent again.",
                      action: "Rotate key") else { return }
        switch registry.rotateKey(clientID: client.id) {
        case .success(let key):
            switch credentialFiles.replace(clientID: client.id, key: key) {
            case .success:
                reload()
                message("Key rotated", "The old key no longer works. The private credential file was replaced.")
            case .failure(let error):
                let revoked = registry.revoke(clientID: client.id)
                let cleanup = credentialFiles.remove(clientID: client.id)
                reload()
                message("Credential replacement failed", "\(error.rawValue). \(Self.cleanupStatus(revoked: revoked, file: cleanup))")
            }
        case .failure(let error): message("Could not rotate key", error.rawValue)
        }
    }

    @objc private func revokeClient(_ sender: Any?) {
        guard let client = selectedClient(), confirmDiscardIfNeeded() else { return }
        guard confirm("Revoke \(client.name)?",
                      "This permanently stops its credential and removes every saved collection permission. To use it again, create a new client.",
                      action: "Revoke client") else { return }
        switch registry.revoke(clientID: client.id) {
        case .success:
            let removed = credentialFiles.remove(clientID: client.id)
            selectedID = nil
            reload()
            switch removed {
            case .success: message("Client revoked", "Its local credential file was removed.")
            case .failure(let error):
                message("Client revoked", "Its key no longer works, but the private credential file could not be removed (\(error.rawValue)). Check the file before continuing.")
            }
        case .failure(let error): message("Could not revoke client", error.rawValue)
        }
    }

    @objc private func toggleBridge(_ sender: Any?) {
        guard confirmDiscardIfNeeded() else { return }
        dirty = false
        if bridgeIsActive() {
            disableBridge()
        } else if !enableBridge() {
            message("Bridge did not start", "Open Controls to see the local bridge error. Permissions were not changed.")
        }
        renderDetail()
    }

    @objc private func showActivity(_ sender: Any?) {
        guard let activity = registry.activity() else {
            message("Activity unavailable", "The local activity history could not be read.")
            return
        }
        let formatter = ISO8601DateFormatter()
        let body = activity.prefix(100).map { row in
            "\(formatter.string(from: row.at))  \(row.clientID ?? "unknown")  \(row.command)  \(row.outcome)"
        }.joined(separator: "\n")
        let text = NSTextView()
        text.isEditable = false
        text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.string = body.isEmpty ? "No activity yet." : body
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = text
        if let existing = activityWindowController?.window {
            existing.contentView = scroll
        } else {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 360),
                                  styleMask: [.titled, .closable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Recent Bridge Activity"
            window.contentView = scroll
            window.center()
            activityWindowController = NSWindowController(window: window)
        }
        activityWindowController?.showWindow(nil)
    }

    private func selectedClient() -> ClientView? {
        clients.first(where: { $0.id == selectedID && !$0.revoked })
    }

    private func confirmDiscardIfNeeded() -> Bool {
        !dirty || confirm("Discard unsaved permissions?",
                          "The checkbox changes you made have not been saved.",
                          action: "Discard changes")
    }

    private func confirm(_ title: String, _ detail: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func message(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func clear(_ stack: NSStackView) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func title(_ string: String) -> NSTextField {
        let field = NSTextField(labelWithString: string)
        field.font = .boldSystemFont(ofSize: 22)
        return field
    }

    private func subtitle(_ string: String) -> NSTextField {
        let field = NSTextField(labelWithString: string)
        field.font = .systemFont(ofSize: 14, weight: .semibold)
        return field
    }

    private func sectionTitle(_ string: String) -> NSTextField {
        let field = NSTextField(labelWithString: string)
        field.font = .boldSystemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        return field
    }

    private func label(_ string: String, secondary: Bool, monospaced: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: string)
        field.maximumNumberOfLines = 0
        field.font = monospaced ? .monospacedSystemFont(ofSize: 11, weight: .regular)
                                : .systemFont(ofSize: 12)
        if secondary { field.textColor = .secondaryLabelColor }
        field.widthAnchor.constraint(lessThanOrEqualToConstant: 690).isActive = true
        return field
    }

    private func sectionGap() {
        let gap = NSView()
        gap.heightAnchor.constraint(equalToConstant: 10).isActive = true
        detail.addArrangedSubview(gap)
    }

    private static func cleanupStatus(
        revoked: Result<Void, ClientRegistryError>,
        file: Result<Void, CredentialFileError>) -> String {
        let revokedOK: Bool
        if case .success = revoked { revokedOK = true } else { revokedOK = false }
        let fileOK: Bool
        if case .success = file { fileOK = true } else { fileOK = false }
        if revokedOK && fileOK { return "The client was revoked and its file removed." }
        return "Cleanup was incomplete. Disable the bridge and inspect this client's record and private file before continuing."
    }
}
