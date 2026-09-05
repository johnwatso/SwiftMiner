import XCTest
@testable import SwiftMinerCore

@MainActor
final class MinerStatePublicationTests: XCTestCase {
    private func makeManager() -> MinerManager {
        let manager = MinerManager(clientId: "test", tokenStore: InMemoryTokenStore())
        manager.miners = [.init(
            id: "miner", accountId: "account", username: "tester",
            status: .watching, currentCampaign: "Campaign", currentCampaignId: "campaign",
            isRunning: true, priorityGames: ["Game"]
        )]
        return manager
    }

    func testRepeatedEngineStateDoesNotNotifyConsumersOrResetStatusAge() {
        let manager = makeManager()
        let statusChangedAt = manager.miners[0].statusChangedAt
        let notifications = PublicationCounter()
        manager.onMinersChanged = { notifications.increment() }

        for _ in 0..<100 {
            manager.updateMinerStatus(
                minerId: "miner", status: .watching, currentCampaign: "Campaign",
                currentCampaignId: .some("campaign"), allCampaigns: [],
                isRunning: true, priorityGames: ["Game"], needsAuth: false
            )
        }

        XCTAssertEqual(notifications.value, 0)
        XCTAssertEqual(manager.miners[0].statusChangedAt, statusChangedAt)
    }

    func testActualStatusAndAuthenticationChangesStillNotify() {
        let manager = makeManager()
        let notifications = PublicationCounter()
        manager.onMinersChanged = { notifications.increment() }

        manager.updateMinerStatus(minerId: "miner", status: .authenticating, needsAuth: true)
        XCTAssertEqual(notifications.value, 1)
        XCTAssertEqual(manager.miners[0].status, .authenticating)
        XCTAssertTrue(manager.miners[0].needsAuth)

        manager.updateMinerStatus(minerId: "miner", status: .watching, needsAuth: false)
        XCTAssertEqual(notifications.value, 2)
        XCTAssertFalse(manager.miners[0].needsAuth)
    }

    func testClearingCampaignPublishesOnceAndClearsItsName() {
        let manager = makeManager()
        let notifications = PublicationCounter()
        manager.onMinersChanged = { notifications.increment() }

        manager.updateMinerStatus(minerId: "miner", currentCampaignId: .some(nil))
        manager.updateMinerStatus(minerId: "miner", currentCampaignId: .some(nil))

        XCTAssertEqual(notifications.value, 1)
        XCTAssertNil(manager.miners[0].currentCampaignId)
        XCTAssertNil(manager.miners[0].currentCampaign)
    }

    func testFirstLiveSnapshotPublishesEvenWhenItMatchesProvisionalCampaigns() {
        let manager = makeManager()
        manager.miners[0].campaignsAreProvisional = true
        let notifications = PublicationCounter()
        manager.onMinersChanged = { notifications.increment() }

        manager.updateMinerStatus(minerId: "miner", allCampaigns: [])
        manager.updateMinerStatus(minerId: "miner", allCampaigns: [])

        XCTAssertEqual(notifications.value, 1)
        XCTAssertFalse(manager.miners[0].campaignsAreProvisional)
    }

    func testClaimStateChangePublishesEvenWithTheSameCampaignAndDropIDs() {
        let manager = makeManager()
        var campaign = Campaign(
            id: "campaign", name: "Campaign", game: Game(id: "game", name: "Game"),
            startDate: Date().addingTimeInterval(-3600), endDate: Date().addingTimeInterval(3600),
            drops: [Drop(id: "tier", name: "Pack", requiredMinutes: 60)]
        )
        manager.miners[0].allCampaigns = [campaign]
        let notifications = PublicationCounter()
        manager.onMinersChanged = { notifications.increment() }

        campaign.drops[0].isClaimed = true
        manager.updateMinerStatus(minerId: "miner", allCampaigns: [campaign])
        manager.updateMinerStatus(minerId: "miner", allCampaigns: [campaign])

        XCTAssertEqual(notifications.value, 1)
        XCTAssertTrue(manager.miners[0].allCampaigns[0].drops[0].isClaimed)
    }
}

private final class PublicationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
