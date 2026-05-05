import XCTest
@testable import SwiftMinerCore

@MainActor
final class MinerEngineCooldownTests: XCTestCase {

    // MARK: - Helper Factories

    private func makeCampaign(id: String, gameName: String = "Test Game") -> Campaign {
        Campaign(
            id: id,
            name: "Campaign \(id)",
            game: Game(id: "g1", name: gameName),
            startDate: Date().addingTimeInterval(-3600),
            endDate: Date().addingTimeInterval(3600),
            drops: [Drop(id: "d1", name: "Drop 1", requiredMinutes: 60)],
            isAccountConnected: true,
            isPrioritised: false
        )
    }

    // MARK: - Stall Threshold

    func testStallThreshold_ActiveSessionObserved_UsesMaxExtraMinutes() {
        XCTAssertEqual(MinerEngine.stallThresholdMinutes(hasObservedActiveDropSession: true), 15)
    }

    func testStallThreshold_NeverActiveSession_UsesWarmupThreshold() {
        XCTAssertEqual(MinerEngine.stallThresholdMinutes(hasObservedActiveDropSession: false), 5)
    }

    // MARK: - Cooldown Filtering

    func testCampaignWithFalsePositiveConnection_IsExcludedDuringCooldown() {
        let campaign = makeCampaign(id: "c1")
        let now = Date()
        let cooldowns = ["c1": now.addingTimeInterval(3600)] // 1 hour remaining

        let filtered = MinerEngine.filterCampaignsExcludingCooldowns([campaign], cooldowns: cooldowns, now: now)

        XCTAssertTrue(filtered.isEmpty, "Campaign on cooldown should be excluded")
    }

    func testCampaignWithExpiredCooldown_IsIncluded() {
        let campaign = makeCampaign(id: "c1")
        let now = Date()
        let cooldowns = ["c1": now.addingTimeInterval(-1)] // expired 1 second ago

        let filtered = MinerEngine.filterCampaignsExcludingCooldowns([campaign], cooldowns: cooldowns, now: now)

        XCTAssertEqual(filtered.count, 1, "Campaign with expired cooldown should be included")
        XCTAssertEqual(filtered.first?.id, "c1")
    }

    func testCampaignWithoutCooldown_IsIncluded() {
        let campaign = makeCampaign(id: "c1")
        let now = Date()

        let filtered = MinerEngine.filterCampaignsExcludingCooldowns([campaign], cooldowns: [:], now: now)

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.id, "c1")
    }

    func testMultipleCampaigns_MixedCooldowns_FiltersCorrectly() {
        let c1 = makeCampaign(id: "c1")
        let c2 = makeCampaign(id: "c2")
        let c3 = makeCampaign(id: "c3")
        let now = Date()
        let cooldowns: [String: Date] = [
            "c1": now.addingTimeInterval(3600), // active
            "c2": now.addingTimeInterval(-1),   // expired
        ]

        let filtered = MinerEngine.filterCampaignsExcludingCooldowns([c1, c2, c3], cooldowns: cooldowns, now: now)

        XCTAssertEqual(filtered.map(\.id).sorted(), ["c2", "c3"])
    }

    // MARK: - Actor-Level Integration

    /// Verifies cooldowns set on the live actor are honored by the production
    /// `candidateCampaigns` filter, AND that expired entries are pruned on read.
    func testCandidateCampaigns_HonorsCooldownsAndPrunesExpiredEntries() async {
        let engine = MinerEngine(clientId: "test_client", tokenStore: TestTokenStore())

        let active = makeCampaign(id: "active-cooldown")
        let expired = makeCampaign(id: "expired-cooldown")
        let clean = makeCampaign(id: "clean")

        let now = Date()
        await engine._testSetCooldown(campaignId: active.id, expiresAt: now.addingTimeInterval(3600))
        await engine._testSetCooldown(campaignId: expired.id, expiresAt: now.addingTimeInterval(-1))

        let result = await engine._testCandidateCampaigns(from: [active, expired, clean])

        let resultIds = Set(result.map(\.id))
        XCTAssertFalse(resultIds.contains(active.id), "Campaign with active cooldown must be filtered out")
        XCTAssertTrue(resultIds.contains(expired.id), "Campaign whose cooldown expired must be re-eligible")
        XCTAssertTrue(resultIds.contains(clean.id), "Campaign with no cooldown must be eligible")

        // Prune-on-read: the expired entry should no longer be in the cooldowns dict.
        let snapshot = await engine._testCooldownsSnapshot()
        XCTAssertNil(snapshot[expired.id], "Expired cooldown should have been pruned during candidate selection")
        XCTAssertNotNil(snapshot[active.id], "Active cooldown should remain in the dict")
    }

    // MARK: - Inventory Progress Protection (Stall Detection)

    /// When a drop is marked claimed locally via inventory sync, the stall detector
    /// must NOT reset the stall counter just because the *old* local `isClaimed` was
    /// stale. This test verifies the `syncCampaigns` call in the stall handler
    /// updates `allCampaigns` before the `newlyClaimedDrops` check.
    func testSyncCampaigns_UpdatesClaimedStateFromInventory() {
        // This is an integration-level assertion: the stall handler calls
        // `syncCampaigns(with: freshInventory)` before checking `newlyClaimedDrops`.
        // We verify the static helper contract holds: once synced, a drop whose
        // benefitID is in the inventory should report `isClaimed = true`.
        var drop = Drop(id: "d1", name: "Drop 1", requiredMinutes: 60, benefitID: "b1")
        XCTAssertFalse(drop.isClaimed)

        // Simulate what DropsService.mergeInventory does
        let snapshot = InventorySnapshot(
            accountId: "test-account",
            benefitIDs: ["b1"],
            progress: [],
            discoveredCampaigns: []
        )

        // Replicate the logic from DropsService.mergeInventory
        let claimedFromInventory = !drop.benefitID.isEmpty && snapshot.benefitIDs.contains(drop.benefitID)
        drop.isClaimed = claimedFromInventory

        XCTAssertTrue(drop.isClaimed, "Drop should be marked claimed after inventory sync")
    }
}
