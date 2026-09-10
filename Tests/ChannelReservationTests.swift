import XCTest
@testable import SwiftMinerCore

/// Stream spreading has to hold a choice across the gap between picking a channel and starting
/// to watch it. Occupancy used to be read from each engine's committed `currentChannelId`, which
/// is only set once watching has begun — so miners that re-picked in the same instant all read
/// the same empty snapshot and converged on one stream. A live log showed three miners logging
/// "avoiding 1 occupied channel(s)" in the same second and all three selecting Gutfoxx.
@MainActor
final class ChannelReservationTests: XCTestCase {

    private let campaign = "campaign-1"
    private let ranked = ["chan-a", "chan-b", "chan-c", "chan-d", "chan-e", "chan-f"]

    private func manager() -> MinerManager {
        let manager = MinerManager(clientId: "test")
        manager.avoidDuplicateStreams = true
        return manager
    }

    /// The case that regressed: two miners choosing back to back, before either has committed.
    func testConcurrentSelectionsDoNotLandOnTheSameChannel() async {
        let manager = manager()

        let first = await manager.reserveChannel(
            campaignId: campaign,
            for: "miner-1",
            rankedChannelIds: ranked,
            viableChannelCount: ranked.count
        )
        let second = await manager.reserveChannel(
            campaignId: campaign,
            for: "miner-2",
            rankedChannelIds: ranked,
            viableChannelCount: ranked.count
        )

        XCTAssertEqual(first, "chan-a")
        XCTAssertEqual(second, "chan-b")
    }

    /// Reservations are per campaign: two miners working different campaigns are not competing
    /// for the same stream even when the ranked lists overlap.
    func testReservationsDoNotSpanCampaigns() async {
        let manager = manager()

        let first = await manager.reserveChannel(
            campaignId: campaign,
            for: "miner-1",
            rankedChannelIds: ranked,
            viableChannelCount: ranked.count
        )
        let second = await manager.reserveChannel(
            campaignId: "campaign-2",
            for: "miner-2",
            rankedChannelIds: ranked,
            viableChannelCount: ranked.count
        )

        XCTAssertEqual(first, "chan-a")
        XCTAssertEqual(second, "chan-a")
    }

    /// A miner re-picking replaces its own reservation rather than competing with itself.
    func testReselectingReleasesTheMinersPreviousReservation() async {
        let manager = manager()

        _ = await manager.reserveChannel(
            campaignId: campaign,
            for: "miner-1",
            rankedChannelIds: ranked,
            viableChannelCount: ranked.count
        )
        let again = await manager.reserveChannel(
            campaignId: campaign,
            for: "miner-1",
            rankedChannelIds: ranked,
            viableChannelCount: ranked.count
        )

        XCTAssertEqual(again, "chan-a")
        XCTAssertEqual(manager.channelReservations.count, 1)
    }

    /// Nil tells the engine to fall back to its own best match. Returning "chan-a" here would
    /// silently claim a channel the caller was told was unavailable.
    func testReturnsNilWhenEveryViableChannelIsTaken() async {
        let manager = manager()
        let two = ["chan-a", "chan-b"]

        _ = await manager.reserveChannel(
            campaignId: campaign, for: "miner-1", rankedChannelIds: two, viableChannelCount: 6
        )
        _ = await manager.reserveChannel(
            campaignId: campaign, for: "miner-2", rankedChannelIds: two, viableChannelCount: 6
        )
        let third = await manager.reserveChannel(
            campaignId: campaign, for: "miner-3", rankedChannelIds: two, viableChannelCount: 6
        )

        XCTAssertNil(third)
        XCTAssertNil(manager.channelReservations["miner-3"])
    }

    /// Spreading across four or fewer channels is deliberately bypassed, so no reservation is
    /// taken and every miner is free to use the best channel.
    func testNarrowChannelSetsBypassReservation() async {
        let manager = manager()

        let first = await manager.reserveChannel(
            campaignId: campaign, for: "miner-1", rankedChannelIds: ranked, viableChannelCount: 4
        )
        let second = await manager.reserveChannel(
            campaignId: campaign, for: "miner-2", rankedChannelIds: ranked, viableChannelCount: 4
        )

        XCTAssertEqual(first, "chan-a")
        XCTAssertEqual(second, "chan-a")
        XCTAssertTrue(manager.channelReservations.isEmpty)
    }

    /// With the setting off, spreading must not quietly happen anyway.
    func testSettingOffLeavesEveryMinerOnTheBestChannel() async {
        let manager = manager()
        manager.avoidDuplicateStreams = false

        let first = await manager.reserveChannel(
            campaignId: campaign,
            for: "miner-1",
            rankedChannelIds: ranked,
            viableChannelCount: ranked.count
        )
        let second = await manager.reserveChannel(
            campaignId: campaign,
            for: "miner-2",
            rankedChannelIds: ranked,
            viableChannelCount: ranked.count
        )

        XCTAssertEqual(first, "chan-a")
        XCTAssertEqual(second, "chan-a")
    }

    /// A miner that died mid-selection must not fence a channel off forever.
    func testExpiredReservationsAreReclaimed() async {
        let manager = manager()

        _ = await manager.reserveChannel(
            campaignId: campaign,
            for: "miner-1",
            rankedChannelIds: ranked,
            viableChannelCount: ranked.count
        )
        manager.channelReservations["miner-1"] = MinerManager.ChannelReservation(
            campaignId: campaign,
            channelIdentity: "chan-a",
            expiresAt: Date().addingTimeInterval(-1)
        )

        let second = await manager.reserveChannel(
            campaignId: campaign,
            for: "miner-2",
            rankedChannelIds: ranked,
            viableChannelCount: ranked.count
        )

        XCTAssertEqual(second, "chan-a")
    }

    /// Channel IDs are compared case-insensitively, the same way the engine identifies them.
    func testReservationMatchingIgnoresCase() async {
        let manager = manager()

        _ = await manager.reserveChannel(
            campaignId: campaign,
            for: "miner-1",
            rankedChannelIds: ["Chan-A", "chan-b"],
            viableChannelCount: 6
        )
        let second = await manager.reserveChannel(
            campaignId: campaign,
            for: "miner-2",
            rankedChannelIds: ["CHAN-a", "chan-b"],
            viableChannelCount: 6
        )

        XCTAssertEqual(second, "chan-b")
    }
}
