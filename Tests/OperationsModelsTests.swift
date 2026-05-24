import XCTest
@testable import SwiftMinerCore

@MainActor
final class OperationsModelsTests: XCTestCase {
    func testDeadlineForecastOnTrackWhenEnoughTimeRemains() {
        let now = Date(timeIntervalSince1970: 1_000)
        let campaign = makeCampaign(
            endDate: now.addingTimeInterval(3 * 60 * 60),
            currentMinutes: 30,
            requiredMinutes: 60
        )

        let forecast = CampaignDeadlineForecast.make(minerId: "miner", campaign: campaign, now: now)

        XCTAssertEqual(forecast.outcome, .onTrack)
        XCTAssertEqual(forecast.minutesRemainingToEarn, 30)
        XCTAssertEqual(Int(forecast.progressPercent), 50)
    }

    func testDeadlineForecastAtRiskWithoutSafetyBuffer() {
        let now = Date(timeIntervalSince1970: 1_000)
        let campaign = makeCampaign(
            endDate: now.addingTimeInterval(45 * 60),
            currentMinutes: 20,
            requiredMinutes: 60
        )

        let forecast = CampaignDeadlineForecast.make(minerId: "miner", campaign: campaign, now: now)

        XCTAssertEqual(forecast.outcome, .atRisk)
        XCTAssertEqual(forecast.minutesRemainingToEarn, 40)
    }

    func testDeadlineForecastMissedWhenWatchTimeExceedsDeadline() {
        let now = Date(timeIntervalSince1970: 1_000)
        let campaign = makeCampaign(
            endDate: now.addingTimeInterval(20 * 60),
            currentMinutes: 0,
            requiredMinutes: 60
        )

        let forecast = CampaignDeadlineForecast.make(minerId: "miner", campaign: campaign, now: now)

        XCTAssertEqual(forecast.outcome, .missed)
    }

    func testDeadlineForecastBlockedWhenAccountNotConnected() {
        let now = Date(timeIntervalSince1970: 1_000)
        let campaign = makeCampaign(
            endDate: now.addingTimeInterval(3 * 60 * 60),
            currentMinutes: 0,
            requiredMinutes: 60,
            isAccountConnected: false
        )

        let forecast = CampaignDeadlineForecast.make(minerId: "miner", campaign: campaign, now: now)

        XCTAssertEqual(forecast.outcome, .blocked)
    }

    func testHealthSnapshotComputesStallConfidenceFromSignals() {
        let now = Date(timeIntervalSince1970: 10_000)
        let miner = MinerManager.ManagedMiner(
            id: "miner",
            accountId: "account",
            username: "tester",
            status: .watching,
            isRunning: true,
            priorityGames: [],
            lastEventAt: now.addingTimeInterval(-25 * 60),
            lastSuccessfulPollAt: now.addingTimeInterval(-16 * 60),
            isHealthy: false
        )

        let snapshot = MinerHealthSnapshot.make(miner: miner, now: now)

        XCTAssertEqual(snapshot.health, .attention)
        XCTAssertGreaterThanOrEqual(snapshot.stallConfidencePercent, 75)
        XCTAssertTrue(snapshot.stallSignals.contains("No successful poll in 15m"))
    }

    private func makeCampaign(
        endDate: Date,
        currentMinutes: Int,
        requiredMinutes: Int,
        isAccountConnected: Bool = true
    ) -> Campaign {
        let startDate = endDate.addingTimeInterval(-24 * 60 * 60)
        let drop = Drop(
            id: "drop",
            name: "Drop",
            requiredMinutes: requiredMinutes,
            progress: Progress(dropId: "drop", campaignId: "campaign", currentMinutes: currentMinutes, requiredMinutes: requiredMinutes)
        )
        return Campaign(
            id: "campaign",
            name: "Campaign",
            game: Game(id: "game", name: "Game"),
            startDate: startDate,
            endDate: endDate,
            drops: [drop],
            isAccountConnected: isAccountConnected
        )
    }
}
