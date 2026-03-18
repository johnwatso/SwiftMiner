import XCTest
@testable import SwiftTwitchMiner

final class DropsServiceTests: XCTestCase {
    
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
    
    func testMergeInventoryClaimedStateUsesPrimaryBenefitIDOnly() async throws {
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
        XCTAssertFalse(updatedDrop.isClaimed, "Claimed state must use the primary benefitID only")
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
}
