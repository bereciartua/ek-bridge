import Foundation

/// Token buckets per client, plus a global throttle for failed MCP
/// authentication. Limits are generous for interactive agents and stop runaway
/// loops; write limits are sized so one client can't exceed its journal quota
/// within the 7-day key lifetime (250/day × 7 < 2,000).
///
/// Thread-safe: the HTTP queue checks the auth throttle before hopping to the
/// main actor, and the pipeline uses the per-client buckets there.
final class RateLimiter: @unchecked Sendable {
    struct Policy {
        var callsPerMinute = 120.0
        var callBurst = 30.0
        var writesPerMinute = 20.0
        var writeBurst = 10.0
        var writesPerDay = 250
        var failedAuthsPerMinute = 120
        var failedAuthLockout: TimeInterval = 60
    }

    enum Decision: Equatable {
        case allowed
        case limited(retryAfter: Int)
    }

    private struct Bucket {
        var tokens: Double
        var updated: TimeInterval
    }

    private let policy: Policy
    private let now: () -> TimeInterval
    private let lock = NSLock()
    private var calls = [String: Bucket]()
    private var writes = [String: Bucket]()
    private var dailyWrites = [String: [TimeInterval]]()
    private var failedAuths = [TimeInterval]()
    private var lockedUntil: TimeInterval = 0

    init(policy: Policy = Policy(), now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.policy = policy
        self.now = now
    }

    /// Takes a token for one call (and one write, for writes) or says how long to wait.
    func allow(_ clientID: String, write: Bool) -> Decision {
        lock.lock()
        defer { lock.unlock() }
        let current = now()
        var call = refilled(calls[clientID], capacity: policy.callBurst,
                            perMinute: policy.callsPerMinute, at: current)
        guard call.tokens >= 1 else {
            calls[clientID] = call
            return .limited(retryAfter: wait(call, perMinute: policy.callsPerMinute))
        }
        if write {
            var bucket = refilled(writes[clientID], capacity: policy.writeBurst,
                                  perMinute: policy.writesPerMinute, at: current)
            let day = (dailyWrites[clientID] ?? []).filter { current - $0 < 86_400 }
            dailyWrites[clientID] = day
            if day.count >= policy.writesPerDay {
                calls[clientID] = call
                writes[clientID] = bucket
                return .limited(retryAfter: max(1, Int((day[0] + 86_400 - current).rounded(.up))))
            }
            guard bucket.tokens >= 1 else {
                calls[clientID] = call
                writes[clientID] = bucket
                return .limited(retryAfter: wait(bucket, perMinute: policy.writesPerMinute))
            }
            bucket.tokens -= 1
            writes[clientID] = bucket
            dailyWrites[clientID] = day + [current]
        }
        call.tokens -= 1
        calls[clientID] = call
        return .allowed
    }

    /// Counts one failed authentication from any caller. Past the limit, every
    /// unauthenticated request is refused for the lockout period.
    func recordFailedAuth() {
        lock.lock()
        defer { lock.unlock() }
        let current = now()
        failedAuths = failedAuths.filter { current - $0 < 60 } + [current]
        if failedAuths.count > policy.failedAuthsPerMinute {
            lockedUntil = current + policy.failedAuthLockout
            failedAuths.removeAll()
        }
    }

    /// Seconds until unauthenticated requests are accepted again, or nil.
    /// Requests with a valid token never consult this.
    func authLockout() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        let remaining = lockedUntil - now()
        return remaining > 0 ? max(1, Int(remaining.rounded(.up))) : nil
    }

    private func refilled(_ bucket: Bucket?, capacity: Double, perMinute: Double,
                          at current: TimeInterval) -> Bucket {
        guard var bucket else { return Bucket(tokens: capacity, updated: current) }
        let elapsed = max(0, current - bucket.updated)
        bucket.tokens = min(capacity, bucket.tokens + elapsed * perMinute / 60)
        bucket.updated = current
        return bucket
    }

    private func wait(_ bucket: Bucket, perMinute: Double) -> Int {
        max(1, Int(((1 - bucket.tokens) * 60 / perMinute).rounded(.up)))
    }
}
