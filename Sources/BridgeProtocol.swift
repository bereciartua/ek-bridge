import Foundation

enum BridgeCommand: String, CaseIterable {
    case authorizationStatus = "authorization_status"
    case calendarCount = "calendar_count"
    case reminderListCount = "reminder_list_count"
    case scopeStatus = "scope_status"
    case listCollections = "list_collections"
    case readEvents = "read_events"
    case getEvent = "get_event"
    case readReminders = "read_reminders"
    case getReminder = "get_reminder"
    case createEvent = "create_event"
    case updateEvent = "update_event"
    case deleteEvent = "delete_event"
    case createReminder = "create_reminder"
    case updateReminder = "update_reminder"
    case completeReminder = "complete_reminder"
    case deleteReminder = "delete_reminder"

    var isWrite: Bool {
        switch self {
        case .createEvent, .updateEvent, .deleteEvent, .createReminder, .updateReminder,
             .completeReminder, .deleteReminder: true
        default: false
        }
    }

    /// Commands about the client itself rather than one calendar or list.
    /// They need only an enrolled client and are never checked against a grant.
    var isClientLevel: Bool {
        switch self {
        case .authorizationStatus, .calendarCount, .reminderListCount, .scopeStatus,
             .listCollections: true
        default: false
        }
    }
}

// Accepted parameter keys per command. CommandPolicy.validate checks keys
// against this table and `bridge-client --help` prints it, so they can't drift.
struct CommandParameterKeys: Equatable {
    let required: [String]
    let optional: [String]

    var isEmpty: Bool { required.isEmpty && optional.isEmpty }
}

extension BridgeCommand {
    var parameterKeys: CommandParameterKeys {
        switch self {
        case .authorizationStatus, .calendarCount, .reminderListCount, .scopeStatus,
             .listCollections:
            CommandParameterKeys(required: [], optional: [])
        case .readEvents:
            CommandParameterKeys(required: ["calendarID", "start", "end", "limit"], optional: ["afterKey"])
        case .getEvent:
            CommandParameterKeys(required: ["calendarID", "itemID"], optional: ["occurrenceStart"])
        case .readReminders:
            CommandParameterKeys(required: ["listID", "limit"],
                                 optional: ["afterID", "status", "dueAfter", "dueBefore"])
        case .getReminder:
            CommandParameterKeys(required: ["listID", "itemID"], optional: [])
        case .createEvent:
            CommandParameterKeys(required: ["calendarID", "title", "start", "end", "idempotencyKey"],
                                 optional: ["allDay", "timeZone", "notes", "location", "structuredLocation",
                                            "url", "alarms", "availability", "recurrence"])
        case .updateEvent:
            CommandParameterKeys(required: ["calendarID", "itemID", "expectedVersion", "idempotencyKey"],
                                 optional: ["title", "start", "end", "allDay", "timeZone", "notes", "location",
                                            "structuredLocation", "url", "alarms", "availability",
                                            "recurrence", "occurrenceStart", "span", "targetCalendarID",
                                            "replaceUnsupportedAlarms"])
        case .deleteEvent:
            CommandParameterKeys(required: ["calendarID", "itemID", "expectedVersion",
                                            "idempotencyKey"], optional: ["occurrenceStart", "span"])
        case .createReminder:
            CommandParameterKeys(required: ["listID", "title", "idempotencyKey"],
                                 optional: ["due", "start", "recurrence", "notes", "url", "location",
                                            "priority", "alarms"])
        case .updateReminder:
            CommandParameterKeys(required: ["listID", "itemID", "expectedVersion", "idempotencyKey"],
                                 optional: ["title", "due", "start", "recurrence", "notes", "url", "location",
                                            "priority", "alarms", "completed", "targetListID",
                                            "replaceUnsupportedAlarms"])
        case .completeReminder:
            CommandParameterKeys(required: ["listID", "itemID", "expectedVersion", "idempotencyKey"],
                                 optional: ["recurrenceScope", "occurrenceDue",
                                            "occurrenceFingerprint"])
        case .deleteReminder:
            CommandParameterKeys(required: ["listID", "itemID", "expectedVersion", "idempotencyKey"],
                                 optional: ["recurrenceScope"])
        }
    }

    /// True when `parameters` has every required key and nothing unknown.
    func acceptsKeys(of parameters: [String: Any]) -> Bool {
        let keys = parameterKeys
        let actual = Set(parameters.keys)
        let required = Set(keys.required)
        return required.isSubset(of: actual) &&
            actual.isSubset(of: required.union(keys.optional))
    }
}

struct BridgeRequest {
    let id: String
    let command: BridgeCommand
    let parameters: [String: Any]
}

enum BridgeRequestError: String, Error {
    case tooLarge = "request_too_large"
    case invalid = "invalid_request"
    case unauthorized = "unauthorized"
    case expired = "expired_request"
    case replay = "replayed_request"
}

enum BridgeProtocol {
    /// An update with 8,000 bytes of notes and every other field (plan 03 §16).
    static let maxRequestBytes = 32_768
    static let maxResponseBytes = 1_048_576
    static let requestLifetime: TimeInterval = 30

    static func validate(
        _ data: Data,
        token: String,
        now: TimeInterval,
        usedIDs: Set<String>
    ) -> Result<BridgeRequest, BridgeRequestError> {
        guard data.count <= maxRequestBytes else { return .failure(.tooLarge) }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any],
              Set(fields.keys) == Set(["version", "id", "command", "token", "issuedAt", "parameters"]),
              let version = fields["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.intValue == 1,
              version.doubleValue == 1,
              let id = fields["id"] as? String, UUID(uuidString: id) != nil,
              let commandName = fields["command"] as? String,
              let command = BridgeCommand(rawValue: commandName),
              let suppliedToken = fields["token"] as? String,
              let issuedAtNumber = fields["issuedAt"] as? NSNumber,
              CFGetTypeID(issuedAtNumber) != CFBooleanGetTypeID(),
              let issuedAt = Optional(issuedAtNumber.doubleValue), issuedAt.isFinite,
              let parameters = fields["parameters"] as? [String: Any]
        else { return .failure(.invalid) }
        guard secureEquals(suppliedToken, token) else { return .failure(.unauthorized) }
        guard now - issuedAt <= requestLifetime, issuedAt - now <= 5 else {
            return .failure(.expired)
        }
        guard !usedIDs.contains(id) else { return .failure(.replay) }
        return .success(BridgeRequest(id: id, command: command, parameters: parameters))
    }

    private static func secureEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = left.count ^ right.count
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            difference |= Int(a ^ b)
        }
        return difference == 0
    }
}
