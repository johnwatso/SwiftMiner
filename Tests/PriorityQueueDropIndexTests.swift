import Foundation
import XCTest
@testable import SwiftMiner
@testable import SwiftMinerCore

/// Overview's priority queue shows one line of drop state per game. These pin what
/// that line is allowed to say: a miner being on the game wins, otherwise the
/// rewards still outstanding on campaigns that can actually be mined right now.
final class PriorityQueueDropIndexTests: XCTestCase {
    private let now = Date()

    private func campaign(
        id: String,
        gameId: String? = "1",
        gameName: String = "The Finals",
        totalDrops: Int = 2,
        dropsClaimed: Int = 0,
        isAccountConnected: Bool = true,
        startOffset: TimeInterval = -3600,
        endOffset: TimeInterval = 3600
    ) -> CampaignViewData {
        CampaignViewData(
            id: id,
            gameId: gameId,
            gameName: gameName,
            campaignName: "Campaign \(id)",
            artworkURL: nil,
            progress: 0,
            isClaimed: false,
            dropsClaimed: dropsClaimed,
            totalDrops: totalDrops,
            status: "ACTIVE",
            miningStatus: .available,
            isAccountConnected: isAccountConnected,
            relevance: .prioritised,
            startDate: now.addingTimeInterval(startOffset),
            endDate: now.addingTimeInterval(endOffset)
        )
    }

    private func index(
        _ campaigns: [CampaignViewData],
        watching: Set<String> = []
    ) -> PriorityQueueDropIndex {
        PriorityQueueDropIndex(campaigns: campaigns, now: now) { watching.contains($0.id) }
    }

    func testRemainingRewardsAcrossCampaignsAreSummed() {
        let subject = index([
            campaign(id: "a", totalDrops: 2),
            campaign(id: "b", totalDrops: 3, dropsClaimed: 1)
        ])

        XCTAssertEqual(
            subject.state(gameId: "1", gameName: "The Finals"),
            PriorityQueueDropState(tone: .available, label: "4 drops")
        )
    }

    func testASingleRemainingRewardReadsAsSingular() {
        let subject = index([campaign(id: "a", totalDrops: 1)])

        XCTAssertEqual(
            subject.state(gameId: "1", gameName: "The Finals"),
            PriorityQueueDropState(tone: .available, label: "1 drop")
        )
    }

    func testAWatchedCampaignReportsActiveInsteadOfACount() {
        let subject = index(
            [campaign(id: "a", totalDrops: 2), campaign(id: "b", totalDrops: 2)],
            watching: ["a"]
        )

        XCTAssertEqual(
            subject.state(gameId: "1", gameName: "The Finals"),
            PriorityQueueDropState(tone: .active, label: "1 active")
        )
    }

    func testCampaignsThatCannotBeMinedNowAreNotCounted() {
        let subject = index([
            campaign(id: "unlinked", isAccountConnected: false),
            campaign(id: "expired", startOffset: -7200, endOffset: -3600),
            campaign(id: "future", startOffset: 3600, endOffset: 7200),
            campaign(id: "claimed", totalDrops: 2, dropsClaimed: 2)
        ])

        XCTAssertEqual(
            subject.state(gameId: "1", gameName: "The Finals"),
            PriorityQueueDropState(tone: .idle, label: "No drops")
        )
    }

    func testAGameWithNoCampaignsAtAllReportsNoDrops() {
        let subject = index([campaign(id: "a")])

        XCTAssertEqual(
            subject.state(gameId: "99", gameName: "Rainbow Six Siege"),
            PriorityQueueDropState(tone: .idle, label: "No drops")
        )
    }

    func testNamesThatDifferOnlyInPunctuationOrCaseShareAGame() {
        let subject = index([
            campaign(id: "a", gameId: "1", gameName: "Battlefield 6", totalDrops: 2),
            campaign(id: "b", gameId: nil, gameName: "battlefield-6", totalDrops: 1)
        ])

        XCTAssertEqual(
            subject.state(gameId: nil, gameName: "BATTLEFIELD6"),
            PriorityQueueDropState(tone: .available, label: "3 drops")
        )
    }

    func testAnUnnamedGameStillGroupsByItsIdentifier() {
        let subject = index([campaign(id: "a", gameId: "42", gameName: "", totalDrops: 2)])

        XCTAssertEqual(
            subject.state(gameId: "42", gameName: ""),
            PriorityQueueDropState(tone: .available, label: "2 drops")
        )
    }
}
