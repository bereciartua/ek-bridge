import Foundation

enum ClientGrantEditing {
    static func allowedMask(resource: ClientResource, writable: Bool) -> Int {
        guard writable else { return ClientGrant.read }
        return resource == .calendar ? 15 : 31
    }

    static func replacing(_ grants: [ClientGrant], resource: ClientResource,
                          targetID: String, requestedMask: Int,
                          writable: Bool) -> [ClientGrant] {
        let retained = grants.filter {
            $0.resource != resource || $0.targetID != targetID
        }
        let mask = requestedMask & allowedMask(resource: resource, writable: writable)
        guard mask > 0 else { return retained }
        return retained + [ClientGrant(resource: resource, targetID: targetID, mask: mask)]
    }

    /// Any write action turns on Read. Used by the checkbox action and the row
    /// shortcuts only; saved grants and registry validation are never widened.
    static func withImpliedRead(_ mask: Int) -> Int {
        mask & ~ClientGrant.read != 0 ? mask | ClientGrant.read : mask
    }

    /// The mask after the user checks or unchecks one action.
    static func toggling(_ mask: Int, bit: Int, on: Bool) -> Int {
        guard on else { return mask & ~bit }
        return bit == ClientGrant.read ? mask | bit : withImpliedRead(mask | bit)
    }

    /// Write actions without Read: allowed, but the client can't look items up.
    static func writeWithoutRead(_ mask: Int) -> Bool {
        mask & ClientGrant.read == 0 && mask & ~ClientGrant.read != 0
    }
}

struct GrantKey: Hashable {
    let resource: ClientResource
    let targetID: String
}

/// Staged access edits for one client. Saving starts from the client's saved
/// grants, so grants for calendars EventKit doesn't list are kept unless the
/// user removes them.
struct GrantDraft: Equatable {
    let clientID: String
    private(set) var saved: [GrantKey: Int]
    private(set) var staged: [GrantKey: Int]

    init(client: ClientView) {
        clientID = client.id
        let masks = Dictionary(client.grants.map {
            (GrantKey(resource: $0.resource, targetID: $0.targetID), $0.mask)
        }, uniquingKeysWith: { $1 })
        saved = masks
        staged = masks
    }

    func mask(_ key: GrantKey) -> Int { staged[key] ?? 0 }
    func savedMask(_ key: GrantKey) -> Int { saved[key] ?? 0 }

    mutating func set(_ key: GrantKey, mask: Int) {
        staged[key] = mask == 0 ? nil : mask
    }

    func isChanged(_ key: GrantKey) -> Bool { mask(key) != savedMask(key) }

    /// Number of changed cells (one per action checked or unchecked).
    var changedCells: Int {
        Set(saved.keys).union(staged.keys).reduce(0) {
            $0 + (mask($1) ^ savedMask($1)).nonzeroBitCount
        }
    }

    var hasChanges: Bool { saved != staged }

    /// The grants to save. Every listed calendar or list is rewritten through
    /// `ClientGrantEditing.replacing`, which also drops write actions from
    /// calendars that are now read only. Unlisted grants are kept unless removed.
    func grantsToSave(base: [ClientGrant],
                      listed: [(key: GrantKey, writable: Bool)]) -> [ClientGrant] {
        var grants = base
        var handled = Set<GrantKey>()
        for row in listed {
            handled.insert(row.key)
            let allowed = ClientGrantEditing.allowedMask(resource: row.key.resource,
                                                         writable: row.writable)
            // Unchanged, still-valid rows keep their place in the saved list.
            guard isChanged(row.key) || mask(row.key) & ~allowed != 0 else { continue }
            grants = ClientGrantEditing.replacing(
                grants, resource: row.key.resource, targetID: row.key.targetID,
                requestedMask: mask(row.key), writable: row.writable)
        }
        for key in Set(saved.keys).union(staged.keys).subtracting(handled) where isChanged(key) {
            grants.removeAll { $0.resource == key.resource && $0.targetID == key.targetID }
            if mask(key) != 0 {
                grants.append(ClientGrant(resource: key.resource, targetID: key.targetID,
                                          mask: mask(key)))
            }
        }
        return grants
    }
}
