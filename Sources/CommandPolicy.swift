import Foundation

// Strict shape checks run before EventKit is touched. A session has at most one
// explicitly selected target of each type; empty IDs mean deny all item access.
struct BridgeScope {
    var calendarID: String?
    var reminderListID: String?
    var writesArmed = false
    var generation = 0
}

enum CommandPolicy {
    static func scopeStillSelected(id: String, generation: Int,
                                   scope: BridgeScope, reminders: Bool) -> Bool {
        scope.generation == generation &&
            (reminders ? scope.reminderListID : scope.calendarID) == id
    }

    static func validate(_ request: BridgeRequest, scope: BridgeScope) -> String? {
        let p = request.parameters
        let command = request.command
        if command.isWrite && !scope.writesArmed { return "writes_disabled" }
        switch command {
        case .authorizationStatus, .calendarCount, .reminderListCount:
            return p.isEmpty ? nil : "invalid_parameters"
        case .readEvents:
            guard keys(p, ["calendarID", "start", "end", "limit"]),
                  target(p, "calendarID", scope.calendarID),
                  let start = number(p["start"]), let end = number(p["end"]),
                  validTimestamp(start), validTimestamp(end),
                  end > start, end - start <= 31 * 86_400,
                  let limit = integer(p["limit"]), (1...100).contains(limit)
            else { return "invalid_parameters_or_target" }
        case .readReminders:
            guard (keys(p, ["listID", "limit"]) ||
                   keys(p, ["listID", "limit", "afterID"])),
                  target(p, "listID", scope.reminderListID),
                  let limit = integer(p["limit"]), (1...100).contains(limit),
                  p["afterID"] == nil || item(p["afterID"])
            else { return "invalid_parameters_or_target" }
        case .createEvent:
            guard keys(p, ["calendarID", "title", "start", "end", "idempotencyKey"]),
                  target(p, "calendarID", scope.calendarID),
                  title(p["title"]),
                  dateRange(p["start"], p["end"]),
                  uuid(p["idempotencyKey"])
            else { return "invalid_parameters_or_target" }
        case .updateEvent:
            guard keys(p, ["calendarID", "itemID", "expectedVersion", "title", "start", "end", "idempotencyKey"]),
                  target(p, "calendarID", scope.calendarID),
                  item(p["itemID"]), version(p["expectedVersion"]),
                  title(p["title"]), dateRange(p["start"], p["end"]),
                  uuid(p["idempotencyKey"])
            else { return "invalid_parameters_or_target" }
        case .deleteEvent:
            guard keys(p, ["calendarID", "itemID", "expectedVersion", "idempotencyKey"]),
                  target(p, "calendarID", scope.calendarID),
                  item(p["itemID"]), version(p["expectedVersion"]),
                  uuid(p["idempotencyKey"])
            else { return "invalid_parameters_or_target" }
        case .createReminder:
            guard keys(p, ["listID", "title", "idempotencyKey"]),
                  target(p, "listID", scope.reminderListID),
                  title(p["title"]), uuid(p["idempotencyKey"])
            else { return "invalid_parameters_or_target" }
        case .updateReminder:
            guard keys(p, ["listID", "itemID", "expectedVersion", "title", "idempotencyKey"]),
                  target(p, "listID", scope.reminderListID),
                  item(p["itemID"]), version(p["expectedVersion"]),
                  title(p["title"]), uuid(p["idempotencyKey"])
            else { return "invalid_parameters_or_target" }
        case .completeReminder, .deleteReminder:
            guard keys(p, ["listID", "itemID", "expectedVersion", "idempotencyKey"]),
                  target(p, "listID", scope.reminderListID),
                  item(p["itemID"]), version(p["expectedVersion"]),
                  uuid(p["idempotencyKey"])
            else { return "invalid_parameters_or_target" }
        }
        return nil
    }

    private static func keys(_ p: [String: Any], _ expected: Set<String>) -> Bool {
        Set(p.keys) == expected
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
