import XCTest
@testable import SwiftMinerCore

final class AggregatedCampaignDataServiceTests: XCTestCase {
    private var accountIds: [String] = []

    override func tearDown() async throws {
        for accountId in accountIds {
            CampaignDiskCache.clear(accountId: accountId)
            InventoryDiskCache.clear(accountId: accountId)
        }
        accountIds.removeAll()
        try await super.tearDown()
    }

    func testUnifiedCampaignAccountStatesRemainAccountSpecificWhenOneMinerClaimed() async throws {
        let suffix = UUID().uuidString
        let claimedAccountId = "claimed-\(suffix)"
        let readyAccountId = "ready-\(suffix)"
        accountIds = [claimedAccountId, readyAccountId]

        let benefitId = "benefit-\(suffix)"
        let campaignId = "campaign-\(suffix)"
        let campaign = Campaign(
            id: campaignId,
            name: "Shared Campaign",
            game: Game(id: "game-\(suffix)", name: "Everyminer Test"),
            startDate: Date().addingTimeInterval(-3600),
            endDate: Date().addingTimeInterval(3600),
            drops: [
                Drop(
                    id: "drop-\(suffix)",
                    name: "Shared Drop",
                    requiredMinutes: 60,
                    benefitID: benefitId
                )
            ],
            isAccountConnected: true
        )

        CampaignDiskCache.save(campaigns: [campaign], accountId: claimedAccountId)
        CampaignDiskCache.save(campaigns: [campaign], accountId: readyAccountId)
        InventoryDiskCache.save(InventorySnapshot(accountId: claimedAccountId, benefitIDs: [benefitId], progress: []))
        InventoryDiskCache.save(InventorySnapshot(accountId: readyAccountId, benefitIDs: [], progress: []))

        let service = AggregatedCampaignDataService()
        await service.registerAccount(
            accountId: claimedAccountId,
            username: "Claimed Miner",
            service: await makeCampaignDataService(accountId: claimedAccountId)
        )
        await service.registerAccount(
            accountId: readyAccountId,
            username: "Ready Miner",
            service: await makeCampaignDataService(accountId: readyAccountId)
        )

        let campaigns = await service.allCampaigns()
        let merged = try XCTUnwrap(campaigns.first { $0.id == campaignId })
        let statesByAccount = Dictionary(uniqueKeysWithValues: merged.accountStates.map { ($0.accountId, $0.miningStatus) })

        XCTAssertEqual(statesByAccount[claimedAccountId], .claimed)
        XCTAssertEqual(statesByAccount[readyAccountId], .ready)
        XCTAssertFalse(merged.isClaimed, "A campaign is not fully claimed while any registered miner still has unclaimed obtainable drops.")
        XCTAssertFalse(merged.showsInClaimedTab)
        XCTAssertTrue(merged.showsInActiveTab)
    }

    private func makeCampaignDataService(accountId: String) async -> CampaignDataService {
        let authService = TwitchAuthService(clientId: "test_client", tokenStore: TestTokenStore())
        let apiClient = TwitchAPIClient(authService: authService, clientId: "test_client", session: .shared, persistsCampaignCaches: false)
        let inventoryService = InventoryService(apiClient: apiClient)
        await inventoryService.setAccountId(accountId)
        return CampaignDataService(apiClient: apiClient, inventoryService: inventoryService, accountId: accountId)
    }
}
