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
        let mergedDrop = try XCTUnwrap(merged.drops.first)
        XCTAssertEqual(
            mergedDrop.claimedAccountIDs,
            [claimedAccountId],
            "A merged claimed reward must retain the account that supplied the inventory claim."
        )
        XCTAssertEqual(mergedDrop.accountStates?.count, 2)
        XCTAssertEqual(
            mergedDrop.accountStates?.first { $0.accountID == readyAccountId }?.isClaimed,
            false
        )
        XCTAssertFalse(merged.isClaimed, "A campaign is not fully claimed while any registered miner still has unclaimed obtainable drops.")
        XCTAssertFalse(merged.showsInClaimedTab)
        XCTAssertTrue(merged.showsInActiveTab)
    }

    func testCampaignDataServiceKeepsDecodedCampaignsInMemoryAfterFirstRead() async throws {
        let suffix = UUID().uuidString
        let accountId = "memory-cache-\(suffix)"
        accountIds = [accountId]
        let campaign = Campaign(
            id: "campaign-\(suffix)",
            name: "Memory Cache Campaign",
            game: Game(id: "game-\(suffix)", name: "Cache Test"),
            startDate: Date().addingTimeInterval(-3600),
            endDate: Date().addingTimeInterval(3600),
            drops: [],
            isAccountConnected: true
        )
        CampaignDiskCache.save(campaigns: [campaign], accountId: accountId)
        let service = await makeCampaignDataService(accountId: accountId)

        let firstRead = await service.allCampaigns().map(\.id)
        XCTAssertEqual(firstRead, [campaign.id])
        CampaignDiskCache.clear(accountId: accountId)

        let secondRead = await service.allCampaigns().map(\.id)
        XCTAssertEqual(
            secondRead,
            [campaign.id],
            "Repeated UI reads should use the decoded actor cache instead of reopening the campaign file."
        )
    }

    func testExternallyClaimedRewardRetainsMinerWhenRemainingRewardNeedsSubscription() async throws {
        let suffix = UUID().uuidString
        let accountId = "partial-\(suffix)"
        accountIds = [accountId]

        let claimedBenefitId = "claimed-benefit-\(suffix)"
        let subscriptionBenefitId = "subscription-benefit-\(suffix)"
        let campaign = Campaign(
            id: "campaign-\(suffix)",
            name: "Badge and Subscription Campaign",
            game: Game(id: "game-\(suffix)", name: "Attribution Test"),
            startDate: Date().addingTimeInterval(-3600),
            endDate: Date().addingTimeInterval(3600),
            drops: [
                Drop(
                    id: "claimed-drop-\(suffix)",
                    name: "Watch Badge",
                    requiredMinutes: 30,
                    benefitID: claimedBenefitId
                ),
                Drop(
                    id: "subscription-drop-\(suffix)",
                    name: "Subscriber Badge",
                    requiredMinutes: 0,
                    benefitID: subscriptionBenefitId,
                    requiredSubs: 1
                )
            ],
            isAccountConnected: false
        )

        CampaignDiskCache.save(campaigns: [campaign], accountId: accountId)
        InventoryDiskCache.save(
            InventorySnapshot(accountId: accountId, benefitIDs: [claimedBenefitId], progress: [])
        )

        let service = AggregatedCampaignDataService()
        await service.registerAccount(
            accountId: accountId,
            username: "External Claim Miner",
            service: await makeCampaignDataService(accountId: accountId)
        )

        let campaigns = await service.allCampaigns()
        let merged = try XCTUnwrap(campaigns.first { $0.id == campaign.id })
        let claimedDrop = try XCTUnwrap(merged.drops.first { $0.id == campaign.drops[0].id })
        let subscriptionDrop = try XCTUnwrap(merged.drops.first { $0.id == campaign.drops[1].id })

        XCTAssertTrue(claimedDrop.isClaimed)
        XCTAssertEqual(claimedDrop.claimedAccountIDs, [accountId])
        XCTAssertEqual(claimedDrop.accountStates?.first?.accountID, accountId)
        XCTAssertFalse(subscriptionDrop.isClaimed)
        XCTAssertTrue(subscriptionDrop.isSubscriptionRequired)
        XCTAssertEqual(merged.accountStates.first?.miningStatus, .blocked)
        XCTAssertFalse(merged.isClaimed)
    }

    private func makeCampaignDataService(accountId: String) async -> CampaignDataService {
        let authService = TwitchAuthService(clientId: "test_client", tokenStore: TestTokenStore())
        let apiClient = TwitchAPIClient(authService: authService, clientId: "test_client", session: .shared, persistsCampaignCaches: false)
        let inventoryService = InventoryService(apiClient: apiClient)
        await inventoryService.setAccountId(accountId)
        return CampaignDataService(apiClient: apiClient, inventoryService: inventoryService, accountId: accountId)
    }
}
