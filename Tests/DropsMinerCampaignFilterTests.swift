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

    func testNeedsSetupPreservesLiveUnlinkedCampaignOutsideCuratedFeed() {
        let campaign = makeCampaign(
            id: "campaign-unlinked",
            gameName: "Unlinked Game",
            isAccountConnected: false,
            relevance: .irrelevant,
            accountStates: [
                AccountState(
                    accountId: "selected",
                    username: "Selected",
                    initials: "S",
                    miningStatus: .blocked
                )
            ]
        )

        XCTAssertTrue(DropsCampaignFilterRules.matchesNeedsSetup(campaign, now: now))
        XCTAssertTrue(
            DropsCampaignFilterRules.preservesCampaignOutsideCuratedFeed(
                campaign,
                selectedFilters: [.needsSetup],
                now: now
            )
        )
        XCTAssertFalse(
            DropsCampaignFilterRules.preservesCampaignOutsideCuratedFeed(
                campaign,
                selectedFilters: [.active],
                now: now
            ),
            "Unlinked public campaigns should only bypass curation for Needs Setup"
        )
    }

    func testNeedsSetupDoesNotPreserveEndedUnlinkedCampaign() {
        let campaign = makeCampaign(
            id: "campaign-ended-unlinked",
            gameName: "Ended Unlinked Game",
            isAccountConnected: false,
            relevance: .irrelevant,
            endDate: now.addingTimeInterval(-60),
            accountStates: [
                AccountState(
                    accountId: "selected",
                    username: "Selected",
                    initials: "S",
                    miningStatus: .blocked
                )
            ]
        )

        XCTAssertFalse(DropsCampaignFilterRules.matchesNeedsSetup(campaign, now: now))
        XCTAssertFalse(
            DropsCampaignFilterRules.preservesCampaignOutsideCuratedFeed(
                campaign,
                selectedFilters: [.needsSetup],
                now: now
            )
        )
    }

    private func makeCampaign(
        id: String,
        gameName: String,
        isAccountConnected: Bool = true,
        relevance: CampaignRelevance = .active,
        endDate: Date? = nil,
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
            isAccountConnected: isAccountConnected,
            relevance: relevance,
            startDate: now.addingTimeInterval(-3600),
            endDate: endDate ?? now.addingTimeInterval(3600),
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
