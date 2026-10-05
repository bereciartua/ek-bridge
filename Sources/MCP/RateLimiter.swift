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
        // Remote Access is stricter: its own buckets per client (the daily
        // write cap is shared), and failed authentication per forwarded
        // address with a longer lockout.
        var remoteCallsPerMinute = 60.0
        var remoteCallBurst = 15.0
        var remoteWritesPerMinute = 10.0
        var remoteWriteBurst = 5.0
        var remoteFailedAuthsPerMinute = 30
        var remoteFailedAuthLockout: TimeInterval = 300
        var maxRemoteKeys = 1_000
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
    private var remoteFailures = [String: [TimeInterval]]()
    private var remoteLockedUntil = [String: TimeInterval]()

    init(policy: Policy = Policy(), now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.policy = policy
        self.now = now
    }

    /// Takes a token for one call (and one write, for writes) or says how long to wait.
    func allow(_ clientID: String, write: Bool, remote: Bool = false) -> Decision {
        lock.lock()
        defer { lock.unlock() }
        let current = now()
        let key = remote ? "remote|" + clientID : clientID
        let callRate = remote ? policy.remoteCallsPerMinute : policy.callsPerMinute
        let writeRate = remote ? policy.remoteWritesPerMinute : policy.writesPerMinute
        var call = refilled(calls[key], capacity: remote ? policy.remoteCallBurst : policy.callBurst,
                            perMinute: callRate, at: current)
        guard call.tokens >= 1 else {
            calls[key] = call
            return .limited(retryAfter: wait(call, perMinute: callRate))
        }
        if write {
            var bucket = refilled(writes[key], capacity: remote ? policy.remoteWriteBurst : policy.writeBurst,
                                  perMinute: writeRate, at: current)
            let day = (dailyWrites[clientID] ?? []).filter { current - $0 < 86_400 }
            dailyWrites[clientID] = day
            if day.count >= policy.writesPerDay {
                calls[key] = call
                writes[key] = bucket
                return .limited(retryAfter: max(1, Int((day[0] + 86_400 - current).rounded(.up))))
            }
            guard bucket.tokens >= 1 else {
                calls[key] = call
                writes[key] = bucket
                return .limited(retryAfter: wait(bucket, perMinute: writeRate))
            }
            bucket.tokens -= 1
            writes[key] = bucket
        }
        call.tokens -= 1
        calls[key] = call
        return .allowed
    }

    /// Charges the daily write cap. The pipeline calls this when a write is
    /// dispatched, so refused, invalid or declined writes don't use it up.
    func recordWrite(_ clientID: String) {
        lock.lock()
        defer { lock.unlock() }
        let current = now()
        dailyWrites[clientID] = (dailyWrites[clientID] ?? []).filter { current - $0 < 86_400 } + [current]
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

    /// Remote Access: counts a failed authentication from one forwarded
    /// address (or "unknown"); past the limit that address is refused for
    /// five minutes. Tunneled requests all come from loopback, so the local
    /// throttle can't tell callers apart.
    func recordFailedRemoteAuth(_ address: String) {
        lock.lock()
        defer { lock.unlock() }
        let current = now()
        remoteFailures = remoteFailures.filter { $0.value.last.map { current - $0 < 60 } ?? false }
        remoteLockedUntil = remoteLockedUntil.filter { $0.value > current }
        // Too many distinct addresses at once: new ones share one overflow key. Only requests
        // without a valid credential ever consult the lockout, so this can't block working agents.
        let key = remoteFailures.count < policy.maxRemoteKeys || remoteFailures[address] != nil
            ? address : Self.overflowKey
        let recent = (remoteFailures[key] ?? []).filter { current - $0 < 60 } + [current]
        remoteFailures[key] = recent
        if recent.count > policy.remoteFailedAuthsPerMinute {
            remoteLockedUntil[key] = current + policy.remoteFailedAuthLockout
            remoteFailures[key] = nil
        }
    }

    private static let overflowKey = "*"

    /// Seconds until requests without a valid credential from `address` are accepted again.
    /// Addresses the table had no room for share the overflow key's lockout.
    func remoteAuthLockout(_ address: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        let current = now()
        let tracked = remoteFailures[address] != nil || remoteLockedUntil[address] != nil
        let full = remoteFailures.filter { $0.value.last.map { current - $0 < 60 } ?? false }.count
            >= policy.maxRemoteKeys
        let until = max(remoteLockedUntil[address] ?? 0,
                        !tracked && full ? remoteLockedUntil[Self.overflowKey] ?? 0 : 0)
        let remaining = until - now()
        return remaining > 0 ? max(1, Int(remaining.rounded(.up))) : nil
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
