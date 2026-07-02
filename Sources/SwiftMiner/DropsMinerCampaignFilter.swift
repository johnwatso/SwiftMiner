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
        let gameId = campaign.gameId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let gameName = normalizedGameName(campaign.gameName)

        return priorityGames.contains { priority in
            let trimmed = priority.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }

            if !gameId.isEmpty && trimmed.lowercased() == gameId {
                return true
            }

            return normalizedGameName(trimmed) == gameName
        }
    }

    private static func normalizedGameName(_ value: String) -> String {
        value
            .lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}
