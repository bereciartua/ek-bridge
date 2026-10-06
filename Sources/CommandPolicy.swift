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
    /// A move's destination, where the client also holds Create (plan 03 §13).
    var moveTargetID: String? = nil
}

enum CommandPolicy {
    static func scopeStillSelected(id: String, generation: Int,
                                   scope: BridgeScope, reminders: Bool) -> Bool {
        scope.generation == generation &&
            (reminders ? scope.reminderListID : scope.calendarID) == id
    }

    static let invalid = "invalid_parameters_or_target"

    static func validate(_ request: BridgeRequest, scope: BridgeScope) -> String? {
        let p = request.parameters
        let command = request.command
        let keysAccepted = command.acceptsKeys(of: p)
        switch command {
        case .authorizationStatus, .calendarCount, .reminderListCount, .scopeStatus,
             .listCollections:
            return keysAccepted ? nil : "invalid_parameters"
        case .readEvents:
            guard keysAccepted,
                  target(p, "calendarID", scope.calendarID),
                  let start = number(p["start"]), let end = number(p["end"]),
                  validTimestamp(start), validTimestamp(end),
                  end > start, end - start <= 31 * 86_400,
                  let limit = integer(p["limit"]), (1...100).contains(limit),
                  p["afterKey"] == nil || cursor(p["afterKey"])
            else { return invalid }
        case .getEvent:
            guard keysAccepted,
                  target(p, "calendarID", scope.calendarID), item(p["itemID"]),
                  p["occurrenceStart"] == nil || ReminderDueSpec.timestamp(p["occurrenceStart"]) != nil
            else { return invalid }
        case .readReminders:
            guard keysAccepted,
                  target(p, "listID", scope.reminderListID),
                  let limit = integer(p["limit"]), (1...100).contains(limit),
                  p["afterID"] == nil || item(p["afterID"]),
                  p["status"] == nil || ["incomplete", "completed", "all"].contains(p["status"] as? String ?? ""),
                  p["dueAfter"] == nil || ReminderDueSpec.timestamp(p["dueAfter"]) != nil,
                  p["dueBefore"] == nil || ReminderDueSpec.timestamp(p["dueBefore"]) != nil
            else { return invalid }
            if let after = ReminderDueSpec.timestamp(p["dueAfter"]),
               let before = ReminderDueSpec.timestamp(p["dueBefore"]), before <= after { return invalid }
        case .getReminder:
            guard keysAccepted, target(p, "listID", scope.reminderListID), item(p["itemID"])
            else { return invalid }
        case .createEvent:
            guard keysAccepted,
                  target(p, "calendarID", scope.calendarID),
                  WriteIdempotencyKey.timestamp(p["idempotencyKey"]) != nil
            else { return invalid }
            switch EventChange.parse(p, creating: true) {
            case .failure(let error): return error.code
            case .success(let change): if let problem = timeProblem(change, creating: true) { return problem }
            }
        case .updateEvent:
            guard keysAccepted,
                  target(p, "calendarID", scope.calendarID),
                  item(p["itemID"]), version(p["expectedVersion"]),
                  WriteIdempotencyKey.timestamp(p["idempotencyKey"]) != nil
            else { return invalid }
            switch EventChange.parse(p, creating: false) {
            case .failure(let error): return error.code
            case .success(let change):
                if let problem = timeProblem(change, creating: false) { return problem }
                if let destination = change.targetCalendarID, destination != scope.calendarID,
                   destination != scope.moveTargetID { return invalid }
            }
        case .deleteEvent:
            guard keysAccepted,
                  target(p, "calendarID", scope.calendarID),
                  item(p["itemID"]), version(p["expectedVersion"]),
                  EventChange.occurrenceTarget(p) != nil,
                  WriteIdempotencyKey.timestamp(p["idempotencyKey"]) != nil
            else { return invalid }
        case .createReminder:
            guard keysAccepted,
                  target(p, "listID", scope.reminderListID),
                  WriteIdempotencyKey.timestamp(p["idempotencyKey"]) != nil
            else { return invalid }
            if case .failure(let error) = ReminderChange.parse(p, creating: true) { return error.code }
        case .updateReminder:
            guard keysAccepted,
                  target(p, "listID", scope.reminderListID),
                  item(p["itemID"]), version(p["expectedVersion"]),
                  WriteIdempotencyKey.timestamp(p["idempotencyKey"]) != nil
            else { return invalid }
            switch ReminderChange.parse(p, creating: false) {
            case .failure(let error): return error.code
            case .success(let change):
                if let destination = change.targetListID, destination != scope.reminderListID,
                   destination != scope.moveTargetID { return invalid }
            }
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
            else { return invalid }
        case .deleteReminder:
            guard keysAccepted,
                  target(p, "listID", scope.reminderListID),
                  item(p["itemID"]), version(p["expectedVersion"]),
                  (p["recurrenceScope"] == nil ||
                   ReminderRecurrenceScope.parse(p["recurrenceScope"]) != nil),
                  WriteIdempotencyKey.timestamp(p["idempotencyKey"]) != nil
            else { return invalid }
        }
        return nil
    }

    /// Span limits the request alone decides: a timed event at most 31 days,
    /// an all-day one 1–366 days between midnights in its zone (§11.4). The
    /// core checks the rest against the current event.
    private static func timeProblem(_ change: EventChange, creating: Bool) -> String? {
        guard let start = change.start, let end = change.end else { return nil }
        let seconds = Double(end - start)
        if change.allDay == true {
            if let zone = change.timeZone {
                guard let days = EventFields.allDayLength(start: Double(start), end: Double(end), zone: zone),
                      (1...EventFields.maxAllDayDays).contains(days) else { return invalid }
            } else if seconds > Double(EventFields.maxAllDayDays + 1) * 86_400 {
                return invalid
            }
        } else if change.allDay == false || creating {
            if seconds > Double(EventFields.maxTimedSeconds) { return invalid }
        } else if seconds > Double(EventFields.maxAllDayDays + 1) * 86_400 {
            return invalid
        }
        return nil
    }

    private static func target(_ p: [String: Any], _ key: String, _ allowed: String?) -> Bool {
        guard let allowed, !allowed.isEmpty else { return false }
        return p[key] as? String == allowed
    }
    private static func item(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        return !value.isEmpty && value.utf8.count <= 512
    }
    private static func cursor(_ value: Any?) -> Bool {
        guard let value = value as? String, value.utf8.count <= 600 else { return false }
        return EventPageKey(cursor: value) != nil
    }
    private static func version(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        return !value.isEmpty && value.utf8.count <= 64
    }
    private static func fingerprint(_ value: Any?) -> Bool {
        guard let value = value as? String, value.utf8.count == 64 else { return false }
        return value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
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
    private static func validTimestamp(_ value: Double) -> Bool {
        value.isFinite && value >= -2_208_988_800 && value <= 4_102_444_800
    }
}
