import Foundation
import SwiftMinerCore

/// Shared rules for "this miner has something the user should look at."
/// Used by the sidebar's Miners-tab badge, the per-miner source list dot,
/// and the miner pane's PENDING section.
@MainActor
enum MinerAttention {
    /// True when the miner has at least one non-muted pending item:
    /// blocked account/auth state, account-link reminder, or a sub-gated campaign.
    static func hasPendingAttention(
        for miner: MinerManager.ManagedMiner,
        settings: Settings
    ) -> Bool {
        if miner.status == .blockedAccountNotLinked || miner.status == .error || miner.needsAuth {
            return true
        }

        // Campaign-derived reminders wait for a live fetch. The launch-time disk
        // seed exists to fill the UI, not to nag: a day-old cache could ask the
        // user to link a game they already linked, or sub to a finished campaign.
        // Auth and blocked states above are miner state, not campaign state, so
        // they still surface immediately.
        guard !miner.campaignsAreProvisional else { return false }

        let priorityKeys = Set(
            settings.priorityGames
                .map(normalizedGameKey)
                .filter { !$0.isEmpty }
        )

        // Account-link reminders are only surfaced for prioritised games.
        if !priorityKeys.isEmpty {
            let hasLinkReminder = miner.allCampaigns.contains { campaign in
                guard campaign.isTimeActive,
                      campaign.status != .disabled,
                      campaign.activityStatus(for: miner) == .requiresLink,
                      campaign.drops.contains(where: { !$0.isClaimed }),
                      priorityKeys.contains(normalizedGameKey(campaign.game.name))
                        || priorityKeys.contains(normalizedGameKey(campaign.game.id)) else {
                    return false
                }
                let gameId = warningGameId(for: campaign)
                return !settings.isIgnoringAccountLinkWarnings(for: miner.accountId, gameId: gameId)
            }
            if hasLinkReminder { return true }
        }

        // Sub-gated campaigns surface across all of this miner's campaigns,
        // not just prioritised ones — they're a hard reason a miner can't proceed.
        let hasSubReminder = miner.allCampaigns.contains { campaign in
            guard campaign.isTimeActive,
                  campaign.status != .disabled,
                  campaign.activityStatus(for: miner) == .requiresSubscription else {
                return false
            }
            return !settings.isIgnoringSubscriptionRequiredWarnings(
                for: miner.accountId,
                campaignId: campaign.id
            )
        }
        if hasSubReminder { return true }

        #if DEBUG
        if ProcessInfo.processInfo.environment["SWIFTMINER_FAKE_PENDING"] == "1" {
            // Mirror the fake item identifiers used by MinersOverviewView's
            // debugFakePendingItems(for:) so the badge respects mute state.
            let fakeLinkMuted = settings.isIgnoringAccountLinkWarnings(
                for: miner.accountId,
                gameId: "debug-fake-link-game"
            )
            let fakeSubMuted = settings.isIgnoringSubscriptionRequiredWarnings(
                for: miner.accountId,
                campaignId: "debug-fake-campaign"
            )
            if !fakeLinkMuted || !fakeSubMuted {
                return true
            }
        }
        #endif

        return false
    }

    /// Number of miners with at least one non-muted pending item.
    static func attentionCount(
        miners: [MinerManager.ManagedMiner],
        settings: Settings
    ) -> Int {
        miners.filter { hasPendingAttention(for: $0, settings: settings) }.count
    }

    private static func warningGameId(for campaign: Campaign) -> String {
        let id = campaign.game.id.trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty { return id }
        return normalizedGameKey(campaign.game.name)
    }

    private static func normalizedGameKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
