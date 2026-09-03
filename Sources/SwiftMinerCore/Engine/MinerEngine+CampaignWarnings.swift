import Foundation

// Reconciling campaign state against inventory, and raising the two warnings a miner cannot
// resolve on its own: an unlinked game account, and a campaign that needs a paid subscription.
//
// Split out of MinerEngine.swift, which had grown past the point where one file could be read.

extension MinerEngine {
    func syncCampaigns(with snapshot: InventorySnapshot) {
        let mergedCampaigns = DropsService.mergeInventory(snapshot, into: allCampaigns)
        guard mergedCampaigns != allCampaigns else { return }

        allCampaigns = mergedCampaigns
        let updatedCandidates = candidateCampaigns(
            from: mergedCampaigns,
            priorityGames: priorityGames,
            excludedGames: excludedGames,
            strategy: miningStrategy
        )
        onCampaignUpdate?(updatedCandidates)
    }

    func warnForUnlinkedPriorityCampaigns(in campaigns: [Campaign]) async {
        let isGlobalIgnore = ignoredAccountLinkWarningGames.contains("all")
        
        let priorityGamesLower = Set(priorityGames.map { $0.lowercased() })
        guard !priorityGamesLower.isEmpty else {
            warnedUnlinkedPriorityGames.removeAll()
            return
        }

        let blockedCampaigns = campaigns.filter { campaign in
            // Filter only to priority games that aren't linked and have active, uncollected drops
            campaign.isTimeActive
                && !campaign.isLikelyInternalTestCampaign
                && !campaign.isAccountConnected
                && priorityGamesLower.contains(campaign.gameName.lowercased())
                && campaign.drops.contains(where: { !$0.isClaimed })
        }

        let blockedGamesNow = Set(blockedCampaigns.map { $0.gameName.lowercased() })
        warnedUnlinkedPriorityGames.formIntersection(blockedGamesNow)

        let blockedByGame = Dictionary(grouping: blockedCampaigns, by: { $0.gameName.lowercased() })
        
        // Filter out games that are explicitly suppressed for this miner
        let suppressibleGames = blockedByGame.keys.filter { gameName in
            if isGlobalIgnore { return true }
            // Check by name or potentially ID (though ignoredAccountLinkWarningGames currently uses lowercased names usually)
            return ignoredAccountLinkWarningGames.contains(gameName) ||
                   ignoredAccountLinkWarningGames.contains(blockedByGame[gameName]?.first?.game.id ?? "")
        }
        
        let newBlockedGames = blockedByGame.keys
            .filter { !warnedUnlinkedPriorityGames.contains($0) }
            .filter { !suppressibleGames.contains($0) }
            .sorted()

        for key in newBlockedGames {
            guard let campaignsForGame = blockedByGame[key], let sample = campaignsForGame.first else {
                continue
            }

            warnedUnlinkedPriorityGames.insert(key)

            let campaignSummary = campaignsForGame
                .map(\.name)
                .prefix(2)
                .joined(separator: ", ")
            let suffix = campaignsForGame.count > 2 ? ", and more" : ""

            log("Priority game may need linking: \(sample.gameName) is prioritised. SwiftMiner will still try to mine it if Twitch allows progress, but link the game account if rewards do not appear in-game. Active campaign(s): \(campaignSummary)\(suffix).")

            if notificationService == nil {
                notificationService = NotificationService()
            }
            if let notificationService {
                await notificationService.configure(enabled: true)
                await notificationService.notifyAccountLinkRequired(
                    gameName: sample.gameName
                )
            }

            onLinkWarning?(sample.gameName)
        }
    }

    /// Reports subscription-only campaigns in the miner's own priority list.
    /// These drops are filtered from eligibleDrops, so they won't cause endless retry loops.
    /// Unrelated campaigns must stay quiet: surfacing every subscription-gated game
    /// Twitch returns made the Activity Log look like the miner was considering
    /// work outside the operator's configured priorities.
    func warnForSubscriptionRequiredCampaigns(in campaigns: [Campaign]) async {
        let priorityKeys = Set(priorityGames.map { normalizedGameKey($0) }.filter { !$0.isEmpty })
        guard !priorityKeys.isEmpty else { return }

        let subscriptionCampaigns = campaigns.filter { campaign in
            campaign.isTimeActive
                && !campaign.isLikelyInternalTestCampaign
                && (priorityKeys.contains(normalizedGameKey(campaign.gameName))
                    || priorityKeys.contains(normalizedGameKey(campaign.game.id)))
                && campaign.subscriptionRequiredDrops.contains(where: { !$0.isClaimed })
        }

        guard !subscriptionCampaigns.isEmpty else { return }

        let now = Date()
        for campaign in subscriptionCampaigns {
            let drops = campaign.subscriptionRequiredDrops.filter { !$0.isClaimed }
            let key = ([campaign.id] + drops.map(\.id).sorted()).joined(separator: "|")
            if let lastWarnedAt = subscriptionWarningKeys[key],
               now.timeIntervalSince(lastWarnedAt) < Self.subscriptionWarningRepeatInterval {
                continue
            }
            subscriptionWarningKeys[key] = now
            let dropNames = drops.map(\.name).joined(separator: ", ")
            log("Subscription required: \(campaign.name) has drops that require purchasing Twitch subscriptions: \(dropNames). These drops are being skipped.")
        }
    }

    static func campaignRefreshSummary(totalCampaigns: Int, candidates: [Campaign]) -> String {
        var statusCounts: [MiningCampaignStatus: Int] = [:]
        for candidate in candidates {
            statusCounts[candidate.miningStatus, default: 0] += 1
        }

        let statusSummary = [
            MiningCampaignStatus.available,
            .inProgress,
            .claimable,
            .claimed,
            .expired
        ].compactMap { status -> String? in
            guard let count = statusCounts[status], count > 0 else { return nil }
            return "\(status.rawValue)=\(count)"
        }.joined(separator: ", ")

        let suffix = statusSummary.isEmpty ? "" : " (\(statusSummary))"
        return "Campaigns: \(totalCampaigns) total, \(candidates.count) account-eligible\(suffix)"
    }

    /// Describes a campaign the miner was actively working that has just stopped being a
    /// candidate, in terms of the fields that decide candidacy.
    ///
    /// `campaignRefreshSummary` and `[CampaignSelect]` both report counts, so a campaign
    /// that quietly leaves the set is invisible: the ALGS Split 2 PL charm was lost over
    /// three consecutive match days before anything in the log said which campaign had
    /// gone or what it had lost. Returns nil when there is nothing to report — no previous
    /// campaign, still a candidate, or legitimately finished.
    static func abandonedCampaignSummary(
        previousCampaignId: String?,
        in allCampaigns: [Campaign],
        candidates: [Campaign]
    ) -> String? {
        guard let previousCampaignId,
              !candidates.contains(where: { $0.id == previousCampaignId }),
              let campaign = allCampaigns.first(where: { $0.id == previousCampaignId })
        else { return nil }

        // A campaign whose window closed, or whose drops are all claimed, was not abandoned.
        // `isFullyComplete` is vacuously true for a campaign with no drops, and that is the
        // headline case here — a campaign that lost its drop list, not one that finished.
        guard campaign.isTimeActive,
              campaign.drops.isEmpty || !campaign.isFullyComplete
        else { return nil }

        let facts = [
            "drops=\(campaign.drops.count)",
            "eligible=\(campaign.eligibleDrops.count)",
            "earnable=\(campaign.earnableDrops.count)",
            "linked=\(campaign.isAccountConnected)",
            "status=\(campaign.status.rawValue)",
            "ends=\(campaign.endDate.formatted(.iso8601))"
        ].joined(separator: " ")

        return "Campaign \"\(campaign.name)\" (\(campaign.gameName)) left the candidate set while still active — \(facts)"
    }

    static func performanceCycleSummary(_ timing: PerformanceDiagnostics.MiningCycleTiming) -> String {
        var parts = [
            "[Perf] cycle \(timing.outcome):",
            "total=\(formatPerfDuration(timing.totalSeconds))",
            "campaigns=\(formatPerfDuration(timing.campaignFetchSeconds))",
            "claims=\(formatPerfDuration(timing.claimCheckSeconds))",
            "channels=\(formatPerfDuration(timing.channelSelectionSeconds))",
            "watchStart=\(formatPerfDuration(timing.watchStartupSeconds))",
            "candidates=\(timing.candidateCount)"
        ]
        if let campaign = timing.selectedCampaign, !campaign.isEmpty {
            parts.append("campaign=\"\(campaign)\"")
        }
        if let channel = timing.selectedChannel, !channel.isEmpty {
            parts.append("channel=\"\(channel)\"")
        }
        return parts.joined(separator: " ")
    }

    private static func formatPerfDuration(_ seconds: TimeInterval) -> String {
        let bounded = max(0, seconds)
        if bounded < 1 {
            return "\(Int((bounded * 1_000).rounded()))ms"
        }
        return String(format: "%.2fs", bounded)
    }
}
