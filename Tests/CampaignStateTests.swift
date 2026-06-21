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

    func testMergePreservesCompletedCachedCampaignOnlyWhenMissingFromTwitch() {
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

        let freshWins = CampaignMergeEngine.merge(fresh: [freshShell], cached: [cached], inventory: nil)

        XCTAssertEqual(freshWins.count, 1)
        XCTAssertTrue(freshWins.first?.drops.isEmpty == true)

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
}
