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
}
