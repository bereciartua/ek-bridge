import Foundation

// The timestamp makes an expired key permanently invalid after its completed
// journal entry is pruned. Callers must reuse the exact same key on a retry.
enum WriteIdempotencyKey {
    static let lifetime: TimeInterval = 7 * 86_400
    static let futureSkew: TimeInterval = 5

    static func make(now: TimeInterval = Date().timeIntervalSince1970) -> String {
        "ekb3_\(Int(now))_\(UUID().uuidString.lowercased())"
    }

    static func timestamp(_ value: Any?) -> TimeInterval? {
        guard let value = value as? String, value.hasPrefix("ekb3_"),
              value.utf8.count <= 64 else { return nil }
        let parts = value.dropFirst(5).split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty, parts[0].first != "0",
              parts[0].allSatisfy({ $0.isASCII && $0.isNumber }),
              let seconds = UInt64(parts[0]), seconds <= UInt64(Int64.max),
              let uuid = UUID(uuidString: String(parts[1])),
              uuid.uuidString.lowercased() == parts[1] else { return nil }
        return TimeInterval(seconds)
    }

    static func isCurrent(_ value: Any?, now: TimeInterval) -> Bool {
        guard let timestamp = timestamp(value), now.isFinite else { return false }
        return timestamp <= now + futureSkew && now - timestamp <= lifetime
    }
}
