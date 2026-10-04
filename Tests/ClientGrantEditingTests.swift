import Foundation

@main
struct ClientGrantEditingTests {
    static func main() {
        let calendar = ClientGrant(resource: .calendar, targetID: "calendar-one",
                                   mask: ClientGrant.read)
        let other = ClientGrant(resource: .reminderList, targetID: "list-two",
                                mask: ClientGrant.read | ClientGrant.complete)
        let old = [calendar, other]
        let expanded = ClientGrantEditing.replacing(old, resource: .calendar,
            targetID: "calendar-one", requestedMask: 15, writable: true)
        precondition(expanded.count == 2 && expanded.contains(other))
        precondition(expanded.first(where: { $0.targetID == "calendar-one" })?.mask == 15)
        let readOnly = ClientGrantEditing.replacing(expanded, resource: .calendar,
            targetID: "calendar-one", requestedMask: 15, writable: false)
        precondition(readOnly.first(where: { $0.targetID == "calendar-one" })?.mask == ClientGrant.read)
        precondition(readOnly.contains(other))
        let removed = ClientGrantEditing.replacing(readOnly, resource: .calendar,
            targetID: "calendar-one", requestedMask: 0, writable: false)
        precondition(removed == [other])
        let newList = ClientGrantEditing.replacing(removed, resource: .reminderList,
            targetID: "list-three", requestedMask: 31, writable: true)
        precondition(newList.count == 2 && newList.contains(other))
        precondition(newList.first(where: { $0.targetID == "list-three" })?.mask == 31)
        precondition(ClientGrantEditing.allowedMask(resource: .reminderList, writable: false) == 1)
        print("Grant editing: add, expand, preserve others, read-only restriction, clear passed")
    }
}
