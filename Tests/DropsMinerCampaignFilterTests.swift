import XCTest
@testable import SwiftMiner
@testable import SwiftMinerCore

final class DropsMinerCampaignFilterTests: XCTestCase {
    private let now = Date()

    func testSelectedMinerFilterRejectsIdleCampaignMentionedByMergedFeed() {
        let campaign = makeCampaign(
            id: "campaign-other",
            gameName: "Other Game",
            accountStates: [
                AccountState(accountId: "selected", username: "Selected", initials: "S", miningStatus: .idle),
                AccountState(accountId: "other", username: "Other", initials: "O", miningStatus: .mining)
            ]
        )

        XCTAssertFalse(
            DropsMinerCampaignFilter.matches(
                campaign,
                selectedAccountId: "selected",
                currentCampaignId: nil,
                priorityGames: []
            )
        )
    }

    func testSelectedMinerFilterIncludesReadyPriorityCampaign() {
        let campaign = makeCampaign(
            id: "campaign-priority",
            gameName: "Priority Game",
            accountStates: [
                AccountState(accountId: "selected", username: "Selected", initials: "S", miningStatus: .ready)
            ]
        )

        XCTAssertTrue(
            DropsMinerCampaignFilter.matches(
                campaign,
                selectedAccountId: "selected",
                currentCampaignId: nil,
                priorityGames: ["priority game"]
            )
        )
    }

    func testSelectedMinerFilterIncludesSelectedProgressWithoutPriority() {
        let campaign = makeCampaign(
            id: "campaign-progress",
            gameName: "Progress Game",
            accountStates: [
                AccountState(
                    accountId: "selected",
                    username: "Selected",
                    initials: "S",
                    miningStatus: .idle,
                    claimedDropCount: 0,
                    progressFraction: 0.35
                )
            ]
        )

        XCTAssertTrue(
            DropsMinerCampaignFilter.matches(
                campaign,
                selectedAccountId: "selected",
                currentCampaignId: nil,
                priorityGames: []
            )
        )
    }

    func testSelectedMinerFilterIncludesCurrentCampaignWithoutAccountState() {
        let campaign = makeCampaign(
            id: "campaign-current",
            gameName: "Current Game",
            accountStates: []
        )

        XCTAssertTrue(
            DropsMinerCampaignFilter.matches(
                campaign,
                selectedAccountId: "selected",
                currentCampaignId: "campaign-current",
                priorityGames: []
            )
        )
    }

    private func makeCampaign(
        id: String,
        gameName: String,
        accountStates: [AccountState]
    ) -> CampaignViewData {
        CampaignViewData(
            id: id,
            gameId: "game-\(id)",
            gameName: gameName,
            campaignName: "Campaign \(id)",
            artworkURL: nil,
            progress: 0,
            isClaimed: false,
            dropsClaimed: 0,
            totalDrops: 1,
            status: "ACTIVE",
            miningStatus: .available,
            isAccountConnected: true,
            relevance: .active,
            startDate: now.addingTimeInterval(-3600),
            endDate: now.addingTimeInterval(3600),
            drops: [
                DropViewData(
                    id: "drop-\(id)",
                    name: "Drop",
                    description: nil,
                    imageURL: nil,
                    rewardType: .inGame,
                    requiredMinutes: 60,
                    currentMinutes: 0,
                    progress: 0,
                    isClaimed: false,
                    isClaimable: false,
                    isEarnable: true
                )
            ],
            accountStates: accountStates
        )
    }
}
