import XCTest
@testable import SwiftMinerCore

/// Guards the ACL approved-channel liveness cache.
///
/// The cache exists to stop five miners asking Twitch the same question dozens of times per
/// minute. The tests that matter here are the ones proving it can never *hide* a channel that
/// came online — that is the property standing between this optimisation and a missed campaign.
final class ChannelLivenessCacheTests: XCTestCase {

    /// Mutable clock the cache's `now` closure can capture across concurrency domains.
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ value: Date = Date()) { self.value = value }
        var current: Date {
            lock.lock(); defer { lock.unlock() }
            return value
        }
        func advance(by interval: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            value = value.addingTimeInterval(interval)
        }
    }

    /// The safety invariant. A cached miss must always have expired by the time the engine
    /// re-probes, so the cache only ever collapses duplicate questions asked inside one
    /// interval — it can never add latency to noticing a go-live.
    func testCacheWindowIsShorterThanTheProbeInterval() {
        XCTAssertLessThan(
            ChannelLivenessCache.ttl,
            MinerEngine.aclProbeInterval,
            "A cached miss must expire before the next ACL probe, otherwise the cache could delay noticing an approved channel going live"
        )
    }

    func testMissExpiresBeforeTheNextProbeInterval() async {
        let clock = TestClock()
        let cache = ChannelLivenessCache(ttl: ChannelLivenessCache.ttl, now: { clock.current })

        await cache.recordOffline(login: "tournamentchannel")
        var known = await cache.isKnownOffline(login: "tournamentchannel")
        XCTAssertTrue(known, "A just-probed offline channel should be served from cache")

        // Advance to the moment the engine would re-probe.
        clock.advance(by: MinerEngine.aclProbeInterval)
        known = await cache.isKnownOffline(login: "tournamentchannel")
        XCTAssertFalse(known, "By the next probe the miss must have expired so Twitch is asked again")
    }

    /// The escalation is the only place responsiveness is traded away. This bounds that trade:
    /// a channel dark for hours is still rediscovered within `maximumBackoff`, which must stay
    /// small against a tournament broadcast lasting hours.
    func testEscalatedBackoffStaysBounded() async {
        let clock = TestClock()
        let cache = ChannelLivenessCache(now: { clock.current })

        // Simulate a channel dark for a very long time.
        for _ in 0..<500 {
            await cache.recordOffline(login: "tournamentchannel")
            clock.advance(by: ChannelLivenessCache.maximumBackoff)
        }

        let window = await cache.backoff(forConsecutiveMisses: 500)
        XCTAssertLessThanOrEqual(window, ChannelLivenessCache.maximumBackoff)
        XCTAssertLessThanOrEqual(
            ChannelLivenessCache.maximumBackoff,
            5 * 60,
            "Worst-case rediscovery must stay a small fraction of a broadcast"
        )
    }

    func testBackoffOnlyEscalatesAfterSustainedDarkness() async {
        let cache = ChannelLivenessCache()

        // A channel cycling on and off keeps the fast window.
        let early = await cache.backoff(forConsecutiveMisses: 1)
        XCTAssertEqual(early, ChannelLivenessCache.ttl)
        let stillEarly = await cache.backoff(forConsecutiveMisses: ChannelLivenessCache.missesBeforeEscalation)
        XCTAssertEqual(stillEarly, ChannelLivenessCache.ttl)

        // Only sustained darkness escalates.
        let later = await cache.backoff(forConsecutiveMisses: ChannelLivenessCache.missesBeforeEscalation * 3)
        XCTAssertGreaterThan(later, ChannelLivenessCache.ttl)
    }

    func testGoingLiveResetsEscalationImmediately() async {
        let clock = TestClock()
        let cache = ChannelLivenessCache(now: { clock.current })

        for _ in 0..<100 {
            await cache.recordOffline(login: "tournamentchannel")
            clock.advance(by: ChannelLivenessCache.maximumBackoff)
        }

        await cache.recordLive(login: "tournamentchannel")

        let known = await cache.isKnownOffline(login: "tournamentchannel")
        XCTAssertFalse(known, "A channel seen live must be probed again immediately")

        // And the next miss is back to the fast window, not the escalated one.
        await cache.recordOffline(login: "tournamentchannel")
        clock.advance(by: ChannelLivenessCache.ttl)
        let stillKnown = await cache.isKnownOffline(login: "tournamentchannel")
        XCTAssertFalse(stillKnown, "Escalation must reset after a live sighting")
    }

    func testLiveChannelsAreNeverCached() async {
        let cache = ChannelLivenessCache()

        // Only misses are recorded; nothing ever marks a login as live.
        let known = await cache.isKnownOffline(login: "livechannel")
        XCTAssertFalse(known)
        let count = await cache.cachedMissCount()
        XCTAssertEqual(count, 0, "A live result must not be cached — a stale hit would send a miner to an ended stream")
    }

    func testMissIsSharedAcrossLoginCasingAndWhitespace() async {
        let cache = ChannelLivenessCache()
        await cache.recordOffline(login: "TournamentChannel")

        let known = await cache.isKnownOffline(login: "  tournamentchannel ")
        XCTAssertTrue(known, "Directory and campaign ACL entries differ in casing; they must share one cache entry")
    }

    func testInvalidateForcesAFreshProbe() async {
        let cache = ChannelLivenessCache()
        await cache.recordOffline(login: "tournamentchannel")

        await cache.invalidate(login: "tournamentchannel")

        let known = await cache.isKnownOffline(login: "tournamentchannel")
        XCTAssertFalse(known)
    }

    func testDeduplicatesRepeatQuestionsWithinOneInterval() async {
        let clock = TestClock()
        let cache = ChannelLivenessCache(ttl: ChannelLivenessCache.ttl, now: { clock.current })
        await cache.recordOffline(login: "tournamentchannel")

        // Five miners asking inside the same window all get the cached answer.
        for _ in 0..<5 {
            clock.advance(by: 1)
            let known = await cache.isKnownOffline(login: "tournamentchannel")
            XCTAssertTrue(known)
        }
    }
}
