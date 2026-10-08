import Foundation

/// A granted calendar's or list's last-known name, so the app can still name
/// it when EventKit stops listing it (an account signed out, say).
struct CollectionLabel: Codable, Equatable {
    var name: String
    var account: String
    /// "#RRGGBB", or nil when EventKit gave no colour.
    var colorHex: String?
    /// When it was last listed (seconds since 1970).
    var lastSeen: TimeInterval
    /// When it stopped being listed, while it's still granted.
    var missingSince: TimeInterval?

    var color: CollectionColor? {
        guard let hex = colorHex, hex.count == 7, hex.hasPrefix("#"),
              let value = Int(hex.dropFirst(), radix: 16) else { return nil }
        return CollectionColor(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255,
                               blue: Double(value & 0xff) / 255)
    }

    static func hex(_ color: CollectionColor?) -> String? {
        guard let color else { return nil }
        func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(color.red), byte(color.green), byte(color.blue))
    }
}

/// `collection-labels.json` in the data folder (0600, atomic writes): the
/// names, accounts and colours of the calendars and lists that some active
/// connection has access to, and nothing else. Labels are cosmetic, so an
/// unreadable file starts over empty. Foundation only (unit tested).
final class CollectionLabelStore {
    static let fileName = "collection-labels.json"
    static let version = 1

    private struct File: Codable {
        var version: Int
        var labels: [String: CollectionLabel]
    }

    let fileURL: URL
    private(set) var labels: [String: CollectionLabel]
    /// Writes so far (tests check that unchanged updates don't write).
    private(set) var writes = 0

    init(folder: URL) {
        fileURL = folder.appendingPathComponent(Self.fileName)
        if let data = try? Data(contentsOf: fileURL),
           let file = try? JSONDecoder().decode(File.self, from: data), file.version == Self.version {
            labels = file.labels
        } else {
            labels = [:]
        }
    }

    static func key(_ grant: GrantKey) -> String { "\(grant.resource.rawValue):\(grant.targetID)" }

    func label(for key: GrantKey) -> CollectionLabel? { labels[Self.key(key)] }

    /// Keeps labels only for `granted` collections: adds or refreshes the
    /// listed ones, marks the others missing, drops labels nobody is granted.
    /// Collections of a resource not in `listedResources` (no macOS access)
    /// keep their labels as they are. Writes only when something changed.
    @discardableResult
    func update(listed: [CollectionInfo], listedResources: Set<ClientResource>, granted: Set<GrantKey>,
                now: Date = Date()) -> Bool {
        var next = [String: CollectionLabel]()
        let byKey = Dictionary(listed.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        for grant in granted {
            let key = Self.key(grant)
            let old = labels[key]
            if let collection = byKey[grant] {
                let fresh = CollectionLabel(name: collection.name, account: collection.account,
                                            colorHex: CollectionLabel.hex(collection.color),
                                            lastSeen: now.timeIntervalSince1970, missingSince: nil)
                // The same label stays as it is, so a refresh doesn't write.
                if let old, old.name == fresh.name, old.account == fresh.account,
                   old.colorHex == fresh.colorHex, old.missingSince == nil {
                    next[key] = old
                } else {
                    next[key] = fresh
                }
            } else if var old {
                if listedResources.contains(grant.resource), old.missingSince == nil {
                    old.missingSince = now.timeIntervalSince1970
                }
                next[key] = old
            }
        }
        guard next != labels else { return false }
        labels = next
        save()
        return true
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(File(version: Self.version, labels: labels)) else { return }
        do {
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            writes += 1
        } catch {
            // Cosmetic: the next change tries again.
        }
    }
}
