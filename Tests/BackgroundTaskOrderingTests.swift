import XCTest
@testable import SwiftMinerCore

/// Covers the places where a detached `Task` used to decide, by luck, what order two pieces of
/// state changed in.
///
/// The pattern was always the same: a synchronous method mutated its own state immediately and
/// fired the matching cross-actor hop into an unstructured task. The two halves then landed in
/// whatever order the scheduler chose, so a teardown could overtake the setup it was undoing and
/// a cache clear could be outrun by the very fetch it was supposed to invalidate.
final class BackgroundTaskOrderingTests: XCTestCase {
    private var accountIds: [String] = []

    override func tearDown() async throws {
        for accountId in accountIds {
            CampaignDiskCache.clear(accountId: accountId)
            InventoryDiskCache.clear(accountId: accountId)
        }
        accountIds.removeAll()
        try await super.tearDown()
    }

    @MainActor
    func testRemovingAMinerCannotOvertakeTheRegistrationItUndoes() async throws {
        let suffix = UUID().uuidString
        let keptAccountId = "kept-\(suffix)"
        let removedAccountId = "removed-\(suffix)"
        accountIds = [keptAccountId, removedAccountId]

        CampaignDiskCache.save(campaigns: [makeCampaign(named: "Kept", suffix: "kept-\(suffix)")], accountId: keptAccountId)
        CampaignDiskCache.save(campaigns: [makeCampaign(named: "Removed", suffix: "gone-\(suffix)")], accountId: removedAccountId)

        let coordinator = MiningDataCoordinator(campaignStore: CampaignStore())

        try await register(removedAccountId, as: "removed-miner", with: coordinator)
        try await register(keptAccountId, as: "kept-miner", with: coordinator)
        coordinator.unregisterMiner(minerId: "removed-miner", accountId: removedAccountId)

        await coordinator.drainPendingCoordination()

        let names = Set(await coordinator.allCampaigns().map(\.campaignName))
        XCTAssertTrue(names.contains("Kept"))
        XCTAssertFalse(
            names.contains("Removed"),
            "A removal issued after a registration has to land after it, or the account stays wired into aggregation for the rest of the session."
        )
    }

    // MARK: - Helpers

    @MainActor
    private func register(
        _ accountId: String,
        as minerId: String,
        with coordinator: MiningDataCoordinator
    ) async throws {
        let authService = TwitchAuthService(clientId: "test_client", tokenStore: TestTokenStore())
        let apiClient = TwitchAPIClient(
            authService: authService,
            clientId: "test_client",
            session: .shared,
            persistsCampaignCaches: false
        )
        let inventoryService = InventoryService(apiClient: apiClient)
        await inventoryService.setAccountId(accountId)

        coordinator.registerMiner(
            minerId: minerId,
            accountId: accountId,
            username: minerId,
            apiClient: apiClient,
            inventoryService: inventoryService,
            engine: MinerEngine(clientId: "test_client")
        )
    }

    private func makeCampaign(named name: String, suffix: String) -> Campaign {
        Campaign(
            id: "campaign-\(suffix)",
            name: name,
            game: Game(id: "game-\(suffix)", name: "Everyminer Test"),
            startDate: Date().addingTimeInterval(-3600),
            endDate: Date().addingTimeInterval(3600),
            drops: [
                Drop(
                    id: "drop-\(suffix)",
                    name: "\(name) Drop",
                    requiredMinutes: 60,
                    benefitID: "benefit-\(suffix)"
                )
            ],
            isAccountConnected: true
        )
    }
}
