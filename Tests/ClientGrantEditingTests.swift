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
        // Starting access for a new connection (B05).
        let listed: [(key: GrantKey, writable: Bool)] = [
            (GrantKey(resource: .calendar, targetID: "home"), true),
            (GrantKey(resource: .calendar, targetID: "holidays"), false),
            (GrantKey(resource: .reminderList, targetID: "groceries"), true)]
        let none = StartingAccess.grants(.nothing, listed: listed)
        precondition(none.grants.isEmpty && !none.capped)
        let readAll = StartingAccess.grants(.readAll, listed: listed)
        precondition(readAll.grants.count == 3 && readAll.grants.allSatisfy { $0.mask == ClientGrant.read } &&
                     !readAll.capped)
        let plusList = StartingAccess.grants(.readAllPlusOne(GrantKey(resource: .reminderList, targetID: "groceries")),
                                             listed: listed)
        precondition(plusList.grants.count == 3)
        precondition(plusList.grants.first { $0.targetID == "groceries" }?.mask == 31, "full on the chosen list")
        precondition(plusList.grants.filter { $0.targetID != "groceries" }.allSatisfy { $0.mask == ClientGrant.read })
        let plusCalendar = StartingAccess.grants(.readAllPlusOne(GrantKey(resource: .calendar, targetID: "home")),
                                                 listed: listed)
        precondition(plusCalendar.grants.first { $0.targetID == "home" }?.mask == 15, "calendars have no Complete")
        // A read-only choice can only be read (the sheet offers writable ones only).
        let plusReadOnly = StartingAccess.grants(.readAllPlusOne(GrantKey(resource: .calendar, targetID: "holidays")),
                                                 listed: listed)
        precondition(plusReadOnly.grants.first { $0.targetID == "holidays" }?.mask == ClientGrant.read)
        // The cap: 99 grants, in display order, and the chosen one always included.
        let many: [(key: GrantKey, writable: Bool)] = (0..<120).map {
            (GrantKey(resource: .calendar, targetID: "c\($0)"), true)
        }
        let cappedAll = StartingAccess.grants(.readAll, listed: many)
        precondition(cappedAll.grants.count == 99 && cappedAll.capped &&
                     cappedAll.grants.map(\.targetID) == (0..<99).map { "c\($0)" })
        let cappedPlus = StartingAccess.grants(.readAllPlusOne(GrantKey(resource: .calendar, targetID: "c110")),
                                               listed: many)
        precondition(cappedPlus.grants.count == 99 && cappedPlus.capped &&
                     cappedPlus.grants.first?.targetID == "c110" && cappedPlus.grants.first?.mask == 15 &&
                     cappedPlus.grants.dropFirst().map(\.targetID) == (0..<98).map { "c\($0)" })
        let exactly = StartingAccess.grants(.readAll, listed: Array(many.prefix(99)))
        precondition(exactly.grants.count == 99 && !exactly.capped)
        print("Grant editing: add, expand, preserve others, read-only restriction, clear, starting access and its cap passed")
    }
}
