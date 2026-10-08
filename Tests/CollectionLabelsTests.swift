import Foundation

// collection-labels.json: last-known names for granted collections only.
@main
struct CollectionLabelsTests {
    static func main() {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("collection-labels-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            precondition(condition, message)
        }

        let grey = CollectionColor(red: 0.5, green: 0.5, blue: 0.5)
        let project = CollectionInfo(resource: .calendar, id: "cal-project", name: "Project calendar",
                                     account: "Exchange", writable: true, color: grey)
        let home = CollectionInfo(resource: .calendar, id: "cal-home", name: "Home", account: "iCloud",
                                  writable: true, color: nil)
        let groceries = CollectionInfo(resource: .reminderList, id: "list-groceries", name: "Groceries",
                                       account: "iCloud", writable: true, color: nil)
        let both: Set<ClientResource> = [.calendar, .reminderList]
        let day1 = Date(timeIntervalSince1970: 1_791_000_000)
        let day2 = day1.addingTimeInterval(86_400)

        let store = CollectionLabelStore(folder: folder)
        // Only granted collections get a label.
        check(store.update(listed: [project, home, groceries], listedResources: both,
                           granted: [project.key, groceries.key], now: day1), "first update writes")
        check(store.labels.count == 2 && store.label(for: home.key) == nil, "ungranted collections have no label")
        check(store.label(for: project.key) == CollectionLabel(name: "Project calendar", account: "Exchange",
                                                             colorHex: "#808080",
                                                             lastSeen: day1.timeIntervalSince1970,
                                                             missingSince: nil), "label fields")
        check(store.label(for: project.key)?.color == CollectionColor(red: 128.0 / 255, green: 128.0 / 255,
                                                                     blue: 128.0 / 255), "colour round trip")
        let mode = (try! FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions]) as! NSNumber
        check(mode.intValue == 0o600, "private file")

        // Nothing changed: no write, even a day later.
        let writes = store.writes
        check(!store.update(listed: [project, home, groceries], listedResources: both,
                            granted: [project.key, groceries.key], now: day2) && store.writes == writes,
              "no write without a change")

        // A rename is picked up.
        let renamed = CollectionInfo(resource: .reminderList, id: "list-groceries", name: "Shopping",
                                     account: "iCloud", writable: true, color: nil)
        check(store.update(listed: [project, renamed], listedResources: both,
                           granted: [project.key, groceries.key], now: day2)
              && store.label(for: groceries.key)?.name == "Shopping", "rename updates the label")

        // Granted but no longer listed: marked missing, once.
        check(store.update(listed: [renamed], listedResources: both, granted: [project.key, groceries.key], now: day2)
              && store.label(for: project.key)?.missingSince == day2.timeIntervalSince1970
              && store.label(for: project.key)?.name == "Project calendar", "marked missing, name kept")
        check(!store.update(listed: [renamed], listedResources: both, granted: [project.key, groceries.key],
                            now: day2.addingTimeInterval(60)), "missing since doesn't move")

        // Without Calendar access nothing is listed; labels stay as they are.
        let fresh = CollectionLabelStore(folder: folder)
        check(fresh.labels == store.labels, "labels reload from the file")
        check(!fresh.update(listed: [renamed], listedResources: [.reminderList],
                            granted: [project.key, groceries.key], now: day2), "no access keeps labels")

        // Listed again: no longer missing.
        check(fresh.update(listed: [project, renamed], listedResources: both,
                           granted: [project.key, groceries.key], now: day2)
              && fresh.label(for: project.key)?.missingSince == nil, "back again")

        // The grant goes: so does the label.
        check(fresh.update(listed: [project, renamed], listedResources: both, granted: [groceries.key], now: day2)
              && fresh.label(for: project.key) == nil && fresh.labels.count == 1, "dropped with the grant")

        // A damaged file starts over empty.
        try! Data("not json".utf8).write(to: fresh.fileURL)
        check(CollectionLabelStore(folder: folder).labels.isEmpty, "unreadable file starts empty")
        print("Collection labels: \(checks) add, rename, missing, no access, drop, no-write and file checks passed")
    }
}
