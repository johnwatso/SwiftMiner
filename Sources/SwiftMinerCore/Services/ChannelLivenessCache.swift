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
/// **Only offline results are cached.** A channel found live is never cached, so a stale reading
/// can never send a miner to a stream that has already ended.
///
/// The window for a miss escalates with how long the channel has been dark:
///
/// - Freshly dark channels use `ttl`, which is deliberately just under the engine's
///   `MinerEngine.aclProbeInterval`. Every entry has therefore expired by the time the next probe
///   runs, so a channel that has only recently gone offline is still re-checked every interval —
///   the cache adds no latency at all, it purely collapses the duplicate questions the fleet asks
///   *within* one interval.
/// - A channel dark for many consecutive probes — a tournament channel between events, which is
///   the case that generates nearly all of this traffic — escalates towards `maximumBackoff`.
///   That bounds worst-case rediscovery at a few minutes against broadcasts lasting hours, and
///   any live sighting resets it instantly via `recordLive`.
///
/// The escalation is the only place responsiveness is traded, and `maximumBackoff` is what bounds
/// that trade. `ChannelLivenessCacheTests` pins both relationships.
public actor ChannelLivenessCache {
    public static let shared = ChannelLivenessCache()

    /// Must stay strictly below `MinerEngine.aclProbeInterval` — see the type comment.
    public static let ttl: TimeInterval = 55

    /// Ceiling on how long a persistently dark channel is skipped. Kept small relative to a
    /// tournament broadcast so a channel coming online is never missed by more than this.
    public static let maximumBackoff: TimeInterval = 5 * 60

    /// Consecutive misses before the window starts escalating. Roughly ten minutes of darkness
    /// at the base window, so a channel cycling on and off keeps fast rediscovery.
    static let missesBeforeEscalation = 10

    private let ttl: TimeInterval
    private let maximumBackoff: TimeInterval
    private let now: @Sendable () -> Date
    private var offlineUntil: [String: Date] = [:]
    private var consecutiveMisses: [String: Int] = [:]

    public init(
        ttl: TimeInterval = ChannelLivenessCache.ttl,
        maximumBackoff: TimeInterval = ChannelLivenessCache.maximumBackoff,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.ttl = ttl
        self.maximumBackoff = maximumBackoff
        self.now = now
    }

    private func key(_ login: String) -> String {
        login.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Window applied to a miss, given how many consecutive misses this login has had.
    /// Doubles once past `missesBeforeEscalation`, capped at `maximumBackoff`.
    func backoff(forConsecutiveMisses misses: Int) -> TimeInterval {
        guard misses > Self.missesBeforeEscalation else { return ttl }
        let doublings = Double((misses - Self.missesBeforeEscalation) / Self.missesBeforeEscalation)
        return min(ttl * pow(2, doublings + 1), maximumBackoff)
    }

    /// True when this login was probed and found offline recently enough to skip.
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
        let key = key(login)
        let misses = (consecutiveMisses[key] ?? 0) + 1
        consecutiveMisses[key] = misses
        offlineUntil[key] = now().addingTimeInterval(backoff(forConsecutiveMisses: misses))
    }

    /// Records that this login was found live. Clears any miss window and resets the escalation,
    /// so a channel that comes back online is probed at full speed again immediately.
    public func recordLive(login: String) {
        let key = key(login)
        offlineUntil[key] = nil
        consecutiveMisses[key] = 0
    }

    /// Drops any cached miss for this login, so the next probe hits Twitch.
    public func invalidate(login: String) {
        offlineUntil[key(login)] = nil
    }

    /// Number of live (unexpired) misses. Diagnostics and tests only.
    public func cachedMissCount() -> Int {
        let cutoff = now()
        return offlineUntil.values.filter { $0 > cutoff }.count
    }
}
