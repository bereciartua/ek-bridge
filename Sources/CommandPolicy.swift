import Foundation

enum ReminderRecurrenceScope: String {
    case occurrence
    case series

    static func parse(_ value: Any?) -> Self? {
        guard let raw = value as? String else { return nil }
        return Self(rawValue: raw)
    }
}

// Strict shape checks run before EventKit is touched. The target comes from
// the signed client's saved grant; empty IDs deny all item access.
struct BridgeScope {
    var calendarID: String?
    var reminderListID: String?
    var generation = 0
}

enum CommandPolicy {
    static func scopeStillSelected(id: String, generation: Int,
                                   scope: BridgeScope, reminders: Bool) -> Bool {
        scope.generation == generation &&
            (reminders ? scope.reminderListID : scope.calendarID) == id
    }

    /// The parameter keys a command accepts. `validate` checks keys against
    /// this same table before any value checks.
    static func parameterKeys(for command: BridgeCommand) -> CommandParameterKeys {
        command.parameterKeys
    }

    static func validate(_ request: BridgeRequest, scope: BridgeScope) -> String? {
        let p = request.parameters
        let command = request.command
        let keysAccepted = command.acceptsKeys(of: p)
        switch command {
        case .authorizationStatus, .calendarCount, .reminderListCount, .scopeStatus:
            return keysAccepted ? nil : "invalid_parameters"
        case .readEvents:
            guard keysAccepted,
                  target(p, "calendarID", scope.calendarID),
                  let start = number(p["start"]), let end = number(p["end"]),
                  validTimestamp(start), validTimestamp(end),
                  end > start, end - start <= 31 * 86_400,
                  let limit = integer(p["limit"]), (1...100).contains(limit)
            else { return "invalid_parameters_or_target" }
        case .readReminders:
            guard keysAccepted,
                  target(p, "listID", scope.reminderListID),
                  let limit = integer(p["limit"]), (1...100).contains(limit),
                  p["afterID"] == nil || item(p["afterID"])
            else { return "invalid_parameters_or_target" }
        case .createEvent:
            guard keysAccepted,
                  target(p, "calendarID", scope.calendarID),
                  title(p["title"]),
                  EventCreationDetails.parse(p) != nil,
                  (p["allDay"] != nil || dateRange(p["start"], p["end"])),
                  WriteIdempotencyKey.timestamp(p["idempotencyKey"]) != nil
            else { return "invalid_parameters_or_target" }
        case .updateEvent:
            guard keysAccepted,
                  target(p, "calendarID", scope.calendarID),
                  item(p["itemID"]), version(p["expectedVersion"]),
                  title(p["title"]), dateRange(p["start"], p["end"]),
                  WriteIdempotencyKey.timestamp(p["idempotencyKey"]) != nil
            else { return "invalid_parameters_or_target" }
        case .deleteEvent:
            guard keysAccepted,
                  target(p, "calendarID", scope.calendarID),
                  item(p["itemID"]), version(p["expectedVersion"]),
                  WriteIdempotencyKey.timestamp(p["idempotencyKey"]) != nil
            else { return "invalid_parameters_or_target" }
        case .createReminder:
            guard keysAccepted,
                  target(p, "listID", scope.reminderListID),
                  title(p["title"]), WriteIdempotencyKey.timestamp(p["idempotencyKey"]) != nil,
                  let due = ReminderDueChange.parse(parameters: p),
                  let recurrence = ReminderRecurrenceChange.parse(parameters: p),
                  validReminderCreation(due: due, recurrence: recurrence)
            else { return "invalid_parameters_or_target" }
        case .updateReminder:
            guard keysAccepted,
                  target(p, "listID", scope.reminderListID),
                  item(p["itemID"]), version(p["expectedVersion"]),
                  title(p["title"]), WriteIdempotencyKey.timestamp(p["idempotencyKey"]) != nil,
                  ReminderDueChange.parse(parameters: p) != nil,
                  ReminderRecurrenceChange.parse(parameters: p) != nil
            else { return "invalid_parameters_or_target" }
        case .completeReminder:
            guard keysAccepted,
                  target(p, "listID", scope.reminderListID),
                  item(p["itemID"]), version(p["expectedVersion"]),
                  (p["recurrenceScope"] == nil ||
                   ReminderRecurrenceScope.parse(p["recurrenceScope"]) != nil),
                  ((p["recurrenceScope"] as? String == "occurrence" &&
                    ReminderDueSpec.timestamp(p["occurrenceDue"]) != nil &&
                    fingerprint(p["occurrenceFingerprint"])) ||
                   (p["recurrenceScope"] as? String != "occurrence" &&
                    p["occurrenceDue"] == nil && p["occurrenceFingerprint"] == nil)),
                  WriteIdempotencyKey.timestamp(p["idempotencyKey"]) != nil
            else { return "invalid_parameters_or_target" }
        case .deleteReminder:
            guard keysAccepted,
                  target(p, "listID", scope.reminderListID),
                  item(p["itemID"]), version(p["expectedVersion"]),
                  (p["recurrenceScope"] == nil ||
                   ReminderRecurrenceScope.parse(p["recurrenceScope"]) != nil),
                  WriteIdempotencyKey.timestamp(p["idempotencyKey"]) != nil
            else { return "invalid_parameters_or_target" }
        }
        return nil
    }

    private static func validReminderCreation(due: ReminderDueChange,
                                              recurrence: ReminderRecurrenceChange) -> Bool {
        if case .set = recurrence {
            if case .set = due { return true }
            return false
        }
        return true
    }
    private static func target(_ p: [String: Any], _ key: String, _ allowed: String?) -> Bool {
        guard let allowed, !allowed.isEmpty else { return false }
        return p[key] as? String == allowed
    }
    private static func title(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            value.utf8.count <= 200 && !value.contains("\u{0000}")
    }
    private static func item(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        return !value.isEmpty && value.utf8.count <= 512
    }
    private static func version(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        return !value.isEmpty && value.utf8.count <= 64
    }
    private static func fingerprint(_ value: Any?) -> Bool {
        guard let value = value as? String, value.utf8.count == 64 else { return false }
        return value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func uuid(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        return UUID(uuidString: value) != nil
    }
    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        return value.doubleValue
    }
    private static func integer(_ value: Any?) -> Int? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let n = value.doubleValue
        return n.isFinite && n.rounded() == n ? Int(exactly: n) : nil
    }
    private static func dateRange(_ a: Any?, _ b: Any?) -> Bool {
        guard let start = number(a), let end = number(b) else { return false }
        return validTimestamp(start) && validTimestamp(end) &&
            end > start && end - start <= 7 * 86_400
    }
    private static func validTimestamp(_ value: Double) -> Bool {
        value.isFinite && value >= -2_208_988_800 && value <= 4_102_444_800
    }
}
