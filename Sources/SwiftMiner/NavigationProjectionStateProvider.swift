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
                miner: miner,
                currentChannelName: summary?.currentChannelName,
                currentChannelId: summary?.currentChannelId
            )
        }
    }

    func recentCompletedCampaigns(
        for discordUserId: String,
        limit: Int
    ) async -> [DiscordUserProjection.RecentCampaign] {
        let accountId = await MainActor.run {
            model?.minerForDiscordUser(discordUserId)?.accountId
        }
        guard let accountId else { return [] }
        return await completedCampaigns(forAccountId: accountId, limit: limit)
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

    func priorityGameArtwork(for discordUserId: String) async -> [String: String] {
        let accountId = await MainActor.run {
            model?.minerForDiscordUser(discordUserId)?.accountId
        }
        guard let accountId else { return [:] }
        return await resolvedPriorityGameArtwork(forAccountId: accountId)
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

    func prioritySource(for discordUserId: String) async -> String {
        await MainActor.run {
            guard let model, let miner = model.minerForDiscordUser(discordUserId) else { return "global" }
            return Settings.shared.prioritySource(forAccountId: miner.accountId).rawValue
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
                miner: miner,
                currentChannelName: summary?.currentChannelName,
                currentChannelId: summary?.currentChannelId
            )
        }
    }

    func recentCompletedCampaigns(forTwitchAccount accountId: String, limit: Int) async -> [DiscordUserProjection.RecentCampaign] {
        await completedCampaigns(forAccountId: accountId, limit: limit)
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

    func priorityGameArtwork(forTwitchAccount accountId: String) async -> [String: String] {
        await resolvedPriorityGameArtwork(forAccountId: accountId)
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

    func prioritySource(forTwitchAccount accountId: String) async -> String {
        await MainActor.run {
            guard let model, model.minerForAccount(accountId) != nil else { return "global" }
            return Settings.shared.prioritySource(forAccountId: accountId).rawValue
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

    @MainActor
    private static func priorityGameArtwork(for miner: MinerManager.ManagedMiner) -> [String: String] {
        var artworkByGame = [String: String]()

        func addArtwork(_ url: URL?, for gameName: String) {
            let key = gameName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty,
                  let url,
                  url.scheme?.lowercased() == "https" else { return }
            artworkByGame[key] = url.absoluteString
        }

        for preference in Settings.shared.gamePreferences where preference.state == .preferred {
            addArtwork(preference.resolvedBoxArtURL, for: preference.gameName)
        }
        for campaign in miner.allCampaigns {
            let key = campaign.game.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if artworkByGame[key] == nil {
                addArtwork(campaign.game.boxArtURL, for: campaign.game.name)
            }
        }
        return artworkByGame
    }

    /// Older preferences stored only a display name. Fill those gaps from Twitch's
    /// category search once, then persist the canonical box art with the existing
    /// preference so dashboard refreshes never have to infer a CDN URL from a name.
    private func resolvedPriorityGameArtwork(forAccountId accountId: String) async -> [String: String] {
        let snapshot = await MainActor.run { priorityArtworkSnapshot(forAccountId: accountId) }
        guard !snapshot.unresolvedGames.isEmpty else { return snapshot.artwork }

        for gameName in snapshot.unresolvedGames {
            guard let match = await matchingTwitchCategory(for: gameName) else { continue }
            await MainActor.run {
                persistArtwork(match, forPreferredGameNamed: gameName)
            }
        }

        return await MainActor.run {
            priorityArtworkSnapshot(forAccountId: accountId).artwork
        }
    }

    @MainActor
    private func priorityArtworkSnapshot(forAccountId accountId: String) -> (
        artwork: [String: String],
        unresolvedGames: [String]
    ) {
        guard let model, let miner = model.minerForAccount(accountId) else { return ([:], []) }
        let artwork = Self.priorityGameArtwork(for: miner)
        let preferredNames = Set(
            Settings.shared.gamePreferences
                .filter { $0.state == .preferred }
                .map { Self.normalizedGameName($0.gameName) }
        )
        let unresolvedGames = model.priorityGames(for: miner).filter { gameName in
            let normalized = Self.normalizedGameName(gameName)
            let artworkKey = gameName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !normalized.isEmpty && preferredNames.contains(normalized) && artwork[artworkKey] == nil
        }
        return (artwork, unresolvedGames)
    }

    @MainActor
    private func matchingTwitchCategory(for gameName: String) async -> Game? {
        guard let model else { return nil }
        guard let categories = try? await model.minerManager.dataCoordinator.searchCategories(query: gameName) else {
            return nil
        }
        let requested = Self.normalizedGameName(gameName)
        return categories.first { Self.normalizedGameName($0.name) == requested }
    }

    @MainActor
    private func persistArtwork(_ game: Game, forPreferredGameNamed gameName: String) {
        guard game.boxArtURL?.scheme?.lowercased() == "https" else { return }
        let requested = Self.normalizedGameName(gameName)
        guard Settings.shared.gamePreferences.contains(where: {
            $0.state == .preferred && Self.normalizedGameName($0.gameName) == requested
        }) else { return }

        // Preserve the user's displayed priority name while adding Twitch's ID and
        // durable artwork URL to the existing preference.
        Settings.shared.setGamePreference(
            Game(id: game.id, name: gameName, boxArtURL: game.boxArtURL),
            state: .preferred
        )
    }

    private static func normalizedGameName(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
            .lowercased()
    }

    // Progress must come from the same reconciliation the native GUI uses:
    // Twitch's inventory payload alone (`drop.progress`) is absent for drops the
    // API isn't currently reporting, so the web showed 0 for minutes the miner's
    // persisted ledger already knows about.
    @MainActor
    private static func activeCampaignProjection(
        from campaign: Campaign,
        miner: MinerManager.ManagedMiner,
        currentChannelName: String? = nil,
        currentChannelId: String? = nil
    ) -> DiscordUserProjection.ActiveCampaign {
        let aggregate = MinerOperatorPresentation.aggregateProgress(for: campaign, miner: miner)
        let totalRequired = aggregate?.requiredMinutes ?? 0
        let totalCurrent = aggregate?.currentMinutes ?? 0
        let pct = aggregate?.percent ?? 0
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

    /// Mirrors the native Drops > Completed filter, including completed campaigns
    /// outside the normal curated mining feed, then groups them by game.
    @MainActor
    private func completedCampaigns(
        forAccountId accountId: String,
        limit: Int
    ) async -> [DiscordUserProjection.RecentCampaign] {
        guard let model, model.minerForAccount(accountId) != nil else { return [] }
        let campaigns = await model.minerManager.dataCoordinator.allCampaigns(
            preferSteamArtwork: Settings.shared.preferSteamArtwork
        )
        let now = Date()
        let excludedGames = Settings.shared.excludedGames
        let completed = campaigns.filter {
            // This is the same completion predicate the native Drops filter
            // uses. Some campaigns (such as THE FINALS) reach complete reward
            // progress while their raw inventory flag still lags behind.
            Self.shouldIncludeInCompletedCampaigns($0, excludedGames: excludedGames)
                && !$0.isExpired(now: now)
                && ($0.combinedProgressFraction >= 0.995 || $0.isCompleted)
        }
        return GameAggregateBuilder.buildDrops(from: completed, now: now)
            .sorted {
                $0.gameName.localizedCaseInsensitiveCompare($1.gameName) == .orderedAscending
            }
            .compactMap { $0.campaigns.first?.campaign }
            .prefix(max(limit, 0))
            .map(Self.recentCampaignProjection)
    }

    /// Completed-drop history must be backed by an actual successful claim.
    /// A campaign with completed watch progress but no claim is still pending
    /// work, and should not appear as a completion in the web dashboard.
    ///
    /// A user's exclusions remain authoritative, but claimed campaigns are
    /// intentionally not limited to the normal curated mining feed.
    @MainActor
    static func shouldIncludeInCompletedCampaigns(
        _ campaign: CampaignViewData,
        excludedGames: [String]
    ) -> Bool {
        guard campaign.dropsClaimed > 0 else { return false }

        return !excludedGames.contains { excludedGame in
            excludedGame.localizedCaseInsensitiveCompare(campaign.gameName) == .orderedSame
                || excludedGame.localizedCaseInsensitiveCompare(campaign.gameId ?? "") == .orderedSame
        }
    }

    private static func recentCampaignProjection(from campaign: CampaignViewData) -> DiscordUserProjection.RecentCampaign {
        DiscordUserProjection.RecentCampaign(
            campaignId: campaign.id,
            campaignName: campaign.campaignName,
            game: campaign.gameName,
            completedAt: nil,
            claimedDrops: campaign.dropsClaimed,
            totalDrops: campaign.totalDrops,
            boxArtURL: campaign.artworkURL?.absoluteString
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
