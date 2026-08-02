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

/// A concise explanation of a miner problem, plus the one next step SwiftMiner recommends.
/// This keeps the miner tab actionable without requiring people to interpret raw event logs.
struct MinerAttentionIssue: Equatable {
    enum Action: Equatable {
        case reconnect
        case restart

        var title: String {
            switch self {
            case .reconnect: return "Reconnect Twitch"
            case .restart: return "Restart Miner"
            }
        }
    }

    let title: String
    let detail: String
    let recommendation: String
    let action: Action?

    static func resolve(
        miner: MinerManager.ManagedMiner,
        events: [EventEntry]
    ) -> MinerAttentionIssue? {
        if miner.needsAuth {
            return MinerAttentionIssue(
                title: "Twitch needs to be reconnected",
                detail: "This miner can no longer use its saved Twitch session.",
                recommendation: "Reconnect Twitch, then SwiftMiner will resume this miner automatically.",
                action: .reconnect
            )
        }

        if miner.workerState == .failed || miner.status == .error {
            let latestError = events.first { event in
                event.minerId == miner.id && event.level == .error
            }?.message
            if let latestError,
               latestError.localizedCaseInsensitiveContains("Twitch compatibility update required") {
                return MinerAttentionIssue(
                    title: "SwiftMiner needs a Twitch update",
                    detail: latestError,
                    recommendation: "Update SwiftMiner, then restart this miner.",
                    action: .restart
                )
            }
            return MinerAttentionIssue(
                title: "The mining worker stopped",
                detail: latestError ?? "SwiftMiner stopped this worker after an unexpected mining error.",
                recommendation: "Restart this miner. If it fails again, export its diagnostics and contact support.",
                action: .restart
            )
        }

        if miner.isStalled {
            return MinerAttentionIssue(
                title: "The miner is no longer responding",
                detail: "Other mining activity continued, but this worker stopped reporting Twitch activity.",
                recommendation: "Restart this miner to rebuild its Twitch session.",
                action: .restart
            )
        }

        if miner.showsNoRecentActivityAttention {
            return MinerAttentionIssue(
                title: "No recent activity from this miner",
                detail: "The worker is still running, but its normal liveness signals have gone quiet.",
                recommendation: "Wait for the automatic recovery. Restart the miner if this message does not clear.",
                action: .restart
            )
        }

        if miner.showsNotEarningAttention {
            let reference = miner.earningReferenceDate ?? Date()
            let minutes = max(1, Int(Date().timeIntervalSince(reference) / 60))
            return MinerAttentionIssue(
                title: "This miner is not earning drop progress",
                detail: "It has been watching for \(minutes) minutes since the last confirmed drop progress.",
                recommendation: "SwiftMiner will keep checking Twitch. Restart the miner if progress does not resume after the next campaign check.",
                action: .restart
            )
        }

        return nil
    }
}
