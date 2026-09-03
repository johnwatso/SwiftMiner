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

    func testExternalClaimDetectionUsesAllBenefitIDsAndIsIdempotentAfterMerge() {
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
        let snapshot = InventorySnapshot(
            accountId: "account",
            benefitIDs: ["secondary", "old-benefit"],
            progress: []
        )

        let detected = MinerEngine.externallyClaimedDrops(
            in: [newlyClaimed, alreadyClaimed],
            snapshot: snapshot
        )
        XCTAssertEqual(detected.map(\.id), ["new"])

        let campaign = Campaign(
            id: "campaign",
            name: "Campaign",
            game: Game(id: "game", name: "Game"),
            status: .active,
            startDate: Date().addingTimeInterval(-60),
            endDate: Date().addingTimeInterval(3600),
            drops: [newlyClaimed, alreadyClaimed]
        )
        let merged = DropsService.mergeInventory(snapshot, into: [campaign])
        XCTAssertTrue(MinerEngine.externallyClaimedDrops(in: merged[0].drops, snapshot: snapshot).isEmpty)
    }
}
