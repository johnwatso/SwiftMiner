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
