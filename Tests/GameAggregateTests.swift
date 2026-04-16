import XCTest
@testable import SwiftMinerCore

final class GameAggregateTests: XCTestCase {

    // MARK: - Campaign Deduplication

    func testCampaignsDeduplicatedById() {
        let drop = Drop(id: "drop1", name: "Drop 1", requiredMinutes: 60)
        let campaign = Campaign(
            id: "camp1",
            name: "Campaign 1",
            game: Game(id: "game1", name: "Test Game"),
            startDate: Date(),
            endDate: Date().addingTimeInterval(86400),
            drops: [drop]
        )
        let duplicate = Campaign(
            id: "camp1",
            name: "Campaign 1 Dup",
            game: Game(id: "game1", name: "Test Game"),
            startDate: Date(),
            endDate: Date().addingTimeInterval(86400),
            drops: []
        )

        let aggregates = GameAggregateBuilder.build(from: [campaign, duplicate])
        XCTAssertEqual(aggregates.count, 1)
        XCTAssertEqual(aggregates.first?.totalDrops, 1)
    }

    // MARK: - Drop Deduplication Across Campaigns

    func testDropsDeduplicatedAcrossCampaignsForSameGame() {
        let sharedDrop = Drop(id: "shared", name: "Shared Drop", requiredMinutes: 30)
        let campaignA = Campaign(
            id: "campA",
            name: "Campaign A",
            game: Game(id: "game1", name: "Test Game"),
            startDate: Date(),
            endDate: Date().addingTimeInterval(86400),
            drops: [sharedDrop]
        )
        let campaignB = Campaign(
            id: "campB",
            name: "Campaign B",
            game: Game(id: "game1", name: "Test Game"),
            startDate: Date(),
            endDate: Date().addingTimeInterval(86400),
            drops: [sharedDrop]
        )

        let aggregates = GameAggregateBuilder.build(from: [campaignA, campaignB])
        XCTAssertEqual(aggregates.count, 1)
        XCTAssertEqual(aggregates.first?.totalDrops, 1)
        XCTAssertEqual(aggregates.first?.earnedDrops, 0)
    }

    // MARK: - Claimed Tracking

    func testDropClaimedTrackedSeparatelyFromEarned() {
        // Task 3: earnedDrops = progressComplete, claimedDrops = isClaimed.
        // A claimed drop without progress does NOT count as earned.
        let dropClaimedOnly = Drop(id: "drop1", name: "Drop 1", requiredMinutes: 60, isClaimed: true)
        let campaignA = Campaign(
            id: "campA",
            name: "Campaign A",
            game: Game(id: "game1", name: "Test Game"),
            startDate: Date(),
            endDate: Date().addingTimeInterval(86400),
            drops: [dropClaimedOnly]
        )

        let aggregates = GameAggregateBuilder.build(from: [campaignA])
        XCTAssertEqual(aggregates.first?.claimedDrops, 1)
        XCTAssertEqual(aggregates.first?.earnedDrops, 0, "Claimed drops without progress should NOT count as earned")
    }

    func testEarnedAndClaimedAreIndependentCounts() {
        var dropEarnedOnly = Drop(id: "drop1", name: "Drop 1", requiredMinutes: 60, isClaimed: false)
        dropEarnedOnly.progress = Progress(
            id: "p1", dropId: "drop1", dropName: "Drop 1", campaignId: "camp1",
            currentMinutes: 60, requiredMinutes: 60, isClaimed: false
        )
        let dropClaimedOnly = Drop(id: "drop2", name: "Drop 2", requiredMinutes: 60, isClaimed: true)
        let campaign = Campaign(
            id: "camp1",
            name: "Campaign 1",
            game: Game(id: "game1", name: "Test Game"),
            startDate: Date(),
            endDate: Date().addingTimeInterval(86400),
            drops: [dropEarnedOnly, dropClaimedOnly]
        )

        let aggregates = GameAggregateBuilder.build(from: [campaign])
        XCTAssertEqual(aggregates.first?.earnedDrops, 1)
        XCTAssertEqual(aggregates.first?.claimedDrops, 1)
        XCTAssertEqual(aggregates.first?.claimableDrops, 1, "Earned but unclaimed drop should be claimable")
    }

    // MARK: - Earned Logic (progress.isComplete)

    func testDropEarnedIfProgressIsComplete() {
        var drop = Drop(id: "drop1", name: "Drop 1", requiredMinutes: 60, isClaimed: false)
        drop.progress = Progress(
            id: "p1",
            dropId: "drop1",
            dropName: "Drop 1",
            campaignId: "camp1",
            currentMinutes: 60,
            requiredMinutes: 60,
            isClaimed: false
        )
        let campaign = Campaign(
            id: "camp1",
            name: "Campaign 1",
            game: Game(id: "game1", name: "Test Game"),
            startDate: Date(),
            endDate: Date().addingTimeInterval(86400),
            drops: [drop]
        )

        let aggregates = GameAggregateBuilder.build(from: [campaign])
        XCTAssertEqual(aggregates.first?.totalDrops, 1)
        XCTAssertEqual(aggregates.first?.earnedDrops, 1)
        XCTAssertEqual(aggregates.first?.progressFraction, 1.0)
    }

    func testClaimableDoesNotCountAsEarned() {
        var drop = Drop(id: "drop1", name: "Drop 1", requiredMinutes: 60, isClaimed: false)
        // isClaimable is true when progress.isComplete && !isClaimed
        // BUT we must NOT use isClaimable as completion criteria.
        // Since progress.isComplete IS true, this drop IS earned by the progress rule.
        // The requirement means we shouldn't write `drop.isClaimable || ...` in the earned check.
        drop.progress = Progress(
            id: "p1",
            dropId: "drop1",
            dropName: "Drop 1",
            campaignId: "camp1",
            currentMinutes: 60,
            requiredMinutes: 60,
            isClaimed: false
        )
        let campaign = Campaign(
            id: "camp1",
            name: "Campaign 1",
            game: Game(id: "game1", name: "Test Game"),
            startDate: Date(),
            endDate: Date().addingTimeInterval(86400),
            drops: [drop]
        )

        let aggregates = GameAggregateBuilder.build(from: [campaign])
        // earned is driven by progress.isComplete, not isClaimable directly
        XCTAssertEqual(aggregates.first?.earnedDrops, 1)
        XCTAssertEqual(aggregates.first?.claimableDrops, 1)
    }

    func testUnearnedUnclaimedDropCountsAsNeither() {
        let drop = Drop(id: "drop1", name: "Drop 1", requiredMinutes: 60, isClaimed: false)
        let campaign = Campaign(
            id: "camp1",
            name: "Campaign 1",
            game: Game(id: "game1", name: "Test Game"),
            startDate: Date(),
            endDate: Date().addingTimeInterval(86400),
            drops: [drop]
        )

        let aggregates = GameAggregateBuilder.build(from: [campaign])
        XCTAssertEqual(aggregates.first?.earnedDrops, 0)
        XCTAssertEqual(aggregates.first?.claimedDrops, 0)
        XCTAssertEqual(aggregates.first?.claimableDrops, 0)
    }

    // MARK: - Progress Calculation

    func testProgressIsEarnedOverTotal() {
        let drop1: Drop = {
            var d = Drop(id: "d1", name: "Drop 1", requiredMinutes: 60, isClaimed: false)
            d.progress = Progress(id: "p1", dropId: "d1", dropName: "Drop 1", campaignId: "c1", currentMinutes: 60, requiredMinutes: 60, isClaimed: false)
            return d
        }()
        let drop2 = Drop(id: "d2", name: "Drop 2", requiredMinutes: 60, isClaimed: false)
        let drop3 = Drop(id: "d3", name: "Drop 3", requiredMinutes: 60, isClaimed: false)
        let campaign = Campaign(
            id: "camp1",
            name: "Campaign 1",
            game: Game(id: "game1", name: "Test Game"),
            startDate: Date(),
            endDate: Date().addingTimeInterval(86400),
            drops: [drop1, drop2, drop3]
        )

        let aggregates = GameAggregateBuilder.build(from: [campaign])
        XCTAssertEqual(aggregates.first?.totalDrops, 3)
        XCTAssertEqual(aggregates.first?.earnedDrops, 1)
        XCTAssertEqual(aggregates.first?.progressFraction ?? -1, 1.0 / 3.0, accuracy: 0.001)
    }

    // MARK: - Multi-Game Separation

    func testMultipleGamesAreSeparate() {
        let gameA = Game(id: "ga", name: "Game A")
        let gameB = Game(id: "gb", name: "Game B")
        let campaignA = Campaign(
            id: "campA",
            name: "Campaign A",
            game: gameA,
            startDate: Date(),
            endDate: Date().addingTimeInterval(86400),
            drops: [Drop(id: "da1", name: "DA1", requiredMinutes: 10)]
        )
        let campaignB = Campaign(
            id: "campB",
            name: "Campaign B",
            game: gameB,
            startDate: Date(),
            endDate: Date().addingTimeInterval(86400),
            drops: [Drop(id: "db1", name: "DB1", requiredMinutes: 10)]
        )

        let aggregates = GameAggregateBuilder.build(from: [campaignA, campaignB])
        XCTAssertEqual(aggregates.count, 2)
    }

    // MARK: - Empty Drops

    func testEmptyDropsReturnsZeroProgress() {
        let campaign = Campaign(
            id: "camp1",
            name: "Campaign 1",
            game: Game(id: "game1", name: "Test Game"),
            startDate: Date(),
            endDate: Date().addingTimeInterval(86400),
            drops: []
        )

        let aggregates = GameAggregateBuilder.build(from: [campaign])
        XCTAssertEqual(aggregates.first?.totalDrops, 0)
        XCTAssertEqual(aggregates.first?.earnedDrops, 0)
        XCTAssertEqual(aggregates.first?.claimedDrops, 0)
        XCTAssertEqual(aggregates.first?.progressFraction, 0)
    }

    // MARK: - Realistic Example

    func testRealisticCampaignDoesNotInflateCounts() {
        let shared = Drop(id: "shared", name: "Shared Reward", requiredMinutes: 30)
        let campaign1 = Campaign(
            id: "c1",
            name: "Week 1",
            game: Game(id: "gzw", name: "Gray Zone Warfare"),
            startDate: Date(),
            endDate: Date().addingTimeInterval(86400),
            drops: [
                shared,
                Drop(id: "c1d2", name: "W1 Drop 2", requiredMinutes: 60),
                Drop(id: "c1d3", name: "W1 Drop 3", requiredMinutes: 90)
            ]
        )
        let campaign2 = Campaign(
            id: "c2",
            name: "Week 2",
            game: Game(id: "gzw", name: "Gray Zone Warfare"),
            startDate: Date(),
            endDate: Date().addingTimeInterval(86400),
            drops: [
                shared,
                Drop(id: "c2d2", name: "W2 Drop 2", requiredMinutes: 60),
                Drop(id: "c2d3", name: "W2 Drop 3", requiredMinutes: 90)
            ]
        )
        let campaign3 = Campaign(
            id: "c3",
            name: "Week 3",
            game: Game(id: "gzw", name: "Gray Zone Warfare"),
            startDate: Date(),
            endDate: Date().addingTimeInterval(86400),
            drops: [
                shared,
                Drop(id: "c3d2", name: "W3 Drop 2", requiredMinutes: 60),
                Drop(id: "c3d3", name: "W3 Drop 3", requiredMinutes: 90)
            ]
        )

        let aggregates = GameAggregateBuilder.build(from: [campaign1, campaign2, campaign3])
        XCTAssertEqual(aggregates.count, 1)
        XCTAssertEqual(aggregates.first?.totalDrops, 7)
    }

    // MARK: - Multi-Account Multi-Campaign Sanity Check

    func testJustChattingExcluded() {
        let justChattingCampaign = Campaign(
            id: "jc-campaign",
            name: "Just Chatting Drops",
            game: Game(id: "509658", name: "Just Chatting"),
            startDate: Date(),
            endDate: Date().addingTimeInterval(86400),
            drops: [Drop(id: "jc-drop", name: "Chat Drop", requiredMinutes: 30)]
        )
        let normalCampaign = Campaign(
            id: "normal-campaign",
            name: "Game Drops",
            game: Game(id: "12345", name: "Real Game"),
            startDate: Date(),
            endDate: Date().addingTimeInterval(86400),
            drops: [Drop(id: "rg-drop", name: "Game Drop", requiredMinutes: 60)]
        )

        let aggregates = GameAggregateBuilder.build(from: [justChattingCampaign, normalCampaign])
        XCTAssertEqual(aggregates.count, 1)
        XCTAssertEqual(aggregates.first?.gameName, "Real Game")
        XCTAssertNil(aggregates.first { $0.gameName == "Just Chatting" })
    }

    func testMultiAccountProgressMerging() {
        // Simulate the same drop seen from 3 accounts with different progress
        var dropAccount1 = Drop(id: "d1", name: "Drop 1", requiredMinutes: 60)
        dropAccount1.progress = Progress(dropId: "d1", campaignId: "c1", currentMinutes: 15, requiredMinutes: 60)

        var dropAccount2 = Drop(id: "d1", name: "Drop 1", requiredMinutes: 60)
        dropAccount2.progress = Progress(dropId: "d1", campaignId: "c1", currentMinutes: 45, requiredMinutes: 60)

        var dropAccount3 = Drop(id: "d1", name: "Drop 1", requiredMinutes: 60)
        dropAccount3.progress = Progress(dropId: "d1", campaignId: "c1", currentMinutes: 30, requiredMinutes: 60)

        let campaign1 = Campaign(
            id: "c1",
            name: "Campaign 1",
            game: Game(id: "game1", name: "Test Game"),
            startDate: Date(),
            endDate: Date().addingTimeInterval(86400),
            drops: [dropAccount1]
        )
        let campaign2 = Campaign(
            id: "c1",
            name: "Campaign 1",
            game: Game(id: "game1", name: "Test Game"),
            startDate: Date(),
            endDate: Date().addingTimeInterval(86400),
            drops: [dropAccount2]
        )
        let campaign3 = Campaign(
            id: "c1",
            name: "Campaign 1",
            game: Game(id: "game1", name: "Test Game"),
            startDate: Date(),
            endDate: Date().addingTimeInterval(86400),
            drops: [dropAccount3]
        )

        let aggregates = GameAggregateBuilder.build(from: [campaign1, campaign2, campaign3])
        XCTAssertEqual(aggregates.count, 1)
        XCTAssertEqual(aggregates.first?.totalDrops, 1)
        // The best progress across all accounts should be preserved (45 minutes)
        XCTAssertEqual(aggregates.first?.earnedDrops, 0)
    }

    func testMultiAccountMultiCampaignDeduplication() {
        // Simulate data from multiple accounts with overlapping campaigns
        let sharedDrop = Drop(id: "shared-drop", name: "Shared Drop", requiredMinutes: 30)
        let dropA = Drop(id: "drop-a", name: "Drop A", requiredMinutes: 60)
        let dropB = Drop(id: "drop-b", name: "Drop B", requiredMinutes: 60)

        // Account 1 sees campaign A with [shared, dropA]
        let campaignA1 = Campaign(
            id: "camp-a",
            name: "Campaign A",
            game: Game(id: "game1", name: "Test Game"),
            startDate: Date(),
            endDate: Date().addingTimeInterval(86400),
            drops: [sharedDrop, dropA]
        )
        // Account 2 sees campaign A with [shared, dropA] (same)
        let campaignA2 = Campaign(
            id: "camp-a",
            name: "Campaign A",
            game: Game(id: "game1", name: "Test Game"),
            startDate: Date(),
            endDate: Date().addingTimeInterval(86400),
            drops: [sharedDrop, dropA]
        )
        // Account 2 also sees campaign B with [shared, dropB]
        let campaignB1 = Campaign(
            id: "camp-b",
            name: "Campaign B",
            game: Game(id: "game1", name: "Test Game"),
            startDate: Date(),
            endDate: Date().addingTimeInterval(86400),
            drops: [sharedDrop, dropB]
        )

        let aggregates = GameAggregateBuilder.build(from: [campaignA1, campaignA2, campaignB1])
        XCTAssertEqual(aggregates.count, 1)
        // shared-drop appears in both campaigns but deduplicated to 1
        // drop-a from camp-a and drop-b from camp-b are unique
        // Total = 1 + 1 + 1 = 3 unique drops
        XCTAssertEqual(aggregates.first?.totalDrops, 3)
        XCTAssertEqual(aggregates.first?.gameName, "Test Game")
    }

    // MARK: - Drops Grouping Aggregates (CampaignViewData)

    func testBuildDrops_AggregatesByGameId_WithBlockedPrecedence() {
        let now = Date()
        let blocked = makeCampaignViewData(
            id: "c-blocked",
            gameId: "g-1",
            gameName: "Game One",
            progress: 0,
            isAccountConnected: false,
            startDate: now.addingTimeInterval(-600),
            endDate: now.addingTimeInterval(3600)
        )
        let inProgress = makeCampaignViewData(
            id: "c-progress",
            gameId: "g-1",
            gameName: "Game One",
            progress: 0.42,
            isAccountConnected: true,
            startDate: now.addingTimeInterval(-600),
            endDate: now.addingTimeInterval(3600)
        )

        let grouped = GameAggregateBuilder.buildDrops(from: [inProgress, blocked], now: now)

        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped.first?.id, "g-1")
        XCTAssertEqual(grouped.first?.aggregateState, .actionRequired)
        XCTAssertEqual(grouped.first?.campaigns.count, 2)
        XCTAssertEqual(grouped.first?.campaigns.first?.state, .actionRequired)
    }

    func testBuildDrops_StatePrecedence_InProgressThenReadyThenCompleted() {
        let now = Date()
        let ready = makeCampaignViewData(
            id: "c-ready",
            gameId: "g-ready",
            gameName: "Ready Game",
            progress: 0,
            isAccountConnected: true,
            startDate: now.addingTimeInterval(-600),
            endDate: now.addingTimeInterval(3600),
            drops: [makeDrop(id: "d-ready", progress: 0, isClaimed: false, isClaimable: false)],
            dropsClaimed: 0,
            totalDrops: 1
        )
        let completed = makeCampaignViewData(
            id: "c-complete",
            gameId: "g-complete",
            gameName: "Complete Game",
            progress: 1.0,
            isClaimed: true,
            isAccountConnected: true,
            startDate: now.addingTimeInterval(-3600),
            endDate: now.addingTimeInterval(-60),
            drops: [makeDrop(id: "d-complete", progress: 1, isClaimed: true, isClaimable: false)],
            dropsClaimed: 1,
            totalDrops: 1
        )
        let inProgress = makeCampaignViewData(
            id: "c-progress",
            gameId: "g-progress",
            gameName: "Progress Game",
            progress: 0.2,
            isAccountConnected: true,
            startDate: now.addingTimeInterval(-600),
            endDate: now.addingTimeInterval(3600)
        )

        let grouped = GameAggregateBuilder.buildDrops(from: [completed, ready, inProgress], now: now)

        XCTAssertEqual(grouped.map(\.aggregateState), [.inProgress, .ready, .completed])
    }

    func testBuildDrops_ExpiredAndUnavailableEdgeCases() {
        let now = Date()
        let expiredUnclaimed = makeCampaignViewData(
            id: "c-expired",
            gameId: "g-edge",
            gameName: "Edge Game",
            progress: 0.3,
            isAccountConnected: true,
            startDate: now.addingTimeInterval(-7200),
            endDate: now.addingTimeInterval(-60),
            drops: [makeDrop(id: "d-expired", progress: 0.3, isClaimed: false, isClaimable: false)],
            dropsClaimed: 0,
            totalDrops: 1
        )
        let expiredClaimed = makeCampaignViewData(
            id: "c-expired-claimed",
            gameId: "g-edge",
            gameName: "Edge Game",
            progress: 1.0,
            isClaimed: true,
            isAccountConnected: true,
            startDate: now.addingTimeInterval(-7200),
            endDate: now.addingTimeInterval(-60),
            drops: [makeDrop(id: "d-expired-claimed", progress: 1, isClaimed: true, isClaimable: false)],
            dropsClaimed: 1,
            totalDrops: 1
        )

        let grouped = GameAggregateBuilder.buildDrops(from: [expiredUnclaimed, expiredClaimed], now: now)
        let states = grouped.first?.campaigns.map(\.state)

        XCTAssertEqual(grouped.first?.aggregateState, .completed)
        XCTAssertEqual(states, [.completed, .unavailable])
    }

    private func makeCampaignViewData(
        id: String,
        gameId: String,
        gameName: String,
        progress: Double,
        isClaimed: Bool = false,
        isAccountConnected: Bool,
        startDate: Date,
        endDate: Date,
        drops: [DropViewData] = [DropViewData(id: "d-default", name: "Drop", description: nil, imageURL: nil, rewardType: .inGame, requiredMinutes: 60, currentMinutes: 0, progress: 0, isClaimed: false, isClaimable: false, isEarnable: true)],
        dropsClaimed: Int = 0,
        totalDrops: Int = 1
    ) -> CampaignViewData {
        CampaignViewData(
            id: id,
            gameId: gameId,
            gameName: gameName,
            campaignName: "Campaign \(id)",
            artworkURL: nil,
            progress: progress,
            isClaimed: isClaimed,
            dropsClaimed: dropsClaimed,
            totalDrops: totalDrops,
            status: "ACTIVE",
            miningStatus: isClaimed ? .claimed : (progress > 0 ? .inProgress : .available),
            isAccountConnected: isAccountConnected,
            relevance: .active,
            startDate: startDate,
            endDate: endDate,
            drops: drops,
            accountStates: []
        )
    }

    private func makeDrop(
        id: String,
        progress: Double,
        isClaimed: Bool,
        isClaimable: Bool
    ) -> DropViewData {
        DropViewData(
            id: id,
            name: "Drop \(id)",
            description: nil,
            imageURL: nil,
            rewardType: .inGame,
            requiredMinutes: 60,
            currentMinutes: Int((progress * 60).rounded()),
            progress: progress,
            isClaimed: isClaimed,
            isClaimable: isClaimable,
            isEarnable: !isClaimed && !isClaimable
        )
    }
}
