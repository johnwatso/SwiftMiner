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
#if DEBUG
        if miner.debugAttention != nil { return true }
#endif

        if miner.status == .blockedAccountNotLinked || miner.status == .error || miner.needsAuth {
            return true
        }

        // Campaign-derived reminders wait for a live fetch. The launch-time disk
        // seed exists to fill the UI, not to nag: a day-old cache could ask the
        // user to link a game they already linked, or sub to a finished campaign.
        // Auth and blocked states above are miner state, not campaign state, so
        // they still surface immediately.
        guard !miner.campaignsAreProvisional else { return false }

        if accountLinkReminderCampaign(for: miner, settings: settings) != nil { return true }
        if subscriptionReminderCampaign(for: miner, settings: settings) != nil { return true }

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

    /// Marker written by `MinerEngine.recordApprovedChannelProbeFailure`.
    static let approvedChannelProbeFailureMarker = "Could not check live state for approved channel"
    /// How many failures within the window count as the query being broken rather than one
    /// unlucky probe, and how far back to look. The engine probes approved channels every
    /// 60 seconds while waiting, so a genuine outage clears this quickly and a one-off does not.
    static let approvedChannelProbeFailureThreshold = 3
    static let approvedChannelProbeFailureWindow: TimeInterval = 30 * 60

    /// Describes a run of failed approved-channel liveness checks for this miner, if the
    /// recent event log holds enough of them to mean the query itself is broken.
    static func approvedChannelProbeFailure(
        for miner: MinerManager.ManagedMiner,
        events: [EventEntry],
        now: Date = Date()
    ) -> String? {
        let cutoff = now.addingTimeInterval(-approvedChannelProbeFailureWindow)
        let failures = events.filter { event in
            event.minerId == miner.id
                && event.timestamp >= cutoff
                && event.message.contains(approvedChannelProbeFailureMarker)
        }
        guard failures.count >= approvedChannelProbeFailureThreshold else { return nil }

        let channels = Set(
            failures.compactMap { event -> String? in
                guard let range = event.message.range(of: approvedChannelProbeFailureMarker) else { return nil }
                let remainder = event.message[range.upperBound...]
                guard let colon = remainder.firstIndex(of: ":") else { return nil }
                let channel = remainder[..<colon].trimmingCharacters(in: .whitespaces)
                return channel.isEmpty ? nil : channel
            }
        )
        let channelSummary = channels.count == 1
            ? "\(channels.first ?? "one channel")"
            : "\(channels.count) channels"
        return "SwiftMiner could not tell whether \(channelSummary) were live — \(failures.count) checks failed in the last 30 minutes."
    }

    /// The first non-muted account-link blocker, if any. Shared with the
    /// attention panel so a badge always has a matching explanation and next step.
    static func accountLinkReminderCampaign(
        for miner: MinerManager.ManagedMiner,
        settings: Settings
    ) -> Campaign? {
        guard !miner.campaignsAreProvisional else { return nil }

        let priorityKeys = Set(
            settings.priorityGames(forAccountId: miner.accountId)
                .map(normalizedGameKey)
                .filter { !$0.isEmpty }
        )
        guard !priorityKeys.isEmpty else { return nil }

        return miner.allCampaigns.first { campaign in
            // Deliberately not `activityStatus(for:) == .requiresLink`: that status
            // resolves to `.watching` for the current campaign, which suppressed the
            // badge for exactly the campaign the miner is mining right now.
            guard campaign.isTimeActive,
                  campaign.status != .disabled,
                  !campaign.isAccountConnected,
                  campaign.drops.contains(where: { !$0.isClaimed }),
                  priorityKeys.contains(normalizedGameKey(campaign.game.name))
                    || priorityKeys.contains(normalizedGameKey(campaign.game.id)) else {
                return false
            }
            return !settings.isIgnoringAccountLinkWarnings(
                for: miner.accountId,
                gameId: warningGameId(for: campaign)
            )
        }
    }

    /// The first non-muted subscription blocker. These apply even when the game
    /// is not prioritised, because watching alone cannot earn its remaining drops.
    static func subscriptionReminderCampaign(
        for miner: MinerManager.ManagedMiner,
        settings: Settings
    ) -> Campaign? {
        guard !miner.campaignsAreProvisional else { return nil }

        return miner.allCampaigns.first { campaign in
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
    }

    static func warningGameId(for campaign: Campaign) -> String {
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
@MainActor
struct MinerAttentionIssue: Equatable {
    enum Action: Equatable {
        case reconnect
        case restart
        case openTwitchDrops

        var title: String {
            switch self {
            case .reconnect: return "Reconnect Twitch"
            case .restart: return "Restart Miner"
            case .openTwitchDrops: return "Open Twitch Drops"
            }
        }
    }

    /// The mute that silences this issue, for the ones the user is allowed to turn off.
    ///
    /// Only the two campaign reminders have one. A miner that needs re-authentication, has a
    /// stopped worker, or has stalled is describing something SwiftMiner cannot work around, and
    /// hiding that would hide the reason the miner is not earning — which is the whole point of
    /// the banner. These map onto the same per-account mutes the Pending list uses, so silencing
    /// an issue here and silencing it there are the same act, and it stays undoable from Pending.
    enum Dismissal: Equatable {
        case accountLink(gameId: String, gameName: String)
        case subscriptionRequired(campaignId: String)
    }

    let title: String
    let detail: String
    let recommendation: String
    let action: Action?
    var dismissal: Dismissal?

    static func resolve(
        miner: MinerManager.ManagedMiner,
        events: [EventEntry]
    ) -> MinerAttentionIssue? {
#if DEBUG
        if let attention = miner.debugAttention {
            switch attention {
            case .accountLink(let gameName):
                return MinerAttentionIssue(
                    title: "Link \(gameName) to Twitch",
                    detail: "This is a Developer-menu preview of a game account link blocker.",
                    recommendation: "Open Twitch Drops, link the game account, then return here. SwiftMiner will retry automatically.",
                    action: .openTwitchDrops,
                    dismissal: .accountLink(gameId: "debug-fake-link-game", gameName: gameName)
                )
            case .subscriptionRequired:
                return MinerAttentionIssue(
                    title: "A Twitch subscription is required",
                    detail: "This is a Developer-menu preview of a subscription-only campaign.",
                    recommendation: "Subscribe to an eligible Twitch channel for this campaign, then refresh the miner to check the drops again.",
                    action: nil,
                    dismissal: .subscriptionRequired(campaignId: "debug-fake-campaign")
                )
            }
        }
#endif

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

        // A miner that is happily watching one campaign can still be blind to the
        // restricted ones. The check that answers "is this esports channel live?" fails
        // silently — the worker never stops, so none of the states above catch it, and the
        // only trace is a warning in a log nobody reads. Campaigns limited to a channel
        // list are exactly the ones whose windows are too short to miss.
        if miner.isRunning,
           let failure = MinerAttention.approvedChannelProbeFailure(for: miner, events: events) {
            return MinerAttentionIssue(
                title: "Restricted campaigns can't be checked",
                detail: failure,
                recommendation: "Use Override Stream to point this miner straight at the channel, or open the stream on Twitch yourself — drops still count either way. SwiftMiner keeps watching everything else meanwhile, and resumes checking on its own once the check recovers.",
                action: .restart
            )
        }

        let settings = Settings.shared
        if let campaign = MinerAttention.accountLinkReminderCampaign(for: miner, settings: settings) {
            return MinerAttentionIssue(
                title: "Link \(campaign.game.name) to Twitch",
                detail: "\(campaign.name) has unclaimed drops, but the \(campaign.game.name) account is not linked.",
                recommendation: "Open Twitch Drops, link the game account, then return here. SwiftMiner will retry automatically.",
                action: .openTwitchDrops,
                dismissal: .accountLink(
                    gameId: MinerAttention.warningGameId(for: campaign),
                    gameName: campaign.game.name
                )
            )
        }

        // The engine can know mining is blocked before a campaign refresh tells
        // us which game needs linking. Keep this as a wording fallback, not a
        // second kind of warning alongside the game-specific version above.
        if miner.status == .blockedAccountNotLinked {
            return MinerAttentionIssue(
                title: "Link a game account to Twitch",
                detail: "Twitch cannot award this miner's pending drops until its game account is linked.",
                recommendation: "Open Twitch Drops, link the game account, then return here. SwiftMiner will retry automatically.",
                action: .openTwitchDrops
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

        if let campaign = MinerAttention.subscriptionReminderCampaign(for: miner, settings: settings) {
            return MinerAttentionIssue(
                title: "A Twitch subscription is required",
                detail: "\(campaign.name) has drops that cannot be earned by watching without a paid Twitch subscription.",
                recommendation: "Subscribe to an eligible Twitch channel for this campaign, then refresh the miner to check the drops again.",
                action: nil,
                dismissal: .subscriptionRequired(campaignId: campaign.id)
            )
        }

        return nil
    }
}
