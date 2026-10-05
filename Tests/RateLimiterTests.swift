import Foundation

@main
struct RateLimiterTests {
    static func main() {
        var clock: TimeInterval = 2_000_000_000
        var checks = 0
        func expect(_ actual: RateLimiter.Decision, _ expected: RateLimiter.Decision,
                    _ note: String) {
            precondition(actual == expected, "\(note): expected \(expected), got \(actual)")
            checks += 1
        }

        // Calls: burst of 30, then 120/min (one token every 0.5 s).
        let limiter = RateLimiter(now: { clock })
        for index in 0..<30 { expect(limiter.allow("a", write: false), .allowed, "burst \(index)") }
        expect(limiter.allow("a", write: false), .limited(retryAfter: 1), "31st call")
        // Limited calls don't consume tokens: hammering doesn't push the wait out.
        for _ in 0..<50 { _ = limiter.allow("a", write: false) }
        clock += 0.5
        expect(limiter.allow("a", write: false), .allowed, "one token after 0.5 s")
        expect(limiter.allow("a", write: false), .limited(retryAfter: 1), "and only one")
        // Refill caps at the burst.
        clock += 3_600
        for index in 0..<30 { expect(limiter.allow("a", write: false), .allowed, "refilled \(index)") }
        expect(limiter.allow("a", write: false), .limited(retryAfter: 1), "capped at 30")

        // Per-client isolation.
        for index in 0..<30 { expect(limiter.allow("b", write: false), .allowed, "client b \(index)") }
        expect(limiter.allow("b", write: false), .limited(retryAfter: 1), "client b limited")
        expect(limiter.allow("c", write: true), .allowed, "client c unaffected")

        // Writes: burst 10, then 20/min (one every 3 s), separate from calls.
        clock += 3_600
        for index in 0..<10 { expect(limiter.allow("w", write: true), .allowed, "write \(index)") }
        expect(limiter.allow("w", write: true), .limited(retryAfter: 3), "11th write")
        clock += 1.5
        expect(limiter.allow("w", write: true), .limited(retryAfter: 2), "write half refilled")
        // The limited writes took no call tokens: 30 - 10 = 20 reads remain
        // (plus 0.5 s × 2/s = 3 after 1.5 s, capped by the bucket).
        var reads = 0
        while limiter.allow("w", write: false) == .allowed { reads += 1 }
        precondition(reads == 23, "reads after limited writes: \(reads)")
        checks += 1
        expect(limiter.allow("w", write: true), .limited(retryAfter: 1),
               "an empty call bucket blocks writes too")
        clock += 1.5
        expect(limiter.allow("w", write: true), .allowed, "write after refill")
        // A client whose writes are exhausted still reads.
        let separate = RateLimiter(now: { clock })
        for _ in 0..<10 { _ = separate.allow("s", write: true) }
        expect(separate.allow("s", write: true), .limited(retryAfter: 3), "writes exhausted")
        expect(separate.allow("s", write: false), .allowed, "reads still allowed")

        // Retry-after reflects the configured rate.
        var slowPolicy = RateLimiter.Policy()
        slowPolicy.callsPerMinute = 6
        slowPolicy.callBurst = 2
        let slow = RateLimiter(policy: slowPolicy, now: { clock })
        expect(slow.allow("x", write: false), .allowed, "slow 1")
        expect(slow.allow("x", write: false), .allowed, "slow 2")
        expect(slow.allow("x", write: false), .limited(retryAfter: 10), "slow wait 10")
        clock += 5
        expect(slow.allow("x", write: false), .limited(retryAfter: 5), "slow wait 5")
        clock += 5
        expect(slow.allow("x", write: false), .allowed, "slow refilled")

        // 250 writes per rolling 24 h with the default policy (one every 3 s
        // stays inside 20/min).
        let start = clock + 86_400
        clock = start
        // The daily cap is charged only for writes that are dispatched
        // (recordWrite); refused or declined ones don't use it up.
        let daily = RateLimiter(now: { clock })
        for _ in 0..<300 {
            expect(daily.allow("d", write: true), .allowed, "undispatched writes don't count")
            clock += 3
        }
        clock = start
        for index in 0..<250 {
            expect(daily.allow("d", write: true), .allowed, "daily write \(index)")
            daily.recordWrite("d")
            clock += 3
        }
        expect(daily.allow("d", write: true), .limited(retryAfter: 86_400 - 750), "251st write")
        expect(daily.allow("d", write: false), .allowed, "reads unaffected by the daily cap")
        clock = start + 86_400 - 1
        expect(daily.allow("d", write: true), .limited(retryAfter: 1), "one second before rollover")
        clock = start + 86_400
        expect(daily.allow("d", write: true), .allowed, "first write left the window")
        daily.recordWrite("d")
        expect(daily.allow("d", write: true), .limited(retryAfter: 3), "250 in the window again")
        expect(daily.allow("e", write: true), .allowed, "other client's daily cap is separate")

        // Failed authentication: more than 120 in a minute locks out for 60 s.
        clock = start + 200_000
        let auth = RateLimiter(now: { clock })
        precondition(auth.authLockout() == nil)
        for _ in 0..<120 { auth.recordFailedAuth() }
        precondition(auth.authLockout() == nil, "120 is still allowed")
        auth.recordFailedAuth()
        precondition(auth.authLockout() == 60, "121st locks out")
        clock += 30
        precondition(auth.authLockout() == 30)
        clock += 29.5
        precondition(auth.authLockout() == 1)
        clock += 0.5
        precondition(auth.authLockout() == nil, "recovered after 60 s")
        // The count restarts after a lockout, and old failures age out.
        for _ in 0..<120 { auth.recordFailedAuth() }
        clock += 60
        for _ in 0..<120 { auth.recordFailedAuth() }
        precondition(auth.authLockout() == nil, "failures a minute apart don't add up")
        // Valid tokens never consult the lockout: per-client buckets are unaffected.
        for _ in 0..<121 { auth.recordFailedAuth() }
        precondition(auth.authLockout() == 60)
        expect(auth.allow("valid", write: false), .allowed, "authenticated call during lockout")
        checks += 8

        // Remote Access: its own stricter buckets, the shared daily cap, and a
        // lockout per forwarded address.
        clock = start + 400_000
        let remote = RateLimiter(now: { clock })
        for index in 0..<15 {
            expect(remote.allow("r", write: false, remote: true), .allowed, "remote call \(index)")
        }
        expect(remote.allow("r", write: false, remote: true), .limited(retryAfter: 1), "16th remote call")
        expect(remote.allow("r", write: false), .allowed, "local bucket is separate")
        clock += 60
        for index in 0..<5 {
            expect(remote.allow("w", write: true, remote: true), .allowed, "remote write \(index)")
        }
        expect(remote.allow("w", write: true, remote: true), .limited(retryAfter: 6), "6th remote write")
        for _ in 0..<250 { remote.recordWrite("d") }
        expect(remote.allow("d", write: true, remote: true), .limited(retryAfter: 86_400), "daily cap shared")
        for _ in 0..<30 { remote.recordFailedRemoteAuth("198.51.100.1") }
        precondition(remote.remoteAuthLockout("198.51.100.1") == nil, "30 a minute is allowed")
        remote.recordFailedRemoteAuth("198.51.100.1")
        precondition(remote.remoteAuthLockout("198.51.100.1") == 300, "31st locks that address out")
        precondition(remote.remoteAuthLockout("198.51.100.2") == nil, "other addresses unaffected")
        precondition(remote.authLockout() == nil, "the local lockout is separate")
        clock += 300
        precondition(remote.remoteAuthLockout("198.51.100.1") == nil, "recovered after 5 min")
        checks += 6

        // A flood of distinct addresses fills the table; new addresses then share one overflow key,
        // which never locks out addresses already tracked.
        let flood = RateLimiter(now: { clock })
        flood.recordFailedRemoteAuth("203.0.113.7")
        for index in 0..<999 { flood.recordFailedRemoteAuth("10.0.\(index / 256).\(index % 256)") }
        for index in 0..<31 { flood.recordFailedRemoteAuth("192.0.2.\(index)") }
        precondition(flood.remoteAuthLockout("192.0.2.200") == 300, "untracked addresses share the overflow lockout")
        precondition(flood.remoteAuthLockout("203.0.113.7") == nil, "tracked addresses keep their own count")
        clock += 61
        precondition(flood.remoteAuthLockout("192.0.2.200") == nil, "overflow applies only while the table is full")
        checks += 3

        print("Rate limiter: \(checks) checks of bursts, refill, retry-after, isolation, write and daily caps, auth lockout, remote limits passed")
    }
}
