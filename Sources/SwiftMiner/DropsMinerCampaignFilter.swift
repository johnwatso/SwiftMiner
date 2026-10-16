import Foundation
import SwiftMinerCore

enum DropsMinerCampaignFilter {
    static func matches(
        _ campaign: CampaignViewData,
        selectedAccountId: String?,
        currentCampaignId: String?,
        priorityGames: [String]
    ) -> Bool {
        guard let selectedAccountId else { return true }

        if currentCampaignId == campaign.id {
            return true
        }

        guard let account = campaign.accountStates.first(where: { $0.accountId == selectedAccountId }) else {
            return false
        }

        if account.claimedDropCount > 0 || (account.progressFraction ?? 0) > 0 {
            return true
        }

        switch account.miningStatus {
        case .mining, .claimed, .claimedUnlinked, .needsAuth, .blocked:
            return true
        case .ready:
            return matchesPriority(campaign, priorityGames: priorityGames)
        case .idle:
            return false
        }
    }

    private static func matchesPriority(_ campaign: CampaignViewData, priorityGames: [String]) -> Bool {
        PriorityGameMatcher(priorityGames).matches(
            gameId: campaign.gameId ?? "",
            gameName: campaign.gameName
        )
    }
}
