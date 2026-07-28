import Foundation

/// Process-wide cache of approved-channel liveness probes, shared by every miner account.
///
/// Whether a channel is streaming is a global fact, so five miners each asking Twitch the same
/// question is pure duplication — and an ACL-restricted campaign (esports drops, typically) can
/// list dozens of approved channels, each costing its own request. Left unshared this dominated
/// the fleet's entire request budget: one diagnostic captured 641 liveness probes and 22 minutes
/// of accumulated rate-limit backoff inside a three-minute window, starving the calls that
/// actually select a channel.
///
/// **Only offline results are cached, and only for `ttl`.** That bound is what makes this safe:
/// `ttl` is deliberately shorter than the engine's ACL re-probe interval
/// (`MinerEngine.aclProbeInterval`), so every entry has already expired by the time the next
/// probe runs. An approved channel coming online is therefore still discovered on the very next
/// tick, exactly as it was before this cache existed — the cache can never be the reason a
/// campaign is missed. It only collapses the repeat questions asked *within* a single interval.
///
/// A channel found live is never cached, so a stale "live" reading can never send a miner to a
/// stream that has already ended.
public actor ChannelLivenessCache {
    public static let shared = ChannelLivenessCache()

    /// Must stay strictly below `MinerEngine.aclProbeInterval` — see the type comment.
    /// `ChannelLivenessCacheTests` pins this relationship.
    public static let ttl: TimeInterval = 30

    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private var offlineUntil: [String: Date] = [:]

    public init(ttl: TimeInterval = ChannelLivenessCache.ttl, now: @escaping @Sendable () -> Date = { Date() }) {
        self.ttl = ttl
        self.now = now
    }

    private func key(_ login: String) -> String {
        login.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// True when this login was probed and found offline within the last `ttl`.
    public func isKnownOffline(login: String) -> Bool {
        let key = key(login)
        guard let until = offlineUntil[key] else { return false }
        guard until > now() else {
            offlineUntil[key] = nil
            return false
        }
        return true
    }

    /// Records that a probe found this login offline.
    public func recordOffline(login: String) {
        offlineUntil[key(login)] = now().addingTimeInterval(ttl)
    }

    /// Drops any cached miss for this login, so the next probe hits Twitch.
    /// Used when something else proves the channel is live.
    public func invalidate(login: String) {
        offlineUntil[key(login)] = nil
    }

    /// Number of live (unexpired) misses. Diagnostics and tests only.
    public func cachedMissCount() -> Int {
        let cutoff = now()
        return offlineUntil.values.filter { $0 > cutoff }.count
    }
}
