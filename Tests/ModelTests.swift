import XCTest
@testable import SwiftMinerCore

final class ModelTests: XCTestCase {

    // MARK: - Account

    func testAccountTokenValid() {
        let account = Account(
            id: "123", username: "testuser",
            accessToken: "token", refreshToken: "refresh",
            tokenExpiry: Date().addingTimeInterval(3600),
            scopes: ["user:read:email"]
        )
        XCTAssertTrue(account.isTokenValid)
    }

    func testAccountTokenExpired() {
        let account = Account(
            id: "123", username: "testuser",
            accessToken: "token", refreshToken: "refresh",
            tokenExpiry: Date().addingTimeInterval(-600),
            scopes: ["user:read:email"]
        )
        XCTAssertFalse(account.isTokenValid)
    }

    // MARK: - Drop

    func testDropNotClaimedByDefault() {
        let drop = Drop(id: "d1", name: "Test Drop", requiredMinutes: 60)
        XCTAssertFalse(drop.isClaimed)
        XCTAssertFalse(drop.isClaimable)
        XCTAssertEqual(drop.percentComplete, 0)
    }

    func testDropIsClaimableWhenProgressComplete() {
        let progress = Progress(
            dropId: "d1", campaignId: "c1",
            currentMinutes: 60, requiredMinutes: 60, isClaimed: false
        )
        let drop = Drop(id: "d1", name: "Test Drop", requiredMinutes: 60, progress: progress)
        XCTAssertTrue(drop.isClaimable)
        XCTAssertFalse(drop.isClaimed)
    }

    func testDropNotClaimableAfterClaimed() {
        let progress = Progress(
            dropId: "d1", campaignId: "c1",
            currentMinutes: 60, requiredMinutes: 60, isClaimed: true
        )
        let drop = Drop(id: "d1", name: "Test Drop", requiredMinutes: 60, progress: progress, isClaimed: true)
        XCTAssertFalse(drop.isClaimable)
        XCTAssertTrue(drop.isClaimed)
    }

    func testDropEquality() {
        let a = Drop(id: "d1", name: "Drop A", requiredMinutes: 30)
        let b = Drop(id: "d1", name: "Drop A", requiredMinutes: 30)
        let c = Drop(id: "d2", name: "Drop C", requiredMinutes: 60)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - Campaign

    func testCampaignIsTimeActive() {
        let now = Date()
        let game = Game(id: "g1", name: "Test Game")

        let active = Campaign(
            id: "c1", name: "Active", game: game, status: .active,
            startDate: now.addingTimeInterval(-3600), endDate: now.addingTimeInterval(3600)
        )
        XCTAssertTrue(active.isTimeActive)

        let future = Campaign(
            id: "c2", name: "Future", game: game, status: .upcoming,
            startDate: now.addingTimeInterval(3600), endDate: now.addingTimeInterval(7200)
        )
        XCTAssertFalse(future.isTimeActive)

        let expired = Campaign(
            id: "c3", name: "Expired", game: game, status: .expired,
            startDate: now.addingTimeInterval(-7200), endDate: now.addingTimeInterval(-3600)
        )
        XCTAssertFalse(expired.isTimeActive)
    }

    func testCampaignUnclaimedDrops() {
        let game = Game(id: "g1", name: "Test Game")
        let now = Date()

        let claimedProg = Progress(dropId: "d1", campaignId: "c1",
                                   currentMinutes: 60, requiredMinutes: 60, isClaimed: true)
        let claimed = Drop(id: "d1", name: "Claimed", requiredMinutes: 60, progress: claimedProg, isClaimed: true)
        let unclaimed = Drop(id: "d2", name: "Unclaimed", requiredMinutes: 60)

        let campaign = Campaign(
            id: "c1", name: "Campaign", game: game, status: .active,
            startDate: now.addingTimeInterval(-3600), endDate: now.addingTimeInterval(3600),
            drops: [claimed, unclaimed]
        )
        XCTAssertEqual(campaign.unclaimedDrops.count, 1)
        XCTAssertEqual(campaign.unclaimedDrops.first?.id, "d2")
    }

    func testCampaignHasClaimableDrops() {
        let game = Game(id: "g1", name: "Test Game")
        let now = Date()

        let readyProg = Progress(dropId: "d1", campaignId: "c1",
                                 currentMinutes: 60, requiredMinutes: 60, isClaimed: false)
        let readyDrop = Drop(id: "d1", name: "Ready", requiredMinutes: 60, progress: readyProg)

        let campaign = Campaign(
            id: "c1", name: "Campaign", game: game, status: .active,
            startDate: now.addingTimeInterval(-3600), endDate: now.addingTimeInterval(3600),
            drops: [readyDrop]
        )
        XCTAssertTrue(campaign.hasClaimableDrops)
    }

    func testCampaignLegacyShims() {
        let game = Game(id: "g1", name: "Fortnite")
        let now = Date()
        let start = now
        let end = now.addingTimeInterval(3600)
        let campaign = Campaign(
            id: "c1", name: "Campaign", game: game, status: .active,
            startDate: start, endDate: end
        )
        XCTAssertEqual(campaign.gameId, "g1")
        XCTAssertEqual(campaign.gameName, "Fortnite")
        XCTAssertEqual(campaign.startAt, start)
        XCTAssertEqual(campaign.endAt, end)
        XCTAssertTrue(campaign.hasDropsEnabled)
    }

    func testCampaignMiningEligibilityRequiresAllowEnabled() {
        let game = Game(id: "g1", name: "Test Game")
        let now = Date()
        let drop = Drop(id: "d1", name: "Drop", requiredMinutes: 60)
        let campaign = Campaign(
            id: "c1",
            name: "Blocked Campaign",
            game: game,
            status: .active,
            startDate: now.addingTimeInterval(-3600),
            endDate: now.addingTimeInterval(3600),
            drops: [drop],
            isAccountConnected: true,
            allowIsEnabled: false
        )

        XCTAssertFalse(campaign.hasDropsEnabled)
        XCTAssertFalse(campaign.isMiningEligible)
    }

    // MARK: - Progress

    func testProgressPartial() {
        let p = Progress(
            id: "p1", dropId: "d1", dropName: "Drop",
            campaignId: "c1", currentMinutes: 30, requiredMinutes: 60
        )
        XCTAssertFalse(p.isComplete)
        XCTAssertEqual(p.remainingMinutes, 30)
        XCTAssertEqual(p.percentComplete, 50.0, accuracy: 0.01)
    }

    func testProgressComplete() {
        let p = Progress(
            id: "p2", dropId: "d2", dropName: "Drop",
            campaignId: "c1", currentMinutes: 60, requiredMinutes: 60
        )
        XCTAssertTrue(p.isComplete)
        XCTAssertEqual(p.remainingMinutes, 0)
        XCTAssertEqual(p.percentComplete, 100.0, accuracy: 0.01)
    }

    func testProgressConvenienceInit() {
        let p = Progress(dropId: "d1", campaignId: "c1", currentMinutes: 15, requiredMinutes: 30)
        XCTAssertEqual(p.dropId, "d1")
        XCTAssertEqual(p.campaignId, "c1")
        XCTAssertEqual(p.currentMinutes, 15)
        XCTAssertFalse(p.isClaimed)
        XCTAssertEqual(p.id, "c1_d1")
    }

    func testDropProgressTrackerIgnoresInitialZeroProgress() {
        var tracker = DropProgressEventTracker()

        let result = tracker.observe(
            DropProgressObservation(
                campaignId: "campaign-1",
                dropId: "drop-1",
                dropLabel: "Drop One",
                currentMinutes: 0,
                requiredMinutes: 60,
                source: .pubSub
            )
        )

        XCTAssertEqual(result.transition, .none)
        XCTAssertFalse(result.shouldAcknowledgeServerProgress)
    }

    func testDropProgressTrackerEmitsDeltaForMeaningfulIncrease() {
        var tracker = DropProgressEventTracker()

        _ = tracker.observe(
            DropProgressObservation(
                campaignId: "campaign-1",
                dropId: "drop-1",
                dropLabel: "Drop One",
                currentMinutes: 12,
                requiredMinutes: 60,
                source: .pubSub
            )
        )

        let result = tracker.observe(
            DropProgressObservation(
                campaignId: "campaign-1",
                dropId: "drop-1",
                dropLabel: "Drop One",
                currentMinutes: 13,
                requiredMinutes: 60,
                source: .gqlPoll
            )
        )

        XCTAssertEqual(
            result.transition,
            .progress(dropLabel: "Drop One", deltaMinutes: 1, currentMinutes: 13, requiredMinutes: 60)
        )
        XCTAssertTrue(result.shouldAcknowledgeServerProgress)
    }

    func testDropProgressTrackerEmitsClaimableAtThresholdInsteadOfZeroNoise() {
        var tracker = DropProgressEventTracker()

        _ = tracker.observe(
            DropProgressObservation(
                campaignId: "campaign-1",
                dropId: "drop-1",
                dropLabel: "Drop One",
                currentMinutes: 59,
                requiredMinutes: 60,
                source: .pubSub
            )
        )

        let result = tracker.observe(
            DropProgressObservation(
                campaignId: "campaign-1",
                dropId: "drop-1",
                dropLabel: "Drop One",
                currentMinutes: 60,
                requiredMinutes: 60,
                source: .gqlPoll
            )
        )

        XCTAssertEqual(
            result.transition,
            .claimable(dropLabel: "Drop One", currentMinutes: 60, requiredMinutes: 60)
        )
        XCTAssertTrue(result.shouldAcknowledgeServerProgress)
    }

    func testDropProgressTrackerSuppressesUnchangedAndRegressingPolls() {
        var tracker = DropProgressEventTracker()

        _ = tracker.observe(
            DropProgressObservation(
                campaignId: "campaign-1",
                dropId: "drop-1",
                dropLabel: "Drop One",
                currentMinutes: 15,
                requiredMinutes: 60,
                source: .pubSub
            )
        )

        let unchanged = tracker.observe(
            DropProgressObservation(
                campaignId: "campaign-1",
                dropId: "drop-1",
                dropLabel: "Drop One",
                currentMinutes: 15,
                requiredMinutes: 60,
                source: .gqlPoll
            )
        )
        let regression = tracker.observe(
            DropProgressObservation(
                campaignId: "campaign-1",
                dropId: "drop-1",
                dropLabel: "Drop One",
                currentMinutes: 14,
                requiredMinutes: 60,
                source: .gqlPoll
            )
        )

        XCTAssertEqual(unchanged.transition, .none)
        XCTAssertFalse(unchanged.shouldAcknowledgeServerProgress)
        XCTAssertEqual(regression.transition, .regression(previousMinutes: 15, observedMinutes: 14))
        XCTAssertFalse(regression.shouldAcknowledgeServerProgress)
    }

    func testDropProgressTrackerMarksClaimedOnlyOnce() {
        var tracker = DropProgressEventTracker()

        _ = tracker.observe(
            DropProgressObservation(
                campaignId: "campaign-1",
                dropId: "drop-1",
                dropLabel: "Drop One",
                currentMinutes: 60,
                requiredMinutes: 60,
                source: .pubSub
            )
        )

        let firstClaim = tracker.markClaimed(campaignId: "campaign-1", dropId: "drop-1", dropLabel: "Drop One")
        let secondClaim = tracker.markClaimed(campaignId: "campaign-1", dropId: "drop-1", dropLabel: "Drop One")

        XCTAssertEqual(firstClaim.transition, .claimed(dropLabel: "Drop One"))
        XCTAssertTrue(firstClaim.shouldAcknowledgeServerProgress)
        XCTAssertEqual(secondClaim.transition, .none)
        XCTAssertFalse(secondClaim.shouldAcknowledgeServerProgress)
    }

    // MARK: - Channel

    func testChannelFullInit() {
        let channel = Channel(
            id: "ch1", login: "shroud", displayName: "Shroud",
            isLive: true, hasDropsEnabled: true
        )
        XCTAssertEqual(channel.login, "shroud")
        XCTAssertTrue(channel.isLive)
        XCTAssertTrue(channel.hasDropsEnabled)
    }

    func testChannelConvenienceInit() {
        let channel = Channel(id: "ch1", login: "shroud", displayName: "Shroud", profileImageURL: nil)
        XCTAssertEqual(channel.id, "ch1")
        XCTAssertFalse(channel.isLive)
        XCTAssertFalse(channel.hasDropsEnabled)
    }

    // MARK: - DropProgressEvent

    func testDropProgressEvent() {
        let event = DropProgressEvent(dropId: "d1", currentMinutes: 10, requiredMinutes: 30)
        XCTAssertEqual(event.dropId, "d1")
        XCTAssertEqual(event.currentMinutes, 10)
        XCTAssertEqual(event.requiredMinutes, 30)
    }

    func testDropClaimEvent() {
        let event = DropClaimEvent(dropInstanceId: "inst_1", dropId: "d1", channelId: "ch1")
        XCTAssertEqual(event.dropInstanceId, "inst_1")
        XCTAssertEqual(event.dropId, "d1")
        XCTAssertEqual(event.channelId, "ch1")
    }

    // MARK: - Overview Projection

    func testOverviewProjectionHidesCampaignWithoutRealProgress() {
        let campaign = makeCampaignViewData(
            dropsClaimed: 0,
            totalDrops: 2,
            drops: [
                makeDropViewData(id: "d1", currentMinutes: 0, requiredMinutes: 60, progress: 0, isClaimed: false),
                makeDropViewData(id: "d2", currentMinutes: 0, requiredMinutes: 60, progress: 0, isClaimed: false)
            ]
        )

        XCTAssertFalse(campaign.hasValidProgress)
        XCTAssertFalse(campaign.isCompleted)
        XCTAssertFalse(campaign.isDisplayableInOverview)
        XCTAssertNil(campaign.overviewProgressFraction)
        XCTAssertEqual(campaign.overviewState, .available)
    }

    func testOverviewProjectionUsesBestRealDropProgressInsteadOfCampaignAverage() {
        let campaign = makeCampaignViewData(
            progress: 0.42,
            dropsClaimed: 0,
            totalDrops: 3,
            drops: [
                makeDropViewData(id: "d1", currentMinutes: 15, requiredMinutes: 60, progress: 0.25, isClaimed: false),
                makeDropViewData(id: "d2", currentMinutes: 45, requiredMinutes: 60, progress: 0.75, isClaimed: false),
                makeDropViewData(id: "d3", currentMinutes: 0, requiredMinutes: 60, progress: 0, isClaimed: false)
            ]
        )

        XCTAssertTrue(campaign.hasValidProgress)
        XCTAssertTrue(campaign.isDisplayableInOverview)
        XCTAssertEqual(campaign.overviewState, .inProgress)
        XCTAssertEqual(campaign.overviewProgressFraction ?? -1, 0.75, accuracy: 0.001)
    }

    func testOverviewProjectionTreatsClaimableAsDisplayableProgress() {
        let campaign = makeCampaignViewData(
            dropsClaimed: 0,
            totalDrops: 1,
            drops: [
                makeDropViewData(id: "d1", currentMinutes: 60, requiredMinutes: 60, progress: 1.0, isClaimed: false, isClaimable: true)
            ]
        )

        XCTAssertTrue(campaign.hasValidProgress)
        XCTAssertTrue(campaign.isDisplayableInOverview)
        XCTAssertEqual(campaign.overviewState, .claimable)
        XCTAssertEqual(campaign.overviewProgressFraction ?? -1, 1.0, accuracy: 0.001)
    }

    func testOverviewProjectionTreatsCompletedAsDisplayableWithoutProgress() {
        let campaign = makeCampaignViewData(
            dropsClaimed: 2,
            totalDrops: 2,
            drops: [
                makeDropViewData(id: "d1", currentMinutes: 60, requiredMinutes: 60, progress: 1.0, isClaimed: true),
                makeDropViewData(id: "d2", currentMinutes: 60, requiredMinutes: 60, progress: 1.0, isClaimed: true)
            ]
        )

        XCTAssertFalse(campaign.hasValidProgress)
        XCTAssertTrue(campaign.isCompleted)
        XCTAssertTrue(campaign.isDisplayableInOverview)
        XCTAssertNil(campaign.overviewProgressFraction)
        XCTAssertEqual(campaign.overviewState, .completed)
    }

    private func makeCampaignViewData(
        progress: Double = 0,
        dropsClaimed: Int,
        totalDrops: Int,
        drops: [DropViewData]
    ) -> CampaignViewData {
        CampaignViewData(
            id: "c1",
            gameName: "Test Game",
            campaignName: "Test Campaign",
            artworkURL: nil,
            progress: progress,
            isClaimed: dropsClaimed == totalDrops && totalDrops > 0,
            dropsClaimed: dropsClaimed,
            totalDrops: totalDrops,
            startDate: Date().addingTimeInterval(-3600),
            endDate: Date().addingTimeInterval(3600),
            drops: drops
        )
    }

    private func makeDropViewData(
        id: String,
        currentMinutes: Int,
        requiredMinutes: Int,
        progress: Double,
        isClaimed: Bool,
        isClaimable: Bool = false
    ) -> DropViewData {
        DropViewData(
            id: id,
            name: id,
            description: nil,
            imageURL: nil,
            rewardType: .inGame,
            requiredMinutes: requiredMinutes,
            currentMinutes: currentMinutes,
            progress: progress,
            isClaimed: isClaimed,
            isClaimable: isClaimable,
            isEarnable: !isClaimed && !isClaimable
        )
    }
}
