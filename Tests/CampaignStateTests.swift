import XCTest
@testable import SwiftMinerCore

final class CampaignStateTests: XCTestCase {

    let now = Date()
    var game: Game!

    override func setUp() {
        super.setUp()
        game = Game(id: "g1", name: "Test Game")
    }

    // MARK: - isClosed Tests

    func testIsClosed_ActiveAndUnclaimed_IsFalse() {
        let drop = Drop(id: "d1", name: "D1", requiredMinutes: 60, isClaimed: false)
        let campaign = Campaign(
            id: "c1", name: "C1", game: game, status: .active,
            startDate: now.addingTimeInterval(-3600), endDate: now.addingTimeInterval(3600),
            drops: [drop]
        )
        XCTAssertFalse(campaign.isClosed)
    }

    func testIsClosed_ActiveAndClaimed_IsFalse() {
        // Even if all drops are claimed, it's not "closed" if the window is still active
        let drop = Drop(id: "d1", name: "D1", requiredMinutes: 60, isClaimed: true)
        let campaign = Campaign(
            id: "c1", name: "C1", game: game, status: .active,
            startDate: now.addingTimeInterval(-3600), endDate: now.addingTimeInterval(3600),
            drops: [drop]
        )
        XCTAssertFalse(campaign.isClosed)
    }

    func testIsClosed_ExpiredAndUnclaimed_IsFalse() {
        // If it's expired but we didn't claim everything, it's not "closed" in the sense of a successful archive
        let drop = Drop(id: "d1", name: "D1", requiredMinutes: 60, isClaimed: false)
        let campaign = Campaign(
            id: "c1", name: "C1", game: game, status: .expired,
            startDate: now.addingTimeInterval(-7200), endDate: now.addingTimeInterval(-3600),
            drops: [drop]
        )
        XCTAssertFalse(campaign.isClosed)
    }

    func testIsClosed_ExpiredAndClaimed_IsTrue() {
        // This is the definition of a closed campaign
        let drop = Drop(id: "d1", name: "D1", requiredMinutes: 60, isClaimed: true)
        let campaign = Campaign(
            id: "c1", name: "C1", game: game, status: .expired,
            startDate: now.addingTimeInterval(-7200), endDate: now.addingTimeInterval(-3600),
            drops: [drop]
        )
        XCTAssertTrue(campaign.isClosed)
    }

    func testIsClosed_EndedByDateAndClaimed_IsTrue() {
        let drop = Drop(id: "d1", name: "D1", requiredMinutes: 60, isClaimed: true)
        let campaign = Campaign(
            id: "c1", name: "C1", game: game, status: .active, // status still active but date passed
            startDate: now.addingTimeInterval(-7200), endDate: now.addingTimeInterval(-3600),
            drops: [drop]
        )
        XCTAssertTrue(campaign.isClosed)
    }

    // MARK: - Relevance Tests

    func testRelevance_Prioritised_TakesPrecedence() {
        let campaign = Campaign(
            id: "c1", name: "C1", game: game, status: .active,
            startDate: now.addingTimeInterval(-3600), endDate: now.addingTimeInterval(3600),
            isPrioritised: true
        )
        XCTAssertEqual(campaign.relevance, CampaignRelevance.prioritised)
    }

    func testRelevance_Active_WhenAvailable() {
        let campaign = Campaign(
            id: "c1", name: "C1", game: game, status: .active,
            startDate: now.addingTimeInterval(-3600), endDate: now.addingTimeInterval(3600),
            isAccountConnected: true
        )
        // miningStatus should be .available
        XCTAssertEqual(campaign.relevance, CampaignRelevance.active)
    }

    func testRelevance_Irrelevant_WhenLiveButGameAccountNotConnectedAndNotPrioritised() {
        let campaign = Campaign(
            id: "c1", name: "C1", game: game, status: .active,
            startDate: now.addingTimeInterval(-3600), endDate: now.addingTimeInterval(3600),
            drops: [Drop(id: "d1", name: "D1", requiredMinutes: 60)],
            isAccountConnected: false
        )

        XCTAssertEqual(campaign.relevance, CampaignRelevance.irrelevant)
    }

    func testRelevance_Irrelevant_WhenOnlyRemainingRewardRequiresSubscriptionAndNotPrioritised() {
        let campaign = Campaign(
            id: "c-sub", name: "Sub Campaign", game: game, status: .active,
            startDate: now.addingTimeInterval(-3600), endDate: now.addingTimeInterval(3600),
            drops: [Drop(id: "d-sub", name: "Paid Reward", requiredMinutes: 0, requiredSubs: 1)],
            isAccountConnected: false
        )

        XCTAssertEqual(campaign.relevance, CampaignRelevance.irrelevant)
        XCTAssertEqual(campaign.subscriptionRequiredDrops.map(\.name), ["Paid Reward"])
        XCTAssertFalse(campaign.canAttemptMining)
    }

    func testLikelyInternalTestCampaignIsNotActionable() {
        let campaign = Campaign(
            id: "c-test", name: "Drops test", game: game, status: .active,
            startDate: now.addingTimeInterval(-3600), endDate: now.addingTimeInterval(3600),
            drops: [Drop(id: "d-test", name: "test", requiredMinutes: 1)],
            isAccountConnected: true
        )

        XCTAssertTrue(campaign.isLikelyInternalTestCampaign)
        XCTAssertFalse(campaign.canAttemptMining)
        XCTAssertEqual(campaign.relevance, CampaignRelevance.irrelevant)
    }

    func testLegitimateCampaignContainingTestWordRemainsActionable() {
        let campaign = Campaign(
            id: "c-legit", name: "Beta Test Rewards", game: game, status: .active,
            startDate: now.addingTimeInterval(-3600), endDate: now.addingTimeInterval(3600),
            drops: [Drop(id: "d-legit", name: "Launch Skin", requiredMinutes: 60)],
            isAccountConnected: true
        )

        XCTAssertFalse(campaign.isLikelyInternalTestCampaign)
        XCTAssertTrue(campaign.canAttemptMining)
        XCTAssertEqual(campaign.relevance, CampaignRelevance.active)
    }

    func testInternalTestProgressUsesExactLabel() {
        let internalProgress = Progress(
            id: "instance-test",
            dropId: "d-test",
            dropName: "test",
            campaignId: "c-test",
            currentMinutes: 1,
            requiredMinutes: 1
        )
        let legitimateProgress = Progress(
            id: "instance-legit",
            dropId: "d-legit",
            dropName: "Beta Test Reward",
            campaignId: "c-legit",
            currentMinutes: 60,
            requiredMinutes: 60
        )

        XCTAssertTrue(internalProgress.isLikelyInternalTestProgress)
        XCTAssertFalse(legitimateProgress.isLikelyInternalTestProgress)
    }

    func testRelevance_Closed_WhenIsClosed() {
        let drop = Drop(id: "d1", name: "D1", requiredMinutes: 60, isClaimed: false)
        let campaign = Campaign(
            id: "c1", name: "C1", game: game, status: .expired,
            startDate: now.addingTimeInterval(-7200), endDate: now.addingTimeInterval(-3600),
            drops: [drop]
        )
        // Ended and NOT fully claimed = closed (if not active)
        XCTAssertEqual(campaign.relevance, CampaignRelevance.closed)
    }

    func testRelevance_Recent_WhenClaimedRecently() {
        let lastUpdated = now.addingTimeInterval(-3600) // 1 hour ago
        let progress = Progress(id: "c1_d1", dropId: "d1", dropName: "D1", campaignId: "c1", currentMinutes: 60, requiredMinutes: 60, isClaimed: true, lastUpdated: lastUpdated)
        let drop = Drop(id: "d1", name: "D1", requiredMinutes: 60, progress: progress, isClaimed: true)
        
        let campaign = Campaign(
            id: "c1", name: "C1", game: game, status: .active,
            startDate: now.addingTimeInterval(-7200), endDate: now.addingTimeInterval(3600),
            drops: [drop],
            isAccountConnected: true
        )
        // miningStatus is .claimed, and new logic prioritises .recent for all claimed
        XCTAssertEqual(campaign.relevance, CampaignRelevance.recent)
    }

    // MARK: - Edge Cases

    func testEdgeCase_EmptyDrops_Expired_IsClosed() {
        let campaign = Campaign(
            id: "c1", name: "C1", game: game, status: .expired,
            startDate: now.addingTimeInterval(-7200), endDate: now.addingTimeInterval(-3600),
            drops: []
        )
        // New logic: fully claimed (empty drops) but !drops.isEmpty is false, so it falls through to .closed
        XCTAssertEqual(campaign.relevance, CampaignRelevance.closed)
    }

    func testEdgeCase_EmptyDrops_Active_IsFalse() {
        let campaign = Campaign(
            id: "c1", name: "C1", game: game, status: .active,
            startDate: now.addingTimeInterval(-3600), endDate: now.addingTimeInterval(3600),
            drops: []
        )
        XCTAssertFalse(campaign.isClosed)
    }

    func testEdgeCase_ExpiredUnclaimed_RelevanceIsActive() {
        let drop = Drop(id: "d1", name: "D1", requiredMinutes: 60, isClaimed: false)
        let campaign = Campaign(
            id: "c1", name: "C1", game: game, status: .expired,
            startDate: now.addingTimeInterval(-7200), endDate: now.addingTimeInterval(-3600),
            drops: [drop],
            isAccountConnected: true
        )
        // Ended = closed (even if connected)
        XCTAssertEqual(campaign.relevance, CampaignRelevance.closed)
    }

    func testEdgeCase_TimeBoundary_JustEnded() {
        let drop = Drop(id: "d1", name: "D1", requiredMinutes: 60, isClaimed: true)
        let campaign = Campaign(
            id: "c1", name: "C1", game: game, status: .active,
            startDate: now.addingTimeInterval(-7200), endDate: now.addingTimeInterval(-1), // Ended 1s ago
            drops: [drop]
        )
        // Fully claimed = recent
        XCTAssertEqual(campaign.relevance, CampaignRelevance.recent)
    }

    func testMergePreservesCachedDropsForEndedFreshShell() {
        let cachedDrop = Drop(
            id: "d1",
            name: "Cached Reward",
            requiredMinutes: 60,
            benefitID: "benefit-1",
            isClaimed: true
        )
        let cached = Campaign(
            id: "c1",
            name: "Cached Campaign",
            game: game,
            status: .active,
            startDate: now.addingTimeInterval(-7200),
            endDate: now.addingTimeInterval(-3600),
            drops: [cachedDrop],
            isAccountConnected: true
        )
        let freshShell = Campaign(
            id: "c1",
            name: "Cached Campaign",
            game: game,
            status: .expired,
            startDate: now.addingTimeInterval(-7200),
            endDate: now.addingTimeInterval(-3600),
            drops: [],
            isAccountConnected: true
        )

        let endedCampaignKeepsCachedArtwork = CampaignMergeEngine.merge(fresh: [freshShell], cached: [cached], inventory: nil)

        XCTAssertEqual(endedCampaignKeepsCachedArtwork.count, 1)
        XCTAssertEqual(endedCampaignKeepsCachedArtwork.first?.drops.map(\.name), ["Cached Reward"])

        let otherFreshCampaign = Campaign(
            id: "c2",
            name: "Other Campaign",
            game: game,
            status: .active,
            startDate: now.addingTimeInterval(-3600),
            endDate: now.addingTimeInterval(3600),
            drops: [Drop(id: "d2", name: "Other Reward", requiredMinutes: 30)],
            isAccountConnected: true
        )
        let cachedFallback = CampaignMergeEngine.merge(fresh: [otherFreshCampaign], cached: [cached], inventory: nil)

        XCTAssertEqual(cachedFallback.count, 2)
        XCTAssertEqual(cachedFallback.first(where: { $0.id == "c1" })?.drops.map(\.name), ["Cached Reward"])
    }

    // MARK: - Live-aware candidate ranking (Overwatch starvation fix)

    /// A limited-time campaign that ends sooner normally sorts first under `.mineAll`. When its
    /// game has no live channel, it must sink below a still-active game (Overwatch) that does —
    /// otherwise it repeatedly preempts / starves the game that can actually be mined.
    func testRanking_DemotesGamesWithNoLiveChannelBelowLiveOnes() {
        let overwatch = Game(id: "ow", name: "Overwatch 2")
        let esports = Game(id: "owcs", name: "OWCS Esports")

        let overwatchCampaign = Campaign(
            id: "c-ow", name: "Reign of Talon", game: overwatch, status: .active,
            startDate: now.addingTimeInterval(-3600), endDate: now.addingTimeInterval(7 * 86_400),
            drops: [Drop(id: "d-ow", name: "Skin", requiredMinutes: 60)],
            isAccountConnected: true
        )
        // Ends sooner — would win the end-date-first sort under `.mineAll`.
        let limitedCampaign = Campaign(
            id: "c-owcs", name: "OWCS S2 Campaign 3", game: esports, status: .active,
            startDate: now.addingTimeInterval(-3600), endDate: now.addingTimeInterval(86_400),
            drops: [Drop(id: "d-owcs", name: "Loot Box", requiredMinutes: 60)],
            isAccountConnected: true
        )

        // Without any empty-game knowledge, the sooner-ending limited campaign sorts first.
        let naive = MinerEngine.rankCandidates(
            [overwatchCampaign, limitedCampaign],
            priorityKeys: [], strategy: .mineAll, emptyGameKeys: []
        )
        XCTAssertEqual(naive.first?.id, "c-owcs")

        // Once the esports game is known to have no live channel, Overwatch ranks first.
        let liveAware = MinerEngine.rankCandidates(
            [overwatchCampaign, limitedCampaign],
            priorityKeys: [], strategy: .mineAll, emptyGameKeys: ["owcs esports"]
        )
        XCTAssertEqual(liveAware.first?.id, "c-ow")
        XCTAssertEqual(liveAware.last?.id, "c-owcs")
    }

    /// Demotion is the primary key: a live non-priority game outranks a priority game that
    /// currently has no live channel, since an unwatchable priority game can't be mined anyway.
    func testRanking_LiveNonPriorityBeatsEmptyPriority() {
        let priorityGame = Game(id: "pri", name: "Priority Game")
        let liveGame = Game(id: "live", name: "Live Game")

        let priorityCampaign = Campaign(
            id: "c-pri", name: "Pri", game: priorityGame, status: .active,
            startDate: now.addingTimeInterval(-3600), endDate: now.addingTimeInterval(86_400),
            drops: [Drop(id: "d-pri", name: "R", requiredMinutes: 60)],
            isAccountConnected: true
        )
        let liveCampaign = Campaign(
            id: "c-live", name: "Live", game: liveGame, status: .active,
            startDate: now.addingTimeInterval(-3600), endDate: now.addingTimeInterval(2 * 86_400),
            drops: [Drop(id: "d-live", name: "R", requiredMinutes: 60)],
            isAccountConnected: true
        )

        let ranked = MinerEngine.rankCandidates(
            [priorityCampaign, liveCampaign],
            priorityKeys: ["priority game"], strategy: .prioritiseSelected,
            emptyGameKeys: ["priority game"]
        )
        XCTAssertEqual(ranked.first?.id, "c-live")
    }
}
