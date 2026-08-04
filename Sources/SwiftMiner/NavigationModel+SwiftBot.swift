// SwiftBot connectivity, pairing, and projection-push integration for
// NavigationModel. Split from NavigationModel.swift; same class, same
// @MainActor isolation.
import SwiftUI
import SwiftMinerCore
import SwiftMinerService

extension NavigationModel {
    // MARK: - SwiftBot Integration

    /// Trigger a SwiftBot connectivity check and update local state.
    public func checkSwiftBotConnection() async {
        guard Settings.shared.swiftBotEnabled else {
            self.swiftBotState = .notConfigured
            return
        }
        let newState = await swiftBotConnectionService.checkHealth()
        self.swiftBotState = newState
    }

    /// Update the SwiftBot endpoint and refresh connectivity.
    public func updateSwiftBotEndpoint(_ urlString: String) async {
        guard Settings.shared.swiftBotEnabled else { return }
        await swiftBotConnectionService.updateEndpoint(urlString)
        await checkSwiftBotConnection()
    }

    /// Refresh webhook delivery settings after the user edits the SwiftBot callback URL or HMAC secret.
    public func updateSwiftBotWebhookConfig() async {
        await eventOutboxService.updateConfig(
            webhookURL: URL(string: Settings.shared.swiftBotWebhookURL),
            hmacSecret: Settings.shared.swiftBotHmacSecret
        )
        if Settings.shared.swiftBotEnabled {
            await eventOutboxService.start()
        }
    }

    /// Dismiss the account-link ("needs linking") warning for a game across all
    /// of the requesting Discord user's miners — the same state the GUI dismiss
    /// sets, so it both stops future DMs and clears the GUI warning.
    /// Returns true when at least one owned miner was updated.
    public func handleDiscordIgnoreLinkWarning(discordUserId: String, gameName: String) async -> Bool {
        let owned = minerManager.miners.filter { $0.ownerDiscordId == discordUserId }
        guard !owned.isEmpty else { return false }

        // Prefer a real game id resolved from loaded campaigns; fall back to the
        // lowercased name (the engine suppresses by either id or lowercased name).
        let gameKey = accountLinkWarningGameKey(for: gameName)

        for miner in owned {
            await minerManager.setAccountLinkWarningIgnored(minerId: miner.id, gameId: gameKey, ignored: true)
            Settings.shared.setIgnoreAccountLinkWarnings(true, for: miner.accountId, gameId: gameKey)
        }
        return true
    }

    public func handleDiscordPauseLinkWarning(discordUserId: String, gameName: String, expiresAt: Date) async -> Bool {
        let owned = minerManager.miners.filter { $0.ownerDiscordId == discordUserId }
        guard !owned.isEmpty else { return false }

        let gameKey = accountLinkWarningGameKey(for: gameName)
        for miner in owned {
            await minerManager.setAccountLinkWarningIgnored(minerId: miner.id, gameId: gameKey, ignored: true)
            Settings.shared.setTemporaryIgnoreWarning(
                until: expiresAt,
                accountId: miner.accountId,
                gameId: gameKey,
                type: .accountLink
            )
        }
        return true
    }

    public func handleDiscordPrioritiseGame(discordUserId: String, accountId: String, gameName: String) async -> [String]? {
        guard let miner = minerManager.miners.first(where: { $0.ownerDiscordId == discordUserId && $0.accountId == accountId }) else {
            return nil
        }
        let previous = Settings.shared.personalPriorityGames(forAccountId: accountId)
        let previousSource = Settings.shared.prioritySource(forAccountId: accountId)
        let priorities = Settings.shared.prioritiseGameForAccount(accountId: accountId, gameName: gameName)
        auditPriorityChange(
            actor: miner.username,
            old: previous,
            new: Settings.shared.personalPriorityGames(forAccountId: accountId),
            oldSource: previousSource,
            newSource: Settings.shared.prioritySource(forAccountId: accountId)
        )
        minerManager.updatePriorityGames(priorities, forMinerId: miner.id)
        if miner.isRunning {
            await minerManager.forceRefreshMiner(minerId: miner.id)
        }
        return priorities
    }

    /// Replace a miner's personal priority games with `games` (the Discord "edit games"
    /// modal submits the whole personal list at once). Returns the resulting effective list.
    public func handleDiscordSetPriorities(
        discordUserId: String,
        accountId: String,
        games: [String],
        includeGlobalPriorities: Bool? = nil,
        prioritySource: String? = nil
    ) async -> [String]? {
        guard let miner = minerManager.miners.first(where: { $0.ownerDiscordId == discordUserId && $0.accountId == accountId }) else {
            return nil
        }
        let previous = Settings.shared.personalPriorityGames(forAccountId: accountId)
        let previousSource = Settings.shared.prioritySource(forAccountId: accountId)
        if let prioritySource,
           let source = Settings.AccountPrioritySource(rawValue: prioritySource) {
            Settings.shared.setPrioritySource(source, forAccountId: accountId)
        } else if let includeGlobalPriorities {
            Settings.shared.setIncludesGlobalPriorityGames(includeGlobalPriorities, forAccountId: accountId)
        }
        let priorities: [String]
        if Settings.shared.prioritySource(forAccountId: accountId) == .global {
            priorities = Settings.shared.priorityGames(forAccountId: accountId)
        } else {
            priorities = Settings.shared.setPersonalPriorityGames(accountId: accountId, games: games)
        }
        auditPriorityChange(
            actor: miner.username,
            old: previous,
            new: Settings.shared.personalPriorityGames(forAccountId: accountId),
            oldSource: previousSource,
            newSource: Settings.shared.prioritySource(forAccountId: accountId)
        )
        minerManager.updatePriorityGames(priorities, forMinerId: miner.id)
        if miner.isRunning {
            await minerManager.forceRefreshMiner(minerId: miner.id)
        }
        return priorities
    }

    /// As above, but identified by Twitch account id alone — used by a
    /// Twitch-authenticated web session, whose principal *is* the account.
    public func handleSetPrioritiesByAccount(
        accountId: String,
        games: [String],
        includeGlobalPriorities: Bool? = nil,
        prioritySource: String? = nil
    ) async -> [String]? {
        guard let miner = minerManager.miners.first(where: { $0.accountId == accountId }) else {
            return nil
        }
        let previous = Settings.shared.personalPriorityGames(forAccountId: accountId)
        let previousSource = Settings.shared.prioritySource(forAccountId: accountId)
        if let prioritySource,
           let source = Settings.AccountPrioritySource(rawValue: prioritySource) {
            Settings.shared.setPrioritySource(source, forAccountId: accountId)
        } else if let includeGlobalPriorities {
            Settings.shared.setIncludesGlobalPriorityGames(includeGlobalPriorities, forAccountId: accountId)
        }
        let priorities: [String]
        if Settings.shared.prioritySource(forAccountId: accountId) == .global {
            priorities = Settings.shared.priorityGames(forAccountId: accountId)
        } else {
            priorities = Settings.shared.setPersonalPriorityGames(accountId: accountId, games: games)
        }
        auditPriorityChange(
            actor: miner.username,
            old: previous,
            new: Settings.shared.personalPriorityGames(forAccountId: accountId),
            oldSource: previousSource,
            newSource: Settings.shared.prioritySource(forAccountId: accountId)
        )
        minerManager.updatePriorityGames(priorities, forMinerId: miner.id)
        if miner.isRunning {
            await minerManager.forceRefreshMiner(minerId: miner.id)
        }
        return priorities
    }

    func accountLinkWarningGameKey(for gameName: String) -> String {
        let target = gameName.lowercased()
        return minerManager.campaignStore.campaigns
            .first(where: { $0.game.name.lowercased() == target })?.game.id ?? target
    }

    public func handleDiscordMinerControl(discordUserId: String, action: MinerControlAction) async -> MinerControlResponse {
        guard let miner = minerManager.miners.first(where: { $0.ownerDiscordId == discordUserId }) else {
            return MinerControlResponse(
                ok: false,
                action: action.rawValue,
                state: "not_linked",
                twitchUsername: nil,
                message: "No linked Twitch account was found for this Discord user."
            )
        }

        switch action {
        case .status:
            return MinerControlResponse(
                ok: true,
                action: action.rawValue,
                state: miner.status.rawValue,
                twitchUsername: miner.username,
                message: miner.statusLabel
            )
        case .pause:
            await minerManager.stopMiner(minerId: miner.id)
            return MinerControlResponse(
                ok: true,
                action: action.rawValue,
                state: "PAUSED",
                twitchUsername: miner.username,
                message: "Miner paused for \(miner.displayName)."
            )
        case .resume:
            do {
                let settings = Settings.shared
                try await minerManager.startMiner(
                    minerId: miner.id,
                    priorityGames: priorityGames(for: miner),
                    excludedGames: settings.excludedGames,
                    strategy: settings.miningStrategy,
                    enableBadgesEmotes: settings.enableBadgesEmotes,
                    showClaimNotifications: settings.showClaimNotifications && settings.allowsOperatorNotifications(),
                    avoidDuplicateStreams: settings.avoidDuplicateStreams,
                    antiStallRecoveryEnabled: settings.antiStallRecoveryEnabled,
                    prioritiseFollowedStreamers: settings.prioritiseFollowedStreamers,
                    failoverStreamers: settings.gameFailoverStreamers
                )
                return MinerControlResponse(
                    ok: true,
                    action: action.rawValue,
                    state: "RESUMING",
                    twitchUsername: miner.username,
                    message: "Miner resume requested for \(miner.displayName)."
                )
            } catch {
                return MinerControlResponse(
                    ok: false,
                    action: action.rawValue,
                    state: "ERROR",
                    twitchUsername: miner.username,
                    message: error.localizedDescription
                )
            }
        case .refresh:
            await minerManager.forceRefreshMiner(minerId: miner.id)
            return MinerControlResponse(
                ok: true,
                action: action.rawValue,
                state: miner.status.rawValue,
                twitchUsername: miner.username,
                message: "Miner refresh requested for \(miner.displayName)."
            )
        }
    }

    public func handleAccountMinerControl(accountId: String, action: MinerControlAction) async -> MinerControlResponse {
        guard let miner = minerManager.miners.first(where: { $0.accountId == accountId }) else {
            return MinerControlResponse(
                ok: false,
                action: action.rawValue,
                state: "not_found",
                twitchUsername: nil,
                message: "No miner was found for this Twitch account."
            )
        }

        switch action {
        case .status:
            return MinerControlResponse(
                ok: true,
                action: action.rawValue,
                state: miner.status.rawValue,
                twitchUsername: miner.username,
                message: miner.statusLabel
            )
        case .pause:
            await minerManager.stopMiner(minerId: miner.id)
            return MinerControlResponse(
                ok: true,
                action: action.rawValue,
                state: "PAUSED",
                twitchUsername: miner.username,
                message: "Miner paused for \(miner.displayName)."
            )
        case .resume:
            do {
                let settings = Settings.shared
                try await minerManager.startMiner(
                    minerId: miner.id,
                    priorityGames: priorityGames(for: miner),
                    excludedGames: settings.excludedGames,
                    strategy: settings.miningStrategy,
                    enableBadgesEmotes: settings.enableBadgesEmotes,
                    showClaimNotifications: settings.showClaimNotifications && settings.allowsOperatorNotifications(),
                    avoidDuplicateStreams: settings.avoidDuplicateStreams,
                    antiStallRecoveryEnabled: settings.antiStallRecoveryEnabled,
                    prioritiseFollowedStreamers: settings.prioritiseFollowedStreamers,
                    failoverStreamers: settings.gameFailoverStreamers
                )
                return MinerControlResponse(
                    ok: true,
                    action: action.rawValue,
                    state: "RESUMING",
                    twitchUsername: miner.username,
                    message: "Miner resume requested for \(miner.displayName)."
                )
            } catch {
                return MinerControlResponse(
                    ok: false,
                    action: action.rawValue,
                    state: "ERROR",
                    twitchUsername: miner.username,
                    message: error.localizedDescription
                )
            }
        case .refresh:
            await minerManager.forceRefreshMiner(minerId: miner.id)
            return MinerControlResponse(
                ok: true,
                action: action.rawValue,
                state: miner.status.rawValue,
                twitchUsername: miner.username,
                message: "Miner refresh requested for \(miner.displayName)."
            )
        }
    }

    public func priorityGames(for miner: MinerManager.ManagedMiner) -> [String] {
        Settings.shared.priorityGames(forAccountId: miner.accountId)
    }

    static func webCampaignSummary(from campaign: Campaign) -> WebCampaignSummary {
        let subscriptionRequiredDrops = campaign.subscriptionRequiredDrops
        return WebCampaignSummary(
            campaignId: campaign.id,
            campaignName: campaign.name,
            game: campaign.game.name,
            status: campaign.isTimeActive ? "available" : "upcoming",
            startsAt: campaign.startDate,
            endsAt: campaign.endDate,
            dropCount: campaign.drops.count,
            claimedDrops: campaign.drops.filter(\.isClaimed).count,
            subscriptionRequiredDropCount: subscriptionRequiredDrops.count,
            requiresSubscription: !subscriptionRequiredDrops.isEmpty && campaign.eligibleDrops.isEmpty,
            boxArtURL: campaign.game.boxArtURL?.absoluteString
        )
    }

    static func normalizedGameKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func startSwiftBotStateSync() {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
                guard Settings.shared.swiftBotEnabled else { continue }
                let newState = await swiftBotConnectionService.checkHealth()
                await MainActor.run {
                    self.swiftBotState = newState
                }
            }
        }
    }

    /// Start/stop the resource-usage diagnostic to match the current setting.
    /// Called at launch and whenever the Advanced toggle changes.
    func startResourceUsageMonitoringIfEnabled() {
        setResourceUsageMonitoring(enabled: Settings.shared.monitorResourceUsage)
    }

    func setResourceUsageMonitoring(enabled: Bool) {
        if enabled {
            resourceUsageMonitor.start()
        } else {
            resourceUsageMonitor.stop()
        }
    }
}
