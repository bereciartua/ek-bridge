import AppKit
import EventKit

// All credential and grant changes are explicit local UI actions. Secret
// material is saved to private files, never shown or copied to the clipboard.
@MainActor
final class ClientManagerUI {
    private let registry: ClientRegistry
    private let store: EKEventStore
    private let credentialFiles = ClientCredentialFiles()

    init(registry: ClientRegistry, store: EKEventStore) {
        self.registry = registry
        self.store = store
    }

    func show() {
        guard let clients = registry.clients() else {
            notice("Client policy store is unavailable. No clients can be used.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Manage local clients"
        let summary = clients.map { client in
            "\(client.name) [\(client.id)] — \(client.revoked ? "revoked" : "active"), \(client.grants.count) collection grants"
        }.joined(separator: "\n")
        alert.informativeText = (summary.isEmpty ? "No clients. New clients start with no permissions." : summary) +
            "\n\nThe app saves signing credentials in private files (mode 0600). Other processes running as this macOS user can read them."
        for title in ["New Client", "Edit Grants", "Rotate Key", "Revoke Client", "Activity", "Cancel"] {
            alert.addButton(withTitle: title)
        }
        switch alert.runModal() {
        case .alertFirstButtonReturn: create()
        case .alertSecondButtonReturn: editGrants()
        case .alertThirdButtonReturn: rotate()
        case NSApplication.ModalResponse(rawValue: 1003): revoke()
        case NSApplication.ModalResponse(rawValue: 1004): activity()
        default: break
        }
    }

    private func create() {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 390, height: 24))
        field.placeholderString = "Client name"
        let alert = NSAlert()
        alert.messageText = "Create a client"
        alert.informativeText = "The client starts with no grants. Its signing credential will be saved privately in Application Support. Cancel makes no changes."
        alert.accessoryView = field
        alert.addButton(withTitle: "Create and Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        switch registry.createClient(name: field.stringValue) {
        case .success(let issued):
            switch credentialFiles.saveNew(clientID: issued.id, key: issued.key) {
            case .success(let url):
                notice("Client created with no grants. Signing credential saved at \(url.path). Keep this file private.")
            case .failure(let error):
                let revoked = registry.revoke(clientID: issued.id)
                let cleanup = credentialFiles.remove(clientID: issued.id)
                let status = Self.cleanupStatus(revoked: revoked, file: cleanup)
                notice("Credential save failed (\(error.rawValue)). \(status)")
            }
        case .failure(let error): notice("Client creation failed: \(error.rawValue)")
        }
    }

    private func rotate() {
        guard let client = selectClient("Rotate which client's key?") else { return }
        let destination: URL
        switch credentialFiles.canReplace(clientID: client.id) {
        case .success(let url): destination = url
        case .failure(let error):
            notice("Cannot rotate: credential file is missing or unsafe (\(error.rawValue)). Revoke this client and create a new one if needed.")
            return
        }
        let confirm = NSAlert()
        confirm.messageText = "Rotate key for \(client.name)?"
        confirm.informativeText = "The old key stops working immediately. Its private file at \(destination.path) will be replaced atomically. Cancel makes no changes."
        confirm.addButton(withTitle: "Rotate and Replace")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        switch registry.rotateKey(clientID: client.id) {
        case .success(let key):
            switch credentialFiles.replace(clientID: client.id, key: key) {
            case .success(let url): notice("Key rotated. Private credential replaced at \(url.path).")
            case .failure(let error):
                let revoked = registry.revoke(clientID: client.id)
                let cleanup = credentialFiles.remove(clientID: client.id)
                let status = Self.cleanupStatus(revoked: revoked, file: cleanup)
                notice("Credential replacement failed (\(error.rawValue)). \(status)")
            }
        case .failure(let error): notice("Key rotation failed: \(error.rawValue)")
        }
    }

    private func revoke() {
        guard let client = selectClient("Revoke which client?") else { return }
        let confirm = NSAlert()
        confirm.messageText = "Revoke \(client.name)?"
        confirm.informativeText = "Its key and every collection grant stop working immediately."
        confirm.addButton(withTitle: "Revoke")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        switch registry.revoke(clientID: client.id) {
        case .success:
            switch credentialFiles.remove(clientID: client.id) {
            case .success: notice("Client revoked and its local credential file removed.")
            case .failure(let error):
                notice("Client revoked, but credential file removal failed (\(error.rawValue)). Remove the file at \(credentialFiles.url(for: client.id)?.path ?? "the displayed client path") after checking it.")
            }
        case .failure(let error): notice("Revocation failed: \(error.rawValue)")
        }
    }

    private func editGrants() {
        guard let client = selectClient("Edit grants for which client?") else { return }
        var targets = [(resource: ClientResource, calendar: EKCalendar)]()
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            targets += store.calendars(for: .event).map { (.calendar, $0) }
        }
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess {
            targets += store.calendars(for: .reminder).map { (.reminderList, $0) }
        }
        guard !targets.isEmpty else {
            notice("Grant Calendar or Reminders Full Access before selecting a collection.")
            return
        }
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 550, height: 28))
        for target in targets {
            let kind = target.resource == .calendar ? "Calendar" : "Reminder list"
            picker.addItem(withTitle: "\(kind): \(target.calendar.title) [\(target.calendar.calendarIdentifier)]")
        }
        let choose = NSAlert()
        choose.messageText = "Choose one collection"
        choose.informativeText = "Repeat this action to add or change other collection grants."
        choose.accessoryView = picker
        choose.addButton(withTitle: "Continue")
        choose.addButton(withTitle: "Cancel")
        guard choose.runModal() == .alertFirstButtonReturn,
              targets.indices.contains(picker.indexOfSelectedItem) else { return }
        let selected = targets[picker.indexOfSelectedItem]
        let kind = selected.resource == .calendar ? "Calendar" : "Reminder list"
        let writable = selected.calendar.allowsContentModifications
        let old = client.grants.first {
            $0.resource == selected.resource &&
                $0.targetID == selected.calendar.calendarIdentifier
        }
        let permissions: [(String, Int)] = selected.resource == .calendar
            ? [("Read", ClientGrant.read), ("Create", ClientGrant.create),
               ("Edit", ClientGrant.edit), ("Delete", ClientGrant.delete)]
            : [("Read", ClientGrant.read), ("Create", ClientGrant.create),
               ("Edit", ClientGrant.edit), ("Delete", ClientGrant.delete),
               ("Complete", ClientGrant.complete)]
        let controls = permissions.map { title, bit -> NSButton in
            let check = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            check.isEnabled = bit == ClientGrant.read || writable
            check.state = check.isEnabled && ((old?.mask ?? 0) & bit) != 0 ? .on : .off
            return check
        }
        // NSAlert measures an accessory view by its frame. A bare NSStackView
        // has no initial frame, so AppKit can lay the checkboxes over the
        // informative text and leave them impossible to click.
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 480,
                                             height: CGFloat(controls.count) * 30))
        let stack = NSStackView(views: controls)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
            stack.topAnchor.constraint(equalTo: accessory.topAnchor),
            stack.bottomAnchor.constraint(equalTo: accessory.bottomAnchor),
        ])
        let edit = NSAlert()
        edit.messageText = "Permissions for \(client.name)"
        edit.informativeText = "\(kind): \(selected.calendar.title)\nID: \(selected.calendar.calendarIdentifier)\n" +
            (writable ? "" : "EventKit reports this collection as read-only.\n") +
            "Checked actions remain authorized until changed or revoked. Clear all to remove this grant."
        edit.accessoryView = accessory
        edit.addButton(withTitle: "Save Grants")
        edit.addButton(withTitle: "Cancel")
        guard edit.runModal() == .alertFirstButtonReturn else { return }
        let mask = zip(controls, permissions).reduce(0) { result, pair in
            result | (pair.0.state == .on ? pair.1.1 : 0)
        }
        let grants = ClientGrantEditing.replacing(
            client.grants, resource: selected.resource,
            targetID: selected.calendar.calendarIdentifier,
            requestedMask: mask, writable: writable)
        switch registry.replaceGrants(clientID: client.id, grants: grants) {
        case .success: notice("Grants saved. Any in-progress request must be sent again.")
        case .failure(let error): notice("Grant update failed: \(error.rawValue)")
        }
    }

    private func activity() {
        guard let rows = registry.activity() else {
            notice("Activity history is unavailable.")
            return
        }
        let formatter = ISO8601DateFormatter()
        let body = rows.prefix(100).map { row in
            "\(formatter.string(from: row.at))  \(row.clientID ?? "unknown")  \(row.command)  \(row.outcome)"
        }.joined(separator: "\n")
        let alert = NSAlert()
        alert.messageText = "Recent bridge activity"
        alert.informativeText = "Only time, client ID, command and result are stored. Item titles and key material are omitted."
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 720, height: 300))
        text.string = body.isEmpty ? "No activity yet." : body
        text.isEditable = false
        text.isSelectable = true
        alert.accessoryView = text
        alert.addButton(withTitle: "Close")
        alert.runModal()
    }

    private func selectClient(_ title: String) -> ClientView? {
        guard let clients = registry.clients()?.filter({ !$0.revoked }), !clients.isEmpty else {
            notice("No active clients.")
            return nil
        }
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 460, height: 28))
        for client in clients { picker.addItem(withTitle: "\(client.name) [\(client.id)]") }
        let alert = NSAlert()
        alert.messageText = title
        alert.accessoryView = picker
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn,
              clients.indices.contains(picker.indexOfSelectedItem) else { return nil }
        return clients[picker.indexOfSelectedItem]
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

    private func notice(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
