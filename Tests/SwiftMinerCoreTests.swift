import XCTest
@testable import SwiftMinerCore

final class SwiftMinerCoreTests: XCTestCase {

    // MARK: - Campaign time window

    func testCampaignTimeActive() {
        let now = Date()
        let game = Game(id: "g1", name: "Test Game")
        let campaign = Campaign(
            id: "c1", name: "Test Campaign", game: game, status: .active,
            startDate: now.addingTimeInterval(-3600),
            endDate: now.addingTimeInterval(3600)
        )
        XCTAssertTrue(campaign.isTimeActive)
    }

    func testCampaignNotActiveYet() {
        let now = Date()
        let game = Game(id: "g1", name: "Test Game")
        let campaign = Campaign(
            id: "c1", name: "Test Campaign", game: game, status: .upcoming,
            startDate: now.addingTimeInterval(3600),
            endDate: now.addingTimeInterval(7200)
        )
        XCTAssertFalse(campaign.isTimeActive)
    }

    // MARK: - Drop progress

    func testDropProgressViaProgress() {
        let progress = Progress(
            dropId: "d1", campaignId: "c1",
            currentMinutes: 0, requiredMinutes: 60, isClaimed: false
        )
        let drop = Drop(id: "d1", name: "Test Drop", requiredMinutes: 60, progress: progress)
        XCTAssertFalse(drop.isClaimed)
        XCTAssertFalse(drop.isClaimable)
    }

    // MARK: - Account token validity

    func testAccountTokenValidity() {
        let valid = Account(
            id: "u1", username: "user",
            accessToken: "tok", refreshToken: "ref",
            tokenExpiry: Date().addingTimeInterval(600),
            scopes: ["user:read:email"]
        )
        XCTAssertTrue(valid.isTokenValid)

        let expired = Account(
            id: "u2", username: "user2",
            accessToken: "tok", refreshToken: "ref",
            tokenExpiry: Date().addingTimeInterval(-600),
            scopes: ["user:read:email"]
        )
        XCTAssertFalse(expired.isTokenValid)
    }

    // MARK: - Channel

    func testChannelDropsEnabled() {
        let channel = Channel(
            id: "ch1", login: "testchannel", displayName: "TestChannel",
            isLive: true, hasDropsEnabled: true
        )
        XCTAssertTrue(channel.isLive)
        XCTAssertTrue(channel.hasDropsEnabled)
    }

    // MARK: - Progress calculations

    func testProgressCalculation() {
        let p = Progress(
            id: "pr1", dropId: "d1", dropName: "Drop",
            campaignId: "c1", currentMinutes: 30, requiredMinutes: 60
        )
        XCTAssertEqual(p.percentComplete, 50.0, accuracy: 0.01)
        XCTAssertEqual(p.remainingMinutes, 30)
        XCTAssertFalse(p.isComplete)

        let done = Progress(
            id: "pr2", dropId: "d2", dropName: "Done Drop",
            campaignId: "c1", currentMinutes: 60, requiredMinutes: 60
        )
        XCTAssertEqual(done.percentComplete, 100.0, accuracy: 0.01)
        XCTAssertEqual(done.remainingMinutes, 0)
        XCTAssertTrue(done.isComplete)
    }

    // MARK: - OverallProgress

    func testOverallProgress() {
        let progress = OverallProgress(
            totalCampaigns: 5, activeCampaigns: 3,
            totalDrops: 10, claimedDrops: 4, pendingDrops: 6,
            totalWatchTimeMinutes: 120, campaigns: []
        )
        XCTAssertEqual(progress.totalCampaigns, 5)
        XCTAssertEqual(progress.claimedDrops, 4)
        XCTAssertEqual(progress.pendingDrops, 6)
    }

    // MARK: - Spade beacon interval

    func testSpadeWatchInterval() {
        // The beacon must fire every 59 seconds — this is the Twitch-defined window
        XCTAssertEqual(SpadeBeaconService.watchInterval, 59)
    }

    // MARK: - Errors

    func testErrorDescriptions() {
        XCTAssertNotNil(TwitchMinerError.tokenExpired.errorDescription)
        XCTAssertNotNil(TwitchMinerError.networkError("test").errorDescription)
        XCTAssertNotNil(TwitchMinerError.rateLimited(retryAfter: 30).errorDescription)
        XCTAssertNotNil(TwitchMinerError.dropAlreadyClaimed.errorDescription)
        XCTAssertNotNil(TwitchMinerError.unknown("boom").errorDescription)
    }
}
