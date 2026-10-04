import AppKit
import EventKit

// All credential and grant changes are explicit local UI actions. The app
// never writes a client secret to disk or copies it to the clipboard.
@MainActor
final class ClientManagerUI {
    private let registry: ClientRegistry
    private let store: EKEventStore

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
            "\n\nA key is shown once. Keep its credentials file private (mode 0600). Other processes running as this macOS user can read that file."
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
        alert.informativeText = "The client will have no collection permissions until you add grants."
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        switch registry.createClient(name: field.stringValue) {
        case .success(let issued): showKey(clientID: issued.id, key: issued.key)
        case .failure(let error): notice("Client creation failed: \(error.rawValue)")
        }
    }

    private func rotate() {
        guard let client = selectClient("Rotate which client's key?") else { return }
        let confirm = NSAlert()
        confirm.messageText = "Rotate key for \(client.name)?"
        confirm.informativeText = "The old key stops working immediately. An in-progress request loses authorization."
        confirm.addButton(withTitle: "Rotate")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        switch registry.rotateKey(clientID: client.id) {
        case .success(let key): showKey(clientID: client.id, key: key)
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
        case .success: notice("Client revoked.")
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
            check.state = ((old?.mask ?? 0) & bit) != 0 ? .on : .off
            return check
        }
        let stack = NSStackView(views: controls)
        stack.orientation = .vertical
        stack.alignment = .leading
        let edit = NSAlert()
        edit.messageText = "Permissions for \(selected.calendar.title)"
        edit.informativeText = "Every unchecked action is denied. Clear all boxes to remove this grant. Each write also needs exact on-screen approval."
        edit.accessoryView = stack
        edit.addButton(withTitle: "Save Grants")
        edit.addButton(withTitle: "Cancel")
        guard edit.runModal() == .alertFirstButtonReturn else { return }
        let mask = zip(controls, permissions).reduce(0) { result, pair in
            result | (pair.0.state == .on ? pair.1.1 : 0)
        }
        var grants = client.grants.filter {
            $0.resource != selected.resource ||
                $0.targetID != selected.calendar.calendarIdentifier
        }
        if mask > 0 {
            grants.append(ClientGrant(resource: selected.resource,
                                      targetID: selected.calendar.calendarIdentifier,
                                      mask: mask))
        }
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

    private func showKey(clientID: String, key: String) {
        let alert = NSAlert()
        alert.messageText = "Save this key now"
        alert.informativeText = "It will not be shown again. Store this exact JSON in a private mode-0600 file for the local client. A same-user process can read that file."
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 90))
        text.string = "{\"clientID\":\"\(clientID)\",\"key\":\"\(key)\"}"
        text.isEditable = false
        text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        alert.accessoryView = text
        alert.addButton(withTitle: "Done")
        alert.runModal()
        text.string = ""
    }

    private func notice(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
