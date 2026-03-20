import XCTest
@testable import SwiftTwitchMiner

/// Regression test suite for campaign tab routing (Active, Claimed, All).
/// This verifies the "Target Contract" agreed upon during Phase 1.
final class CampaignTabRoutingTests: XCTestCase {

    let now = Date()
    var game: Game!

    override func setUp() {
        super.setUp()
        game = Game(id: "g1", name: "Test Game")
    }

    // MARK: - Test Scenarios

    func test_Prioritised_Campaign_Routing() {
        let campaign = createCampaign(relevance: .prioritised)
        
        XCTAssertTrue(campaign.showsInActiveTab, "Prioritised should show in Active tab")
        XCTAssertFalse(campaign.showsInClaimedTab, "Prioritised should NOT show in Claimed tab")
        XCTAssertTrue(campaign.showsInAllTab, "Should show in All tab")
    }

    func test_Active_Campaign_Routing() {
        let campaign = createCampaign(relevance: .active, miningStatus: .inProgress)
        
        XCTAssertTrue(campaign.showsInActiveTab, "Active should show in Active tab")
        XCTAssertFalse(campaign.showsInClaimedTab, "Active should NOT show in Claimed tab")
        XCTAssertTrue(campaign.showsInAllTab, "Should show in All tab")
    }

    func test_ExpiredUnclaimed_Campaign_Routing() {
        // This scenario covers "The Finals" bug (expired but drops still eligible)
        let campaign = createCampaign(relevance: .active, status: "EXPIRED", isClaimed: false)
        
        XCTAssertTrue(campaign.showsInActiveTab, "Expired+Unclaimed should show in Active tab")
        XCTAssertFalse(campaign.showsInClaimedTab, "Expired+Unclaimed should NOT show in Claimed tab")
        XCTAssertTrue(campaign.showsInAllTab, "Should show in All tab")
    }

    func test_ExpiredClaimed_Campaign_Routing() {
        // This scenario covers John's requirement: expired+claimed should be in Claimed tab
        let campaign = createCampaign(relevance: .closed, status: "EXPIRED", isClaimed: true)
        
        XCTAssertFalse(campaign.showsInActiveTab, "Expired+Claimed should NOT show in Active tab")
        XCTAssertTrue(campaign.showsInClaimedTab, "Expired+Claimed should show in Claimed tab")
        XCTAssertTrue(campaign.showsInAllTab, "Should show in All tab")
    }

    func test_ActiveClaimed_Campaign_Routing() {
        // Recently claimed but campaign window still open
        let campaign = createCampaign(relevance: .recent, status: "ACTIVE", isClaimed: true)
        
        XCTAssertFalse(campaign.showsInActiveTab, "Active+Claimed should NOT show in Active tab")
        XCTAssertTrue(campaign.showsInClaimedTab, "Active+Claimed should show in Claimed tab")
        XCTAssertTrue(campaign.showsInAllTab, "Should show in All tab")
    }

    func test_Irrelevant_Campaign_Routing() {
        // Completely finished/irrelevant (e.g. old unclaimed expired)
        let campaign = createCampaign(relevance: .irrelevant)
        
        XCTAssertFalse(campaign.showsInActiveTab, "Irrelevant should NOT show in Active tab")
        XCTAssertFalse(campaign.showsInClaimedTab, "Irrelevant should NOT show in Claimed tab")
        XCTAssertTrue(campaign.showsInAllTab, "Should always show in All tab")
    }

    func test_ClaimedAccountState_Campaign_RoutesToClaimedTab() {
        let campaign = CampaignViewData(
            id: "test",
            gameName: "Test Game",
            campaignName: "Test Campaign",
            artworkURL: nil,
            progress: 0.5,
            isClaimed: false,
            dropsClaimed: 0,
            totalDrops: 1,
            status: "ACTIVE",
            miningStatus: .available,
            relevance: .active,
            startDate: now.addingTimeInterval(-3600),
            endDate: now.addingTimeInterval(3600),
            accountStates: [
                AccountState(
                    accountId: "a1",
                    username: "miner",
                    initials: "M",
                    miningStatus: .claimed
                )
            ]
        )

        XCTAssertTrue(campaign.showsInActiveTab, "Active relevance should keep the campaign in Active")
        XCTAssertTrue(campaign.showsInClaimedTab, "Claimed account state should surface the campaign in Claimed")
    }

    func test_AccountState_MiningStatus_Logic() {
        let mining = AccountState(accountId: "1", username: "U1", initials: "U1", miningStatus: .mining)
        let claimed = AccountState(accountId: "2", username: "U2", initials: "U2", miningStatus: .claimed)
        let needsAuth = AccountState(accountId: "3", username: "U3", initials: "U3", miningStatus: .needsAuth)
        let idle = AccountState(accountId: "4", username: "U4", initials: "U4", miningStatus: .idle)
        
        XCTAssertEqual(mining.miningStatus, .mining)
        XCTAssertEqual(claimed.miningStatus, .claimed)
        XCTAssertEqual(needsAuth.miningStatus, .needsAuth)
        XCTAssertEqual(idle.miningStatus, .idle)
    }

    @MainActor
    func test_RequiresManualReauth_ReturnsTrueForAuthenticationFailure() {
        XCTAssertTrue(
            MinerManager.requiresManualReauth(
                for: TwitchMinerError.authenticationFailed("No valid credentials")
            )
        )
    }

    @MainActor
    func test_RequiresManualReauth_ReturnsTrueForExpiredToken() {
        XCTAssertTrue(MinerManager.requiresManualReauth(for: TwitchMinerError.tokenExpired))
    }

    @MainActor
    func test_RequiresManualReauth_ReturnsFalseForNonAuthError() {
        XCTAssertFalse(
            MinerManager.requiresManualReauth(
                for: TwitchMinerError.networkError("offline")
            )
        )
    }

    // MARK: - Helpers

    private func createCampaign(
        relevance: CampaignRelevance,
        status: String = "ACTIVE",
        miningStatus: MiningCampaignStatus = .available,
        isClaimed: Bool = false
    ) -> CampaignViewData {
        return CampaignViewData(
            id: "test",
            gameName: "Test Game",
            campaignName: "Test Campaign",
            artworkURL: nil,
            progress: isClaimed ? 1.0 : 0.5,
            isClaimed: isClaimed,
            dropsClaimed: isClaimed ? 1 : 0,
            totalDrops: 1,
            status: status,
            miningStatus: miningStatus,
            relevance: relevance,
            startDate: now.addingTimeInterval(-3600),
            endDate: now.addingTimeInterval(3600)
        )
    }
}
