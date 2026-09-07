import XCTest
@testable import SwiftMinerCore

final class DropsServiceTests: XCTestCase {

    func testDropStateDeduplicationKeepsTheMostCompleteStateAndOriginalOrder() {
        let older = Date().addingTimeInterval(-60)
        let states = [
            DropState(
                dropId: "duplicate",
                accountId: "account",
                progressMinutes: 45,
                requiredMinutes: 60,
                isClaimed: false,
                lastUpdated: older
            ),
            DropState(
                dropId: "other",
                accountId: "account",
                progressMinutes: 10,
                requiredMinutes: 30,
                isClaimed: false
            ),
            DropState(
                dropId: "duplicate",
                accountId: "account",
                progressMinutes: 0,
                requiredMinutes: 60,
                isClaimed: true
            )
        ]

        let deduplicated = DropState.deduplicatedByDropID(states)

        XCTAssertEqual(deduplicated.map(\.dropId), ["duplicate", "other"])
        XCTAssertTrue(deduplicated[0].isClaimed)
    }

    func testMergeInventoryCoalescesDuplicateProgressRecords() {
        let drop = Drop(id: "drop", name: "Drop", requiredMinutes: 60, benefitID: "benefit")
        let campaign = Campaign(
            id: "campaign",
            name: "Campaign",
            game: Game(id: "game", name: "Game"),
            status: .active,
            startDate: Date().addingTimeInterval(-60),
            endDate: Date().addingTimeInterval(3600),
            drops: [drop]
        )
        let snapshot = InventorySnapshot(
            accountId: "account",
            benefitIDs: [],
            progress: [
                Progress(id: "first", dropId: "drop", dropName: "Drop", campaignId: "campaign", currentMinutes: 15, requiredMinutes: 60),
                Progress(id: "second", dropId: "drop", dropName: "Drop", campaignId: "campaign", currentMinutes: 45, requiredMinutes: 60)
            ]
        )

        let merged = DropsService.mergeInventory(snapshot, into: [campaign])

        XCTAssertEqual(merged[0].drops[0].progress?.currentMinutes, 45)
    }
    
    func testMergeInventoryClaimedFallback_BenefitIdMatch() async throws {
        let campaignId = "c1"
        let dropId = "d1"
        let benefitId = "b1"
        
        let game = Game(id: "g1", name: "THE FINALS")
        let drop = Drop(
            id: dropId,
            name: "Drop 1",
            requiredMinutes: 60,
            benefitID: benefitId,
            benefitIds: [benefitId]
        )
        
        let campaign = Campaign(
            id: campaignId,
            name: "THE FINALS Release Drops",
            game: game,
            status: .active,
            startDate: Date(),
            endDate: Date(),
            drops: [drop]
        )
        
        let snapshot = InventorySnapshot(
            accountId: "acc1",
            benefitIDs: [benefitId],
            progress: []
        )
        
        let enriched = DropsService.mergeInventory(snapshot, into: [campaign])
        
        // Then
        let updatedDrop = enriched[0].drops[0]
        XCTAssertNotNil(updatedDrop.progress)
        XCTAssertTrue(updatedDrop.isClaimed, "Drop should be claimed via benefitId matching")
    }
    
    func testMergeInventoryClaimedStateUsesAnyKnownBenefitID() async throws {
        let campaignId = "c1"
        let dropId = "d1"
        let primaryBenefitId = "primary_benefit"
        let secondaryBenefitId = "secondary_benefit"
        
        let game = Game(id: "g1", name: "THE FINALS")
        let reward = Reward(id: "r1", type: .inGame, name: "Free Advice", description: "")
        let drop = Drop(
            id: dropId,
            name: "Drop 1",
            requiredMinutes: 60,
            benefitID: primaryBenefitId,
            reward: reward,
            benefitIds: [primaryBenefitId, secondaryBenefitId]
        )
        
        let campaign = Campaign(
            id: campaignId,
            name: "THE FINALS Release Drops",
            game: game,
            status: .active,
            startDate: Date(),
            endDate: Date(),
            drops: [drop]
        )
        
        let snapshot = InventorySnapshot(
            accountId: "acc1",
            benefitIDs: [secondaryBenefitId],
            progress: []
        )

        let enriched = DropsService.mergeInventory(snapshot, into: [campaign])
        
        let updatedDrop = enriched[0].drops[0]
        XCTAssertTrue(updatedDrop.isClaimed, "Claimed state should match any benefit ID attached to the drop")
        XCTAssertEqual(updatedDrop.progress?.currentMinutes, 60)
    }

    func testMergeInventoryClaimedFallback_NoMatch() async throws {
        let campaignId = "c1"
        let dropId = "d1"
        let benefitId = "b1"
        
        let game = Game(id: "g1", name: "THE FINALS")
        let reward = Reward(id: "r1", type: .inGame, name: "Actual Reward Name", description: "")
        let drop = Drop(
            id: dropId,
            name: "Drop Title",
            requiredMinutes: 60,
            benefitID: benefitId,
            reward: reward,
            benefitIds: [benefitId]
        )
        
        let campaign = Campaign(
            id: campaignId,
            name: "THE FINALS Release Drops",
            game: game,
            status: .active,
            startDate: Date(),
            endDate: Date(),
            drops: [drop]
        )
        
        let snapshot = InventorySnapshot(
            accountId: "acc1",
            benefitIDs: ["b2"],
            progress: []
        )

        let enriched = DropsService.mergeInventory(snapshot, into: [campaign])
        
        // Then
        let updatedDrop = enriched[0].drops[0]
        XCTAssertNil(updatedDrop.progress)
        XCTAssertFalse(updatedDrop.isClaimed, "Drop should NOT be claimed")
    }

    /// A real external claim — made in the Twitch UI or on another device — is the merge
    /// changing its mind about a drop, and stall recovery must see it so it does not switch
    /// away from a campaign that is still earning.
    func testExternalClaimIsDetectedAsTheMergeSettlingADropClaimed() {
        let newlyClaimed = Drop(
            id: "new",
            name: "Newly claimed",
            requiredMinutes: 30,
            benefitID: "primary",
            benefitIds: ["primary", "secondary"]
        )
        var alreadyClaimed = Drop(
            id: "old",
            name: "Already claimed",
            requiredMinutes: 30,
            benefitID: "old-benefit"
        )
        alreadyClaimed.isClaimed = true
        let campaign = Campaign(
            id: "campaign",
            name: "Campaign",
            game: Game(id: "game", name: "Game"),
            status: .active,
            startDate: Date().addingTimeInterval(-60),
            endDate: Date().addingTimeInterval(3600),
            drops: [newlyClaimed, alreadyClaimed]
        )
        let snapshot = InventorySnapshot(
            accountId: "account",
            benefitIDs: ["secondary", "old-benefit"],
            progress: []
        )

        let unclaimedBefore = Set(campaign.drops.filter { !$0.isClaimed }.map(\.id))
        let merged = DropsService.mergeInventory(snapshot, into: [campaign])
        let detected = MinerEngine.newlyClaimedDrops(
            in: merged[0].drops,
            unclaimedBeforeMerge: unclaimedBefore
        )
        XCTAssertEqual(detected.map(\.id), ["new"])

        // Idempotent: a second window over the same already-merged state finds nothing new.
        let afterMerge = Set(merged[0].drops.filter { !$0.isClaimed }.map(\.id))
        let again = DropsService.mergeInventory(snapshot, into: merged)
        XCTAssertTrue(
            MinerEngine.newlyClaimedDrops(in: again[0].drops, unclaimedBeforeMerge: afterMerge).isEmpty
        )
    }

    /// Regression: Rainbow Six offers "Esports Pack" at 60, 180 and 360 minutes on one shared
    /// benefit ID. Claiming the 60 puts that ID in inventory while the 360 is still being earned.
    /// Testing the raw benefit IDs called the 360 externally claimed, and because `mergeInventory`
    /// correctly refuses to mark it claimed, the phantom recurred every 15-minute stall window and
    /// reset the counter forever — anti-stall recovery could never run, and miners logged hours of
    /// watching with nothing credited. The unclaimed tier must read as a stall, not a claim.
    func testSharedBenefitAcrossTiersIsNotReportedAsAnExternalClaim() {
        var claimedTier = Drop(
            id: "tier-60",
            name: "Esports Pack",
            requiredMinutes: 60,
            benefitID: "esports-pack",
            benefitIds: ["esports-pack"]
        )
        claimedTier.isClaimed = true
        let earningTier = Drop(
            id: "tier-360",
            name: "Esports Pack",
            requiredMinutes: 360,
            benefitID: "esports-pack",
            benefitIds: ["esports-pack"]
        )
        let campaign = Campaign(
            id: "r6s",
            name: "R6S S2 2026 1",
            game: Game(id: "rainbow6", name: "Rainbow Six Siege"),
            status: .active,
            startDate: Date().addingTimeInterval(-3600),
            endDate: Date().addingTimeInterval(3600),
            drops: [claimedTier, earningTier]
        )
        let snapshot = InventorySnapshot(
            accountId: "account",
            benefitIDs: ["esports-pack"],
            progress: [
                Progress(
                    id: "p-360",
                    dropId: "tier-360",
                    dropName: "Esports Pack",
                    campaignId: "r6s",
                    currentMinutes: 295,
                    requiredMinutes: 360,
                    isClaimed: false
                )
            ]
        )

        let unclaimedBefore = Set(campaign.drops.filter { !$0.isClaimed }.map(\.id))
        let merged = DropsService.mergeInventory(snapshot, into: [campaign])

        XCTAssertFalse(
            merged[0].drops.first { $0.id == "tier-360" }?.isClaimed ?? true,
            "an unclaimed tier sharing a benefit ID must not be marked claimed"
        )
        XCTAssertTrue(
            MinerEngine.newlyClaimedDrops(in: merged[0].drops, unclaimedBeforeMerge: unclaimedBefore).isEmpty,
            "a shared benefit ID must not read as an external claim, or stall recovery never runs"
        )
    }
}
