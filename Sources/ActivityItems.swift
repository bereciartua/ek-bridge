import Foundation

/// Which item a write touched, from the request and its result (P6). Only
/// EventKit identifiers are taken; never a title or any other field.
/// Reads never get an item reference.
enum ActivityItems {
    static func ref(command: BridgeCommand, parameters: [String: Any], result: [String: Any]) -> ItemRef? {
        guard command.isWrite else { return nil }
        let item = result["item"] as? [String: Any]
        let requested = parameters["itemID"] as? String
        let ref: ItemRef?
        switch command {
        case .createEvent, .updateEvent:
            ref = (item?["id"] as? String ?? requested ?? result["itemID"] as? String).map {
                ItemRef(kind: "event", id: $0,
                        occurrence: number(item?["occurrenceStart"]) ?? number(parameters["occurrenceStart"]),
                        span: parameters["span"] as? String,
                        externalID: item?["externalID"] as? String)
            }
        case .deleteEvent:
            ref = requested.map {
                ItemRef(kind: "event", id: $0, occurrence: number(parameters["occurrenceStart"]),
                        span: parameters["span"] as? String)
            }
        case .createReminder, .updateReminder:
            ref = (item?["id"] as? String ?? requested ?? result["itemID"] as? String).map {
                ItemRef(kind: "reminder", id: $0, span: parameters["recurrenceScope"] as? String,
                        externalID: item?["externalID"] as? String)
            }
        case .completeReminder:
            // A repeating reminder: the completed occurrence is a new item.
            if let done = result["completedOccurrence"] as? [String: Any], let id = done["id"] as? String {
                ref = ItemRef(kind: "reminder", id: id, occurrence: number(result["completedDue"]),
                              span: parameters["recurrenceScope"] as? String)
            } else {
                ref = (item?["id"] as? String ?? requested).map {
                    ItemRef(kind: "reminder", id: $0, occurrence: number(parameters["occurrenceDue"]),
                            span: parameters["recurrenceScope"] as? String)
                }
            }
        case .deleteReminder:
            ref = requested.map {
                ItemRef(kind: "reminder", id: $0, occurrence: number(parameters["occurrenceDue"]),
                        span: parameters["recurrenceScope"] as? String)
            }
        default:
            ref = nil
        }
        guard let ref, ref.isValid else { return nil }
        // An ID the request supplied is the agent's text until EventKit has
        // used it: for a write that didn't go through, keep it only if it's
        // shaped like an EventKit ID, so Activity never holds anything else.
        let fromRequest = requested == ref.id && (item?["id"] as? String) != ref.id &&
            (result["itemID"] as? String) != ref.id
        if fromRequest && result["error"] != nil && !looksLikeEventKitID(ref.id) { return nil }
        return ref
    }

    /// "UUID", "UUID:UUID", optionally with "/RID=<seconds>" (an occurrence).
    static func looksLikeEventKitID(_ id: String) -> Bool {
        let uuid = "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
        return id.range(of: "^\(uuid)(:\(uuid))?(/RID=[0-9]+)?$", options: .regularExpression) != nil
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }
}
