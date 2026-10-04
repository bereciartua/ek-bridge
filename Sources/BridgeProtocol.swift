import Foundation

enum BridgeCommand: String {
    case authorizationStatus = "authorization_status"
    case calendarCount = "calendar_count"
    case reminderListCount = "reminder_list_count"
}

struct BridgeRequest {
    let id: String
    let command: BridgeCommand
}

enum BridgeRequestError: String, Error {
    case tooLarge = "request_too_large"
    case invalid = "invalid_request"
    case unauthorized = "unauthorized"
    case expired = "expired_request"
    case replay = "replayed_request"
}

enum BridgeProtocol {
    static let maxRequestBytes = 2_048
    static let maxResponseBytes = 2_048
    static let sessionLifetime: TimeInterval = 15 * 60
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
              Set(fields.keys) == Set(["version", "id", "command", "token", "issuedAt"]),
              let version = fields["version"] as? Int, version == 1,
              let id = fields["id"] as? String, UUID(uuidString: id) != nil,
              let commandName = fields["command"] as? String,
              let command = BridgeCommand(rawValue: commandName),
              let suppliedToken = fields["token"] as? String,
              let issuedAt = fields["issuedAt"] as? Double, issuedAt.isFinite
        else { return .failure(.invalid) }
        guard secureEquals(suppliedToken, token) else { return .failure(.unauthorized) }
        guard now - issuedAt <= requestLifetime, issuedAt - now <= 5 else {
            return .failure(.expired)
        }
        guard !usedIDs.contains(id) else { return .failure(.replay) }
        return .success(BridgeRequest(id: id, command: command))
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
