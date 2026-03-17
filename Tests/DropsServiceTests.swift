import XCTest
@testable import SwiftTwitchMiner

final class DropsServiceTests: XCTestCase {
    
    func testMergeInventoryClaimedFallback_BenefitIdMatch() async throws {
        // Given
        let authService = TwitchAuthService(clientId: "test")
        let apiClient = TwitchAPIClient(authService: authService, clientId: "test")
        let dropsService = DropsService(apiClient: apiClient)
        
        let campaignId = "c1"
        let dropId = "d1"
        let benefitId = "b1"
        
        let game = Game(id: "g1", name: "THE FINALS")
        let drop = Drop(
            id: dropId,
            name: "Drop 1",
            requiredMinutes: 60,
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
        
        // Claimed benefits by ID
        let claimedBenefit = TwitchAPIClient.ClaimedBenefit(id: benefitId, name: "Free Advice", lastAwardedAt: Date())
        let claimedBenefits = [benefitId: claimedBenefit]
        
        // When
        let enriched = await dropsService.mergeInventory([], into: [campaign], claimedBenefits: claimedBenefits)
        
        // Then
        let updatedDrop = enriched[0].drops[0]
        XCTAssertNotNil(updatedDrop.progress)
        XCTAssertTrue(updatedDrop.isClaimed, "Drop should be claimed via benefitId matching")
    }
    
    func testMergeInventoryClaimedFallback_NameMatch() async throws {
        // Given
        let authService = TwitchAuthService(clientId: "test")
        let apiClient = TwitchAPIClient(authService: authService, clientId: "test")
        let dropsService = DropsService(apiClient: apiClient)
        
        let campaignId = "c1"
        let dropId = "d1"
        let benefitId = "wrong_id"
        
        let game = Game(id: "g1", name: "THE FINALS")
        let reward = Reward(id: "r1", type: .inGame, name: "Free Advice", description: "")
        let drop = Drop(
            id: dropId,
            name: "Drop 1",
            requiredMinutes: 60,
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
        
        // Claimed benefits - ID mismatch, but NAME matches the REWARD name
        let claimedBenefit = TwitchAPIClient.ClaimedBenefit(id: "some_other_id", name: "Free Advice", lastAwardedAt: Date())
        let claimedBenefits = ["some_other_id": claimedBenefit]
        
        // When
        let enriched = await dropsService.mergeInventory([], into: [campaign], claimedBenefits: claimedBenefits)
        
        // Then
        let updatedDrop = enriched[0].drops[0]
        XCTAssertNotNil(updatedDrop.progress)
        XCTAssertTrue(updatedDrop.isClaimed, "Drop should be claimed via reward/benefit name matching")
    }

    func testMergeInventoryClaimedFallback_NoMatch() async throws {
        // Given
        let authService = TwitchAuthService(clientId: "test")
        let apiClient = TwitchAPIClient(authService: authService, clientId: "test")
        let dropsService = DropsService(apiClient: apiClient)
        
        let campaignId = "c1"
        let dropId = "d1"
        
        let game = Game(id: "g1", name: "THE FINALS")
        let reward = Reward(id: "r1", type: .inGame, name: "Actual Reward Name", description: "")
        let drop = Drop(
            id: dropId,
            name: "Drop Title",
            requiredMinutes: 60,
            reward: reward,
            benefitIds: ["b1"]
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
        
        // No matches for ID or Reward Name
        let claimedBenefit = TwitchAPIClient.ClaimedBenefit(id: "b2", name: "Different Reward", lastAwardedAt: Date())
        let claimedBenefits = ["b2": claimedBenefit]
        
        // When
        let enriched = await dropsService.mergeInventory([], into: [campaign], claimedBenefits: claimedBenefits)
        
        // Then
        let updatedDrop = enriched[0].drops[0]
        XCTAssertNil(updatedDrop.progress)
        XCTAssertFalse(updatedDrop.isClaimed, "Drop should NOT be claimed")
    }
}
