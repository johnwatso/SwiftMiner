// Bridges NavigationModel state into DiscordUserProjection lookups for the
// web dashboard and SwiftBot. Split from NavigationModel.swift.
import SwiftUI
import SwiftMinerCore
import SwiftMinerService

final class NavigationProjectionStateProvider: ProjectionStateProvider, @unchecked Sendable {
    private weak var model: NavigationModel?

    init(model: NavigationModel) {
        self.model = model
    }

    func activeCampaign(for discordUserId: String) async -> DiscordUserProjection.ActiveCampaign? {
        let optionalMiner = await MainActor.run { model?.minerForDiscordUser(discordUserId) }
        guard let miner = optionalMiner else { return nil }
        let summary = await model?.minerManager.getMinerActivitySummary(minerId: miner.id)
        
        return await MainActor.run {
            guard let campaignId = miner.currentCampaignId,
                  let campaign = miner.allCampaigns.first(where: { $0.id == campaignId }) else {
                return nil
            }
            return Self.activeCampaignProjection(
                from: campaign,
                currentChannelName: summary?.currentChannelName,
                currentChannelId: summary?.currentChannelId
            )
        }
    }

    func recentCompletedCampaigns(
        for discordUserId: String,
        limit: Int
    ) async -> [DiscordUserProjection.RecentCampaign] {
        await MainActor.run {
            guard let miner = model?.minerForDiscordUser(discordUserId) else { return [] }
            return miner.allCampaigns
                .filter { !$0.drops.isEmpty && $0.drops.allSatisfy(\.isClaimed) }
                .sorted { Self.completedSortDate($0) > Self.completedSortDate($1) }
                .prefix(max(limit, 0))
                .map(Self.recentCampaignProjection)
        }
    }

    func projectionState(for discordUserId: String) async -> DiscordUserProjection.ProjectionState? {
        await MainActor.run {
            guard let miner = model?.minerForDiscordUser(discordUserId) else { return nil }
            if miner.needsAuth || miner.status == .blockedAccountNotLinked || miner.status == .error {
                return .blocked
            }
            if miner.currentCampaignId != nil {
                return .active
            }
            return nil
        }
    }

    func priorityGames(for discordUserId: String) async -> [String] {
        await MainActor.run {
            guard let model, let miner = model.minerForDiscordUser(discordUserId) else { return [] }
            return model.priorityGames(for: miner)
        }
    }

    func personalPriorityGames(for discordUserId: String) async -> [String] {
        await MainActor.run {
            guard let model, let miner = model.minerForDiscordUser(discordUserId) else { return [] }
            return Settings.shared.personalPriorityGames(forAccountId: miner.accountId)
        }
    }

    func includesGlobalPriorityGames(for discordUserId: String) async -> Bool {
        await MainActor.run {
            guard let model, let miner = model.minerForDiscordUser(discordUserId) else { return true }
            return Settings.shared.includesGlobalPriorityGames(forAccountId: miner.accountId)
        }
    }

    func diagnostics(for discordUserId: String) async -> DiscordUserProjection.Diagnostics? {
        let optionalMiner = await MainActor.run { model?.minerForDiscordUser(discordUserId) }
        guard let miner = optionalMiner else { return nil }
        let summary = await model?.minerManager.getMinerActivitySummary(minerId: miner.id)
        return await MainActor.run {
            Self.diagnosticsProjection(from: miner, summary: summary)
        }
    }

    // MARK: - Twitch-principal variants (keyed by mined account id)

    func activeCampaign(forTwitchAccount accountId: String) async -> DiscordUserProjection.ActiveCampaign? {
        let optionalMiner = await MainActor.run { model?.minerForAccount(accountId) }
        guard let miner = optionalMiner else { return nil }
        let summary = await model?.minerManager.getMinerActivitySummary(minerId: miner.id)
        
        return await MainActor.run {
            guard let campaignId = miner.currentCampaignId,
                  let campaign = miner.allCampaigns.first(where: { $0.id == campaignId }) else {
                return nil
            }
            return Self.activeCampaignProjection(
                from: campaign,
                currentChannelName: summary?.currentChannelName,
                currentChannelId: summary?.currentChannelId
            )
        }
    }

    func recentCompletedCampaigns(forTwitchAccount accountId: String, limit: Int) async -> [DiscordUserProjection.RecentCampaign] {
        await MainActor.run {
            guard let miner = model?.minerForAccount(accountId) else { return [] }
            return miner.allCampaigns
                .filter { !$0.drops.isEmpty && $0.drops.allSatisfy(\.isClaimed) }
                .sorted { Self.completedSortDate($0) > Self.completedSortDate($1) }
                .prefix(max(limit, 0))
                .map(Self.recentCampaignProjection)
        }
    }

    func projectionState(forTwitchAccount accountId: String) async -> DiscordUserProjection.ProjectionState? {
        await MainActor.run {
            guard let miner = model?.minerForAccount(accountId) else { return nil }
            if miner.needsAuth || miner.status == .blockedAccountNotLinked || miner.status == .error {
                return .blocked
            }
            if miner.currentCampaignId != nil {
                return .active
            }
            return nil
        }
    }

    func priorityGames(forTwitchAccount accountId: String) async -> [String] {
        await MainActor.run {
            guard let model, let miner = model.minerForAccount(accountId) else { return [] }
            return model.priorityGames(for: miner)
        }
    }

    func personalPriorityGames(forTwitchAccount accountId: String) async -> [String] {
        await MainActor.run {
            guard let model, model.minerForAccount(accountId) != nil else { return [] }
            return Settings.shared.personalPriorityGames(forAccountId: accountId)
        }
    }

    func includesGlobalPriorityGames(forTwitchAccount accountId: String) async -> Bool {
        await MainActor.run {
            guard let model, model.minerForAccount(accountId) != nil else { return true }
            return Settings.shared.includesGlobalPriorityGames(forAccountId: accountId)
        }
    }

    func diagnostics(forTwitchAccount accountId: String) async -> DiscordUserProjection.Diagnostics? {
        let optionalMiner = await MainActor.run { model?.minerForAccount(accountId) }
        guard let miner = optionalMiner else { return nil }
        let summary = await model?.minerManager.getMinerActivitySummary(minerId: miner.id)
        return await MainActor.run {
            Self.diagnosticsProjection(from: miner, summary: summary)
        }
    }

    private static func activeCampaignProjection(
        from campaign: Campaign,
        currentChannelName: String? = nil,
        currentChannelId: String? = nil
    ) -> DiscordUserProjection.ActiveCampaign {
        let totalRequired = max(campaign.drops.map(\.requiredMinutes).reduce(0, +), 0)
        let totalCurrent = campaign.drops.reduce(0) { total, drop in
            total + (drop.isClaimed ? drop.requiredMinutes : min(drop.progress?.currentMinutes ?? 0, drop.requiredMinutes))
        }
        let pct = totalRequired > 0 ? min(Int((Double(totalCurrent) / Double(totalRequired)) * 100), 100) : 0
        return DiscordUserProjection.ActiveCampaign(
            campaignId: campaign.id,
            game: campaign.game.name,
            progress: DiscordUserProjection.Progress(
                current: totalCurrent,
                required: totalRequired,
                unit: "minutes",
                pct: pct
            ),
            endsAt: campaign.endDate,
            boxArtURL: campaign.game.boxArtURL?.absoluteString,
            currentChannelName: currentChannelName,
            currentChannelId: currentChannelId
        )
    }

    private static func recentCampaignProjection(from campaign: Campaign) -> DiscordUserProjection.RecentCampaign {
        DiscordUserProjection.RecentCampaign(
            campaignId: campaign.id,
            campaignName: campaign.name,
            game: campaign.game.name,
            // Only report a completion time we actually know: the campaign's
            // end. For campaigns finished early (all drops claimed while the
            // window is still open) min(endDate, now) would just be "now" on
            // every refresh — the web showed a perpetual "1m ago".
            completedAt: campaign.endDate <= Date() ? campaign.endDate : nil,
            claimedDrops: campaign.drops.filter(\.isClaimed).count,
            totalDrops: campaign.drops.count,
            boxArtURL: campaign.game.boxArtURL?.absoluteString
        )
    }

    @MainActor
    private static func diagnosticsProjection(
        from miner: MinerManager.ManagedMiner,
        summary: MinerManager.MinerActivitySummary?
    ) -> DiscordUserProjection.Diagnostics {
        let snapshot = MinerHealthSnapshot.make(miner: miner)
        return DiscordUserProjection.Diagnostics(
            health: snapshot.health.rawValue,
            statusRaw: miner.status.rawValue,
            statusLabel: snapshot.statusLabel,
            isRunning: miner.isRunning,
            isHealthy: miner.isHealthy,
            isStalled: miner.isStalled,
            stallConfidencePercent: snapshot.stallConfidencePercent,
            stallSignals: snapshot.stallSignals,
            lastSuccessfulPollAt: snapshot.lastSuccessfulPollAt,
            lastEventAt: snapshot.lastEventAt,
            lastCampaignRefreshAt: snapshot.lastCampaignRefreshAt,
            minutesSinceLastProgress: summary?.minutesSinceLastProgress,
            currentChannelName: summary?.currentChannelName,
            currentChannelId: summary?.currentChannelId,
            lastSwitchReason: summary?.lastSwitchReason?.summary,
            lastSwitchAt: summary?.lastSwitchAt,
            recentEvents: summary?.recentEvents.map {
                DiscordUserProjection.DiagnosticEvent(
                    timestamp: $0.timestamp,
                    type: $0.type.rawValue,
                    summary: $0.summary
                )
            } ?? []
        )
    }

    private static func completedSortDate(_ campaign: Campaign) -> Date {
        min(campaign.endDate, Date())
    }
}

extension NavigationModel {
    func minerForDiscordUser(_ discordUserId: String) -> MinerManager.ManagedMiner? {
        minerManager.miners.first { miner in
            miner.ownerDiscordId == discordUserId
        }
    }

    func minerForAccount(_ accountId: String) -> MinerManager.ManagedMiner? {
        minerManager.miners.first { $0.accountId == accountId }
    }
}

// MARK: - Supporting Models
